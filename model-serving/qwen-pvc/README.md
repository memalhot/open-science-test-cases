# Serving a Qwen Model from a PVC via the RHOAI UI

Deploy [Qwen2.5-3B-Instruct](https://huggingface.co/Qwen/Qwen2.5-3B-Instruct) with vLLM on
KServe, reading the model weights from a PersistentVolumeClaim instead of S3.

Two paths are documented here:

- **[UI deployment](#ui-deployment)** — prepare the PVC from the CLI, then deploy through the
  RHOAI dashboard. Use this when you want to exercise the dashboard's PVC model-source flow.
- **[CLI deployment](#cli-deployment)** — `./deploy.sh` does everything end to end.

Both share the same PVC and weights; only the InferenceService creation differs.

## Prerequisites

- `oc` CLI, logged in to an OpenShift cluster with RHOAI installed
- A HuggingFace access token in `credentials.env` (see below)
- An RWX-capable StorageClass (the cluster default `pure-fb-nfsv4` is Portworx fronting Pure
  FlashBlade over NFS, and supports RWX)
- A GPU node available in the cluster (1x NVIDIA GPU; 3B at float16 fits comfortably on A100/H100)

### `credentials.env`

```env
# HuggingFace access token
ACCESS_TOKEN=<your-hf-token>
```

Do **not** commit this file — it is gitignored via `*.env`.

## UI deployment

The dashboard can select an existing PVC as a model source, but it cannot *populate* one. Steps
1–3 below are CLI prerequisites; step 4 onward is the UI.

### 1. Make the project visible to the dashboard

A namespace only appears as a Data Science Project when it carries the dashboard label. Setting
`modelmesh-enabled=false` selects the single-model (KServe) serving platform.

```bash
oc label namespace mm-test \
  opendatahub.io/dashboard=true \
  modelmesh-enabled=false \
  --overwrite --as system:admin
```

### 2. Create the PVC

```bash
oc process -f yaml/model-pvc.yaml --as system:admin \
  -p PVC_NAME=qwen-model-pvc \
  -p STORAGE_SIZE=20Gi \
  -p STORAGE_CLASS=pure-fb-nfsv4 \
  -p ACCESS_MODE=ReadWriteMany \
  | oc apply -n mm-test --as system:admin -f -
```

> **The `opendatahub.io/dashboard=true` label on the PVC is required.** The dashboard does not
> list every PVC in the namespace — it calls `getDashboardPvcs`, which queries with
> `labelSelector: opendatahub.io/dashboard=true`. An unlabelled PVC is invisible, and because the
> **Existing cluster storage** radio only renders when that filtered list is non-empty, the option
> disappears from the deploy form entirely rather than showing an empty dropdown.
> `yaml/model-pvc.yaml` applies the label for you.

> `--as system:admin` is needed on `oc process` itself, not just on `oc apply`. `oc process` is a
> server-side call against `processedtemplates`, which most users cannot create in a project.

### 3. Load the weights onto the PVC

```bash
source credentials.env
oc process -f yaml/model-loader-job.yaml --as system:admin \
  -p PVC_NAME=qwen-model-pvc \
  -p MODEL_REPO=Qwen/Qwen2.5-3B-Instruct \
  -p MODEL_DIR=Qwen2.5-3B-Instruct \
  -p ACCESS_TOKEN="${ACCESS_TOKEN}" \
  | oc apply -n mm-test --as system:admin -f -

oc wait --for=condition=complete job/model-loader -n mm-test --timeout=1800s
```

The job mounts the PVC at `/mnt/models`, installs `huggingface_hub[hf_xet]`, and runs
`hf download` into `/mnt/models/Qwen2.5-3B-Instruct`. Roughly 5.8 GB across 12 files; the xet
transfer typically completes in under a minute.

Confirm the weights landed:

```bash
oc logs job/model-loader -n mm-test --as system:admin | tail -20
```

### 4. Deploy through the dashboard

Open the RHOAI dashboard and go to **Data Science Projects → mm-test → Models → Deploy model**.

| Field | Value |
|---|---|
| Model deployment name | `qwen-model` |
| Serving runtime | vLLM NVIDIA GPU ServingRuntime for KServe |
| Deployment mode | Standard |
| Model framework | `vLLM` |
| Hardware profile | NVIDIA A100 GPU *or* NVIDIA H100 GPU |
| Number of replicas | 1 |

Use **Standard** (KServe RawDeployment) rather than Advanced/Serverless — it matches the DSC's
`rawDeploymentServiceConfig: Headless` and the `deploymentMode: RawDeployment` annotation the CLI
path uses.

Pick a hardware profile rather than setting resources by hand. The GPU nodes are tainted
`nvidia.com/gpu.product=<PRODUCT>:NoSchedule`, and the profiles carry the matching toleration; a
deployment without it stays `Pending` forever with no obviously useful event.

### 5. Source model location

Select the **Existing cluster storage** radio (below the connection-based options). If you only
see S3 / URI / OCI, the PVC is missing the dashboard label — see step 2. Reload the page after
labelling; the PVC list is fetched once on mount.

Two fields appear:

- **Cluster storage** — select `qwen-model-pvc`.
- **Model path** — the field is prefixed with a fixed, non-editable `pvc://qwen-model-pvc/`. Enter
  only the remainder:

  ```
  Qwen2.5-3B-Instruct
  ```

The resulting URI is `pvc://qwen-model-pvc/Qwen2.5-3B-Instruct`. The input validates against
`/^pvc:\/\/[a-zA-Z0-9-]+\/[^/\s][^\s]*$/`, which means:

- **No leading slash.** `/Qwen2.5-3B-Instruct` is rejected — easy to get wrong, since the
  directory is at `/mnt/models/Qwen2.5-3B-Instruct` inside the loader pod. The path is relative
  to the PVC root.
- **Not empty.** The path cannot point at the PVC root.
- No whitespace. Dots and hyphens are fine.

A *"The access mode of the selected cluster storage is not ReadWriteMany"* warning means the PVC
is not RWX. With `ACCESS_MODE=ReadWriteMany` it will not appear.

### 6. Verify

Click **Deploy** and wait for the model to report as started.

```bash
oc get isvc -n mm-test
oc get pods -n mm-test -l serving.kserve.io/inferenceservice=qwen-model
```

The dashboard shows an inference endpoint on the model's row. To test it, see
[Using the model](#using-the-model).

## CLI deployment

```bash
chmod +x deploy.sh
./deploy.sh
```

Override defaults with env vars: `PROJECT` (default `mm-test`), `MODEL_NAME`, `PVC_NAME`,
`STORAGE_CLASS`, `STORAGE_SIZE`, `ACCESS_MODE`, `MODEL_REPO`, `MODEL_DIR`.

The script will:

1. Create the PVC.
2. Run the model-loader job and wait for the download to finish.
3. Label the namespace for single-model serving (`modelmesh-enabled=false`).
4. Apply the vLLM ServingRuntime and the InferenceService (`storageUri: pvc://...`).
5. Wait for the deployment to become available (with an automatic scale-to-1 workaround).
6. Create an external service and edge route.
7. Verify the model responds to a test request.

This path creates its own route, which the UI path does not.

## Using the model

Served as an OpenAI-compatible API:

```bash
curl -sk https://qwen-model-<project>.apps.<cluster>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-model",
    "messages": [{"role": "user", "content": "What is OpenShift?"}],
    "max_tokens": 100
  }'
```

Other endpoints: `GET /v1/models`, `POST /v1/completions`.

`inference/test-inference-qwen.sh` runs a fuller PASS/FAIL suite against the deployed model.

## Scaling

```bash
./scale.sh up    # scale to 1 replica, create route, wait for readiness
./scale.sh down  # scale to 0 replicas
```

## Cleanup

```bash
chmod +x cleanup.sh
./cleanup.sh
```

Removes the route, external service, InferenceService, ServingRuntime, loader job, PVC, and the
`modelmesh-enabled` namespace label. A model deployed through the UI is an InferenceService of the
same name, so `cleanup.sh` removes it too — but it does not drop the
`opendatahub.io/dashboard=true` label from the namespace.

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | Full CLI deploy: PVC, weight download, ServingRuntime, InferenceService, route |
| `cleanup.sh` | Tears down all resources created by `deploy.sh` |
| `scale.sh` | Scale the model deployment up (with route creation) or down |
| `yaml/model-pvc.yaml` | OpenShift template for the model PVC (dashboard-labelled) |
| `yaml/model-loader-job.yaml` | OpenShift template for the Job that downloads weights onto the PVC |
| `yaml/serving-runtime.yaml` | vLLM ServingRuntime for KServe |
| `yaml/inference-service.yaml` | OpenShift template for the KServe InferenceService |
| `credentials.env` | HuggingFace token (gitignored, create manually) |

## Troubleshooting

| Symptom | Cause |
|---|---|
| Only S3 / URI / OCI shown under source model location | PVC missing `opendatahub.io/dashboard=true`; reload the page after labelling |
| Project absent from the dashboard | Namespace missing `opendatahub.io/dashboard=true` |
| `processedtemplates ... is forbidden` | `--as system:admin` missing on `oc process`, not just `oc apply` |
| Predictor pod stuck `Pending` | Toleration does not match the GPU node taint (`nvidia.com/gpu.product=<PRODUCT>:NoSchedule`) |
| Model path rejected by the form | Leading slash, or path pointing at the PVC root |
| vLLM cannot find the model | `MODEL_DIR` and the UI **Model path** disagree |
