#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t4-dev-env-moc-r4pcc02u09-notebook-server.yaml..."
oc apply -f manifests/t4-dev-env-moc-r4pcc02u09-notebook-server.yaml -n uat-project
echo "Waiting for t4-dev-env-moc-r4pcc02u09-notebook-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t4-dev-env-moc-r4pcc02u09-notebook-server --timeout=600s -n uat-project
echo "t4-dev-env-moc-r4pcc02u09-notebook-server is ready"
echo "--- t4-dev-env-moc-r4pcc02u09-notebook-server recent logs ---"
oc logs t4-dev-env-moc-r4pcc02u09-notebook-server --tail=10 -n uat-project || true
