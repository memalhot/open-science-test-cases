#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t5-kserve-test-runner.yaml..."
oc apply -f manifests/t5-kserve-test-runner.yaml -n uat-project

echo "Waiting for t5-kserve-test-runner to start..."
while true; do
  PHASE=$(oc get pod t5-kserve-test-runner -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t5-kserve-test-runner logs ---"
oc logs -f t5-kserve-test-runner -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t5-kserve-test-runner -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t5-kserve-test-runner"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t5-kserve-test-runner (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t5-kserve-test-runner to complete (timeout: 900s)..."
DEADLINE=$(($(date +%s) + 900))
while true; do
  PHASE=$(oc get pod t5-kserve-test-runner -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t5-kserve-test-runner"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t5-kserve-test-runner (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t5-kserve-test-runner did not complete within 900s"
    exit 1
  fi
  sleep 5
done
