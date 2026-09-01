#!/bin/bash

set -euo pipefail

# Configuration
OPENSHELL_NAMESPACE=${OPENSHELL_NAMESPACE:-openshell}
SANDBOX_NAMESPACE=${SANDBOX_NAMESPACE:-openshell-sandboxes}
TIMEOUT=${TIMEOUT:-300}

echo "=== NVIDIA OpenShell Deployment Test ==="
echo "Namespace: $OPENSHELL_NAMESPACE"
echo "Sandbox Namespace: $SANDBOX_NAMESPACE"
echo "Timeout: ${TIMEOUT}s"
echo

# Color output
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# Test tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_WARNED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    local required="${3:-true}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if eval "$test_command" &>/dev/null; then
        green "✓ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        if [ "$required" = "true" ]; then
            red "✗ $test_name"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        else
            yellow "⚠ $test_name"
            TESTS_WARNED=$((TESTS_WARNED + 1))
        fi
        return 1
    fi
}

echo "1. Agent Sandbox CRD Checks"
echo "==========================="

run_test "Sandbox CRD installed" \
    "oc get crd sandboxes.agents.x-k8s.io"

run_test "SandboxClass CRD installed" \
    "oc get crd sandboxclasses.agents.x-k8s.io" false

echo
echo "2. Namespace Checks"
echo "==================="

run_test "OpenShell namespace exists" \
    "oc get namespace $OPENSHELL_NAMESPACE"

run_test "Sandbox namespace exists" \
    "oc get namespace $SANDBOX_NAMESPACE" false

echo
echo "3. Gateway Deployment"
echo "===================="

# Detect workload type
WORKLOAD_TYPE=""
WORKLOAD_NAME=""

if oc get statefulset -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell &>/dev/null; then
    WORKLOAD_TYPE="statefulset"
    WORKLOAD_NAME=$(oc get statefulset -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
elif oc get deployment -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell &>/dev/null; then
    WORKLOAD_TYPE="deployment"
    WORKLOAD_NAME=$(oc get deployment -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -n "$WORKLOAD_NAME" ]; then
    green "✓ Gateway $WORKLOAD_TYPE '$WORKLOAD_NAME' found"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Check ready replicas
    if [ "$WORKLOAD_TYPE" = "statefulset" ]; then
        READY=$(oc get statefulset "$WORKLOAD_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    else
        READY=$(oc get deployment "$WORKLOAD_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    fi

    if [ "$READY" -ge 1 ]; then
        green "✓ Gateway has $READY ready replica(s)"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        red "✗ Gateway has 0 ready replicas"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    red "✗ No gateway StatefulSet or Deployment found"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo
echo "4. Service Checks"
echo "================"

SVC_NAME=$(oc get svc -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$SVC_NAME" ]; then
    green "✓ Gateway service '$SVC_NAME' exists"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Check service endpoints
    ENDPOINTS=$(oc get endpoints "$SVC_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [ -n "$ENDPOINTS" ]; then
        green "✓ Service has endpoints"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        red "✗ Service has no endpoints"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Check service ports
    GRPC_PORT=$(oc get svc "$SVC_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="grpc")].port}' 2>/dev/null || echo "")
    HEALTH_PORT=$(oc get svc "$SVC_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="health")].port}' 2>/dev/null || echo "")
    METRICS_PORT=$(oc get svc "$SVC_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}' 2>/dev/null || echo "")

    if [ -n "$GRPC_PORT" ]; then
        green "✓ gRPC port configured: $GRPC_PORT"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        yellow "⚠ gRPC port not found"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_WARNED=$((TESTS_WARNED + 1))
    fi

    if [ -n "$HEALTH_PORT" ]; then
        green "✓ Health port configured: $HEALTH_PORT"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi

    if [ -n "$METRICS_PORT" ]; then
        green "✓ Metrics port configured: $METRICS_PORT"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
else
    red "✗ Gateway service not found"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo
echo "5. Pod Health Checks"
echo "==================="

POD_NAME=$(oc get pods -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD_NAME" ]; then
    green "✓ Gateway pod '$POD_NAME' found"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Check pod phase
    POD_PHASE=$(oc get pod "$POD_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$POD_PHASE" = "Running" ]; then
        green "✓ Pod is running"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        red "✗ Pod phase: $POD_PHASE"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Health endpoint check
    if [ -n "$HEALTH_PORT" ]; then
        run_test "Health endpoint responding" \
            "timeout 10 oc exec $POD_NAME -n $OPENSHELL_NAMESPACE -- curl -sf http://localhost:${HEALTH_PORT}/health" false
    fi
else
    red "✗ Gateway pod not found"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo
echo "6. Database and Storage"
echo "======================"

if [ "$WORKLOAD_TYPE" = "statefulset" ]; then
    run_test "PersistentVolumeClaim exists" \
        "oc get pvc -n $OPENSHELL_NAMESPACE -l app.kubernetes.io/name=openshell" false

    PVC_NAME=$(oc get pvc -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$PVC_NAME" ]; then
        PVC_STATUS=$(oc get pvc "$PVC_NAME" -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$PVC_STATUS" = "Bound" ]; then
            green "✓ PVC '$PVC_NAME' is bound"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_PASSED=$((TESTS_PASSED + 1))
        fi
    fi
else
    yellow "⚠ Deployment mode, assuming external database"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_WARNED=$((TESTS_WARNED + 1))
fi

echo
echo "7. RBAC and Security"
echo "==================="

run_test "Service accounts exist" \
    "oc get sa -n $OPENSHELL_NAMESPACE -l app.kubernetes.io/name=openshell"

# Check SCC
SA_NAME=$(oc get sa -n "$OPENSHELL_NAMESPACE" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "openshell-sandbox")
if oc adm policy who-can use scc privileged -n "$OPENSHELL_NAMESPACE" 2>/dev/null | grep -q "$SA_NAME"; then
    green "✓ Service account has privileged SCC"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    yellow "⚠ Service account may not have privileged SCC (required for sandboxes)"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_WARNED=$((TESTS_WARNED + 1))
fi

run_test "Roles/RoleBindings exist" \
    "oc get role,rolebinding -n $OPENSHELL_NAMESPACE -l app.kubernetes.io/name=openshell" false

echo
echo "8. Route (External Access)"
echo "=========================="

run_test "Route exists" \
    "oc get route openshell-gateway -n $OPENSHELL_NAMESPACE" false

if oc get route openshell-gateway -n "$OPENSHELL_NAMESPACE" &>/dev/null; then
    ROUTE_URL=$(oc get route openshell-gateway -n "$OPENSHELL_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$ROUTE_URL" ]; then
        green "✓ Route URL: https://$ROUTE_URL"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
fi

echo
echo "=== Test Summary ==="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Warnings:     $TESTS_WARNED"
echo "Failed:       $TESTS_FAILED"
echo

if [ $TESTS_FAILED -eq 0 ]; then
    if [ $TESTS_WARNED -gt 0 ]; then
        yellow "OpenShell deployment successful with $TESTS_WARNED warnings"
        exit 0
    else
        green "OpenShell deployment fully successful!"
        exit 0
    fi
else
    red "OpenShell deployment failed with $TESTS_FAILED critical issues"
    echo
    echo "Troubleshooting commands:"
    echo "  oc describe $WORKLOAD_TYPE $WORKLOAD_NAME -n $OPENSHELL_NAMESPACE"
    echo "  oc logs -l app.kubernetes.io/name=openshell -n $OPENSHELL_NAMESPACE"
    echo "  oc get events -n $OPENSHELL_NAMESPACE --sort-by='.lastTimestamp'"
    exit 1
fi
