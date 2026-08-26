#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/create-peer-builder.yaml..."
oc apply -f manifests/create-peer-builder.yaml -n uat-peer
echo "Waiting for ginkgo-builder to be ready (timeout: 300s)..."
oc wait --for=condition=Ready pod/ginkgo-builder --timeout=300s -n uat-peer
echo "ginkgo-builder is ready"
echo "--- ginkgo-builder recent logs ---"
oc logs ginkgo-builder --tail=10 -n uat-peer || true
