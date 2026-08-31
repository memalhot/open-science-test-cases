# open-science-test-cases

A collection of test cases and examples for open science workflows and deployments.

Before any of the inference, UI, or fine tuning tests can be run, the model must be deployed first.

## Test Cases

| Test Case | Description | Category | Completion | Notes | Link |
|-----------|-------------|----------|------------|-------|------|
| Model Serving | OpenShift deployment scripts and YAML manifests for deploying a model serving endpoint with vLLM, including ConfigMaps, Secrets, Services, and Routes | Model Serving | Done | Qwen and Gemma4 model deployed | [model-serving/granite-model](https://github.com/memalhot/open-science-test-cases/tree/main/model-serving/granite-model) |
| Inference Benchmark | Automated sweep benchmark using [inference-benchmarker](https://github.com/huggingface/inference-benchmarker) to detect max throughput and measure latency across request rates | Inference | Done | 5 benchmark runs completed for Qwen | [inference/benchmark.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Inference Tests | Manual curl-based inference tests covering chat completions, text completions, sequential and concurrent throughput | Inference | Done | Successfully inferenced with Qwen and Gemma4 | [inference/test-inference.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Extended Inference Tests | Validation suite: content correctness, schema validation, determinism, streaming, error handling, latency SLO, stop sequences | Inference | Done | 35 out 35 passed for qwen model | [inference/test-inference-extended.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Open WebUI (OPTIONAL) | Public chat UI for interacting with the deployed model, using [Open WebUI](https://github.com/endpoints/open-webui) on OpenShift | Endpoints | Done | | [endpoints/open-webui](https://github.com/memalhot/open-science-test-cases/tree/main/endpoints/open-webui) |
| Fine-Tuning | QLoRA fine-tuning of Granite 3.0 8B Instruct on OpenShift using a Kubeflow PyTorchJob, with configurable datasets and training parameters | Fine-Tuning | Done | Qwen fine-tuning jobs successfully run with Openshift jobs. Look into adding operator for pytorch jobs | [fine-tuning](https://github.com/memalhot/open-science-test-cases/tree/main/fine-tuning) |
| Agent Deployment | Tests agent deployment verification based on RHOAI 3.4 AgentCard and AgentRuntime features, including discovery, sidecar injection, and tracing | Agent Testing | Not Started | | [agent-deployment](https://github.com/memalhot/open-science-test-cases/tree/main/agent-deployment) |
| Component Checks | Validates operator health, DataScienceCluster readiness, GPU node labels, required pods, and networking for the target OpenShift cluster | Platform Readiness | Done | 23 passed, 0 failed | [component-checks](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks) |
| Label & Taint Checks | Verifies GPU node labels (NFD, gpu.count, gpu.product, gpu.memory) and taints (nvidia.com/gpu.product:NoSchedule) to ensure proper GPU isolation | Platform Readiness | Done | Taints configured | [component-checks/taint-checks.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/taint-checks.sh) |
| Negative / Failure-Mode Tests | Verifies that resource over-requests go Pending (not silently queued), pod deletions complete cleanly, and no workloads are stuck Terminating or orphaned Pending | Platform Readiness | Done | 7 passed, 0 failed | [component-checks/negative-tests.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/negative-tests.sh) |

## AI Inference UAT Results

Harness run against the oac-prod cluster. Two GPU nodes: `moc-r4pcc02u05` (u05) and `moc-r4pcc02u09` (u09), each 4x H100 SXM (NV6, all-to-all NVLink). Scopes: project (single namespace), node (one pod per GPU node), multi-tenancy (project + peer).

Raw artifacts: [`results_uat_harness/results_all_tests/`](results_uat_harness/results_all_tests/). Runtime and GPU-minutes: [`results_uat_harness/tracking/usage.md`](results_uat_harness/tracking/usage.md). 

Type = pass-fail (asserts conditions) or quant (records measurements). Each subtest is its own row. Pass-fail tests with sub-checks (platform-check, component, dev-env, ping) are broken out in [Check detail](#check-detail). Throughput is total tokens/s (input + output) except guidellm, which reports output tokens/s.

### Quantitative subtests

Values are the measured result on each node (u05, u09) for that subtest.

| Test | Subtest (load profile) | Scope | u05 result | u09 result | What ran / what it means |
|------|------------------------|-------|------------|------------|--------------------------|
| t3 iperf3 | single TCP stream, 10s | node pair | 11.42 Gbps (u05 to u09) | 13.40 Gbps (u09 to u05) | Inter-node TCP bandwidth; each column is that node sending to the other. Both directions pass the greater-than-zero assertion |
| t6 guidellm | short-burst, 4 req/s, 128 in / 64 out | node, 1 GPU | 541 output tok/s | 279 output tok/s | Single-GPU vLLM server benchmarked by guidellm; output tokens per second |
| t6 guidellm | sustained-load, 1 req/s, 256 in / 128 out | node, 1 GPU | 137 output tok/s | 138 output tok/s | Same single-GPU server, steady moderate load |
| t6 guidellm | long-context, 1 req/s, 1024 in / 512 out | node, 1 GPU | 136 output tok/s | 137 output tok/s | Same single-GPU server, larger prompt and output |
| t7 inference-perf | constant-low, 1 req/s | node, 1 GPU | 204 total tok/s, TTFT 21ms | 198 total tok/s, TTFT 27ms | Single-GPU vLLM server, inference-perf load; total tokens per second (input + output), 0 failed requests |
| t7 inference-perf | constant-high, 10 req/s | node, 1 GPU | 1919 total tok/s, TTFT 25ms | 1918 total tok/s, TTFT 29ms | Single-GPU server at high steady load, 0 failed requests |
| t7 inference-perf | poisson-burst, 5 req/s | node, 1 GPU | 874 total tok/s, TTFT 24ms | 957 total tok/s, TTFT 28ms | Single-GPU server under bursty Poisson arrivals, 0 failed requests |
| t8 chunked-prefill | stress, ramped 0.5 to 2 req/s | node, all 4 GPUs (TP) | 18,608 total tok/s, TTFT 75ms | 17,537 total tok/s, TTFT 119ms | One vLLM instance spanning all 4 GPUs in a single tensor-parallel group with chunked prefill; GPU-to-GPU traffic is NCCL over NVLink |
| t9 llm-d-local | stress, ramped 0.5 to 2 req/s | node, 4 GPUs (2 prefill + 2 decode) | 11,977 total tok/s, TTFT 514ms | 11,442 total tok/s, TTFT 588ms | Disaggregated prefill/decode in one pod; KV cache moved from prefill to decode GPUs over NVLink via NIXL cuda_ipc; this workload is prefill-bound, so it trails chunked-prefill |
| t11 peer-load-high | constant-low, 1 req/s | node, 2 project + 2 peer GPUs | 191 total tok/s, TTFT 18ms | 200 total tok/s, TTFT 24ms | Project-side sweep against a 2-GPU vLLM server while the peer namespace runs its own 2-GPU tensor-parallel vLLM server on the same node under a sustained 10 req/s background load (noisy neighbor) |
| t11 peer-load-high | constant-high, 10 req/s | node, 2 project + 2 peer GPUs | 1950 total tok/s, TTFT 19ms | 1964 total tok/s, TTFT 24ms | Same setup, project side at high load, against the busy (10 req/s) peer neighbor |
| t11 peer-load-high | poisson-burst, 5 req/s | node, 2 project + 2 peer GPUs | 971 total tok/s, TTFT 19ms | 1126 total tok/s, TTFT 23ms | Same setup, bursty project load against the busy (10 req/s) peer neighbor |
| t12 peer-load-low | constant-low, 1 req/s | node, 2 project + 2 peer GPUs | 195 total tok/s, TTFT 17ms | 200 total tok/s, TTFT 24ms | Project-side sweep while the peer namespace runs its own 2-GPU vLLM server on the same node under only a light 1 req/s background load (low-contention control) |
| t12 peer-load-low | constant-high, 10 req/s | node, 2 project + 2 peer GPUs | 1925 total tok/s, TTFT 19ms | 1933 total tok/s, TTFT 24ms | Same setup, project side at high load, against the quiet (1 req/s) peer neighbor |
| t12 peer-load-low | poisson-burst, 5 req/s | node, 2 project + 2 peer GPUs | 950 total tok/s, TTFT 18ms | 1063 total tok/s, TTFT 23ms | Same setup, bursty project load against the quiet (1 req/s) peer neighbor |

All sweeps recorded 0 failed requests. In t11 and t12 the peer namespace holds a second 2-GPU vLLM server that a background load generator hits continuously (10 req/s for t11, 1 req/s for t12) to create GPU contention on the shared node; the numbers above are the project side. Comparing each project-side sweep against its matching t7 single-tenant sweep (constant-low vs constant-low, and so on), throughput is essentially unchanged at both peer load levels, so no meaningful noisy-neighbor degradation was observed. t5 kserve is N/A (see Finding 3).

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

| Check | Category | u05 | u09 |
|-------|----------|-----|-----|
| GPU count | Sanity | pass | pass |
| GPU model | Sanity | pass | pass |
| NVLink width | Sanity | pass | pass |
| NVLink topology | Sanity | pass | pass |
| PCIe link width | Sanity | pass | pass |
| PCIe generation | Sanity | pass | pass |
| CPU model | Sanity | pass | pass |
| CPU count | Sanity | pass | pass |
| Memory capacity | Sanity | pass | pass |
| NUMA node count | Sanity | pass | pass |
| CUDA driver version | Ideal | pass | pass |
| GPU power limit | Ideal | pass | pass |
| GPU persistence mode | Ideal | pass | pass |
| Kernel version | Ideal | pass | pass |
| Hugepages 2Mi | Ideal | fail (0, expected 4000) | fail (0) |
| CPU frequency governor | Ideal | pass | pass |
| CPU idle driver | Ideal | fail (`none`, expected `acpi_idle`) | pass |
| CPU idle governor | Ideal | pass | pass |
| C-states | Ideal | fail (none exposed) | pass |
| Transparent hugepages | Ideal | fail (`always`, expected `madvise`) | pass |
| FIPS mode | Compliance | skipped (not required) | skipped |

Totals: u05 16/21 pass (4 Ideal fails), u09 18/21 pass (2 Ideal fails). See Finding 1.

#### t4 dev-env (per node, 6/6 pass both)

| Check | u05 | u09 |
|-------|-----|-----|
| Create diagnostic notebook | pass | pass |
| Start kernel and execute diagnostic code | pass | pass |
| Read and parse result.txt | pass | pass |
| GPU count | pass | pass |
| NVLink width | pass | pass |
| All GPU devices reported | pass | pass |

#### t10 ping (project + peer)

| Check | project-check | peer-check |
|-------|---------------|------------|
| reach own service (short name) | pass | pass |
| not reach other service (short name) | pass | pass |
| not reach other service (FQDN) | fail (reachable) | fail (reachable) |

See Finding 2.

### Findings

#### Finding 1: u05 schedulable CPU (192) and per-node kernel config divergence

Hosts expose 512 logical CPUs (2x EPYC 9754). The component test reads `/proc/cpuinfo` (512), so its CPU-count check passes on both nodes. But u05 advertises only 192 schedulable CPUs to Kubernetes (`node.status.capacity.cpu`), a ~320-core gap from a kubelet/cpuset restriction. The test does not check k8s-advertised capacity, so 192 vs 512 goes undetected.

Kernel/tuning config also differs (Ideal checks, non-fatal). Both nodes miss hugepages and THP. u05 additionally has cpuidle disabled (driver `none`, no C-states), a boot/tuning difference from u09. u05 fails 4 Ideal checks, u09 fails 2. All Sanity and Compliance checks pass (FIPS skipped, not required).

#### Finding 2: Cross-namespace FQDN reachable

DNS short-name scoping works (cross-namespace short-name lookups fail). But cross-namespace access by FQDN succeeds both ways:

- project reached `svc-t10-ping-peer-server.uat-peer.svc.cluster.local:8080`
- peer reached `svc-t10-ping-project-server.uat-project.svc.cluster.local:8080`

Both "should not reach by FQDN" assertions failed. No NetworkPolicy blocks cross-namespace traffic; isolation relies on DNS scoping alone, which any workload bypasses with an FQDN.

#### Finding 3: KServe N/A under Serverless

The kserve test targets RawDeployment: it polls a plain predictor `Service:8080` from a sidecar-less runner. This cluster defaults KServe to Serverless (Knative + Istio, mesh-wide STRICT mTLS). The predictor came up healthy, but the runner has no Istio sidecar, so STRICT mTLS resets every request; the availability step timed out and the run was interrupted (no pass/fail signal). N/A for a Serverless cluster, not a KServe failure. Validating it needs RawDeployment mode or a sidecar on the runner.
