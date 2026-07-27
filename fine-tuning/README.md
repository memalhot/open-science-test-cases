# Fine-Tuning Granite on OpenShift

Fine-tune [Granite 3.0 8B Instruct](https://huggingface.co/ibm-granite/granite-3.0-8b-instruct)
on OpenShift using a Kubeflow PyTorchJob with QLoRA. The base model is loaded from MinIO
(deployed by `model-serving/granite-model/deploy.sh`), fine-tuned on a GPU node, and the
LoRA adapter is uploaded back to MinIO.

## Prerequisites

- The base model must already be deployed (see `../model-serving/granite-model/README.md`)
- Kubeflow Training Operator installed (ships with RHOAI)
- A GPU node available in the cluster (1x NVIDIA GPU with >= 24GB VRAM)
- `podman` or `docker` for building the training image
- `oc` CLI, logged in to the cluster

## Setup

### 1. Build and push the training image

The `Containerfile` bakes all Python dependencies into the image so nothing
is installed at runtime.

```bash
podman build -t quay.io/memalhot/granite-fine-tune:latest -f Containerfile .
podman push quay.io/memalhot/granite-fine-tune:latest
```

Make sure the quay.io repository is set to **public**, or create a pull secret:

```bash
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=memalhot \
  --docker-password=<your-quay-token> \
  -n mm-test --as system:admin

oc secrets link default quay-pull-secret --for=pull -n mm-test --as system:admin
```

### 2. Run fine-tuning

Change the project name, if needed:
```
PROJECT=<your-project-name>
```

```bash
chmod +x fine.tune.sh
./fine-tune.sh
```

This submits the PyTorchJob, waits for the pod to start, and streams training logs.

### 3. Custom datasets and parameters

Override any parameter via environment variables:

```bash
DATASET_NAME="databricks/databricks-dolly-15k" \
NUM_EPOCHS=5 \
LORA_RANK=32 \
BATCH_SIZE=2 \
./fine-tune.sh
```

To use your own JSONL data, upload it to MinIO and reference the S3 key:

```bash
DATASET_NAME="datasets/my-training-data.jsonl" ./fine-tune.sh
```

The JSONL file should contain objects with one of these formats:
- `{"instruction": "...", "input": "...", "output": "..."}` (Alpaca-style)
- `{"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "..."}]}` (chat format)
- `{"text": "..."}` (raw text)

## Parameters

| Variable | Default | Description |
|---|---|---|
| `JOB_NAME` | `granite-fine-tune` | Name for the PyTorchJob |
| `BASE_MODEL_PATH` | `models/granite-3.0-8b-instruct` | S3 path to the base model |
| `OUTPUT_PATH` | `models/granite-3.0-8b-instruct-finetuned` | S3 path for the adapter output |
| `DATASET_NAME` | `tatsu-lab/alpaca` | HuggingFace dataset or S3 key to a JSONL file |
| `NUM_EPOCHS` | `3` | Number of training epochs |
| `LEARNING_RATE` | `2e-4` | Learning rate |
| `BATCH_SIZE` | `4` | Per-device training batch size |
| `LORA_RANK` | `16` | LoRA rank (higher = more capacity, more memory) |
| `MAX_SEQ_LENGTH` | `2048` | Maximum sequence length |
| `GPU_COUNT` | `1` | Number of GPUs per worker |

## Monitoring

```bash
# Job status
oc get pytorchjob granite-fine-tune -n mm-test

# Stream training logs
oc logs -f granite-fine-tune-master-0 -n mm-test

```

## How it works

1. The PyTorchJob downloads the base Granite model from MinIO into the container
2. Loads it with 4-bit QLoRA quantization (NF4) to fit on a single GPU
3. Applies LoRA adapters to all attention and MLP projection layers
4. Fine-tunes using `SFTTrainer` with gradient checkpointing and sequence packing
5. Uploads the LoRA adapter weights back to MinIO

The adapter is small (~50-200MB depending on rank) compared to the full model (~15GB).
To serve it, merge the adapter with the base model and redeploy, or configure vLLM
to load the adapter at inference time.

## Cleanup

```bash
oc delete pytorchjob granite-fine-tune -n mm-test --as system:admin
oc delete configmap granite-fine-tune-script -n mm-test --as system:admin
```

## Files

| File | Purpose |
|---|---|
| `fine-tune.sh` | Orchestration script: cleans up previous runs, submits the job, streams logs |
| `fine-tune-job.yaml` | OpenShift Template for the PyTorchJob and training script ConfigMap |
| `Containerfile` | Container image with all Python dependencies pre-installed |
