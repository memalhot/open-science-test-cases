# Serving a Granite Model on OpenShift

Deploy [Granite 3.0 8B Instruct](https://huggingface.co/ibm-granite/granite-3.0-8b-instruct)
on OpenShift using MinIO for model storage and vLLM for inference via RHOAI/KServe.

## Prerequisites

- `oc` CLI, logged in to an OpenShift cluster with RHOAI installed
- Python 3 with `boto3` and `python-dotenv` (`pip install -r requirements.txt`)
- `git-lfs` installed (`dnf install git-lfs` or [manual install](https://git-lfs.com))
- A HuggingFace access token with read access to `ibm-granite/granite-3.0-8b-instruct`
- A GPU node available in the cluster (requires 1x NVIDIA GPU with >= 16GB VRAM)

## Setup

### 1. Create `credentials.env`

```env
# MinIO Root User (minimum 3 characters)
MINIO_ROOT_USER=<your-minio-user>

# MinIO Root Password (minimum 8 characters)
MINIO_ROOT_PASSWORD=<your-minio-password>

# HuggingFace access token
ACCESS_TOKEN=<your-hf-token>
```

Do **not** commit this file.

### 2. Deploy

```bash
./deploy.sh
```

The script will:

1. Deploy MinIO with a PVC, Secret, Service, and Routes.
2. Clone the Granite model from HuggingFace and pull weights via Git LFS (~15GB).
3. Create the S3 bucket and upload model files to MinIO.
4. Create the S3 data connection secret for KServe.
5. Label the namespace for single-model serving (`modelmesh-enabled=false`).
6. Apply the vLLM ServingRuntime and InferenceService.
7. Wait for the deployment to become available (with automatic scale-to-1 workaround).
8. Create an external route for the model endpoint.
9. Verify the model is responding with a test request.

### 3. Use the model

The model is served as an OpenAI-compatible API:

```bash
curl -sk https://granite-model-<project>.apps.<cluster>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-model",
    "messages": [{"role": "user", "content": "What is OpenShift?"}],
    "max_tokens": 100
  }'
```

Other available endpoints:

- `GET /v1/models` — list served models
- `POST /v1/completions` — text completion
- `POST /v1/embeddings` — embeddings

## Cleanup

```bash
./cleanup.sh
```

This removes all deployed resources: route, external service, InferenceService, ServingRuntime, data connection, S3 bucket contents, MinIO, namespace label, and local model files.

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | Full deploy workflow: MinIO, model download, upload, and serving |
| `cleanup.sh` | Tears down all resources created by `deploy.sh` |
| `yaml/minio.yaml` | OpenShift template for MinIO (PVC, Secret, Deployment, Service, Routes) |
| `yaml/data-connection.yaml` | OpenShift template for the S3 data connection secret |
| `yaml/serving-runtime.yaml` | vLLM ServingRuntime for KServe |
| `yaml/inference-service.yaml` | OpenShift template for the KServe InferenceService |
| `python/create-bucket.py` | Creates the `models` S3 bucket |
| `python/model-to-s3.py` | Uploads the local model directory to MinIO |
| `python/delete-bucket.py` | Deletes all objects and the bucket from MinIO |
| `credentials.env` | Credentials file (gitignored, create manually) |

## Configuration

Edit `deploy.sh` to change:

- `PROJECT` — the OpenShift project/namespace to deploy into

## Troubleshooting

**Deployment stuck at 0/1 ready**

RHOAI can scale the deployment to 0 before the model finishes loading. The deploy script handles this automatically, but if it times out, manually scale back up:

```bash
oc scale deployment granite-model-predictor --replicas=1 --as system:admin
```

**`HeaderTooLarge` error in vLLM logs**

The model weights in MinIO are Git LFS pointers (135 bytes) instead of actual weights (~5GB each). Re-run `git lfs pull` in the model directory and re-upload with `python python/model-to-s3.py`.

**503 / "Application is not available" from the route**

KServe creates a headless service which OpenShift routes cannot target. The deploy script creates a separate `granite-model-external` ClusterIP service for routing. If the route was deleted, recreate it:

```bash
oc create route edge granite-model --service=granite-model-external --port=80-8080 --as system:admin
```
