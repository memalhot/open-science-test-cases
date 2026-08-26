#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/create-builder.yaml..."
oc apply -f manifests/create-builder.yaml -n uat-project
echo "Waiting for ginkgo-builder to be ready (timeout: 300s)..."
oc wait --for=condition=Ready pod/ginkgo-builder --timeout=300s -n uat-project
echo "ginkgo-builder is ready"
echo "--- ginkgo-builder recent logs ---"
oc logs ginkgo-builder --tail=10 -n uat-project || true
