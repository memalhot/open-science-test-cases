#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT=${PROJECT:-mm-test}

oc project "${PROJECT}"

echo "Deleting Open WebUI..."
oc process -f "${SCRIPT_DIR}/yaml/open-webui.yaml" \
  -p MODEL_URL=placeholder \
  | oc delete --as system:admin --ignore-not-found -f -

echo "Cleanup complete."
