#!/bin/bash

set -euo pipefail

# Agent deployment test case based on Red Hat OpenShift AI Self-Managed 3.4
# Section 4.1: AgentCard and AgentRuntime features

PROJECT=${PROJECT:-mm-test}
AGENT_NAME=${AGENT_NAME:-test-agent}
TIMEOUT=${TIMEOUT:-300}

echo "=== Agent Deployment Test Case ==="
echo "Project: $PROJECT"
echo "Agent: $AGENT_NAME"
echo "Timeout: ${TIMEOUT}s"
echo

# Test 1: Check if agent deployment exists
echo "1. Checking agent deployment..."
if oc get deployment "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
    echo "✓ Agent deployment '$AGENT_NAME' exists"

    # Check deployment status
    READY_REPLICAS=$(oc get deployment "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    READY_REPLICAS=${READY_REPLICAS:-0}  # Default to 0 if empty
    DESIRED_REPLICAS=$(oc get deployment "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    DESIRED_REPLICAS=${DESIRED_REPLICAS:-1}  # Default to 1 if empty

    if [[ "$READY_REPLICAS" == "$DESIRED_REPLICAS" ]]; then
        echo "✓ Agent deployment is ready ($READY_REPLICAS/$DESIRED_REPLICAS)"
    else
        echo "✗ Agent deployment not ready ($READY_REPLICAS/$DESIRED_REPLICAS)"
        exit 1
    fi
else
    echo "✗ Agent deployment '$AGENT_NAME' not found"
    exit 1
fi

# Test 2: Verify agent has required labels for discovery
echo
echo "2. Checking agent labels..."
AGENT_TYPE_LABEL=$(oc get deployment "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.metadata.labels.kagenti\.io/type}' 2>/dev/null || echo "")
if [[ "$AGENT_TYPE_LABEL" == "agent" ]]; then
    echo "✓ Agent has kagenti.io/type: agent label"
else
    echo "✗ Agent missing kagenti.io/type: agent label (found: '$AGENT_TYPE_LABEL')"
    exit 1
fi

# Check for protocol label using proper JSON parsing
if command -v jq &>/dev/null; then
    PROTOCOL_LABELS=$(oc get deployment "$AGENT_NAME" -n "$PROJECT" -o json 2>/dev/null | jq -r '.metadata.labels | to_entries[] | select(.key | startswith("protocol.kagenti.io/")) | .key' 2>/dev/null | head -1 || echo "")
else
    # Fallback to grep if jq not available
    PROTOCOL_LABELS=$(oc get deployment "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.metadata.labels}' 2>/dev/null | tr ',' '\n' | grep 'protocol\.kagenti\.io' | head -1 || echo "")
fi
if [[ -n "$PROTOCOL_LABELS" ]]; then
    echo "✓ Agent has protocol label: $PROTOCOL_LABELS"
else
    echo "✗ Agent missing protocol.kagenti.io/* label"
    exit 1
fi

# Test 3: Check AgentCard creation for discovery
echo
echo "3. Checking AgentCard resource..."
# AgentCard should be automatically created by platform
if oc get agentcard "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
    echo "✓ AgentCard '$AGENT_NAME' exists"

    # Check AgentCard contents
    AGENT_ENDPOINTS=$(oc get agentcard "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.spec.endpoints}' 2>/dev/null || echo "[]")
    AGENT_CAPABILITIES=$(oc get agentcard "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.spec.capabilities}' 2>/dev/null || echo "[]")

    if [[ "$AGENT_ENDPOINTS" != "[]" ]]; then
        echo "✓ AgentCard has endpoints configured"
    else
        echo "⚠ AgentCard has no endpoints (may be normal for some agent types)"
    fi

    if [[ "$AGENT_CAPABILITIES" != "[]" ]]; then
        echo "✓ AgentCard has capabilities advertised"
    else
        echo "⚠ AgentCard has no capabilities (may be normal for some agent types)"
    fi
else
    echo "⚠ AgentCard '$AGENT_NAME' not found (may not be created yet)"
fi

# Test 4: Check AgentRuntime configuration
echo
echo "4. Checking AgentRuntime resource..."
if oc get agentruntime "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
    echo "✓ AgentRuntime '$AGENT_NAME' exists"

    # Check if AgentRuntime references the correct deployment
    TARGET_REF=$(oc get agentruntime "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.spec.targetRef.name}' 2>/dev/null || echo "")
    if [[ "$TARGET_REF" == "$AGENT_NAME" ]]; then
        echo "✓ AgentRuntime references correct deployment"
    else
        echo "✗ AgentRuntime targetRef mismatch (expected: '$AGENT_NAME', found: '$TARGET_REF')"
        exit 1
    fi
else
    echo "⚠ AgentRuntime '$AGENT_NAME' not found (may not be configured)"
fi

# Test 5: Check pod injection and sidecars
echo
echo "5. Checking agent pod configuration..."
# Check if any pods exist first
POD_COUNT=$(oc get pods -n "$PROJECT" -l app="$AGENT_NAME" --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "$POD_COUNT" -gt 0 ]]; then
    POD_NAME=$(oc get pods -n "$PROJECT" -l app="$AGENT_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
else
    POD_NAME=""
fi

if [[ -n "$POD_NAME" ]]; then
    echo "✓ Agent pod '$POD_NAME' found"

    # Check for injected sidecars (AuthBridge, SPIFFE helper)
    CONTAINERS=$(oc get pod "$POD_NAME" -n "$PROJECT" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")

    if echo "$CONTAINERS" | grep -q "authbridge"; then
        echo "✓ AuthBridge sidecar injected"
    else
        echo "⚠ AuthBridge sidecar not found"
    fi

    if echo "$CONTAINERS" | grep -q "spiffe-helper"; then
        echo "✓ SPIFFE helper sidecar injected"
    else
        echo "⚠ SPIFFE helper sidecar not found"
    fi

    # Check pod status
    POD_PHASE=$(oc get pod "$POD_NAME" -n "$PROJECT" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$POD_PHASE" == "Running" ]]; then
        echo "✓ Agent pod is running"
    else
        echo "✗ Agent pod not running (phase: $POD_PHASE)"
        exit 1
    fi
else
    echo "✗ No agent pods found"
    exit 1
fi

# Test 6: Check agent service/endpoint accessibility
echo
echo "6. Checking agent service..."
if oc get service "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
    echo "✓ Agent service '$AGENT_NAME' exists"

    SERVICE_TYPE=$(oc get service "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.spec.type}' 2>/dev/null || echo "ClusterIP")
    SERVICE_PORTS=$(oc get service "$AGENT_NAME" -n "$PROJECT" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")

    echo "✓ Service type: $SERVICE_TYPE"
    echo "✓ Service ports: $SERVICE_PORTS"

    # Test basic connectivity if port 8080 is available
    if echo "$SERVICE_PORTS" | grep -q "8080"; then
        echo "Testing agent connectivity..."
        # Check if curl is available in the container, fallback to simpler test
        if timeout 10 oc exec -n "$PROJECT" deploy/"$AGENT_NAME" -- which curl &>/dev/null; then
            if timeout 10 oc exec -n "$PROJECT" deploy/"$AGENT_NAME" -- curl -s -f "http://$AGENT_NAME:8080/health" &>/dev/null; then
                echo "✓ Agent health endpoint responsive"
            else
                echo "⚠ Agent health endpoint not responding (may not implement /health)"
            fi
        else
            echo "⚠ curl not available in container, skipping health check"
        fi
    fi
else
    echo "⚠ Agent service '$AGENT_NAME' not found"
fi

# Test 7: Check distributed tracing configuration (if enabled)
echo
echo "7. Checking distributed tracing..."
OTEL_CONFIG=$(oc get pod "$POD_NAME" -n "$PROJECT" -o jsonpath='{.spec.containers[*].env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' 2>/dev/null || echo "")
if [[ -n "$OTEL_CONFIG" ]]; then
    echo "✓ OpenTelemetry configuration found: $OTEL_CONFIG"
else
    echo "⚠ OpenTelemetry not configured"
fi

echo
echo "=== Agent Deployment Test Summary ==="
echo "✓ Agent '$AGENT_NAME' deployment verification complete"
echo "✓ All critical checks passed"
echo "⚠ Warnings indicate optional features that may not be configured"