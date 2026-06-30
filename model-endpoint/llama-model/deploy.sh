#!/bin/bash
set -e

# Model Endpoint Deployment Script for OpenShift
# This script deploys a model serving endpoint using oc and Kustomize

NAMESPACE="${NAMESPACE:-model-serving}"
MODEL_NAME="${MODEL_NAME:-llm-model}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying Model Endpoint with Kustomize ==="
echo "Namespace: $NAMESPACE"
echo "Model Name: $MODEL_NAME"
echo ""

# Create namespace if it doesn't exist
echo "Checking namespace..."
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "Creating namespace: $NAMESPACE"
    oc create namespace "$NAMESPACE"
else
    echo "Namespace $NAMESPACE already exists"
fi

# Switch to the namespace
oc project "$NAMESPACE"

# Check if secret.yaml exists in base directory
if [ ! -f "$SCRIPT_DIR/base/secret.yaml" ]; then
    echo "Warning: base/secret.yaml not found."
    echo "Creating it from base/secret.yaml.example..."
    if [ -f "$SCRIPT_DIR/base/secret.yaml.example" ]; then
        cp "$SCRIPT_DIR/base/secret.yaml.example" "$SCRIPT_DIR/base/secret.yaml"
        echo "Please edit base/secret.yaml with your actual credentials before deploying!"
        exit 1
    else
        echo "Error: base/secret.yaml.example not found!"
        exit 1
    fi
fi

# Apply all resources using Kustomize
echo ""
echo "Applying all resources with Kustomize..."
oc apply -k "$SCRIPT_DIR"

# Wait for deployment to be ready
echo ""
echo "Waiting for deployment to be ready..."
oc rollout status deployment/"$MODEL_NAME" -n "$NAMESPACE" --timeout=300s

# Get the route URL
echo ""
echo "=== Deployment Complete ==="
ROUTE_URL=$(oc get route "$MODEL_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')
echo "Model endpoint is available at: https://$ROUTE_URL"
echo ""
echo "Test the endpoint with:"
echo "curl -X POST https://$ROUTE_URL/v1/predict -H 'Content-Type: application/json' -d '{\"text\": \"test input\"}'"
echo ""
echo "To delete all resources, run:"
echo "  ./cleanup.sh"
echo "Or manually:"
echo "  oc delete -k $SCRIPT_DIR"
