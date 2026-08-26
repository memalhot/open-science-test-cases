#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t6-guidellm-moc-r4pcc02u05-sweep-sustained-load.yaml..."
oc apply -f manifests/t6-guidellm-moc-r4pcc02u05-sweep-sustained-load.yaml -n uat-project

echo "Waiting for t6-guidellm-moc-r4pcc02u05-sweep-sustained-load to start..."
while true; do
  PHASE=$(oc get pod t6-guidellm-moc-r4pcc02u05-sweep-sustained-load -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t6-guidellm-moc-r4pcc02u05-sweep-sustained-load logs ---"
oc logs -f t6-guidellm-moc-r4pcc02u05-sweep-sustained-load -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t6-guidellm-moc-r4pcc02u05-sweep-sustained-load -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t6-guidellm-moc-r4pcc02u05-sweep-sustained-load"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t6-guidellm-moc-r4pcc02u05-sweep-sustained-load (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t6-guidellm-moc-r4pcc02u05-sweep-sustained-load to complete (timeout: 1200s)..."
DEADLINE=$(($(date +%s) + 1200))
while true; do
  PHASE=$(oc get pod t6-guidellm-moc-r4pcc02u05-sweep-sustained-load -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t6-guidellm-moc-r4pcc02u05-sweep-sustained-load"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t6-guidellm-moc-r4pcc02u05-sweep-sustained-load (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t6-guidellm-moc-r4pcc02u05-sweep-sustained-load did not complete within 1200s"
    exit 1
  fi
  sleep 5
done
