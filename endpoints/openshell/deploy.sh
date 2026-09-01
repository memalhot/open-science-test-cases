#!/bin/bash

set -euo pipefail

# Configuration
OPENSHELL_NAMESPACE=${OPENSHELL_NAMESPACE:-openshell}
OPENSHELL_VERSION=${OPENSHELL_VERSION:-0.0.116}
SANDBOX_NAMESPACE=${SANDBOX_NAMESPACE:-openshell-sandboxes}
AGENT_SANDBOX_VERSION=${AGENT_SANDBOX_VERSION:-v1.0.0}
AGENT_SANDBOX_MANIFEST=${AGENT_SANDBOX_MANIFEST:-https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox-with-extensions.yaml}

echo "=== NVIDIA OpenShell Deployment Script ==="
echo "Namespace: $OPENSHELL_NAMESPACE"
echo "Version: $OPENSHELL_VERSION"
echo "Sandbox Namespace: $SANDBOX_NAMESPACE"
echo

# Check prerequisites
echo "0. Checking prerequisites..."
if ! command -v helm &>/dev/null; then
    echo "✗ helm not found. Install from https://helm.sh/docs/intro/install/"
    exit 1
fi

HELM_VERSION=$(helm version --short | grep -oP 'v\K[0-9]+\.[0-9]+' || echo "0.0")
if ! awk -v ver="$HELM_VERSION" 'BEGIN{exit !(ver >= 3.18)}'; then
    echo "⚠ Helm version $HELM_VERSION detected. Recommend >= 3.18.0"
fi

echo "✓ Prerequisites check passed"
echo

# Step 1: Install agent-sandbox CRDs
echo "1. Installing kubernetes-sigs agent-sandbox CRDs..."
if oc get crd sandboxes.agents.x-k8s.io --as system:admin &>/dev/null; then
    echo "✓ Agent sandbox CRDs already installed"
else
    echo "Applying manifest: $AGENT_SANDBOX_MANIFEST"
    oc apply -f "$AGENT_SANDBOX_MANIFEST" --as system:admin
    echo "✓ Agent sandbox CRDs installed"
fi

# Wait for CRDs to be established
echo "Waiting for CRDs to be established..."
timeout 60 bash -c 'until oc get crd sandboxes.agents.x-k8s.io --as system:admin &>/dev/null; do sleep 2; done' || {
    echo "✗ Timeout waiting for CRDs"
    exit 1
}
echo "✓ CRDs established"
echo

# Step 2: Create namespaces
echo "2. Creating namespaces..."
if oc get namespace "$OPENSHELL_NAMESPACE" --as system:admin &>/dev/null; then
    echo "✓ Namespace $OPENSHELL_NAMESPACE already exists"
else
    oc create namespace "$OPENSHELL_NAMESPACE" --as system:admin
    echo "✓ Namespace $OPENSHELL_NAMESPACE created"
fi

if oc get namespace "$SANDBOX_NAMESPACE" --as system:admin &>/dev/null; then
    echo "✓ Namespace $SANDBOX_NAMESPACE already exists"
else
    oc create namespace "$SANDBOX_NAMESPACE" --as system:admin
    echo "✓ Namespace $SANDBOX_NAMESPACE created"
fi
echo

# Step 3: Configure Security Context Constraints
echo "3. Configuring OpenShift Security Context Constraints..."
# OpenShell sandboxes require privileged SCC
if oc get sa openshell-sandbox -n "$OPENSHELL_NAMESPACE" --as system:admin &>/dev/null 2>&1; then
    echo "Service account openshell-sandbox exists, checking SCC..."
else
    echo "Service account will be created by Helm, will configure SCC post-install"
fi
echo

# Step 4: Deploy OpenShell via Helm
echo "4. Deploying OpenShell via Helm..."
HELM_CHART="oci://ghcr.io/nvidia/openshell/helm-chart"

if [ "$OPENSHELL_VERSION" = "latest" ]; then
    echo "Using latest version (0.0.0-dev tag)"
    HELM_VERSION_FLAG="--version 0.0.0-dev"
else
    HELM_VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "Installing from: $HELM_CHART"
echo "Using helm template + oc apply (Helm doesn't support --as system:admin)"

# Render Helm template to YAML
echo "Rendering Helm template..."
# shellcheck disable=SC2086
helm template openshell "$HELM_CHART" \
    $HELM_VERSION_FLAG \
    --namespace "$OPENSHELL_NAMESPACE" \
    --values values-openshift.yaml \
    --set server.sandboxNamespace="$SANDBOX_NAMESPACE" \
    --set agentSandbox.preflight.enabled=false \
    > /tmp/openshell-manifests.yaml

echo "Applying manifests with system:admin..."
# Apply cluster-scoped and openshell namespace resources
oc apply -f /tmp/openshell-manifests.yaml -n "$OPENSHELL_NAMESPACE" --as system:admin 2>&1 | grep -v "the namespace from the provided object.*does not match" || true

# Apply sandbox namespace resources
oc apply -f /tmp/openshell-manifests.yaml -n "$SANDBOX_NAMESPACE" --as system:admin 2>&1 | grep -v "the namespace from the provided object.*does not match" || true

echo "✓ Manifests applied"
echo "Waiting for resources to be ready..."
sleep 5
echo

# Step 5: Post-install SCC configuration
echo "5. Configuring post-install SCC..."
# Wait for service account in sandbox namespace
timeout 60 bash -c "until oc get sa openshell-sandbox -n $SANDBOX_NAMESPACE --as system:admin &>/dev/null; do sleep 2; done" || {
    echo "⚠ openshell-sandbox service account not found in $SANDBOX_NAMESPACE"
}

# Grant privileged SCC to sandbox service account
if oc get sa openshell-sandbox -n "$SANDBOX_NAMESPACE" --as system:admin &>/dev/null; then
    echo "Granting privileged SCC to openshell-sandbox..."
    oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "$SANDBOX_NAMESPACE" --as system:admin
    echo "✓ SCC configured"
else
    echo "⚠ openshell-sandbox service account not found, skipping SCC configuration"
fi
echo

# Step 6: Verify deployment
echo "6. Verifying deployment..."
echo "Checking StatefulSet/Deployment..."
if oc get statefulset -n "$OPENSHELL_NAMESPACE" --as system:admin -l app.kubernetes.io/name=openshell &>/dev/null; then
    WORKLOAD_TYPE="statefulset"
    WORKLOAD_NAME=$(oc get statefulset -n "$OPENSHELL_NAMESPACE" --as system:admin -l app.kubernetes.io/name=openshell -o name | head -1)
elif oc get deployment -n "$OPENSHELL_NAMESPACE" --as system:admin -l app.kubernetes.io/name=openshell &>/dev/null; then
    WORKLOAD_TYPE="deployment"
    WORKLOAD_NAME=$(oc get deployment -n "$OPENSHELL_NAMESPACE" --as system:admin -l app.kubernetes.io/name=openshell -o name | head -1)
else
    echo "✗ No StatefulSet or Deployment found"
    exit 1
fi

echo "Found: $WORKLOAD_NAME"
oc rollout status "$WORKLOAD_NAME" -n "$OPENSHELL_NAMESPACE" --as system:admin --timeout=5m
echo "✓ Workload ready"
echo

# Step 7: Display access information
echo "7. Access information..."
echo
echo "=== Deployment Complete ==="
echo
echo "OpenShell Gateway Service:"
SVC_NAME=$(oc get svc -n "$OPENSHELL_NAMESPACE" --as system:admin -l app.kubernetes.io/name=openshell -o name | head -1 | cut -d/ -f2 || echo "openshell-gateway")
echo "  Internal: http://$SVC_NAME.$OPENSHELL_NAMESPACE.svc.cluster.local:8080 (gRPC/HTTP)"
echo "  Health:   http://$SVC_NAME.$OPENSHELL_NAMESPACE.svc.cluster.local:8081"
echo "  Metrics:  http://$SVC_NAME.$OPENSHELL_NAMESPACE.svc.cluster.local:9090"
echo
echo "Port-forward for local access:"
echo "  oc port-forward svc/$SVC_NAME 8080:8080 -n $OPENSHELL_NAMESPACE"
echo
echo "Create Route for external access:"
echo "  oc create route edge openshell-gateway --service=$SVC_NAME --port=8080 -n $OPENSHELL_NAMESPACE --as system:admin"
echo
echo "Sandbox namespace: $SANDBOX_NAMESPACE"
echo
echo "Run './test-openshell.sh' to verify the deployment"
