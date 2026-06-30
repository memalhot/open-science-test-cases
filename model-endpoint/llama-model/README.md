# Model Endpoint Deployment

This directory contains scripts and YAML manifests to deploy a model serving endpoint on OpenShift.

## Prerequisites

- OpenShift CLI (`oc`) installed and configured
- Access to an OpenShift cluster
- Appropriate permissions to create namespaces, deployments, services, and routes

## Quick Start

1. **Deploy the model endpoint:**
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

2. **Customize deployment (optional):**
   ```bash
   # Set custom namespace and model name
   NAMESPACE=my-namespace MODEL_NAME=my-model ./deploy.sh
   ```

## Configuration

### Environment Variables

- `NAMESPACE`: Target namespace (default: `model-serving`)
- `MODEL_NAME`: Name of the model deployment (default: `llm-model`)

### ConfigMap (`configmap.yaml`)

Edit `configmap.yaml` to configure:
- Model name/ID
- Batch size
- Sequence length
- Inference parameters (temperature, top_p, etc.)

### Secrets (`secret.yaml.example`)

1. Copy the example file:
   ```bash
   cp secret.yaml.example secret.yaml
   ```

2. Edit `secret.yaml` and add your actual credentials:
   - Hugging Face token (for private models)
   - API keys for authentication

3. **Never commit `secret.yaml` to version control**

### Deployment Configuration

Edit `deployment.yaml` to customize:
- Container image
- Resource limits (CPU, memory, GPU)
- Replica count
- Health check endpoints
- Volume mounts
- Node selectors for GPU nodes

## Manual Deployment Steps

If you prefer to deploy manually:

```bash
# Create namespace
oc create namespace model-serving
oc project model-serving

# Apply manifests
oc apply -f configmap.yaml
oc apply -f secret.yaml  # if using secrets
oc apply -f deployment.yaml
oc apply -f service.yaml
oc apply -f route.yaml

# Check deployment status
oc rollout status deployment/llm-model
oc get pods
oc get route
```

## Testing the Endpoint

Once deployed, get the route URL:
```bash
oc get route llm-model -o jsonpath='{.spec.host}'
```

Test the endpoint:
```bash
curl -X POST https://$(oc get route llm-model -o jsonpath='{.spec.host}')/v1/predict \
  -H 'Content-Type: application/json' \
  -d '{"text": "What is machine learning?"}'
```

## Cleanup

To remove the deployment:
```bash
oc delete -f route.yaml
oc delete -f service.yaml
oc delete -f deployment.yaml
oc delete -f configmap.yaml
oc delete -f secret.yaml  # if created

# Optionally delete the namespace
oc delete namespace model-serving
```

## Troubleshooting

Check pod logs:
```bash
oc logs -l app=llm-model --tail=100 -f
```

Check pod status:
```bash
oc describe pod -l app=llm-model
```

Check events:
```bash
oc get events --sort-by='.lastTimestamp'
```
