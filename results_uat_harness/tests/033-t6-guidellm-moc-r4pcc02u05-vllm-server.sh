#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t6-guidellm-moc-r4pcc02u05-vllm-server.yaml..."
oc apply -f manifests/t6-guidellm-moc-r4pcc02u05-vllm-server.yaml -n uat-project
echo "Waiting for t6-guidellm-moc-r4pcc02u05-vllm-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t6-guidellm-moc-r4pcc02u05-vllm-server --timeout=600s -n uat-project
echo "t6-guidellm-moc-r4pcc02u05-vllm-server is ready"
echo "--- t6-guidellm-moc-r4pcc02u05-vllm-server recent logs ---"
oc logs t6-guidellm-moc-r4pcc02u05-vllm-server --tail=10 -n uat-project || true
