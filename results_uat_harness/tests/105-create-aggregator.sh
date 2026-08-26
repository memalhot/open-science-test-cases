#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/create-aggregator.yaml..."
oc apply -f manifests/create-aggregator.yaml -n uat-project
echo "Waiting for uat-aggregator to be ready (timeout: 120s)..."
oc wait --for=condition=Ready pod/uat-aggregator --timeout=120s -n uat-project
echo "uat-aggregator is ready"
echo "--- uat-aggregator recent logs ---"
oc logs uat-aggregator --tail=10 -n uat-project || true
