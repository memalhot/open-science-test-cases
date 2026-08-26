#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t12-peer-load-low-moc-r4pcc02u09-peer-server.yaml..."
oc apply -f manifests/t12-peer-load-low-moc-r4pcc02u09-peer-server.yaml -n uat-peer
echo "Waiting for t12-peer-load-low-moc-r4pcc02u09-peer-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t12-peer-load-low-moc-r4pcc02u09-peer-server --timeout=600s -n uat-peer
echo "t12-peer-load-low-moc-r4pcc02u09-peer-server is ready"
echo "--- t12-peer-load-low-moc-r4pcc02u09-peer-server recent logs ---"
oc logs t12-peer-load-low-moc-r4pcc02u09-peer-server --tail=10 -n uat-peer || true
