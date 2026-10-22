# Beam 1.0 LoRA fine-tuning

LoRA supervised fine-tuning for
[`reflection/Beam-1.0-501B-A23B`](https://huggingface.co/reflection/Beam-1.0-501B-A23B)
via TRL, in two variants: a Kubeflow Trainer v2 `TrainJob` for RHOAI 3.x and a
Training Operator v1 `PyTorchJob` for RHOAI 2.25.

> **The target cluster cannot run this recipe to completion.** Reflection's
> published LoRA SFT recipe is one node of 8x B300, or four nodes of 8x H100 —
> 32 GPUs. The cluster here has 8x H100-80GB (637 GB aggregate), and Beam's
> BF16 base weights alone are **1003 GB**. No amount of sharding, offload, or
> sequence-length reduction closes a gap larger than total device memory.
>
> Everything that *can* be verified without that hardware is verified by
> `validate.sh`. Start there.

## Layout

Shared between both variants, because none of it is RHOAI-coupled:

| File | Purpose |
| --- | --- |
| `train.py` | The training script. Formatting helpers are importable and CUDA-free so `validate.sh` can exercise them. |
| `Containerfile` | Training image (Transformers 5 + TRL + PEFT). |
| `validate_in_cluster.py` | CPU-only checks of the data pipeline and LoRA targets, run in a pod. Downloads no weights. |
| `common/lib.sh` | Capacity arithmetic, weight seeding, the validation pod, log following. |
| `common/seed-job.yaml` | Stages the 1003 GB BF16 base onto the weight PVC. |

Per RHOAI generation:

| | `rhoai3/` | `rhoai2/` |
| --- | --- | --- |
| Training CR | `trainjob.yaml` — `TrainJob` | `pytorchjob.yaml` — `PyTorchJob` |
| API group | `trainer.kubeflow.org/v1alpha1` | `kubeflow.org/v1` |
| Node count | one `numNodes` field | `1` Master + `NUM_NODES-1` Worker replicas |
| Pod template | patched over a `ClusterTrainingRuntime` | written out in full, twice |
| Container name | anything | must be **`pytorch`** |
| Admission | direct | usually Kueue-gated (`LOCAL_QUEUE`) |

Each also has its own `fine-tune.sh`, `validate.sh` and `cleanup.sh`. The
scripts warn if run against the wrong RHOAI generation.

## Start here

```bash
cd rhoai3     # or rhoai2
./validate.sh
```

It reports, in order:

1. **Prerequisites** — the right training CRD for the generation, an RWX
   storage class, and (on 2.x) Kueue and the LocalQueue. Each variant also
   notes whether the *other* one would run on this cluster.
2. **Capacity** — required vs. allocatable GPUs, and aggregate GPU memory
   against the 1003 GB of base weights. This is where the gap is stated plainly.
3. **Manifests** — processed and `oc apply --dry-run=server`'d, so CRD schema
   validation and admission webhooks run against the real object without
   creating anything.
4. **Data pipeline and LoRA targets** — in a CPU pod, with no weights
   downloaded. Covered below.

Add `--no-pod` to skip step 4 if the training image hasn't been built yet.

## What the in-cluster checks actually prove

These are the two failure modes that are invisible until deep into a
multi-node run, so they are worth catching on a laptop-sized pod.

**LoRA targets resolve.** `model.safetensors.index.json` (3.5 MB) maps every
parameter name in the checkpoint, so the regex can be matched against the real
module paths without downloading a single weight. Beam's layout is:

| Module path | Count | LoRA target? |
| --- | --- | --- |
| `model.layers.{0..51}.self_attn.{q,k,v,o,gate}_proj` | 260 | yes (gated GQA — note the extra `gate_proj`) |
| `model.layers.{0..2}.mlp.{gate,up,down}_proj` | 9 | yes (the dense layers) |
| `model.layers.{3..51}.mlp.experts.{0..255}.{gate,up,down}_proj` | 37,632 | opt-in |
| `model.layers.{3..51}.mlp.gate` | 49 | **no** — the router |
| norms, `embed_tokens`, `lm_head` | 161 | no |

The default regex targets the first two rows: **269 modules**. This matters
more than it looks. The obvious pattern —
`.*(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$` — also matches
all 37,632 expert projections, yielding an adapter two orders of magnitude
larger than intended, with no error anywhere to tell you. To deliberately
adapt the experts too (closer to Reflection's own recipe):

```
LORA_TARGET_REGEX='.*(self_attn\.(q|k|v|o|gate)_proj|mlp\.(experts\.\d+\.)?(gate|up|down)_proj)$'
```

The validator fails if the regex catches the router or any norm/embedding
layer, and reports the expert count either way. At the other extreme, a regex
matching *nothing* produces a run that completes successfully having trained
zero parameters — `train.py` aborts on `trainable_params == 0` as a backstop.

**Harmony formatting is correct.** The dataset is rendered through Beam's own
chat template using `build_formatter` — the exact function `train.py` uses —
and asserted to carry Harmony control tokens and, where the dataset provides
reasoning traces, an `analysis` channel. Training on plain text instead would
teach the adapter a format the serving stack then strips.

## Running the real thing

On hardware that meets the floor:

```bash
podman build -t quay.io/memalhot/beam-fine-tune:latest -f Containerfile .
podman push quay.io/memalhot/beam-fine-tune:latest

cd rhoai3            # or rhoai2
./validate.sh
./fine-tune.sh
```

`fine-tune.sh` refuses to submit when the cluster is short on GPUs — otherwise
the job sits Pending indefinitely while holding a 1.2 TB PVC. `FORCE=1`
overrides.

Tunable via environment variables (all also `oc process` parameters on the
variant's template):

| Variable | Default | Notes |
| --- | --- | --- |
| `NUM_NODES` | `4` | Training nodes. 4x8 H100 is the documented minimum. On 2.x this becomes 1 Master + 3 Workers. |
| `GPUS_PER_NODE` | `8` | |
| `MODEL_ID` | `reflection/Beam-1.0-501B-A23B` | BF16, **not** the NVFP4 serving checkpoint. |
| `DATASET_NAME` | `HuggingFaceH4/Multilingual-Thinking` | The dataset Reflection demonstrates with. |
| `NUM_EPOCHS` | `1` | |
| `LEARNING_RATE` | `1e-4` | |
| `BATCH_SIZE` / `GRAD_ACCUM` | `1` / `8` | Per-device. |
| `MAX_SEQ_LENGTH` | `4096` | Sequence packing is on. |
| `LORA_RANK` / `LORA_ALPHA` | `16` / `32` | |
| `LORA_TARGET_REGEX` | attention + dense MLP (269 modules) | Validated against the checkpoint; see above. |
| `LOCAL_QUEUE` | *(unset)* | **rhoai2 only.** Kueue LocalQueue. Stripped entirely when empty — an empty queue-name label means admitted to nothing. |

### Why BF16 and not the NVFP4 checkpoint

The serving stack uses NVFP4 (294 GB) because inference only needs a forward
pass. LoRA backpropagates through the frozen base to reach the adapters, which
needs full-precision base weights — so training pulls the 1003 GB BF16 repo
into its own PVC. The two are intentionally separate claims.

### How the sharding works

Beam cannot be materialised on one rank, so there is no "load then `.to(device)`"
step. `train.py` shards at load time:

```python
model = AutoModelForCausalLM.from_pretrained(
    source,
    dtype=torch.bfloat16,
    distributed_config=DistributedConfig(tp_size=world_size, ep_size=world_size, tp_plan={}),
)
```

Tensor parallelism splits the attention tensors; expert parallelism splits the
256 experts; `tp_plan={}` lets Transformers derive the plan from the
architecture. This requires **Transformers 5.x**, which is why the
`Containerfile` here does not share a base with `../granite` or `../qwen`
(their 4.x pin fails on Beam with an unrecognized model type).

The same `train.py` and the same image serve both variants: `torchrun` reads
`PET_*` environment variables, and both Trainer v2's torch runtime and Training
Operator v1's `elasticPolicy` rendezvous populate them. Only the surrounding CR
changes.

### A note on the v1 recipe

`rhoai2/pytorchjob.yaml` spells the Master and Worker pod templates out twice
and identically. v1 has no way to share one template between replica specs —
removing exactly that duplication is part of why Trainer v2 exists. The
drift hazard is real, so `validate.sh`'s server-side dry run is worth running
after any edit, and the offline schema check below compares the two directly.

Where the 2.x CRD is not installed (for example on a 3.x cluster, where the
`PyTorchJob` CRD has been removed), the manifest can still be validated
offline against the published upstream schema:

```bash
pip install pyyaml jsonschema
curl -sSLO https://raw.githubusercontent.com/kubeflow/training-operator/v1.8-branch/manifests/base/crds/kubeflow.org_pytorchjobs.yaml
oc process -f rhoai2/pytorchjob.yaml -p WORKER_REPLICAS=3 -o yaml > /tmp/ptj.yaml
# checks schema conformance, node arithmetic, the `pytorch` container name,
# and that the Master and Worker specs have not drifted apart
```

## Beyond LoRA SFT

For completeness, Reflection's other published recipes and their hardware:

| Recipe | Hardware |
| --- | --- |
| LoRA SFT (this directory) | 8x B300, or 4 nodes of 8x H100 |
| LoRA GRPO | 32x H200 (16 train + 16 rollout) |
| Full-parameter GRPO | 96x H200, plus 2 TB NVMe scratch per trainer node |

## Serving the adapter

The adapter lands on the output PVC at `/output/<JOB_NAME>`. To serve it,
either merge it into the base weights or load it as a LoRA adapter in the vLLM
runtime — see [`../../model-serving/beam/README.md`](../../model-serving/beam/README.md).
