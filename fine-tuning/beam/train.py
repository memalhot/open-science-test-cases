#!/usr/bin/env python3
"""LoRA supervised fine-tuning for Reflection Beam 1.0 (501B-A23B).

Launched by torchrun under a Kubeflow TrainJob; every knob comes from an
environment variable so the TrainJob template stays the only place parameters
are declared.

Beam is a 501B-total / 23.4B-active sparse MoE, which forces two departures
from the usual single-GPU PEFT script in this repo:

  * The base weights (1003GB in BF16) do not fit on one node, so the model is
    sharded at load time with tensor + expert parallelism across the whole
    world via transformers' DistributedConfig. There is no "load then
    .to(device)" step — materialising the full model on one rank is exactly
    what we cannot do.
  * Training data has to be rendered through Beam's Harmony chat template,
    including the analysis channel, or the adapter learns to answer in a
    format the serving stack will then strip.

The formatting half of this file is deliberately importable and free of any
CUDA or distributed dependency, so validate.sh can exercise it on a laptop
with nothing but the tokenizer.
"""

import json
import os
import sys

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def _str(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _int(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


def _float(name: str, default: float) -> float:
    return float(os.environ.get(name, default))


def _bool(name: str, default: bool) -> bool:
    return os.environ.get(name, str(default)).strip().lower() in ("1", "true", "yes")


# The BF16 checkpoint, not the NVFP4 serving one: LoRA needs full-precision
# base weights to compute meaningful gradients through the frozen layers.
MODEL_ID = _str("MODEL_ID", "reflection/Beam-1.0-501B-A23B")
MODEL_PATH = _str("MODEL_PATH", "")  # local dir wins over the hub id when set
DATASET_NAME = _str("DATASET_NAME", "HuggingFaceH4/Multilingual-Thinking")
DATASET_SPLIT = _str("DATASET_SPLIT", "train")
OUTPUT_DIR = _str("OUTPUT_DIR", "/output/beam-lora")

NUM_EPOCHS = _float("NUM_EPOCHS", 1.0)
LEARNING_RATE = _float("LEARNING_RATE", 1e-4)
BATCH_SIZE = _int("BATCH_SIZE", 1)
GRAD_ACCUM = _int("GRAD_ACCUM", 8)
MAX_SEQ_LENGTH = _int("MAX_SEQ_LENGTH", 4096)
LORA_RANK = _int("LORA_RANK", 16)
LORA_ALPHA = _int("LORA_ALPHA", 32)
LORA_DROPOUT = _float("LORA_DROPOUT", 0.0)
PACKING = _bool("PACKING", True)
GRAD_CHECKPOINTING = _bool("GRAD_CHECKPOINTING", True)
LOGGING_STEPS = _int("LOGGING_STEPS", 5)
SAVE_STEPS = _int("SAVE_STEPS", 100)
SEED = _int("SEED", 42)

# Which projections the adapter attaches to, as a regex matched against the
# checkpoint's real module paths. Beam's layout (verified against
# model.safetensors.index.json) is:
#
#   model.layers.{0..51}.self_attn.{q,k,v,o,gate}_proj   260 modules
#   model.layers.{0..2}.mlp.{gate,up,down}_proj            9 modules  (dense)
#   model.layers.{3..51}.mlp.experts.{0..255}.{g,u,d}  37,632 modules  (MoE)
#   model.layers.{3..51}.mlp.gate                         49 modules  (router)
#
# The default targets attention plus the three dense MLP layers — 269 modules.
# A naive `.*(q_proj|...|down_proj)$` instead sweeps in all 37,632 expert
# projections, producing an adapter two orders of magnitude larger than
# intended. To adapt the experts as well (closer to Reflection's own recipe,
# and far more expensive) use:
#
#   .*(self_attn\.(q|k|v|o|gate)_proj|mlp\.(experts\.\d+\.)?(gate|up|down)_proj)$
#
# The router (`mlp.gate`) is deliberately excluded: adapting the thing that
# chooses experts destabilises routing.
#
# Run validate.sh to confirm whatever you set actually resolves, before
# burning a multi-node allocation on a run that would train zero parameters.
LORA_TARGET_REGEX = _str(
    "LORA_TARGET_REGEX",
    r".*(self_attn\.(q|k|v|o|gate)_proj|layers\.[0-2]\.mlp\.(gate|up|down)_proj)$",
)

# Keep the analysis channel in the training signal. Beam is a reasoning model;
# training only on final-channel text teaches it to skip the reasoning it was
# post-trained to do.
PRESERVE_THINKING = _bool("PRESERVE_THINKING", True)


# --------------------------------------------------------------------------
# Data formatting (importable, CPU-only)
# --------------------------------------------------------------------------

def normalise_example(example: dict) -> list[dict]:
    """Coerce one dataset row into a list of chat messages.

    Accepts the two shapes we actually encounter: a conversational dataset with
    a `messages` column, and an instruction dataset with prompt/response
    columns. Anything else should fail loudly here rather than silently train
    on an empty string.
    """
    if "messages" in example and example["messages"]:
        return list(example["messages"])

    if "conversations" in example and example["conversations"]:
        role_map = {"human": "user", "gpt": "assistant", "system": "system"}
        return [
            {"role": role_map.get(m.get("from"), m.get("from")), "content": m.get("value", "")}
            for m in example["conversations"]
        ]

    for prompt_key in ("prompt", "instruction", "question"):
        for answer_key in ("completion", "response", "output", "answer"):
            if example.get(prompt_key) and example.get(answer_key):
                msgs = []
                if example.get("system"):
                    msgs.append({"role": "system", "content": example["system"]})
                msgs.append({"role": "user", "content": example[prompt_key]})
                msgs.append({"role": "assistant", "content": example[answer_key]})
                return msgs

    raise ValueError(
        f"cannot derive chat messages from row with keys {sorted(example)}; "
        "set DATASET_NAME to a conversational dataset or extend normalise_example()"
    )


def build_formatter(tokenizer, preserve_thinking: bool = True):
    """Return a TRL formatting_func that renders rows via Beam's Harmony template."""

    def format_example(example: dict) -> str:
        messages = normalise_example(example)
        kwargs = {}
        # Older tokenizer builds don't take this kwarg; losing the reasoning is
        # a quality regression, not a crash, so degrade rather than fail.
        if preserve_thinking:
            kwargs["preserve_thinking"] = True
        try:
            return tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=False, **kwargs
            )
        except TypeError:
            return tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=False
            )

    return format_example


# --------------------------------------------------------------------------
# Training
# --------------------------------------------------------------------------

def main() -> int:
    import torch
    from datasets import load_dataset
    from peft import LoraConfig
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from transformers.distributed import DistributedConfig
    from trl import SFTConfig, SFTTrainer

    world_size = int(os.environ.get("WORLD_SIZE", "1"))
    rank = int(os.environ.get("RANK", "0"))
    source = MODEL_PATH or MODEL_ID

    def log(msg: str) -> None:
        if rank == 0:
            print(f"[train] {msg}", flush=True)

    log(f"model            : {source}")
    log(f"world size       : {world_size}")
    log(f"dataset          : {DATASET_NAME} [{DATASET_SPLIT}]")
    log(f"lora             : r={LORA_RANK} alpha={LORA_ALPHA} targets={LORA_TARGET_REGEX}")
    log(f"seq len / packing: {MAX_SEQ_LENGTH} / {PACKING}")

    tokenizer = AutoTokenizer.from_pretrained(source)

    # Shard at load time. tp_size/ep_size = world_size means every rank holds a
    # slice of both the attention tensors and the 256 experts; tp_plan={} lets
    # transformers derive the plan from the architecture rather than us
    # hand-writing one.
    log("loading base weights (sharded; this is the slow part)")
    model = AutoModelForCausalLM.from_pretrained(
        source,
        dtype=torch.bfloat16,
        distributed_config=DistributedConfig(
            tp_size=world_size,
            ep_size=world_size,
            tp_plan={},
        ),
    )
    model.config.use_cache = False

    peft_config = LoraConfig(
        r=LORA_RANK,
        lora_alpha=LORA_ALPHA,
        lora_dropout=LORA_DROPOUT,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=LORA_TARGET_REGEX,
    )

    dataset = load_dataset(DATASET_NAME, split=DATASET_SPLIT)
    log(f"dataset rows     : {len(dataset)}")

    args = SFTConfig(
        output_dir=OUTPUT_DIR,
        num_train_epochs=NUM_EPOCHS,
        learning_rate=LEARNING_RATE,
        per_device_train_batch_size=BATCH_SIZE,
        gradient_accumulation_steps=GRAD_ACCUM,
        gradient_checkpointing=GRAD_CHECKPOINTING,
        max_length=MAX_SEQ_LENGTH,
        packing=PACKING,
        bf16=True,
        logging_steps=LOGGING_STEPS,
        save_steps=SAVE_STEPS,
        save_strategy="steps",
        report_to=[],
        seed=SEED,
    )

    trainer = SFTTrainer(
        model=model,
        args=args,
        train_dataset=dataset,
        peft_config=peft_config,
        formatting_func=build_formatter(tokenizer, PRESERVE_THINKING),
    )

    trainable = sum(p.numel() for p in trainer.model.parameters() if p.requires_grad)
    log(f"trainable params : {trainable:,}")
    if trainable == 0:
        # The usual cause is LORA_TARGET_REGEX matching nothing — which
        # otherwise produces a run that completes successfully and changes
        # nothing at all.
        log("FATAL: no trainable parameters — LORA_TARGET_REGEX matched no modules")
        return 1

    trainer.train()

    log(f"saving adapter to {OUTPUT_DIR}")
    trainer.save_model(OUTPUT_DIR)
    if rank == 0:
        tokenizer.save_pretrained(OUTPUT_DIR)
        with open(os.path.join(OUTPUT_DIR, "training-run.json"), "w") as fh:
            json.dump(
                {
                    "base_model": source,
                    "dataset": DATASET_NAME,
                    "epochs": NUM_EPOCHS,
                    "learning_rate": LEARNING_RATE,
                    "lora_rank": LORA_RANK,
                    "lora_alpha": LORA_ALPHA,
                    "lora_target_regex": LORA_TARGET_REGEX,
                    "max_seq_length": MAX_SEQ_LENGTH,
                    "world_size": world_size,
                    "trainable_params": trainable,
                },
                fh,
                indent=2,
            )
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
