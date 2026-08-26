#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/create-peer-aggregator.yaml..."
oc apply -f manifests/create-peer-aggregator.yaml -n uat-peer
echo "Waiting for peer-uat-aggregator to be ready (timeout: 120s)..."
oc wait --for=condition=Ready pod/peer-uat-aggregator --timeout=120s -n uat-peer
echo "peer-uat-aggregator is ready"
echo "--- peer-uat-aggregator recent logs ---"
oc logs peer-uat-aggregator --tail=10 -n uat-peer || true
