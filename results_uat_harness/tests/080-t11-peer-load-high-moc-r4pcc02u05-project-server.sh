#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t11-peer-load-high-moc-r4pcc02u05-project-server.yaml..."
oc apply -f manifests/t11-peer-load-high-moc-r4pcc02u05-project-server.yaml -n uat-project
echo "Waiting for t11-peer-load-high-moc-r4pcc02u05-project-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t11-peer-load-high-moc-r4pcc02u05-project-server --timeout=600s -n uat-project
echo "t11-peer-load-high-moc-r4pcc02u05-project-server is ready"
echo "--- t11-peer-load-high-moc-r4pcc02u05-project-server recent logs ---"
oc logs t11-peer-load-high-moc-r4pcc02u05-project-server --tail=10 -n uat-project || true
