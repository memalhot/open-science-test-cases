#!/bin/bash
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
JOB_NAME=${JOB_NAME:-granite-fine-tune}

oc project "${PROJECT}"

echo "Deleting fine-tuning PyTorchJob..."
oc delete pytorchjob "${JOB_NAME}" -n "${PROJECT}" --as system:admin --ignore-not-found

echo "Deleting training script ConfigMap..."
oc delete configmap "${JOB_NAME}-script" -n "${PROJECT}" --as system:admin --ignore-not-found

echo "Cleanup complete."
