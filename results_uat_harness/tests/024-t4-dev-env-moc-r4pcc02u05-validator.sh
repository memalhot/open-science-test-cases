#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t4-dev-env-moc-r4pcc02u05-validator.yaml..."
oc apply -f manifests/t4-dev-env-moc-r4pcc02u05-validator.yaml -n uat-project

echo "Waiting for t4-dev-env-moc-r4pcc02u05-validator to start..."
while true; do
  PHASE=$(oc get pod t4-dev-env-moc-r4pcc02u05-validator -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t4-dev-env-moc-r4pcc02u05-validator logs ---"
oc logs -f t4-dev-env-moc-r4pcc02u05-validator -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t4-dev-env-moc-r4pcc02u05-validator -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t4-dev-env-moc-r4pcc02u05-validator"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t4-dev-env-moc-r4pcc02u05-validator (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t4-dev-env-moc-r4pcc02u05-validator to complete (timeout: 600s)..."
DEADLINE=$(($(date +%s) + 600))
while true; do
  PHASE=$(oc get pod t4-dev-env-moc-r4pcc02u05-validator -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t4-dev-env-moc-r4pcc02u05-validator"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t4-dev-env-moc-r4pcc02u05-validator (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t4-dev-env-moc-r4pcc02u05-validator did not complete within 600s"
    exit 1
  fi
  sleep 5
done
