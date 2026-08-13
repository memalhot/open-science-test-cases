# Operator & Platform Readiness Checks

Validates that all OpenShift operators, configurations, and RHOAI components required by this project are installed and healthy.

## Usage

```bash
cd component-checks
./checks.sh          # operator & platform readiness
./taint-checks.sh    # GPU node labels & taints
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

## Output

Reports PASS/FAIL per check with a summary. Exits `0` if all pass, `1` if any fail.
