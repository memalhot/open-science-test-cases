#!/bin/bash

set -euo pipefail

PROJECT=${PROJECT:-ajamias}
AGENT_NAME=${AGENT_NAME:-test-agent}

echo "=== Agent Deployment Script ==="
echo "Project: $PROJECT"
echo "Agent: $AGENT_NAME"
echo

# Ensure we have admin privileges for mutating commands
if ! oc auth can-i create deployments -n "$PROJECT" --as system:admin &>/dev/null; then
    echo "Warning: May need system:admin privileges for some operations"
fi

echo "1. Creating project if it doesn't exist..."
if ! oc get project "$PROJECT" &>/dev/null; then
    echo "Creating project $PROJECT..."
    oc new-project "$PROJECT" --as system:admin || oc adm new-project "$PROJECT"
else
    echo "Project $PROJECT already exists"
fi

echo
echo "2. Deploying sample agent..."
oc apply -f sample-agent.yaml -n "$PROJECT" --as system:admin

echo
echo "3. Waiting for deployment to be ready..."
oc rollout status deployment/"$AGENT_NAME" -n "$PROJECT" --timeout=300s --watch

echo
echo "4. Checking agent status..."
oc get deployment,service,pod -l app="$AGENT_NAME" -n "$PROJECT"

# Check if AgentCard CRD exists (it may not on all clusters)
if oc get crd agentcards.kagenti.io &>/dev/null; then
    echo
    echo "5. Checking AgentCard..."
    if oc get agentcard "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
        oc describe agentcard "$AGENT_NAME" -n "$PROJECT"
    else
        echo "AgentCard not created yet (may be created automatically by platform)"
    fi
else
    echo
    echo "5. AgentCard CRD not available on this cluster"
fi

# Check if AgentRuntime CRD exists
if oc get crd agentruntimes.kagenti.io &>/dev/null; then
    echo
    echo "6. Checking AgentRuntime..."
    if oc get agentruntime "$AGENT_NAME" -n "$PROJECT" &>/dev/null; then
        oc describe agentruntime "$AGENT_NAME" -n "$PROJECT"
    else
        echo "AgentRuntime not created yet (may be created automatically by platform)"
    fi
else
    echo
    echo "6. AgentRuntime CRD not available on this cluster"
fi

echo
echo "=== Deployment Complete ==="
echo "Agent URL: http://$AGENT_NAME.$PROJECT.svc.cluster.local:8080"
echo "Health check: curl http://$AGENT_NAME.$PROJECT.svc.cluster.local:8080/health"
echo "Capabilities: curl http://$AGENT_NAME.$PROJECT.svc.cluster.local:8080/capabilities"
echo
echo "Run './test-agent-deployment.sh' to verify the deployment"
