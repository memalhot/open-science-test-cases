#!/bin/bash
set -euo pipefail

PASSED=0
FAILED=0

check_deployment() {
  local name="$1"
  local namespace="$2"
  local label="$3"

  echo ""
  echo "--- ${label}: ${name} (${namespace}) ---"

  local available
  available=$(oc get deployment "${name}" -n "${namespace}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

  if [[ "${available}" == "True" ]]; then
    echo "PASS (Available)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (Available=${available:-not found})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_dsc_phase() {
  echo ""
  echo "--- DataScienceCluster: phase ---"

  local phase
  phase=$(oc get datasciencecluster -A \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

  if [[ "${phase}" == "Ready" ]]; then
    echo "PASS (phase: Ready)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (phase: ${phase:-not found})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_cluster_policy() {
  echo ""
  echo "--- GPU ClusterPolicy: state ---"

  local state
  state=$(oc get clusterpolicy -A \
    -o jsonpath='{.items[0].status.state}' 2>/dev/null || echo "")

  if [[ "${state}" == "ready" ]]; then
    echo "PASS (state: ready)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (state: ${state:-not found})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_nfd_instance() {
  echo ""
  echo "--- NFD Instance: Available ---"

  local available
  available=$(oc get nodefeaturediscovery -A \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

  if [[ "${available}" == "True" ]]; then
    echo "PASS (Available: True)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (Available: ${available:-not found})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_dsc_component() {
  local condition_type="$1"
  local label="$2"

  echo ""
  echo "--- DSC Component: ${label} (${condition_type}) ---"

  local status
  status=$(oc get datasciencecluster -A \
    -o jsonpath="{.items[0].status.conditions[?(@.type==\"${condition_type}\")].status}" 2>/dev/null || echo "")

  if [[ "${status}" == "True" ]]; then
    echo "PASS (${condition_type}: True)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (${condition_type}: ${status:-not found})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_node_label() {
  local node="$1"
  local label="$2"

  local value
  value=$(oc get node "${node}" -o jsonpath="{.metadata.labels.${label}}" 2>/dev/null || echo "")

  if [[ -n "${value}" ]]; then
    echo "  ${label}=${value}"
    return 0
  else
    echo "  ${label} MISSING" >&2
    return 1
  fi
}

check_gpu_node_labels() {
  echo ""
  echo "=== GPU Node Labels ==="

  local gpu_nodes
  gpu_nodes=$(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "${gpu_nodes}" ]]; then
    echo ""
    echo "--- GPU Node Labels ---"
    echo "FAIL (no nodes with nvidia.com/gpu.present=true found)" >&2
    FAILED=$((FAILED + 1))
    return
  fi

  for node in ${gpu_nodes}; do
    echo ""
    echo "--- Node: ${node} ---"

    local nfd_ok=false
    if oc get node "${node}" -o jsonpath='{.metadata.labels}' 2>/dev/null \
        | grep -qE '"feature\.node\.kubernetes\.io/pci-10de\.present"|"feature\.node\.kubernetes\.io/pci-0302_10de\.present"'; then
      nfd_ok=true
    fi

    if ${nfd_ok}; then
      echo "  NFD label: present"
    else
      echo "  NFD label: MISSING (expected pci-10de.present or pci-0302_10de.present)" >&2
    fi

    local gpu_count
    gpu_count=$(oc get node "${node}" \
      -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.count}' 2>/dev/null || echo "")

    if ${nfd_ok} && [[ -n "${gpu_count}" ]]; then
      echo "  nvidia.com/gpu.count=${gpu_count}"
      echo "PASS"
      PASSED=$((PASSED + 1))
    else
      [[ -z "${gpu_count}" ]] && echo "  nvidia.com/gpu.count: MISSING" >&2
      echo "FAIL" >&2
      FAILED=$((FAILED + 1))
    fi
  done
}

check_pods_running() {
  local label_selector="$1"
  local namespace="$2"
  local description="$3"

  echo ""
  echo "--- ${description} (${namespace}, ${label_selector}) ---"

  local running_count
  running_count=$(oc get pods -n "${namespace}" -l "${label_selector}" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

  if [[ "${running_count}" -gt 0 ]]; then
    echo "PASS (${running_count} pod(s) running)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (no running pods found)" >&2
    FAILED=$((FAILED + 1))
  fi
}

echo "========================================="
echo "  Operator & Platform Readiness Checks"
echo "========================================="

# --- Operator Health ---

echo ""
echo "=== Operator Health ==="

check_deployment "rhods-operator" "redhat-ods-operator" "Red Hat OpenShift AI"
check_deployment "nfd-controller-manager" "openshift-nfd" "Node Feature Discovery"
check_deployment "gpu-operator" "nvidia-gpu-operator" "NVIDIA GPU Operator"
check_deployment "knative-openshift" "openshift-serverless" "OpenShift Serverless"
check_deployment "istio-operator" "openshift-operators" "OpenShift Service Mesh"

# --- Configuration & Component Readiness ---

echo ""
echo "=== Configuration & Component Readiness ==="

check_dsc_phase
check_cluster_policy
check_nfd_instance

# --- DataScienceCluster Components ---

echo ""
echo "=== DataScienceCluster Components ==="

check_dsc_component "DashboardReady" "Dashboard"
check_dsc_component "WorkbenchesReady" "Workbenches"
check_dsc_component "DataSciencePipelinesReady" "DataSciencePipelines"
check_dsc_component "CodeFlareReady" "CodeFlare"
check_dsc_component "KserveReady" "KServe"
check_dsc_component "RayReady" "Ray"
check_dsc_component "TrustyAIReady" "TrustyAI"
check_dsc_component "ModelMeshServingReady" "ModelMeshServing"
check_dsc_component "KueueReady" "Kueue"

# --- GPU Node Labels ---

check_gpu_node_labels

# --- Required Pods Running ---

echo ""
echo "=== Required Pods ==="

check_pods_running "app=nfd-worker" "openshift-nfd" "NFD Worker"
check_pods_running "app.kubernetes.io/component=nvidia-driver" "nvidia-gpu-operator" "NVIDIA GPU Driver"

# --- Summary ---

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
