#!/bin/bash
# Assisted by Claude Opus 4.6
set -e
echo "Applying manifests/t7-inference-perf-moc-r4pcc02u05-sweep-constant-high.yaml..."
oc apply -f manifests/t7-inference-perf-moc-r4pcc02u05-sweep-constant-high.yaml -n uat-project

echo "Waiting for t7-inference-perf-moc-r4pcc02u05-sweep-constant-high to start..."
while true; do
  PHASE=$(oc get pod t7-inference-perf-moc-r4pcc02u05-sweep-constant-high -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  case "$PHASE" in
    Running|Succeeded|Failed) break ;;
    *) sleep 2 ;;
  esac
done

echo "--- t7-inference-perf-moc-r4pcc02u05-sweep-constant-high logs ---"
oc logs -f t7-inference-perf-moc-r4pcc02u05-sweep-constant-high -n uat-project 2>/dev/null || true

PHASE=$(oc get pod t7-inference-perf-moc-r4pcc02u05-sweep-constant-high -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Unknown")
if [ "$PHASE" = "Succeeded" ]; then
  echo "PASSED: t7-inference-perf-moc-r4pcc02u05-sweep-constant-high"
  exit 0
elif [ "$PHASE" = "Failed" ]; then
  echo "FAILED: t7-inference-perf-moc-r4pcc02u05-sweep-constant-high (phase: $PHASE)"
  exit 1
fi

echo "Waiting for t7-inference-perf-moc-r4pcc02u05-sweep-constant-high to complete (timeout: 1200s)..."
DEADLINE=$(($(date +%s) + 1200))
while true; do
  PHASE=$(oc get pod t7-inference-perf-moc-r4pcc02u05-sweep-constant-high -o jsonpath='{.status.phase}' -n uat-project 2>/dev/null || echo "Pending")
  if [ "$PHASE" = "Succeeded" ]; then
    echo "PASSED: t7-inference-perf-moc-r4pcc02u05-sweep-constant-high"
    exit 0
  elif [ "$PHASE" = "Failed" ]; then
    echo "FAILED: t7-inference-perf-moc-r4pcc02u05-sweep-constant-high (phase: $PHASE)"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT: t7-inference-perf-moc-r4pcc02u05-sweep-constant-high did not complete within 1200s"
    exit 1
  fi
  sleep 5
done
