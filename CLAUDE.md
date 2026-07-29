# CLAUDE.md

## Project Overview

Test cases and deployment scripts for open science workflows on OpenShift (RHOAI). Covers the full lifecycle of IBM Granite 3.0 8B Instruct: deploying with vLLM via KServe, benchmarking inference, fine-tuning with QLoRA, and providing a web UI (Open WebUI).

## Repository Structure

```
model-serving/granite-model/   Deploy Granite model with vLLM on OpenShift (MinIO for model storage)
inference/                     Benchmark and manual test suites for the deployed model
fine-tuning/                   QLoRA fine-tuning via Kubeflow PyTorchJob
endpoints/open-webui/          Open WebUI deployment connecting to the model
compliance/                    Placeholder (empty)
```

## Commands

All scripts must be run from their own directory. Default OpenShift project is `mm-test` (override with `PROJECT` env var).

### Model Serving (`model-serving/granite-model/`)
- `./deploy.sh` — full deploy: MinIO, model clone from HuggingFace, S3 upload, vLLM serving
- `./cleanup.sh` — tear down all resources
- `./scale.sh up|down` — scale model without redeploying

### Inference (`inference/`)
- `./benchmark.sh` — automated sweep benchmark (requires Rust `inference-benchmarker`)
- `./test-inference.sh` — curl-based manual test suite, reports PASS/FAIL

### Fine-Tuning (`fine-tuning/`)
- `podman build -t quay.io/memalhot/granite-fine-tune:latest -f Containerfile .` — build training image
- `./fine-tune.sh` — submit PyTorchJob, stream logs (env vars: `NUM_EPOCHS`, `LEARNING_RATE`, `BATCH_SIZE`, `LORA_RANK`, etc.)
- `./cleanup.sh` — delete PyTorchJob and ConfigMap

### Endpoints (`endpoints/open-webui/`)
- `./deploy.sh` — deploy Open WebUI
- `./cleanup.sh` — remove Open WebUI resources

## Conventions

- All scripts use `set -euo pipefail`
- All `oc` mutating commands use `--as system:admin`
- YAML manifests are OpenShift Templates, processed with `oc process -f ... -p KEY=VALUE | oc apply` (not Helm or Kustomize)
- Model weights (`granite-3.0-8b-instruct/`) are gitignored and cloned at deploy time

## Prerequisites

`oc` CLI, Python 3 with `boto3`/`python-dotenv`, `git-lfs`, Rust toolchain (for inference-benchmarker), `podman` (for container builds)
