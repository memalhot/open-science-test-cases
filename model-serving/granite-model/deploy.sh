#!/bin/bash
set -euo pipefail

PROJECT=mm-test

if [[ ! -f credentials.env ]]; then
  echo "Error: credentials.env not found" >&2
  exit 1
fi
source credentials.env

oc project "${PROJECT}"
oc process -f minio.yaml \
  -p MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  -p MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  | oc apply --as system:admin -f -
oc wait --for=condition=available deployment/minio --timeout=120s

S3_ENDPOINT=$(oc get route minio-api -o jsonpath='https://{.spec.host}')
if [[ -z "${S3_ENDPOINT}" ]]; then
  echo "Error: failed to get minio-api route" >&2
  exit 1
fi
export S3_ENDPOINT

git clone "https://memalhot:${ACCESS_TOKEN}@huggingface.co/ibm-granite/granite-3.0-8b-instruct"
sleep 3

python create-bucket.py
sleep 3

python model-to-s3.py

# Step 4.1: Create S3 data connection
echo "Creating S3 data connection..."
oc process -f data-connection.yaml \
  -p MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  -p MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  -p S3_ENDPOINT="${S3_ENDPOINT}" \
  | oc apply --as system:admin -f -

# Step 4.2: Deploy model with vLLM single-model serving
MODEL_NAME=granite-model

echo "Enabling single-model serving..."
oc label namespace "${PROJECT}" modelmesh-enabled=false --overwrite --as system:admin

SERVING_RUNTIME=$(oc get servingruntime -o name 2>/dev/null | grep -i vllm | head -1 | cut -d/ -f2)
if [[ -z "${SERVING_RUNTIME}" ]]; then
  echo "Error: no vLLM ServingRuntime found" >&2
  exit 1
fi
echo "Using serving runtime: ${SERVING_RUNTIME}"

echo "Deploying model..."
oc process -f inference-service.yaml \
  -p SERVING_RUNTIME="${SERVING_RUNTIME}" \
  | oc apply --as system:admin -f -

# Step 4.3: Wait for deployment and apply scale workaround
echo "Waiting for deployment to start..."
sleep 60

DEPLOYMENT_NAME=$(oc get deployment -l serving.kserve.io/inferenceservice="${MODEL_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "${DEPLOYMENT_NAME}" ]]; then
  echo "Scaling ${DEPLOYMENT_NAME} to 1 replica..."
  oc scale deployment/"${DEPLOYMENT_NAME}" --replicas=1 --as system:admin
else
  echo "Warning: could not find deployment for ${MODEL_NAME}, you may need to scale manually"
fi

echo "Model deployment complete."
echo "Check status: oc get inferenceservice ${MODEL_NAME}"