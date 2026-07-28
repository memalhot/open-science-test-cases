# Open WebUI on OpenShift

Deploy [Open WebUI](https://github.com/open-webui/open-webui) as a chat interface
for the Granite model served via vLLM on OpenShift.

## Prerequisites

- The Granite model must already be deployed and serving (see `../../model-serving/granite-model/README.md`)
- `oc` CLI, logged in to the cluster

## Deploy
Change the project name if needed:
```
PROJECT=${PROJECT:-<your-project>}
```
Then run:
```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:

1. Auto-discover the model's internal cluster service URL
2. Deploy Open WebUI with a PVC, Deployment, Service, and Route
3. Wait for the deployment to become available
4. Print the public URL

### Custom project or model name

```bash
PROJECT=my-project MODEL_NAME=my-model ./deploy.sh
```

## How it connects to the model

Open WebUI connects to the model using the **internal cluster service URL**
(`http://granite-model-external.<project>.svc.cluster.local`) rather than the
external route. This avoids TLS certificate issues that occur when connecting
through the OpenShift router from inside the cluster.

The model is auto-discovered via the `/v1/models` endpoint and appears in
the model dropdown automatically.

## Troubleshooting

### UI can't find the model

Verify the model is reachable from inside the cluster:

```bash
oc exec deploy/open-webui -n mm-test -- \
  curl -s http://granite-model-external.mm-test.svc.cluster.local/v1/models
```

If this returns connection refused, check that the model predictor pod is running:

```bash
oc get pods -n mm-test -l serving.kserve.io/inferenceservice=granite-model
```

## Cleanup

```bash
chmod +x cleanup.sh
./cleanup.sh
```

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | Deploys Open WebUI and connects it to the model |
| `cleanup.sh` | Removes all Open WebUI resources |
| `yaml/open-webui.yaml` | OpenShift Template for PVC, Deployment, Service, and Route |
