#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-mm-test}"
PVC_NAME="${PVC_NAME:-rwx-test}"

POD1="rwx-test-1"
POD2="rwx-test-2"

echo "Using namespace: $NAMESPACE"

echo
echo "Deleting test pods..."
oc delete pod "$POD1" "$POD2" \
  -n "$NAMESPACE" \
  --as system:admin \
  --ignore-not-found \
  --wait \
  --timeout=120s

echo
echo "Deleting RWX PVC..."
oc delete pvc "$PVC_NAME" \
  -n "$NAMESPACE" \
  --as system:admin \
  --ignore-not-found \
  --wait \
  --timeout=120s

echo
echo "Cleanup complete."
