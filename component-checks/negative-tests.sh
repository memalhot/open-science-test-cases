#!/bin/bash
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
TEST_PREFIX="neg-test"
PASSED=0
FAILED=0

pass() {
  echo "PASS"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "FAIL ($1)" >&2
  FAILED=$((FAILED + 1))
}

cleanup() {
  echo ""
  echo "=== Cleaning up test resources ==="
  oc delete pod "${TEST_PREFIX}-gpu-overreq" -n "${PROJECT}" --as system:admin --ignore-not-found --wait=false 2>/dev/null || true
  oc delete pod "${TEST_PREFIX}-teardown" -n "${PROJECT}" --as system:admin --ignore-not-found --wait=false 2>/dev/null || true
  oc delete pod "${TEST_PREFIX}-mem-overreq" -n "${PROJECT}" --as system:admin --ignore-not-found --wait=false 2>/dev/null || true
  oc wait --for=delete pod/"${TEST_PREFIX}-gpu-overreq" -n "${PROJECT}" --timeout=30s 2>/dev/null || true
  oc wait --for=delete pod/"${TEST_PREFIX}-teardown" -n "${PROJECT}" --timeout=30s 2>/dev/null || true
  oc wait --for=delete pod/"${TEST_PREFIX}-mem-overreq" -n "${PROJECT}" --timeout=30s 2>/dev/null || true
}
trap cleanup EXIT

oc project "${PROJECT}"

echo "========================================="
echo "  Negative / Failure-Mode Tests"
echo "========================================="

# =========================================================
#  1. GPU over-request → pod should go Pending, not crash
# =========================================================

echo ""
echo "=== Resource Over-Request ==="
echo ""
echo "--- Pod requesting 99 GPUs goes Pending with Unschedulable reason ---"

POD_GPU="${TEST_PREFIX}-gpu-overreq"

oc run "${POD_GPU}" -n "${PROJECT}" --as system:admin \
  --image=busybox --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "test",
        "image": "busybox",
        "command": ["sleep", "3600"],
        "resources": {
          "requests": {"nvidia.com/gpu": "99"},
          "limits": {"nvidia.com/gpu": "99"}
        }
      }],
      "tolerations": [{
        "key": "nvidia.com/gpu",
        "operator": "Exists",
        "effect": "NoSchedule"
      }]
    }
  }' 2>/dev/null

sleep 10

POD_PHASE=$(oc get pod "${POD_GPU}" -n "${PROJECT}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
SCHED_REASON=$(oc get pod "${POD_GPU}" -n "${PROJECT}" \
  -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || echo "")

if [[ "${POD_PHASE}" == "Pending" ]]; then
  pass
  echo "  phase=Pending, reason=${SCHED_REASON:-unknown}"
else
  fail "expected Pending, got phase=${POD_PHASE:-not found}"
fi

# =========================================================
#  2. Memory over-request → same behavior
# =========================================================

echo ""
echo "--- Pod requesting 99Ti memory goes Pending ---"

POD_MEM="${TEST_PREFIX}-mem-overreq"

oc run "${POD_MEM}" -n "${PROJECT}" --as system:admin \
  --image=busybox --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "test",
        "image": "busybox",
        "command": ["sleep", "3600"],
        "resources": {
          "requests": {"memory": "99Ti"},
          "limits": {"memory": "99Ti"}
        }
      }]
    }
  }' 2>/dev/null

sleep 5

POD_PHASE=$(oc get pod "${POD_MEM}" -n "${PROJECT}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

if [[ "${POD_PHASE}" == "Pending" ]]; then
  pass
else
  fail "expected Pending, got phase=${POD_PHASE:-not found}"
fi

# =========================================================
#  3. Pending workloads are discoverable
# =========================================================
#  The "vacation test": if something can't schedule, you need
#  to be able to find it before walking away from the cluster.

echo ""
echo "--- Pending pods are discoverable via field-selector ---"

PENDING_PODS=$(oc get pods -n "${PROJECT}" \
  --field-selector=status.phase=Pending -o name 2>/dev/null || echo "")
PENDING_COUNT=$(echo "${PENDING_PODS}" | grep -c . || echo "0")

if [[ "${PENDING_COUNT}" -ge 2 ]]; then
  pass
  echo "  found ${PENDING_COUNT} pending pod(s) — you can detect stalled workloads"
else
  fail "expected to find the 2 pending test pods via field-selector"
fi

# Clean up over-request pods before teardown tests
oc delete pod "${POD_GPU}" "${POD_MEM}" -n "${PROJECT}" --as system:admin --ignore-not-found 2>/dev/null || true
oc wait --for=delete pod/"${POD_GPU}" pod/"${POD_MEM}" -n "${PROJECT}" --timeout=30s 2>/dev/null || true

# =========================================================
#  4. Unschedulable pod can be deleted cleanly
# =========================================================

echo ""
echo "=== Teardown Reliability ==="
echo ""
echo "--- Unschedulable pods do not get stuck on deletion ---"

STILL_EXISTS=$(oc get pod "${POD_GPU}" "${POD_MEM}" -n "${PROJECT}" -o name 2>/dev/null || echo "")

if [[ -z "${STILL_EXISTS}" ]]; then
  pass
  echo "  both over-request pods deleted cleanly"
else
  fail "pods still exist after deletion: ${STILL_EXISTS}"
fi

# =========================================================
#  5. Running pod terminates within 60s of deletion
# =========================================================

echo ""
echo "--- Running pod terminates within 60s of deletion ---"

POD_TEARDOWN="${TEST_PREFIX}-teardown"

oc run "${POD_TEARDOWN}" -n "${PROJECT}" --as system:admin \
  --image=busybox --restart=Never \
  --command -- sleep 3600 2>/dev/null

STARTED=false
for (( i=1; i<=30; i++ )); do
  PHASE=$(oc get pod "${POD_TEARDOWN}" -n "${PROJECT}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "${PHASE}" == "Running" ]]; then
    STARTED=true
    break
  fi
  sleep 2
done

if ! ${STARTED}; then
  fail "test pod never reached Running (phase=${PHASE:-not found}), skipping deletion test"
else
  oc delete pod "${POD_TEARDOWN}" -n "${PROJECT}" --as system:admin 2>/dev/null

  DEADLINE=60
  ELAPSED=0
  while [[ ${ELAPSED} -lt ${DEADLINE} ]]; do
    EXISTS=$(oc get pod "${POD_TEARDOWN}" -n "${PROJECT}" -o name 2>/dev/null || echo "")
    if [[ -z "${EXISTS}" ]]; then
      break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
  done

  if [[ -z "$(oc get pod "${POD_TEARDOWN}" -n "${PROJECT}" -o name 2>/dev/null || echo "")" ]]; then
    pass
    echo "  terminated in ~${ELAPSED}s"
  else
    DEL_TS=$(oc get pod "${POD_TEARDOWN}" -n "${PROJECT}" \
      -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "none")
    fail "pod still exists after ${DEADLINE}s (deletionTimestamp=${DEL_TS})"
  fi
fi

# =========================================================
#  6. No pods stuck in Terminating state
# =========================================================
#  Catches finalizer deadlocks, stuck volume unmounts, etc.

echo ""
echo "=== Namespace Health ==="
echo ""
echo "--- No pods stuck in Terminating > 5 minutes ---"

STUCK_TERMINATING=$(oc get pods -n "${PROJECT}" -o json 2>/dev/null \
  | python3 -c "
import sys, json
from datetime import datetime, timezone
data = json.load(sys.stdin)
stuck = []
now = datetime.now(timezone.utc)
for pod in data.get('items', []):
    ts = pod.get('metadata', {}).get('deletionTimestamp')
    if ts:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        age_min = (now - dt).total_seconds() / 60
        if age_min > 5:
            stuck.append(f\"{pod['metadata']['name']} ({age_min:.0f}m)\")
if stuck:
    print(', '.join(stuck))
" 2>/dev/null || echo "")

if [[ -z "${STUCK_TERMINATING}" ]]; then
  pass
else
  fail "stuck Terminating: ${STUCK_TERMINATING}"
fi

# =========================================================
#  7. No orphaned pods Pending > 10 minutes
# =========================================================
#  Catches forgotten workloads that will auto-start if
#  resources become available (the "vacation" scenario).

echo ""
echo "--- No pods stuck Pending > 10 minutes ---"

STALE_PENDING=$(oc get pods -n "${PROJECT}" --field-selector=status.phase=Pending -o json 2>/dev/null \
  | python3 -c "
import sys, json
from datetime import datetime, timezone
data = json.load(sys.stdin)
stuck = []
now = datetime.now(timezone.utc)
for pod in data.get('items', []):
    ts = pod.get('metadata', {}).get('creationTimestamp', '')
    if ts:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        age_min = (now - dt).total_seconds() / 60
        if age_min > 10:
            stuck.append(f\"{pod['metadata']['name']} ({age_min:.0f}m)\")
if stuck:
    print(', '.join(stuck))
" 2>/dev/null || echo "")

if [[ -z "${STALE_PENDING}" ]]; then
  pass
else
  fail "stale Pending pods: ${STALE_PENDING}"
fi

# --- Summary ---

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
