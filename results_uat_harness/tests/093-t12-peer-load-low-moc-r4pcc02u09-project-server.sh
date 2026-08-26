#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t12-peer-load-low-moc-r4pcc02u09-project-server.yaml..."
oc apply -f manifests/t12-peer-load-low-moc-r4pcc02u09-project-server.yaml -n uat-project
echo "Waiting for t12-peer-load-low-moc-r4pcc02u09-project-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t12-peer-load-low-moc-r4pcc02u09-project-server --timeout=600s -n uat-project
echo "t12-peer-load-low-moc-r4pcc02u09-project-server is ready"
echo "--- t12-peer-load-low-moc-r4pcc02u09-project-server recent logs ---"
oc logs t12-peer-load-low-moc-r4pcc02u09-project-server --tail=10 -n uat-project || true
