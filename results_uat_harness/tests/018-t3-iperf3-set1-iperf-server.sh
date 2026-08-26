#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t3-iperf3-set1-iperf-server.yaml..."
oc apply -f manifests/t3-iperf3-set1-iperf-server.yaml -n uat-project
echo "Waiting for t3-iperf3-set1-iperf-server to be ready (timeout: 600s)..."
oc wait --for=condition=Ready pod/t3-iperf3-set1-iperf-server --timeout=600s -n uat-project
echo "t3-iperf3-set1-iperf-server is ready"
echo "--- t3-iperf3-set1-iperf-server recent logs ---"
oc logs t3-iperf3-set1-iperf-server --tail=10 -n uat-project || true
