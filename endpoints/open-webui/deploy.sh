#!/bin/bash
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-granite-model}
MODEL_URL=${MODEL_URL:-}

oc project "${PROJECT}"

# Auto-discover model endpoint if not provided
if [[ -z "${MODEL_URL}" ]]; then
  echo "Discovering model endpoint..."
  MODEL_URL=$(oc get route "${MODEL_NAME}" -n "${PROJECT}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
  if [[ -z "${MODEL_URL}" ]]; then
    echo "Error: could not find route '${MODEL_NAME}' in project '${PROJECT}'" >&2
    echo "Set MODEL_URL directly or deploy the model first." >&2
    exit 1
  fi
fi
echo "Model endpoint: ${MODEL_URL}"

echo "Deploying Open WebUI..."
oc process -f yaml/open-webui.yaml \
  -p MODEL_URL="${MODEL_URL}" \
  | oc apply --as system:admin -f -

echo "Waiting for deployment to become available..."
oc wait --for=condition=available deployment/open-webui --timeout=300s

WEBUI_URL=$(oc get route open-webui -n "${PROJECT}" -o jsonpath='https://{.spec.host}')

echo ""
echo "Open WebUI is ready."
echo "URL: ${WEBUI_URL}"
