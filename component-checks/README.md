# Operator & Platform Readiness Checks

Validates that all OpenShift operators, configurations, and RHOAI components required by this project are installed and healthy. Includes negative tests that verify failure modes behave predictably.

## Usage

```bash
cd component-checks
./checks.sh          # operator & platform readiness
./taint-checks.sh    # GPU node labels & taints
./negative-tests.sh  # failure-mode & teardown tests
```

Requires `oc` CLI authenticated to the target cluster.

## What It Checks

### Operator Health

Verifies each operator's Deployment has `Available: True`.

| Operator | Deployment | Namespace |
|----------|-----------|-----------|
| Red Hat OpenShift AI | `rhods-operator` | `redhat-ods-operator` |
| Node Feature Discovery | `nfd-controller-manager` | `openshift-nfd` |
| NVIDIA GPU Operator | `gpu-operator` | `nvidia-gpu-operator` |
| OpenShift Serverless | `knative-openshift` | `openshift-serverless` |
| OpenShift Service Mesh | `istio-operator` | `openshift-operators` |
| NVIDIA Network Operator | `nvidia-network-operator-controller-manager` | `nvidia-network-operator` |
| SR-IOV Network Operator | `sriov-network-operator` | `openshift-sriov-network-operator` |
| NVIDIA Maintenance Operator | `maintenance-operator-controller-manager` | `nvidia-maintenance-operator` |
| NVIDIA NIC Configuration Operator | `nic-configuration-operator` | `nvidia-network-operator` |

### Configuration & Component Readiness

| Configuration | Expected State |
|--------------|---------------|
| DataScienceCluster | `phase: Ready` |
| GPU ClusterPolicy | `state: ready` |
| NFD Instance | `Available: True` |

### DataScienceCluster Components

Checks that each component condition is `True` on the DataScienceCluster resource:

Dashboard, Workbenches, DataSciencePipelines, CodeFlare, KServe, Ray, TrustyAI, ModelMeshServing, Kueue

### GPU Node Labels (`checks.sh`)

For each node with `nvidia.com/gpu.present=true`, verifies:

- NFD PCI label is present (`pci-10de.present` or `pci-0302_10de.present`)
- `nvidia.com/gpu.count` label exists

### GPU Node Labels & Taints (`taint-checks.sh`)

Separate script for GPU node label and taint validation. For each node with `nvidia.com/gpu.present=true`, verifies:

**Labels:**
- NFD PCI label (`pci-10de.present` or `pci-0302_10de.present`)
- `nvidia.com/gpu.count`
- `nvidia.com/gpu.product`
- `nvidia.com/gpu.memory`

**Taints:**
- `nvidia.com/gpu.product:NoSchedule` — prevents non-GPU workloads from being scheduled on GPU nodes

### Required Pods

| Pod | Label Selector | Namespace |
|-----|---------------|-----------|
| NFD Worker | `app=nfd-worker` | `openshift-nfd` |
| NVIDIA GPU Driver | `app.kubernetes.io/component=nvidia-driver` | `nvidia-gpu-operator` |

### Networking

| Resource | Expected State |
|----------|---------------|
| ServiceMeshControlPlane | `Ready: True` |

### Negative / Failure-Mode Tests (`negative-tests.sh`)

Verifies that the platform fails predictably — workloads that can't be scheduled don't silently queue up, and teardowns complete cleanly.

**Resource Over-Request:**

| Test | Expected Behavior |
|------|-------------------|
| Pod requesting 99 GPUs | Goes `Pending` with `Unschedulable` reason, does not crash or hang |
| Pod requesting 99Ti memory | Goes `Pending`, does not get OOM-killed on a node |
| Pending pods discoverable | `oc get pods --field-selector=status.phase=Pending` finds them |

**Teardown Reliability:**

| Test | Expected Behavior |
|------|-------------------|
| Unschedulable pod deletion | Completes immediately, pod does not linger |
| Running pod deletion | Pod fully terminates within 60s |
| No stuck Terminating pods | No pods with `deletionTimestamp` older than 5 minutes |
| No orphaned Pending pods | No pods stuck `Pending` longer than 10 minutes |

The last two health checks catch problems from any workload in the namespace, not just the test resources — run them before going on vacation.

Creates temporary `neg-test-*` pods that are cleaned up automatically on exit.

## Output

Reports PASS/FAIL per check with a summary. Exits `0` if all pass, `1` if any fail.
