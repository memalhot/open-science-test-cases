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
  │  ├ ray-head   4x H100   │◄──────►│  └ ray-worker  4x H100  │
  │  │            ranks 0-3 │  NCCL  │               ranks 4-7 │
  │  └ vllm       0 GPUs    │        │                         │
  │    driver + OpenAI API  │        │                         │
  └───────────▲─────────────┘        └─────────────────────────┘
              │ :8000
    Service beam-external -> Route beam-infer

  both pods mount the same RWX PVC (beam-weights) at /models
  on rhoai2 the head also carries a CodeFlare-injected oauth-proxy container
```

The vLLM driver is a **sidecar in the head pod**, not a separate Deployment:
it reaches the Ray GCS over loopback and shares the head's lifecycle. It
requests no GPU of its own — in vLLM V1 the Ray executor places all eight TP
ranks as actors inside the placement group, and the driver process never
touches a device.

The two pods land on different nodes without any anti-affinity rule, simply
because each requests 4 GPUs and each node has exactly 4 allocatable.

## What differs between the variants

Everything below is default-on behaviour of the CodeFlare operator, which
exists on 2.x and not on 3.x.

| | rhoai3 | rhoai2 (2.25) |
| --- | --- | --- |
| Ray operator | KubeRay, no admission mutation | KubeRay + CodeFlare mutating webhook |
| mTLS between Ray nodes | off | **on by default**, certs via an injected `create-cert` init container |
| Dashboard auth | none added | `oauth-proxy` sidecar on :8443; head SA forced to `beam-oauth-proxy` |
| NetworkPolicies | none | CodeFlare installs head + worker policies |
| Extra manifest | — | `yaml/networkpolicy.yaml` |
| Admission | direct | usually Kueue-gated (`LOCAL_QUEUE`) |

Three of these actively break a naive port-8000 sidecar deployment, and the
rhoai2 variant exists to handle them:

**1. The mTLS injection skips sidecars.** The webhook writes `RAY_USE_TLS`,
`RAY_TLS_SERVER_CERT/KEY/CA_CERT` and the `ca-vol` / `server-cert` mounts into
`Containers[0]` *only*. Our vLLM driver is `Containers[1]`, so it gets neither
the env nor the certs and cannot speak to a TLS-enabled GCS. `rhoai2/yaml/raycluster.yaml`
therefore sets both by hand, copying the webhook's own values verbatim.

**2. The head NetworkPolicy does not allow port 8000.** CodeFlare's policy
admits any port from the Ray workers, 8265/10001 from in-namespace pods and
the operator, 8080 from monitoring, and 8443 from anywhere. Port 8000 is on
none of those lists, and a pod selected by any policy denies what isn't
explicitly allowed — so the router cannot reach vLLM and the route just times
out. `rhoai2/yaml/networkpolicy.yaml` adds a second, additive policy for 8000.

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
TCP-backed TP group, plus NVFP4 kernel autotuning on first boot. The vLLM
container uses a `startupProbe` with an 80-minute budget rather than a long
`readinessProbe`, so that once it *is* up a failing engine is pulled out of the
Service within 30 seconds. `VLLM_ENGINE_READY_TIMEOUT_S=3600` is set for the
same reason — the default trips long before the model is ready.

`VLLM_CACHE_ROOT` points at the shared RWX PVC, so the torch.compile artifacts
for Beam's 52-layer MoE graph are written once and reused by the second node
and by every later restart.

## Testing

```bash
./test.sh
```

Checks what is specific to this topology — that Ray advertises exactly
`TP_SIZE` GPUs, that the pods really did span two nodes, that the route
answers, and that one completion returns a correct answer. The shared
assertions live in `common/lib.sh`; each variant adds its own. `rhoai2/test.sh`
additionally verifies the oauth-proxy and `create-cert` injections happened,
that the **vLLM sidecar** carries the `RAY_TLS_*` env and can actually read the
certificates, and that `beam-head-vllm` exists.

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
| Deployed against real weights | **no** | **no** |

Neither variant has been run with the 294GB seed. The rhoai2 variant has the
larger unknown: its CodeFlare interaction is modelled from the operator source
rather than observed, so treat the first run on a real 2.25 cluster as the
actual test.

## Troubleshooting

**Head pod never becomes Ready.** The startupProbe is waiting on vLLM. Watch
the driver:

```bash
oc logs -f $(oc get pod -l ray.io/cluster=beam,ray.io/node-type=head -n mm-test -o name) \
  -c vllm -n mm-test
```

**Stuck at "N/8 GPUs registered".** The worker pod hasn't joined. Either it's
unschedulable (`oc get pods -l ray.io/cluster=beam`), the second GPU node is
occupied, or — on 2.x — Kueue hasn't admitted the cluster (`oc get workloads`).
The driver waits 30 minutes before giving up.

**rhoai2: route times out but the pod is Ready.** Almost certainly the
NetworkPolicy. Check `oc get networkpolicy -n mm-test` for `beam-head-vllm`.

**rhoai2: driver exits during the certificate check.** The `create-cert` init
container didn't produce `/home/ray/workspace/tls/*`, or mTLS is off and the
by-hand `RAY_USE_TLS=1` is now wrong for the cluster. `./test.sh` distinguishes
these.

**Ray cluster state:**

```bash
oc exec -n mm-test $(oc get pod -l ray.io/cluster=beam,ray.io/node-type=head -n mm-test -o name) \
  -c ray-head -- ray status
```

**OOM during KV cache allocation.** Lower `MAX_MODEL_LEN` or `GPU_MEM_UTIL`.

**Responses contain `<|channel|>` or raw reasoning.** The reasoning parser
isn't active — confirm the image supports `--reasoning-parser beam`.
`test-inference-beam.sh` asserts against exactly this.
