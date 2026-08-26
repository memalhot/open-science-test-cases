#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t10-ping-project-server.yaml..."
oc apply -f manifests/t10-ping-project-server.yaml -n uat-project
echo "Waiting for t10-ping-project-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t10-ping-project-server --timeout=600s -n uat-project
echo "t10-ping-project-server is ready"
echo "--- t10-ping-project-server recent logs ---"
oc logs t10-ping-project-server --tail=10 -n uat-project || true
