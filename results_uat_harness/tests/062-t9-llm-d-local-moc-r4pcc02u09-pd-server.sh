#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t9-llm-d-local-moc-r4pcc02u09-pd-server.yaml..."
oc apply -f manifests/t9-llm-d-local-moc-r4pcc02u09-pd-server.yaml -n uat-project
echo "Waiting for t9-llm-d-local-moc-r4pcc02u09-pd-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t9-llm-d-local-moc-r4pcc02u09-pd-server --timeout=600s -n uat-project
echo "t9-llm-d-local-moc-r4pcc02u09-pd-server is ready"
echo "--- t9-llm-d-local-moc-r4pcc02u09-pd-server recent logs ---"
oc logs t9-llm-d-local-moc-r4pcc02u09-pd-server --tail=10 -n uat-project || true
