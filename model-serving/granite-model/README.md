# Serving a Granite Model on OpenShift

Deploy a MinIO S3-compatible object store on OpenShift, upload the
[Granite 3.0 8B Instruct](https://huggingface.co/ibm-granite/granite-3.0-8b-instruct)
model to it, and serve it.

## Prerequisites

- `oc` CLI, logged in to an OpenShift cluster
- Python 3 with `boto3` and `python-dotenv`
- A HuggingFace access token with read access to `ibm-granite/granite-3.0-8b-instruct`

## Setup

### 1. Create `credentials.env`

```bash
touch credentials.env
```

Add the following (do **not** commit this file):

```env
# MinIO Root User (minimum 3 characters)
MINIO_ROOT_USER=<your-minio-user>

# MinIO Root Password (minimum 8 characters)
MINIO_ROOT_PASSWORD=<your-minio-password>

# HuggingFace access token
ACCESS_TOKEN=<your-hf-token>
```

### 2. Run the deploy script

```bash
./serve.sh
```

This script:

1. Switches to the OpenShift project (set `MY_WORKBENCH` in the script).
2. Applies `minio.yaml` — creates a PVC, Secret, Deployment, Service, and Routes for MinIO.
3. Clones the Granite model from HuggingFace.
4. Runs `create-bucket.py` to create the `models` bucket in MinIO.
5. Runs `model-to-s3.py` to upload the model files to `models/granite-3.0-8b-instruct/`.

## Files

| File | Purpose |
|---|---|
| `serve.sh` | Orchestrates the full deploy-and-upload workflow |
| `minio.yaml` | OpenShift manifests for MinIO (PVC, Secret, Deployment, Service, Routes) |
| `create-bucket.py` | Creates the `models` S3 bucket if it doesn't exist |
| `model-to-s3.py` | Uploads the local model directory to MinIO |
| `credentials.env` | Credentials (gitignored — you must create this yourself) |

## Configuration

Edit `serve.sh` to change:

- `MY_WORKBENCH` — the OpenShift project/namespace to deploy into
