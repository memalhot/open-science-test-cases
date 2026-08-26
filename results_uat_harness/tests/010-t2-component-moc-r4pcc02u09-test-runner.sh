#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t2-component-moc-r4pcc02u09-test-runner.yaml..."
oc apply -f manifests/t2-component-moc-r4pcc02u09-test-runner.yaml -n uat-project

echo "Waiting for t2-component-moc-r4pcc02u09-test-runner to start..."
while true; do
  PHASE=$(oc get pod t2-component-moc-r4pcc02u09-test-runner -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t2-component-moc-r4pcc02u09-test-runner logs ---"
oc logs -f t2-component-moc-r4pcc02u09-test-runner -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t2-component-moc-r4pcc02u09-test-runner -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t2-component-moc-r4pcc02u09-test-runner"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t2-component-moc-r4pcc02u09-test-runner (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t2-component-moc-r4pcc02u09-test-runner to complete (timeout: 600s)..."
DEADLINE=$(($(date +%s) + 600))
while true; do
  PHASE=$(oc get pod t2-component-moc-r4pcc02u09-test-runner -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t2-component-moc-r4pcc02u09-test-runner"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t2-component-moc-r4pcc02u09-test-runner (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t2-component-moc-r4pcc02u09-test-runner did not complete within 600s"
    exit 1
  fi
  sleep 5
done
