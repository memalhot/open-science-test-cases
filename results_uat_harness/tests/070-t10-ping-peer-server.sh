#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t10-ping-peer-server.yaml..."
oc apply -f manifests/t10-ping-peer-server.yaml -n uat-peer
echo "Waiting for t10-ping-peer-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t10-ping-peer-server --timeout=600s -n uat-peer
echo "t10-ping-peer-server is ready"
echo "--- t10-ping-peer-server recent logs ---"
oc logs t10-ping-peer-server --tail=10 -n uat-peer || true
