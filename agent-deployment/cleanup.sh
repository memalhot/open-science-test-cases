#!/bin/bash

set -euo pipefail

PROJECT=${PROJECT:-mm-test}
AGENT_NAME=${AGENT_NAME:-test-agent}

echo "=== Agent Cleanup Script ==="
echo "Project: $PROJECT"
echo "Agent: $AGENT_NAME"
echo

# Ensure we have admin privileges for mutating commands
if ! oc auth can-i delete deployments -n "$PROJECT" --as system:admin &>/dev/null; then
    echo "Warning: May need system:admin privileges for some operations"
fi

echo "1. Removing agent resources..."

# Remove AgentRuntime if it exists
if oc get agentruntime "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
    echo "Removing AgentRuntime..."
    oc delete agentruntime "$AGENT_NAME" -n "$PROJECT" --as system:admin
fi

# Remove AgentCard if it exists
if oc get agentcard "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
    echo "Removing AgentCard..."
    oc delete agentcard "$AGENT_NAME" -n "$PROJECT" --as system:admin
fi

# Remove main resources
echo "Removing deployment and service..."
oc delete -f sample-agent.yaml -n "$PROJECT" --as system:admin --ignore-not-found=true

echo
echo "2. Waiting for cleanup to complete..."
timeout 60 bash -c "while oc get pods -l app=$AGENT_NAME -n $PROJECT 2>/dev/null | grep -q .; do echo 'Waiting for pods to terminate...'; sleep 2; done" || {
    echo "⚠ Timeout waiting for pod termination. Checking for stuck pods..."
    STUCK_PODS=$(oc get pods -l app="$AGENT_NAME" -n "$PROJECT" --no-headers 2>/dev/null || echo "")
    if [[ -n "$STUCK_PODS" ]]; then
        echo "Stuck pods found, attempting force delete..."
        oc delete pods -l app="$AGENT_NAME" -n "$PROJECT" --grace-period=0 --force --as system:admin 2>/dev/null || true
    fi
}

echo
echo "=== Cleanup Complete ==="
echo "All agent resources have been removed from project $PROJECT"