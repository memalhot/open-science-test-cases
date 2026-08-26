#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t3-iperf3-set1-iperf-client.yaml..."
oc apply -f manifests/t3-iperf3-set1-iperf-client.yaml -n uat-project

echo "Waiting for t3-iperf3-set1-iperf-client to start..."
while true; do
  PHASE=$(oc get pod t3-iperf3-set1-iperf-client -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t3-iperf3-set1-iperf-client logs ---"
oc logs -f t3-iperf3-set1-iperf-client -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t3-iperf3-set1-iperf-client -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t3-iperf3-set1-iperf-client"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t3-iperf3-set1-iperf-client (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t3-iperf3-set1-iperf-client to complete (timeout: 600s)..."
DEADLINE=$(($(date +%s) + 600))
while true; do
  PHASE=$(oc get pod t3-iperf3-set1-iperf-client -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t3-iperf3-set1-iperf-client"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t3-iperf3-set1-iperf-client (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t3-iperf3-set1-iperf-client did not complete within 600s"
    exit 1
  fi
  sleep 5
done
