#!/bin/bash
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-qwen-model}
PVC_NAME=${PVC_NAME:-qwen-model-pvc}
STORAGE_CLASS=${STORAGE_CLASS:?'STORAGE_CLASS is required (e.g. ocs-storagecluster-ceph-rbd for block, ocs-storagecluster-cephfs for file)'}
STORAGE_SIZE=${STORAGE_SIZE:-20Gi}
ACCESS_MODE=${ACCESS_MODE:-ReadWriteOnce}
MODEL_REPO=${MODEL_REPO:-Qwen/Qwen2.5-3B-Instruct}
MODEL_DIR=${MODEL_DIR:-Qwen2.5-3B-Instruct}

if [[ ! -f credentials.env ]]; then
  echo "Error: .env not found (needs ACCESS_TOKEN for HuggingFace)" >&2
  exit 1
fi
source credentials.env

: "${ACCESS_TOKEN:?'ACCESS_TOKEN must be set in credentials.env'}"

oc project "${PROJECT}"

echo "Creating PVC (${STORAGE_SIZE}, ${STORAGE_CLASS}, ${ACCESS_MODE})..."
oc process -f yaml/model-pvc.yaml \
  -p PVC_NAME="${PVC_NAME}" \
  -p STORAGE_SIZE="${STORAGE_SIZE}" \
  -p STORAGE_CLASS="${STORAGE_CLASS}" \
  -p ACCESS_MODE="${ACCESS_MODE}" \
  | oc apply --as system:admin -f -

echo "Launching model loader job..."
oc delete job model-loader --as system:admin --ignore-not-found
oc process -f yaml/model-loader-job.yaml \
  -p PVC_NAME="${PVC_NAME}" \
  -p MODEL_REPO="${MODEL_REPO}" \
  -p MODEL_DIR="${MODEL_DIR}" \
  -p ACCESS_TOKEN="${ACCESS_TOKEN}" \
  | oc apply --as system:admin -f -

echo "Waiting for model download to complete..."
oc wait --for=condition=complete job/model-loader --timeout=1800s
echo "Model download complete."

echo "Enabling single-model serving..."
oc label namespace "${PROJECT}" modelmesh-enabled=false --overwrite --as system:admin

echo "Creating vLLM ServingRuntime..."
oc apply -f yaml/serving-runtime.yaml --as system:admin

SERVING_RUNTIME=vllm-runtime
echo "Using serving runtime: ${SERVING_RUNTIME}"

echo "Deploying model from PVC..."
oc process -f yaml/inference-service.yaml \
  -p MODEL_NAME="${MODEL_NAME}" \
  -p PVC_NAME="${PVC_NAME}" \
  -p MODEL_DIR="${MODEL_DIR}" \
  -p SERVING_RUNTIME="${SERVING_RUNTIME}" \
  | oc apply --as system:admin -f -

echo "Waiting for deployment to appear..."
MAX_ATTEMPTS=80
POLL_INTERVAL=60

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
