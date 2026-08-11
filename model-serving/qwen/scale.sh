#!/bin/bash
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-qwen-model}

usage() {
  echo "Usage: $(basename "$0") {up|down}" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

ACTION="$1"

DEPLOYMENT_NAME=$(oc get deployment -n "${PROJECT}" \
  -l serving.kserve.io/inferenceservice="${MODEL_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "${DEPLOYMENT_NAME}" ]]; then
  echo "Error: could not find deployment for ${MODEL_NAME} in project ${PROJECT}" >&2
  exit 1
fi

case "${ACTION}" in
  up)
    echo "Scaling up ${DEPLOYMENT_NAME}..."
    oc scale deployment/"${DEPLOYMENT_NAME}" --replicas=1 -n "${PROJECT}" --as system:admin

    echo "Waiting for deployment to become available..."
    MAX_ATTEMPTS=80
    POLL_INTERVAL=60
    for (( i=1; i<=MAX_ATTEMPTS; i++ )); do
      AVAILABLE=$(oc get deployment/"${DEPLOYMENT_NAME}" -n "${PROJECT}" \
        -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")

      if [[ "${AVAILABLE}" -ge 1 ]]; then
        echo "Deployment is available."

        echo "Creating external service and route..."
        oc create service clusterip "${MODEL_NAME}-external" \
          --tcp=80:8080 -n "${PROJECT}" --as system:admin 2>/dev/null || true
        oc set selector service "${MODEL_NAME}-external" \
          app="isvc.${MODEL_NAME}-predictor" -n "${PROJECT}" --as system:admin
        oc create route edge "${MODEL_NAME}" \
          --service="${MODEL_NAME}-external" \
          --port=80-8080 -n "${PROJECT}" --as system:admin 2>/dev/null || true

        MODEL_URL=$(oc get route "${MODEL_NAME}" -n "${PROJECT}" -o jsonpath='https://{.spec.host}')
        echo "Model endpoint: ${MODEL_URL}/v1/chat/completions"
        exit 0
      fi

      REPLICAS=$(oc get deployment/"${DEPLOYMENT_NAME}" -n "${PROJECT}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      if [[ "${REPLICAS}" -eq 0 ]]; then
        echo "  Attempt ${i}/${MAX_ATTEMPTS}: deployment scaled back to 0, re-scaling to 1..."
        oc scale deployment/"${DEPLOYMENT_NAME}" --replicas=1 -n "${PROJECT}" --as system:admin
      else
        echo "  Attempt ${i}/${MAX_ATTEMPTS}: waiting for pod to become ready..."
      fi

      sleep "${POLL_INTERVAL}"
    done

    echo "Warning: deployment not available after $((MAX_ATTEMPTS * POLL_INTERVAL))s, check manually" >&2
    exit 1
    ;;

  down)
    echo "Scaling down ${DEPLOYMENT_NAME}..."
    oc scale deployment/"${DEPLOYMENT_NAME}" --replicas=0 -n "${PROJECT}" --as system:admin
    echo "Deployment scaled to 0."
    ;;

  *)
    usage
    ;;
esac
