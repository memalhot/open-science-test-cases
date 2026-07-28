#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-granite-model}

oc project "${PROJECT}"

# Use the internal cluster service URL to avoid TLS/certificate issues
# The external service was created by model-serving/granite-model/deploy.sh
MODEL_URL="http://${MODEL_NAME}-external.${PROJECT}.svc.cluster.local"

echo "Deploying Open WebUI..."
echo "  Model endpoint (internal): ${MODEL_URL}"

oc process -f "${SCRIPT_DIR}/yaml/open-webui.yaml" \
  -p MODEL_URL="${MODEL_URL}" \
  | oc apply --as system:admin -f -

echo "Waiting for deployment to become available..."
oc wait --for=condition=available deployment/open-webui --timeout=300s

WEBUI_URL=$(oc get route open-webui -n "${PROJECT}" -o jsonpath='https://{.spec.host}')

echo ""
echo "Open WebUI is ready."
echo "URL: ${WEBUI_URL}"
