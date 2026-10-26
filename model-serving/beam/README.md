# Beam 1.0 (501B-A23B) on vLLM, tensor-parallel across two nodes with Ray

Serves [`reflection/Beam-1.0-501B-A23B`](https://huggingface.co/reflection/Beam-1.0-501B-A23B)
— a 501B-total / 23.4B-active sparse MoE with a 1M-token context — on
OpenShift, with the tensor-parallel group spread across both GPU nodes by Ray.

There are two variants, because RHOAI 2.x and 3.x treat a RayCluster very
differently. Pick the one matching your cluster; each script warns if you
picked wrong.

```bash
cd rhoai3   # or rhoai2
./up.sh                 # PVC -> seed 294GB -> RayCluster -> route
./test.sh               # topology + API smoke test
./down.sh               # tear down (keeps the weights)
```

| | |
| --- | --- |
| `common/` | `config.conf` and `lib.sh`, plus the manifests that are identical either way (`weights-pvc.yaml`, `seed-job.yaml`, `endpoint.yaml`) |
| `rhoai3/` | RHOAI 3.x. Plain KubeRay — nothing mutates the pods |
| `rhoai2/` | RHOAI 2.25. CodeFlare injects mTLS, an oauth-proxy sidecar and NetworkPolicies; the variant works around all three |

Model-behaviour coverage is shared by both and lives in
[`../../inference/test-inference-beam.sh`](../../inference/test-inference-beam.sh).

## Why this deployment looks different from the others

Every other model in this repo fits on one node. Beam does not, and that single
fact drives most of the design here.

| Checkpoint | Weights | Minimum GPU memory | Topology |
| --- | --- | --- | --- |
| BF16 | 1003 GB | 1204 GB | 8x B200/B300, TP8 |
| FP8 | 503 GB | 604 GB | 8x H200, TP8 |
| **NVFP4** | **294 GB** | **353 GB** | 4x B200 TP4, or **8x H100 TP8 (marlin)** |

The target cluster has 8x H100-80GB — but as **4 + 4 across two machines**. So
NVFP4 is the only viable checkpoint, TP8 the only viable split, and the TP
group has to span two nodes. vLLM's cross-node executor is Ray, hence the
`RayCluster` rather than a plain Deployment or a KServe `InferenceService`.

### Topology (both variants)

```
         node A                              node B
  ┌─────────────────────────┐        ┌─────────────────────────┐
  │ Ray head pod            │        │ Ray worker pod          │
  │  └ ray-head   4x H100   │◄──────►│  └ ray-worker  4x H100  │
  │    ranks 0-3            │  NCCL  │               ranks 4-7 │
  │    + vLLM OpenAI API    │        │                         │
  └───────────▲─────────────┘        └─────────────────────────┘
              │ :8000
    Service beam-external -> Route beam-infer

  both pods mount the same RWX PVC (beam-weights) at /models
  on rhoai3 the head also carries an operator-injected kube-rbac-proxy
  on rhoai2 the head also carries a CodeFlare-injected oauth-proxy container
```

The Ray head container runs the vLLM server **itself** rather than beside it,
which is also the upstream multi-node recipe: `ray start` on every node, then
`vllm serve` on the head one. The container keeps no `command` of its own by
accident — supplying one means KubeRay stops generating `ray start`, so the
manifest owns the whole invocation and `rayStartParams` is deliberately `{}`.

This is worth stating plainly because the obvious alternative does not work.
A separate GPU-less driver sidecar — which is what this deployment originally
used — cannot start at all: vLLM selects its platform by calling
`nvmlDeviceGetCount()`, and a container with no `nvidia.com/gpu` allocation
never gets the NVML library mounted, so it dies in config with
`RuntimeError: Failed to infer device type`. Setting
`NVIDIA_VISIBLE_DEVICES=all` does not help; the GPU operator refuses that
envvar for unprivileged pods. The driver genuinely needs to live where the
GPUs are, even though in vLLM V1 the Ray executor places all eight TP ranks as
actors and the driver process itself never computes on a device.

The two pods land on different nodes without any anti-affinity rule, simply
because each requests 4 GPUs and each node has exactly 4 allocatable.

## What differs between the variants

Everything below is default-on behaviour of the CodeFlare operator, which
exists on 2.x and not on 3.x.

| | rhoai3 | rhoai2 (2.25) |
| --- | --- | --- |
| Ray operator | KubeRay, mutates the CR itself | KubeRay + CodeFlare mutating webhook |
| mTLS between Ray nodes | **on**, certs via cert-manager and a `wait-for-tls-ip-san` init container | **on by default**, certs via an injected `create-cert` init container |
| Dashboard auth | `kube-rbac-proxy` sidecar | `oauth-proxy` sidecar on :8443; head SA forced to `beam-oauth-proxy` |
| NetworkPolicies | KubeRay's networkpolicy-controller installs head + worker policies | CodeFlare installs head + worker policies |
| Extra manifest | `common/yaml/networkpolicy.yaml` | same |
| Admission | direct | usually Kueue-gated (`LOCAL_QUEUE`) |

**1. The mTLS injection only touches `Containers[0]`.** The webhook writes
`RAY_USE_TLS`, `RAY_TLS_SERVER_CERT/KEY/CA_CERT` and the `ca-vol` /
`server-cert` mounts into the first container *only*. This used to require
copying all of it by hand onto the sidecar; now that vLLM serves from
`Containers[0]` itself, the injection lands on the serving process and the
manifest declares none of it. `rhoai2/test.sh` still asserts the env and certs
are present, precisely so that moving the server back out of container 0 fails
loudly instead of silently losing its credentials.

**2. The head NetworkPolicy does not allow port 8000 — on either generation.**
This is not CodeFlare-specific: on 3.x the KubeRay operator's own
networkpolicy-controller installs an equivalent `beam-head` policy admitting
only 10001, 8265 and 8443. Any port is allowed from pods labelled
`ray.io/cluster=beam`, so Ray itself is fine, but a pod selected by any policy
denies what isn't explicitly allowed — so the router cannot reach vLLM and the
route just times out, *after* a full model load. `common/yaml/networkpolicy.yaml`
adds a second, additive policy for 8000 and both variants apply it.

**3. The head service account is overwritten.** The webhook replaces
`serviceAccountName` with `beam-oauth-proxy` and its validating webhook then
rejects a spec that disagrees, so the manifest deliberately sets none.

Because that interaction cannot be exercised without a 2.x cluster, the
mutation is reimplemented from the operator source and checked statically:

```bash
cd rhoai2
VARIANT_DIR="$PWD" . ../common/lib.sh && load_config && render raycluster.yaml > /tmp/rc.yaml
python3 check-codeflare-mutation.py /tmp/rc.yaml     # needs PyYAML
```

That proves the manifest and the webhook agree about container ordering,
volume names, env, and mount paths. It does not prove the cluster behaves as
documented — see *Status* below.

## The serving image is built, not pulled

`up.sh` builds the image in-cluster before deploying anything, and the pods run
the result rather than `BASE_IMAGE`:

```
BASE_IMAGE  docker.io/vllm/vllm-openai:reflection-beam
     │
     ├─ pip install ray[default]==$RAY_VERSION
     └─ apt-get install wget
     ▼
IMAGE       image-registry.openshift-image-registry.svc:5000/$NAMESPACE/vllm-beam-ray:latest
```

Both additions are load-bearing:

- **Ray is absent from the base image.** Not missing from `PATH` — `find / -name ray`
  returns nothing. KubeRay's injected `ray start` exits 127 and the head
  crashloops immediately.
- **`wget` is absent, and KubeRay's injected probes shell out to it.** Every
  readiness and liveness probe fails with `wget: command not found`, and at the
  injected `failureThreshold: 120 × 5s` the kubelet kills the container at
  almost exactly ten minutes — on the worker that lands mid-load, every time.

The build runs in-cluster (`common/yaml/buildconfig.yaml`) so the ~25GB base is
pulled by the cluster rather than down to a workstation and back. It is skipped
when the ImageStream tag already exists; force it with `./up.sh --rebuild-image`.
Setting `IMAGE` explicitly bypasses the build entirely.

`RAY_VERSION` is therefore load-bearing rather than informational: the same
value pins the `pip install` and the RayCluster's `rayVersion`, and the build
runs `ray --version` so a mismatch fails there rather than at pod start.

## Settings a two-node TP group cannot do without

These are defaults that are correct on a single NVLink node and wrong here.
Each one fails as a hang or an unrelated-looking crash, never as a clear error.

| Setting | Default | Why it has to change |
| --- | --- | --- |
| `VLLM_ALLREDUCE_USE_SYMM_MEM=0` | on | PyTorch symmetric memory assumes every rank reaches the others over NVLink/P2P. vLLM's `SymmMemCommunicator` checks device capability and world size but **not node count**, unlike `CustomAllreduce` and `FlashInferAllReduce` which both self-disable on multi-node. At TP=8 on H100 it calls `torch_symm_mem.rendezvous()` and never returns. |
| `OMP_NUM_THREADS=8`, `RAY_num_server_call_thread=8` | sized from host CPU count | These nodes have **512 CPUs** and containers cap at ~4096 threads. The cap is invisible from inside — the container's own `pids.max` reads `max`. |
| `DIST_TIMEOUT_S=3600` | gloo 1800s, NCCL 600s | 294GB off a shared NFS PVC over TCP does not fit in either. Surfaces as `RuntimeError: Application timeout caused pair closure` — a gloo error, despite NCCL being the GPU backend. |

The symmetric-memory one is the most expensive to diagnose, because the hang
raises nothing: `SymmMemCommunicator` wraps the rendezvous in `except
RuntimeError`, which a hang never triggers. Whichever timeout is shortest fires
first and takes the blame — the gloo timeout at 30 minutes, or the head's
startupProbe at 80. A `py-spy dump` on a rank actor is what actually identifies
it:

```bash
oc exec -n mm-test <worker-pod> -c ray-worker --as system:admin -- \
  py-spy dump --pid <rank-pid>
```

It must be set on **every container where ranks run**, not just where the
server runs. The TP ranks are Ray actors spawned by the raylet, so they inherit
the Ray container's environment.

## Configuration

Everything lives in [`common/config.conf`](common/config.conf), shared by both
variants; any value can be overridden per-run by an environment variable of
the same name:

```bash
MAX_MODEL_LEN=65536 ./up.sh
LOCAL_QUEUE=team-a ./up.sh          # rhoai2 only
```

The one invariant the scripts enforce is
`TP_SIZE == HEAD_GPUS + WORKER_REPLICAS * WORKER_GPUS`. A mismatch doesn't fail
fast on its own — vLLM simply blocks forever waiting for ranks that can never
be placed — so `lib.sh` rejects it up front.

`LOCAL_QUEUE` is stripped from the manifest entirely when empty, rather than
rendered as an empty label: Kueue treats a labelled workload as one it manages,
so an empty queue name means the RayCluster is admitted to nothing and the pods
never appear, with no error on the object.

### Flags that are not optional for Beam

| Flag | Why |
| --- | --- |
| `--reasoning-parser beam` | Splits the Harmony `analysis` and `final` channels. Without it, private chain-of-thought and raw control tokens are served to clients inside `content`. |
| `--tool-call-parser beam` + `--enable-auto-tool-choice` | Beam stops on `<\|call\|>` when invoking a tool; this turns that into OpenAI-shaped `tool_calls`. |
| `--moe-backend marlin` | NVFP4 on Hopper. The Blackwell MoE paths (flashinfer / cutedsl) have no SM90 kernels. |
| `--kv-cache-dtype fp8` | Halves KV memory, which is the binding constraint once 294GB of weights are resident. |

## Context length

Beam's window is 1,048,576 tokens, but `MAX_MODEL_LEN` is what actually binds,
and KV cache is what you have left after the weights. With 294GB of weights
across 640GB of H100 memory there is roughly 346GB for KV, activations and
CUDA overhead. The default is a deliberately conservative **32768**; raise it
until vLLM refuses to allocate the cache at startup.

## Known performance cost: no RDMA

Both GPU nodes have RDMA-capable Mellanox NICs and report
`feature.node.kubernetes.io/rdma.capable=true`, but **no RDMA device plugin is
exposed**, so there are no `rdma/*` resources to request. Cross-node NCCL
therefore runs over TCP on the pod network.

This matters: tensor parallelism is latency-sensitive and exchanges activations
at every layer, so the inter-node hop is on the critical path for all 52
layers. Within a node the 4 GPUs are NVLink-connected; between nodes they are
not. Expect materially lower throughput than a single 8-GPU NVLink node would
give. `NCCL_IB_DISABLE=1` is set deliberately — left enabled, NCCL spends a
long time probing for InfiniBand and failing over before it falls back to
sockets.

If an RDMA device plugin is ever installed, set `NCCL_IB_DISABLE=0` in
`config.conf` and add the corresponding resource request to the variant's
`yaml/raycluster.yaml`.

## First run

The seed Job downloads 294GB across 53 shards and verifies the shard count
before declaring success — a short download would otherwise only surface as a
confusing vLLM load error much later. Budget 30–90 minutes.

The weight PVC deliberately survives `down.sh`:

```bash
./down.sh               # keeps beam-weights
./up.sh --skip-seed     # back up in minutes, no re-download
./down.sh --weights     # really delete the 294GB
```

Model load is the slow part of every start: 294GB off NFS, sharded across a
TCP-backed TP group, plus NVFP4 kernel autotuning on first boot. The head
container uses a `startupProbe` with an 80-minute budget rather than a long
`readinessProbe`, so that once it *is* up a failing engine is pulled out of the
Service within 30 seconds. `VLLM_ENGINE_READY_TIMEOUT_S=3600` is set for the
same reason — the default trips long before the model is ready.

The startupProbe earns its keep twice over: until it passes, the kubelet also
suppresses the liveness probe KubeRay injects, so a slow load cannot be
mistaken for a hung raylet and restarted. That is why the head declares no
`livenessProbe` of its own — KubeRay's raylet + GCS healthz check is the right
liveness signal once readiness tracks vLLM instead.

Measured on RHOAI 3.5.2 with warm weights, the 53 shards load in about **five
minutes** (~5.6s/shard). The 80-minute and 3600s budgets therefore have a lot
of headroom; they are sized for a cold, contended first run. If you would
rather genuine hangs surfaced quickly, these are the numbers to lower.

`VLLM_CACHE_ROOT` points at the shared RWX PVC, so the torch.compile artifacts
for Beam's 52-layer MoE graph are written once and reused by the second node
and by every later restart.

## Testing

```bash
./test.sh
```

Checks what is specific to this topology — that Ray advertises exactly
`TP_SIZE` GPUs, that the pods really did span two nodes, that `beam-head-vllm`
exists, that the route answers, and that one completion returns a correct
answer. The shared assertions live in `common/lib.sh`; each variant adds its
own. `rhoai2/test.sh` additionally verifies the oauth-proxy and `create-cert`
injections happened and that the serving container carries the `RAY_TLS_*` env
and can read the certificates.

The `oc exec` assertions impersonate `system:admin`. The Ray pods run as uid
1000 under the operator's `run-as-ray-user` SCC, which an ordinary account
cannot validate against, so a plain `oc exec` is rejected outright — and the
check would then report a broken cluster rather than a permissions problem.
Expect a current login too: `oc` returning `Unauthorized` makes the head-pod
lookup come back empty, which reads as *"no Ray head pod found (is the cluster
up?)"*.

For model behaviour (Harmony channels, the five reasoning-effort levels, tool
calling, structured output, long-context retrieval, error handling):

```bash
cd ../../inference
BASE_URL=$(oc get route beam-infer -n mm-test -o jsonpath='https://{.spec.host}') \
  ./test-inference-beam.sh
```

That suite is endpoint-agnostic and shared by both variants, so the same
assertions can be run against a hosted provider for comparison:

```bash
BASE_URL=https://openrouter.ai/api API_KEY=sk-... \
  MODEL_NAME=reflection/beam-1.0-501b-a23b ./test-inference-beam.sh
```

## Status

| | rhoai3 | rhoai2 |
| --- | --- | --- |
| Manifests pass `oc apply --dry-run=server` | yes (on RHOAI 3.5.2) | yes (RayCluster CRD is generation-independent) |
| CodeFlare mutation checked | n/a | statically, via `check-codeflare-mutation.py` (22 assertions) |
| Deployed against real weights | **yes** — RHOAI 3.5.2, 2026-10-23 | **no** |
| `./test.sh` | **9/9 passing** | not run |

**rhoai3 is verified end to end**: 294GB seeded, TP=8 formed across two nodes,
`/health` 200, `/v1/models` listing `beam`, and a correct chat completion over
the route. `ray status` reports `8.0/8.0 GPU` in the placement group.

**rhoai2 is unverified.** It carries the same design and all the same fixes,
but no part of it has run on a 2.x cluster. Its CodeFlare interaction is still
modelled from the operator source rather than observed, and three things in
particular are untested: whether the validating webhook accepts a head
container with a user-supplied `command`, whether `create-cert` and
`oauth-proxy` still inject correctly alongside it, and whether 2.x KubeRay
injects probes the same way the `wget` fix assumes. Treat the first run on a
real 2.25 cluster as the actual test.

## Troubleshooting

**Head pod never becomes Ready.** The startupProbe is waiting on vLLM. Watch
the serving container:

```bash
oc logs -f $(oc get pod -l ray.io/cluster=beam,ray.io/node-type=head -n mm-test -o name) \
  -c ray-head -n mm-test
```

If the log goes quiet right after `Creating a new placement group` and no
`Loading safetensors checkpoint shards` line ever appears, it is hung rather
than slow — check `VLLM_ALLREDUCE_USE_SYMM_MEM=0` is set on head *and* worker,
and confirm with a `py-spy dump` (see *Settings a two-node TP group cannot do
without*). GPUs sitting at ~1.1 GiB used and 0% utilisation is the same
symptom seen from the other side:

```bash
oc exec -n mm-test <worker-pod> -c ray-worker --as system:admin -- \
  nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv
```

**Pods restart on a regular cadence.** Note the interval — it usually names the
timer. Almost exactly 10 minutes is KubeRay's injected liveness probe
(`failureThreshold: 120 × 5s`), normally because `wget` is missing from the
image. Almost exactly 80 minutes is the head's startupProbe budget expiring,
meaning the load genuinely did not finish. 30 minutes is the gloo default
timeout if `DIST_TIMEOUT_S` is not applied.

**`Unhandled exception ... thread: Resource temporarily unavailable
[system:11]` and SIGABRT.** The ~4096-thread container cap, not a Ray bug.
Confirm `OMP_NUM_THREADS` and `RAY_num_server_call_thread` are set. The ceiling
is not visible as `pids.max`; measure it instead by spawning threads until
`can't start new thread`.

**`up.sh` says "Ray pods never scheduled" seconds after applying.** If the pods
do exist, this is the stale form of the race `wait_for_ray_pods_to_exist()`
now handles — `oc wait` exits immediately when its selector matches nothing
yet. If they genuinely do not exist, the RayCluster's `ReplicaFailure`
condition carries the reason, which is usually a rejected pod template:

```bash
oc get raycluster beam -n mm-test \
  -o jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")].message}'
```

**Stuck at "N/8 GPUs registered".** The worker pod hasn't joined. Either it's
unschedulable (`oc get pods -l ray.io/cluster=beam`), the second GPU node is
occupied, or — on 2.x — Kueue hasn't admitted the cluster (`oc get workloads`).
The driver waits 30 minutes before giving up.

**Route times out but the pod is Ready.** Almost certainly the NetworkPolicy,
on either generation. Check `oc get networkpolicy -n mm-test` for
`beam-head-vllm`.

**rhoai2: container exits during the certificate check.** The `create-cert`
init container didn't produce `/home/ray/workspace/tls/*`, or mTLS is off on
this cluster while the webhook still set `RAY_USE_TLS=1`. `./test.sh`
distinguishes these.

**Ray cluster state:**

```bash
oc exec -n mm-test $(oc get pod -l ray.io/cluster=beam,ray.io/node-type=head -n mm-test -o name) \
  -c ray-head --as system:admin -- ray status
```

**OOM during KV cache allocation.** Lower `MAX_MODEL_LEN` or `GPU_MEM_UTIL`.

**Responses contain `<|channel|>` or raw reasoning.** The reasoning parser
isn't active — confirm the image supports `--reasoning-parser beam`.
`test-inference-beam.sh` asserts against exactly this.
