#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t1-platform-check-checker.yaml..."
oc apply -f manifests/t1-platform-check-checker.yaml -n uat-project

echo "Waiting for t1-platform-check-checker to start..."
while true; do
  PHASE=$(oc get pod t1-platform-check-checker -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t1-platform-check-checker logs ---"
oc logs -f t1-platform-check-checker -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t1-platform-check-checker -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t1-platform-check-checker"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t1-platform-check-checker (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t1-platform-check-checker to complete (timeout: 600s)..."
DEADLINE=$(($(date +%s) + 600))
while true; do
  PHASE=$(oc get pod t1-platform-check-checker -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t1-platform-check-checker"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t1-platform-check-checker (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t1-platform-check-checker did not complete within 600s"
    exit 1
  fi
  sleep 5
done
