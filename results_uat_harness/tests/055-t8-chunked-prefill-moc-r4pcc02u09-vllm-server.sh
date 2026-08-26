#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t8-chunked-prefill-moc-r4pcc02u09-vllm-server.yaml..."
oc apply -f manifests/t8-chunked-prefill-moc-r4pcc02u09-vllm-server.yaml -n uat-project
echo "Waiting for t8-chunked-prefill-moc-r4pcc02u09-vllm-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t8-chunked-prefill-moc-r4pcc02u09-vllm-server --timeout=600s -n uat-project
echo "t8-chunked-prefill-moc-r4pcc02u09-vllm-server is ready"
echo "--- t8-chunked-prefill-moc-r4pcc02u09-vllm-server recent logs ---"
oc logs t8-chunked-prefill-moc-r4pcc02u09-vllm-server --tail=10 -n uat-project || true
