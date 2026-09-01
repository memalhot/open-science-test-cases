#!/bin/bash

set -euo pipefail

# Configuration
OPENSHELL_NAMESPACE=${OPENSHELL_NAMESPACE:-openshell}
SANDBOX_NAMESPACE=${SANDBOX_NAMESPACE:-openshell-sandboxes}
KEEP_CRDS=${KEEP_CRDS:-true}  # Preserve CRDs by default (may be used by other tools)

echo "=== NVIDIA OpenShell Cleanup Script ==="
echo "Namespace: $OPENSHELL_NAMESPACE"
echo "Sandbox Namespace: $SANDBOX_NAMESPACE"
echo "Keep CRDs: $KEEP_CRDS"
echo

# Step 1: Remove SCC bindings
echo "1. Removing SCC bindings..."
if oc adm policy who-can use scc privileged -n "$SANDBOX_NAMESPACE" --as system:admin 2>&1 | grep -q openshell-sandbox; then
    echo "Removing privileged SCC from openshell-sandbox..."
    oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "$SANDBOX_NAMESPACE" --as system:admin || true
    echo "✓ SCC binding removed"
else
    echo "✓ No SCC bindings found"
fi
echo

# Step 2: Remove cluster-scoped resources
echo "2. Removing cluster-scoped resources..."
oc delete clusterrole openshell-node-reader --as system:admin --ignore-not-found=true
oc delete clusterrolebinding openshell-node-reader --as system:admin --ignore-not-found=true
echo "✓ Cluster resources removed"
echo

# Step 3: Delete namespaces (cascades all namespace-scoped resources)
echo "3. Deleting namespaces..."
if oc get namespace "$OPENSHELL_NAMESPACE" --as system:admin &>/dev/null; then
    oc delete namespace "$OPENSHELL_NAMESPACE" --as system:admin --wait=false
    echo "✓ Namespace $OPENSHELL_NAMESPACE deletion initiated"
else
    echo "✓ Namespace $OPENSHELL_NAMESPACE does not exist"
fi

if oc get namespace "$SANDBOX_NAMESPACE" --as system:admin &>/dev/null; then
    oc delete namespace "$SANDBOX_NAMESPACE" --as system:admin --wait=false
    echo "✓ Namespace $SANDBOX_NAMESPACE deletion initiated"
else
    echo "✓ Namespace $SANDBOX_NAMESPACE does not exist"
fi

# Wait for namespace deletion
echo "Waiting for namespaces to terminate (max 2 minutes)..."
timeout 120 bash -c "
while oc get namespace $OPENSHELL_NAMESPACE --as system:admin &>/dev/null || \
      oc get namespace $SANDBOX_NAMESPACE --as system:admin &>/dev/null; do
    echo 'Still terminating...'
    sleep 3
done
" || {
    echo "⚠ Namespaces still terminating (will complete in background)"
}
echo

# Step 4: Remove agent-sandbox CRDs (optional)
if [ "$KEEP_CRDS" = "false" ]; then
    echo "4. Removing agent-sandbox CRDs..."

    # Delete controller first
    if oc get deployment agent-sandbox-controller -n agent-sandbox-system --as system:admin &>/dev/null; then
        echo "Deleting agent-sandbox controller..."
        oc delete deployment agent-sandbox-controller -n agent-sandbox-system --as system:admin --timeout=60s || true
    fi

    # Delete namespace
    if oc get namespace agent-sandbox-system --as system:admin &>/dev/null; then
        echo "Deleting agent-sandbox-system namespace..."
        oc delete namespace agent-sandbox-system --as system:admin --wait=false || true
    fi

    # Delete CRDs
    for crd in sandboxes.agents.x-k8s.io \
               sandboxclaims.extensions.agents.x-k8s.io \
               sandboxtemplates.extensions.agents.x-k8s.io \
               sandboxwarmpools.extensions.agents.x-k8s.io; do
        if oc get crd "$crd" --as system:admin &>/dev/null; then
            echo "Deleting CRD $crd..."
            oc delete crd "$crd" --as system:admin --timeout=60s || true
        fi
    done

    echo "✓ CRDs removed"
else
    echo "4. Skipping CRD removal (KEEP_CRDS=$KEEP_CRDS)"
    echo "   To remove CRDs, run: KEEP_CRDS=false ./cleanup.sh"
fi
echo

# Step 5: Verification
echo "5. Cleanup verification..."
REMAINING=0

if oc get namespace "$OPENSHELL_NAMESPACE" --as system:admin &>/dev/null; then
    echo "⚠ Namespace $OPENSHELL_NAMESPACE still exists (may be terminating)"
    REMAINING=$((REMAINING + 1))
fi

if oc get namespace "$SANDBOX_NAMESPACE" --as system:admin &>/dev/null; then
    echo "⚠ Namespace $SANDBOX_NAMESPACE still exists (may be terminating)"
    REMAINING=$((REMAINING + 1))
fi

if oc get clusterrole openshell-node-reader --as system:admin &>/dev/null; then
    echo "⚠ ClusterRole still exists"
    REMAINING=$((REMAINING + 1))
fi

if [ $REMAINING -eq 0 ]; then
    echo "✓ All OpenShell resources removed successfully"
else
    echo "⚠ $REMAINING resource(s) may still be terminating"
fi
echo

echo "=== Cleanup Complete ==="
echo
echo "Notes:"
echo "  - Namespaces may take a few minutes to fully terminate"
echo "  - CRDs preserved: $KEEP_CRDS"
echo "  - To force CRD removal: KEEP_CRDS=false ./cleanup.sh"
