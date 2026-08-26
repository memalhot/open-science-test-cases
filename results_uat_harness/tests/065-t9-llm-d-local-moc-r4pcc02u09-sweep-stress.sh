#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t9-llm-d-local-moc-r4pcc02u09-sweep-stress.yaml..."
oc apply -f manifests/t9-llm-d-local-moc-r4pcc02u09-sweep-stress.yaml -n uat-project

echo "Waiting for t9-llm-d-local-moc-r4pcc02u09-sweep-stress to start..."
while true; do
  PHASE=$(oc get pod t9-llm-d-local-moc-r4pcc02u09-sweep-stress -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t9-llm-d-local-moc-r4pcc02u09-sweep-stress logs ---"
oc logs -f t9-llm-d-local-moc-r4pcc02u09-sweep-stress -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t9-llm-d-local-moc-r4pcc02u09-sweep-stress -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t9-llm-d-local-moc-r4pcc02u09-sweep-stress"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t9-llm-d-local-moc-r4pcc02u09-sweep-stress (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t9-llm-d-local-moc-r4pcc02u09-sweep-stress to complete (timeout: 900s)..."
DEADLINE=$(($(date +%s) + 900))
while true; do
  PHASE=$(oc get pod t9-llm-d-local-moc-r4pcc02u09-sweep-stress -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t9-llm-d-local-moc-r4pcc02u09-sweep-stress"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t9-llm-d-local-moc-r4pcc02u09-sweep-stress (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t9-llm-d-local-moc-r4pcc02u09-sweep-stress did not complete within 900s"
    exit 1
  fi
  sleep 5
done
