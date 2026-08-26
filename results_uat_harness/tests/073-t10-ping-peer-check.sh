#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t10-ping-peer-check.yaml..."
oc apply -f manifests/t10-ping-peer-check.yaml -n uat-peer

echo "Waiting for t10-ping-peer-check to start..."
while true; do
  PHASE=$(oc get pod t10-ping-peer-check -o jsonpath='{.status.phase}' -n uat-peer 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t10-ping-peer-check logs ---"
oc logs -f t10-ping-peer-check -n uat-peer 2>/dev/null || true

PHASE=$(oc get pod t10-ping-peer-check -o jsonpath='{.status.phase}' -n uat-peer 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t10-ping-peer-check"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t10-ping-peer-check (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t10-ping-peer-check to complete (timeout: 600s)..."
DEADLINE=$(($(date +%s) + 600))
while true; do
  PHASE=$(oc get pod t10-ping-peer-check -o jsonpath='{.status.phase}' -n uat-peer 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t10-ping-peer-check"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t10-ping-peer-check (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t10-ping-peer-check did not complete within 600s"
    exit 1
  fi
  sleep 5
done
