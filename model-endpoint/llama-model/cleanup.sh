#!/bin/bash
set -e

# Cleanup Script - Delete all resources deployed via Kustomize

NAMESPACE="${NAMESPACE:-model-serving}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Cleaning up Model Endpoint ==="
echo "Namespace: $NAMESPACE"
echo ""

# Delete all resources using Kustomize
echo "Deleting all resources with Kustomize..."
oc delete -k "$SCRIPT_DIR"

# Optionally delete the namespace
read -p "Do you want to delete the namespace '$NAMESPACE' as well? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting namespace $NAMESPACE..."
    oc delete namespace "$NAMESPACE"
    echo "Namespace deleted."
else
    echo "Namespace kept."
fi

echo ""
echo "=== Cleanup Complete ==="
