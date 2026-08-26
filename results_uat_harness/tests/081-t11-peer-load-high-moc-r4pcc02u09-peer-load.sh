#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t11-peer-load-high-moc-r4pcc02u09-peer-load.yaml..."
oc apply -f manifests/t11-peer-load-high-moc-r4pcc02u09-peer-load.yaml -n uat-peer
echo "Waiting for t11-peer-load-high-moc-r4pcc02u09-peer-load to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t11-peer-load-high-moc-r4pcc02u09-peer-load --timeout=600s -n uat-peer
echo "t11-peer-load-high-moc-r4pcc02u09-peer-load is ready"
echo "--- t11-peer-load-high-moc-r4pcc02u09-peer-load recent logs ---"
oc logs t11-peer-load-high-moc-r4pcc02u09-peer-load --tail=10 -n uat-peer || true
