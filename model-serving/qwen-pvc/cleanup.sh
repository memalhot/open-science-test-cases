#!/bin/bash
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-qwen-model}
PVC_NAME=${PVC_NAME:-qwen-model-pvc}

oc project "${PROJECT}"

echo "Deleting external route and service..."
oc delete route "${MODEL_NAME}" -n "${PROJECT}" --as system:admin --ignore-not-found
oc delete service "${MODEL_NAME}-external" -n "${PROJECT}" --as system:admin --ignore-not-found

echo "Deleting InferenceService..."
oc process -f yaml/inference-service.yaml \
  -p SERVING_RUNTIME=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

echo "Deleting ServingRuntime..."
oc delete -f yaml/serving-runtime.yaml --as system:admin --ignore-not-found

echo "Deleting model loader job..."
oc delete job model-loader --as system:admin --ignore-not-found

echo "Deleting PVC..."
oc delete pvc "${PVC_NAME}" --as system:admin --ignore-not-found

echo "Removing namespace label..."
oc label namespace "${PROJECT}" modelmesh-enabled- --as system:admin 2>/dev/null || true

echo "Cleanup complete."
