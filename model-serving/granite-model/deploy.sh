#!/bin/bash
set -euo pipefail

PROJECT=mm-test

if [[ ! -f credentials.env ]]; then
  echo "Error: credentials.env not found" >&2
  exit 1
fi
source credentials.env

oc project "${PROJECT}"
oc process -f yaml/minio.yaml \
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
cd granite-3.0-8b-instruct
git lfs install
git lfs pull
cd ..

python python/create-bucket.py
sleep 3

python python/model-to-s3.py

# Step 4.1: Create S3 data connection
echo "Creating S3 data connection..."
oc process -f yaml/data-connection.yaml \
  -p MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  -p MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  -p S3_ENDPOINT="${S3_ENDPOINT}" \
  | oc apply --as system:admin -f -

# Step 4.2: Deploy model with vLLM single-model serving
MODEL_NAME=granite-model

echo "Enabling single-model serving..."
oc label namespace "${PROJECT}" modelmesh-enabled=false --overwrite --as system:admin

echo "Creating vLLM ServingRuntime..."
oc apply -f yaml/serving-runtime.yaml --as system:admin

SERVING_RUNTIME=vllm-runtime
echo "Using serving runtime: ${SERVING_RUNTIME}"

echo "Deploying model..."
oc process -f yaml/inference-service.yaml \
  -p SERVING_RUNTIME="${SERVING_RUNTIME}" \
  | oc apply --as system:admin -f -

# Wait for deployment and apply scale workaround
# Large models can trigger an RHOAI bug where the deployment scales to 0
# before the model finishes loading. Poll and re-scale until it's available.
echo "Waiting for deployment to appear..."
MAX_ATTEMPTS=60
POLL_INTERVAL=15

DEPLOYMENT_NAME=""
for (( i=1; i<=MAX_ATTEMPTS; i++ )); do
  DEPLOYMENT_NAME=$(oc get deployment -l serving.kserve.io/inferenceservice="${MODEL_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${DEPLOYMENT_NAME}" ]]; then
    echo "Found deployment: ${DEPLOYMENT_NAME}"
    break
  fi
  echo "  Attempt ${i}/${MAX_ATTEMPTS}: deployment not yet created, retrying in ${POLL_INTERVAL}s..."
  sleep "${POLL_INTERVAL}"
done

if [[ -z "${DEPLOYMENT_NAME}" ]]; then
  echo "Error: could not find deployment for ${MODEL_NAME} after $((MAX_ATTEMPTS * POLL_INTERVAL))s" >&2
  exit 1
fi

echo "Waiting for deployment to become available..."
for (( i=1; i<=MAX_ATTEMPTS; i++ )); do
  REPLICAS=$(oc get deployment/"${DEPLOYMENT_NAME}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  AVAILABLE=$(oc get deployment/"${DEPLOYMENT_NAME}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")

  if [[ "${AVAILABLE}" -ge 1 ]]; then
    echo "Deployment is available."
    break
  fi

  if [[ "${REPLICAS}" -eq 0 ]]; then
    echo "  Attempt ${i}/${MAX_ATTEMPTS}: deployment scaled to 0, scaling back to 1..."
    oc scale deployment/"${DEPLOYMENT_NAME}" --replicas=1 --as system:admin
  else
    echo "  Attempt ${i}/${MAX_ATTEMPTS}: waiting for pod to become ready..."
  fi

  sleep "${POLL_INTERVAL}"
done

AVAILABLE=$(oc get deployment/"${DEPLOYMENT_NAME}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
if [[ "${AVAILABLE}" -lt 1 ]]; then
  echo "Warning: deployment is not yet available after $((MAX_ATTEMPTS * POLL_INTERVAL))s, check manually"
fi

# Create a routable service and external route
# KServe creates a headless service which routes cannot target directly
echo "Creating external service and route..."
oc create service clusterip "${MODEL_NAME}-external" \
  --tcp=80:8080 -n "${PROJECT}" --as system:admin 2>/dev/null || true
oc set selector service "${MODEL_NAME}-external" \
  app="isvc.${MODEL_NAME}-predictor" -n "${PROJECT}" --as system:admin

oc create route edge "${MODEL_NAME}" \
  --service="${MODEL_NAME}-external" \
  --port=80-8080 -n "${PROJECT}" --as system:admin 2>/dev/null || true

MODEL_URL=$(oc get route "${MODEL_NAME}" -n "${PROJECT}" -o jsonpath='https://{.spec.host}')

echo "Model deployment complete."
echo "Check status: oc get inferenceservice ${MODEL_NAME}"
echo "Model endpoint: ${MODEL_URL}/v1/chat/completions"

echo "Verifying model is responding..."
RESPONSE=$(curl -sk -w "\n%{http_code}" "${MODEL_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Hello, are you working?"}],
    "max_tokens": 20
  }')
HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -eq 200 ]]; then
  echo "Model is running correctly (HTTP ${HTTP_CODE})."
  echo "Response: ${BODY}"
else
  echo "Warning: model returned HTTP ${HTTP_CODE}" >&2
  echo "Response: ${BODY}" >&2
fi