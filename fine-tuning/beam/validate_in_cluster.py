#!/usr/bin/env python3
"""CPU-only validation of the Beam LoRA recipe.

Runs inside a pod built from the training image, with no GPU and without
downloading any weights. It checks the two things that would otherwise only
surface deep into a multi-node run:

  1. LORA_TARGET_REGEX actually resolves against the real checkpoint's
     parameter names — including reaching both the dense MLP layers (0-2) and
     the MoE expert layers (3-51). A regex that matches nothing yields a
     training run that completes successfully and learns nothing.
  2. The dataset renders through Beam's Harmony chat template with the
     analysis channel intact, using the exact formatter train.py will use.

Only two small files leave the network: model.safetensors.index.json (~14MB,
the parameter-name map) and the tokenizer.
"""

import json
import os
import re
import sys

sys.path.insert(0, "/workspace")

MODEL_ID = os.environ.get("MODEL_ID", "reflection/Beam-1.0-501B-A23B")
DATASET_NAME = os.environ.get("DATASET_NAME", "HuggingFaceH4/Multilingual-Thinking")
DATASET_SPLIT = os.environ.get("DATASET_SPLIT", "train")
LORA_TARGET_REGEX = os.environ.get(
    "LORA_TARGET_REGEX",
    r".*(self_attn\.(q|k|v|o|gate)_proj|layers\.[0-2]\.mlp\.(gate|up|down)_proj)$",
)

passed = 0
failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  PASS  {msg}", flush=True)


def bad(msg):
    global failed
    failed += 1
    print(f"  FAIL  {msg}", flush=True)


# ---------------------------------------------------------------------------
# 1. LoRA target resolution against the real parameter names
# ---------------------------------------------------------------------------
print("\n=== LoRA target modules ===", flush=True)

try:
    from huggingface_hub import hf_hub_download

    index_path = hf_hub_download(MODEL_ID, "model.safetensors.index.json")
    with open(index_path) as fh:
        weight_map = json.load(fh)["weight_map"]

    # Parameter names look like model.layers.7.self_attn.q_proj.weight; PEFT
    # matches target_modules against the *module* path, so strip the trailing
    # parameter name.
    modules = sorted({k.rsplit(".", 1)[0] for k in weight_map})
    ok(f"checkpoint index lists {len(weight_map):,} tensors across {len(modules):,} modules")

    pattern = re.compile(LORA_TARGET_REGEX)
    matched = [m for m in modules if pattern.match(m)]

    if matched:
        ok(f"LORA_TARGET_REGEX matches {len(matched):,} modules")
    else:
        bad(f"LORA_TARGET_REGEX matched 0 modules — training would learn nothing")

    def layer_of(name):
        m = re.search(r"\.layers\.(\d+)\.", name)
        return int(m.group(1)) if m else None

    matched_layers = {layer_of(m) for m in matched} - {None}
    # Beam is 52 layers: 0-2 dense, 3-51 MoE.
    dense_hit = bool(matched_layers & {0, 1, 2})
    moe_hit = bool(matched_layers - {0, 1, 2})

    if dense_hit:
        ok("reaches the dense MLP layers (0-2)")
    else:
        bad("no dense-layer modules matched (layers 0-2)")

    if moe_hit:
        ok(f"reaches the MoE layers ({len(matched_layers - {0, 1, 2})} of layers 3-51)")
    else:
        bad("no MoE-layer modules matched (layers 3-51)")

    # The router decides which experts a token goes to. Adapting it
    # destabilises routing, and it is easy to hit by accident with a loose
    # pattern, so treat it as an error rather than a note.
    routers = [m for m in matched if m.endswith("mlp.gate")]
    if routers:
        bad(f"{len(routers)} MoE router module(s) targeted — exclude `mlp.gate`")
    else:
        ok("MoE router (mlp.gate) correctly excluded")

    non_adaptable = [m for m in matched if "norm" in m or "embed" in m or m == "lm_head"]
    if non_adaptable:
        bad(f"{len(non_adaptable)} norm/embedding module(s) targeted")
    else:
        ok("norms and embeddings correctly excluded")

    # Beam has 37,632 expert projections (49 MoE layers x 256 experts x 3).
    # Sweeping them all in is the single easiest mistake to make here — a
    # pattern like `.*down_proj$` does it silently — and the result is an
    # adapter two orders of magnitude larger than intended.
    expert_modules = [m for m in matched if ".experts." in m]
    if not matched:
        pass  # already reported as a failure above; the note below would be noise
    elif expert_modules:
        print(
            f"  NOTE  {len(expert_modules):,} expert projections targeted. This is "
            "Reflection's fuller recipe and is far more expensive than adapting "
            "attention alone — confirm it is what you meant.",
            flush=True,
        )
    else:
        print(
            f"  NOTE  experts not targeted; adapting attention + dense MLP only "
            f"({len(matched)} modules). Cheaper than Reflection's recipe, which "
            "also adapts experts.",
            flush=True,
        )

    print("\n  sample matched modules:", flush=True)
    for m in matched[:5]:
        print(f"    {m}", flush=True)

except Exception as exc:  # noqa: BLE001 - surface anything as a validation failure
    bad(f"could not resolve LoRA targets: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# 2. Harmony formatting of the real dataset, through train.py's own formatter
# ---------------------------------------------------------------------------
print("\n=== Harmony data formatting ===", flush=True)

try:
    from datasets import load_dataset
    from transformers import AutoTokenizer

    from train import build_formatter, normalise_example

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    ok(f"loaded tokenizer ({len(tokenizer):,} vocab)")

    dataset = load_dataset(DATASET_NAME, split=f"{DATASET_SPLIT}[:8]")
    ok(f"loaded {len(dataset)} sample rows from {DATASET_NAME}")

    formatter = build_formatter(tokenizer, preserve_thinking=True)

    rendered = []
    for row in dataset:
        normalise_example(row)  # raises if the row shape is unsupported
        rendered.append(formatter(row))
    ok(f"all {len(rendered)} rows rendered through the chat template")

    sample = rendered[0]

    # Harmony framing must be present, or we are training on plain text and
    # the adapter will not match what the serving stack parses.
    if "<|channel|>" in sample or "<|start|>" in sample:
        ok("rendered text carries Harmony control tokens")
    else:
        bad("rendered text has no Harmony framing — wrong chat template?")

    if "analysis" in sample:
        ok("analysis channel present (preserve_thinking is taking effect)")
    else:
        print(
            "  NOTE  no analysis channel in the first row — expected if the "
            "dataset has no reasoning traces; the adapter will train on "
            "final-channel text only",
            flush=True,
        )

    lengths = [len(tokenizer(r).input_ids) for r in rendered]
    ok(f"token lengths: min={min(lengths)} median={sorted(lengths)[len(lengths) // 2]} max={max(lengths)}")

    max_seq = int(os.environ.get("MAX_SEQ_LENGTH", "4096"))
    over = sum(1 for n in lengths if n > max_seq)
    if over:
        print(
            f"  NOTE  {over}/{len(lengths)} sample rows exceed MAX_SEQ_LENGTH="
            f"{max_seq} and will be truncated or packed across boundaries",
            flush=True,
        )

    print("\n  first 400 chars of a rendered example:", flush=True)
    print("  " + sample[:400].replace("\n", "\n  "), flush=True)

except Exception as exc:  # noqa: BLE001
    bad(f"data pipeline failed: {type(exc).__name__}: {exc}")


print(f"\n=== in-cluster checks: {passed} passed, {failed} failed ===", flush=True)
sys.exit(1 if failed else 0)
