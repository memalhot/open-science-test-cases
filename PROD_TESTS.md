## Test Cases

| Test Case | Description | Category | Completion | Notes | Link |
|-----------|-------------|----------|------------|-------|------|
| Model Serving | OpenShift deployment scripts and YAML manifests for deploying a model serving endpoint with vLLM, including ConfigMaps, Secrets, Services, and Routes | Model Serving | Done | Qwen model deployed | [model-serving/granite-model](https://github.com/memalhot/open-science-test-cases/tree/main/model-serving/granite-model) |
| Fine-Tuning | QLoRA fine-tuning of Granite 3.0 8B Instruct on OpenShift using a Kubeflow PyTorchJob, with configurable datasets and training parameters | Fine-Tuning | Done | Qwen fine-tuning jobs successfully run with Openshift jobs.| [fine-tuning](https://github.com/memalhot/open-science-test-cases/tree/main/fine-tuning) |
| Inference Benchmark | Automated sweep benchmark using [inference-benchmarker](https://github.com/huggingface/inference-benchmarker) to detect max throughput and measure latency across request rates | Inference | Done | 5 benchmark runs completed for Qwen | [inference/benchmark.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Inference Tests | Manual curl-based inference tests covering chat completions, text completions, sequential and concurrent throughput | Inference | Done | Successfully inferenced with Qwen | [inference/test-inference.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Extended Inference Tests | Validation suite: content correctness, schema validation, determinism, streaming, error handling, latency SLO, stop sequences | Inference | Done | 35 out 35 passed for qwen model | [inference/test-inference-extended.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Component Checks | Validates operator health, DataScienceCluster readiness, GPU node labels, required pods, and networking for the target OpenShift cluster | Platform Readiness | Done | 23 passed, 0 failed | [component-checks](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks) |
| Negative / Failure-Mode Tests | Verifies that resource over-requests go Pending (not silently queued), pod deletions complete cleanly, and no workloads are stuck Terminating or orphaned Pending | Platform Readiness | Done | 7 passed, 0 failed | [component-checks/negative-tests.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/negative-tests.sh) |
| Agent Deployment | Validates agent deployment with Rossoctl operator, covering AgentCard/AgentRuntime CRDs, protocol labels, service discovery, and pod lifecycle | Agent Platform | Done | 16 passed, 3 warnings (optional features: AuthBridge, SPIFFE, OTEL) | [agent-deployment](https://github.com/memalhot/open-science-test-cases/tree/main/agent-deployment) |
| Label & Taint Checks | Verifies GPU node labels (NFD, gpu.count, gpu.product, gpu.memory) and taints (nvidia.com/gpu.product:NoSchedule) to ensure proper GPU isolation | Platform Readiness | Done | Taints configured | [component-checks/taint-checks.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/taint-checks.sh) |

## AI Inference UAT Results

Harness run against the oac-prod-workload0 cluster. Three GPU nodes: `moc-r4pcc02u30` (u30), `moc-r4pcc04u09` (u09), `moc-r4pcc04u11` (u11), each 4x H100-80GB-HBM3 SXM (NV6, all-to-all NVLink), AMD EPYC 9754, kernel 5.14.0-570.78.1.el9_6, driver 595.91.07 (CUDA runtime 13.2). Scopes: project (single namespace), node (one pod per GPU node), multi-tenancy (project + peer). t5 kserve is excluded from this run.

Type = pass-fail (asserts conditions) or quant (records measurements). Each subtest is its own row. Pass-fail tests with sub-checks (platform-check, component, dev-env, ping) are broken out in [Check detail](#check-detail-1). Throughput is total tokens/s (input + output) except guidellm, which reports output tokens/s. Latest run folder per test.

### Quantitative subtests

Values are the measured result on each node (u30, u09, u11) for that subtest.

| Test | Subtest (load profile) | Scope | u30 result | u09 result | u11 result | What ran / what it means |
|------|------------------------|-------|------------|------------|------------|--------------------------|
| t3 iperf3 | single TCP stream, 10s | node pair | 6.50 Gbps (to u11) | 6.50 Gbps (to u30) | 6.45 Gbps (to u09) | Inter-node TCP bandwidth; each column is that node's best outbound pair (receiver-measured). All 6 directed pairs land 6.2-6.5 Gbps and pass the greater-than-zero assertion |
| t6 guidellm | short-burst, 4 req/s, 128 in / 64 out | node, 1 GPU | 501 output tok/s | 511 output tok/s | 506 output tok/s | Single-GPU vLLM server benchmarked by guidellm; output tokens per second |
| t6 guidellm | sustained-load, 1 req/s, 256 in / 128 out | node, 1 GPU | 133 output tok/s | 135 output tok/s | 134 output tok/s | Same single-GPU server, steady moderate load |
| t6 guidellm | long-context, 1 req/s, 1024 in / 512 out | node, 1 GPU | 133 output tok/s | 135 output tok/s | 134 output tok/s | Same single-GPU server, larger prompt and output |
| t7 inference-perf | constant-low, 1 req/s | node, 1 GPU | 191 total tok/s, TTFT 29ms | 200 total tok/s, TTFT 31ms | 187 total tok/s, TTFT 32ms | Single-GPU vLLM server, inference-perf load; total tokens per second (input + output), 0 failed requests |
| t7 inference-perf | constant-high, 10 req/s | node, 1 GPU | 1921 total tok/s, TTFT 31ms | 1936 total tok/s, TTFT 31ms | 1913 total tok/s, TTFT 31ms | Single-GPU server at high steady load, 0 failed requests |
| t7 inference-perf | poisson-burst, 5 req/s | node, 1 GPU | 913 total tok/s, TTFT 28ms | 923 total tok/s, TTFT 29ms | 936 total tok/s, TTFT 29ms | Single-GPU server under bursty Poisson arrivals, 0 failed requests |
| t8 chunked-prefill | stress, ramped 0.5 to 2 req/s | node, all 4 GPUs (TP) | 17,543 total tok/s, TTFT 193ms | 17,691 total tok/s, TTFT 192ms | 17,071 total tok/s, TTFT 193ms | One vLLM instance spanning all 4 GPUs in a single tensor-parallel group with chunked prefill; GPU-to-GPU traffic is NCCL over NVLink |
| t9 llm-d-local | stress, ramped 0.5 to 2 req/s | node, 4 GPUs (2 prefill + 2 decode) | 11,617 total tok/s, TTFT 554ms | 11,458 total tok/s, TTFT 558ms | 11,329 total tok/s, TTFT 559ms | Disaggregated prefill/decode in one pod; KV cache moved from prefill to decode GPUs over NVLink via NIXL cuda_ipc; this workload is prefill-bound, so it trails chunked-prefill |
| t9 NVLink (KV transfer) | steady-state, 1280 MB transfers | node | ~113 GB/s (max 118) | ~118 GB/s (max 122) | ~116 GB/s (max 121) | Per-transfer cuda_ipc/NVLink bandwidth for the KV move, ~11.4 ms per 1280 MB; ~75-79% of the 150 GB/s NV6 pair ceiling (light load, one request in flight) |
| t11 peer-load-high | constant-low, 1 req/s | node, 2 project + 2 peer GPUs | 219 total tok/s, TTFT 27ms | 210 total tok/s, TTFT 28ms | 194 total tok/s, TTFT 30ms | Project-side sweep against a 2-GPU vLLM server while the peer namespace runs its own 2-GPU tensor-parallel vLLM server on the same node under a sustained 10 req/s background load (noisy neighbor) |
| t11 peer-load-high | constant-high, 10 req/s | node, 2 project + 2 peer GPUs | 1956 total tok/s, TTFT 24ms | 1940 total tok/s, TTFT 24ms | 1928 total tok/s, TTFT 25ms | Same setup, project side at high load, against the busy (10 req/s) peer neighbor |
| t11 peer-load-high | poisson-burst, 5 req/s | node, 2 project + 2 peer GPUs | 910 total tok/s, TTFT 24ms | 906 total tok/s, TTFT 24ms | 1075 total tok/s, TTFT 24ms | Same setup, bursty project load against the busy (10 req/s) peer neighbor |
| t12 peer-load-low | constant-low, 1 req/s | node, 2 project + 2 peer GPUs | 217 total tok/s, TTFT 28ms | 203 total tok/s, TTFT 29ms | 179 total tok/s, TTFT 27ms | Project-side sweep while the peer namespace runs its own 2-GPU vLLM server on the same node under only a light 1 req/s background load (low-contention control) |
| t12 peer-load-low | constant-high, 10 req/s | node, 2 project + 2 peer GPUs | 1933 total tok/s, TTFT 24ms | 1918 total tok/s, TTFT 24ms | 1965 total tok/s, TTFT 24ms | Same setup, project side at high load, against the quiet (1 req/s) peer neighbor |
| t12 peer-load-low | poisson-burst, 5 req/s | node, 2 project + 2 peer GPUs | 949 total tok/s, TTFT 24ms | 961 total tok/s, TTFT 24ms | 939 total tok/s, TTFT 25ms | Same setup, bursty project load against the quiet (1 req/s) peer neighbor |

All sweeps recorded 0 failed requests. In t11 and t12 the peer namespace holds a second 2-GPU vLLM server that a background load generator hits continuously (10 req/s for t11, 1 req/s for t12) to create GPU contention on the shared node; the numbers above are the project side. See [Cross-test observations](#cross-test-observations).

### Cross-test observations

- **NVLink bandwidth (t9).** On the full 1280 MB KV transfers over cuda_ipc/NVLink, steady-state bandwidth reached ~113 GB/s (u30), ~118 GB/s (u09), ~116 GB/s (u11), peaking ~118-122 GB/s. Against the NV6 per-GPU-pair ceiling of 150 GB/s (6 links x 25 GB/s), that is ~75-79% utilization. This was a light load (one request in flight, KV cache 0-2%), so it reflects the per-transfer path bandwidth, not a saturating sweep.
- **chunked-prefill (t8) vs llm-d-local (t9)**, both 4 GPUs, same model and ramped load: t8 ~17.4k tok/s at ~192ms TTFT vs t9 ~11.5k tok/s at ~557ms TTFT, i.e. chunked delivers ~1.5x the throughput at ~3x lower TTFT. The workload is prefill-heavy (16,250 input tokens), so splitting the 4 GPUs into a 2-GPU prefill group + 2-GPU decode group, plus the KV-transfer step, makes the disaggregated path trail the single all-GPU TP group.
- **peer-stress vs unstressed.** Throughput and TTFT are essentially flat across single-tenant (t7), busy neighbor (t11, 10 req/s), and quiet neighbor (t12, 1 req/s) at every matching load profile, with 0 failed requests everywhere, so no measurable noisy-neighbor degradation. Two caveats: throughput here tracks the offered request rate rather than GPU headroom (the servers keep up in every case, so the real contention signal is TTFT, which stays low), and t7 is a 1-GPU single-tenant server while t11/t12 project-side is 2-GPU, so the clean apples-to-apples A/B is t11 vs t12 (identical 2-GPU setup, differing only in neighbor load) - and those two are within noise of each other. Each tenant has dedicated GPUs; contention is only on shared PCIe/memory/power, which is not the bottleneck at these loads.

### Check detail

#### t1 platform-check (project scope, 14/14 pass)

RBAC (expected denied):

| Check | Result |
|-------|--------|
| cannot get pods | pass |
| cannot create pods | pass |
| cannot get secrets | pass |
| cannot get nodes | pass |

API groups present:

| Check | Result |
|-------|--------|
| `kubeflow.org` present | pass |
| `serving.kserve.io` present | pass |
| `ray.io` present | pass |
| `nonexistent.example.io` absent (control) | pass |

Operator CRDs registered:

| Check | Result |
|-------|--------|
| `DataScienceCluster` (RHOAI) | pass |
| `DSCInitialization` (RHOAI) | pass |
| `ClusterPolicy` (GPU operator) | pass |
| `NodeFeatureDiscovery` (NFD) | pass |
| `KnativeServing` (Serverless) | pass |
| `ServiceMeshControlPlane` (Service Mesh) | pass |

#### t2 component (per node)

| Check | Category | u30 | u09 | u11 |
|-------|----------|-----|-----|-----|
| GPU count | Sanity | pass | pass | pass |
| GPU model | Sanity | pass | pass | pass |
| NVLink width | Sanity | pass | pass | pass |
| NVLink topology | Sanity | pass | pass | pass |
| PCIe link width | Sanity | pass | pass | pass |
| PCIe generation | Sanity | pass | pass | pass |
| CPU model | Sanity | pass | pass | pass |
| CPU count | Sanity | pass | pass | pass |
| Memory capacity | Sanity | pass | pass | pass |
| NUMA node count | Sanity | pass | pass | pass |
| CUDA driver version | Ideal | pass | pass | pass |
| GPU power limit | Ideal | pass | pass | pass |
| GPU persistence mode | Ideal | pass | pass | pass |
| Kernel version | Ideal | pass | pass | pass |
| Hugepages 2Mi | Ideal | fail (0, expected 4000) | fail (0) | fail (0) |
| CPU frequency governor | Ideal | pass | pass | pass |
| CPU idle driver | Ideal | pass | pass | pass |
| CPU idle governor | Ideal | pass | pass | pass |
| C-states | Ideal | pass | pass | pass |
| Transparent hugepages | Ideal | fail (`always`, expected `madvise`) | fail (`always`) | fail (`always`) |
| FIPS mode | Compliance | skipped (not required) | skipped | skipped |

Totals: 18/21 pass on all three nodes (2 Ideal fails each: hugepages and THP). See Finding 1.

#### t4 dev-env (per node, 6/6 pass all three)

| Check | u30 | u09 | u11 |
|-------|-----|-----|-----|
| Create diagnostic notebook | pass | pass | pass |
| Start kernel and execute diagnostic code | pass | pass | pass |
| Read and parse result.txt | pass | pass | pass |
| GPU count | pass | pass | pass |
| NVLink width | pass | pass | pass |
| All GPU devices reported | pass | pass | pass |

#### t10 ping (project scope)

| Check | project-check |
|-------|---------------|
| reach own service (short name) | pass |
| not reach other service (short name) | pass |
| not reach other service (FQDN) | fail (reachable) |

peer-check side not run (3 specs skipped). See Finding 2.

### Findings

#### Finding 1: hugepages and THP out of spec on all three nodes

All three nodes have `hugepages: 0` (expected 4000 x 2Mi = 8000Mi) and `transparentHugepages: always` (expected `madvise`). These are the only deviations from the reference ideal; all Sanity checks pass and the hardware (SKU, GPU, NVLink, PCIe, CPU, memory, NUMA) is identical across nodes and matches the oac-prod H100 SKU. Non-fatal (Ideal category) but relevant for inference latency - `always` THP risks khugepaged-induced latency spikes. Needs node tuning (kernel boot params / Tuned / PerformanceProfile). Unlike oac-prod u05, cpuidle and C-states are configured correctly here.

#### Finding 2: Cross-namespace FQDN reachable

DNS short-name scoping works (cross-namespace short-name lookups fail). But cross-namespace access by FQDN succeeds: the project reached `svc-t10-ping-peer-server.uat-peer.svc.cluster.local:8080`. The "should not reach by FQDN" assertion failed. No NetworkPolicy blocks cross-namespace traffic; isolation relies on DNS scoping alone, which any workload bypasses with an FQDN.

#### Finding 3: KServe N/A

The kserve test (t5) was excluded from this run. On oac-prod it was N/A under Serverless: the runner has no Istio sidecar, so mesh-wide STRICT mTLS resets every request against the plain predictor Service. Validating it needs RawDeployment mode or a sidecar on the runner.
