#!/bin/bash
set -e

# Model Endpoint Deployment Script for OpenShift
# This script deploys a model serving endpoint using oc and YAML manifests

NAMESPACE="${NAMESPACE:-model-serving}"
MODEL_NAME="${MODEL_NAME:-llm-model}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying Model Endpoint ==="
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

# Apply ConfigMap for model configuration
echo ""
echo "Applying ConfigMap..."
oc apply -f "$SCRIPT_DIR/configmap.yaml"

# Apply Secret for API keys (if exists)
if [ -f "$SCRIPT_DIR/secret.yaml" ]; then
    echo "Applying Secret..."
    oc apply -f "$SCRIPT_DIR/secret.yaml"
fi

# Apply Deployment
echo ""
echo "Applying Deployment..."
oc apply -f "$SCRIPT_DIR/deployment.yaml"

# Apply Service
echo ""
echo "Applying Service..."
oc apply -f "$SCRIPT_DIR/service.yaml"

# Apply Route for external access
echo ""
echo "Applying Route..."
oc apply -f "$SCRIPT_DIR/route.yaml"

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
