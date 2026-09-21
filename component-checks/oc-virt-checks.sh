#!/bin/bash
set -euo pipefail

CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"

PASSED=0
FAILED=0

check_deployment() {
  local name="$1"
  local label="$2"

  echo ""
  echo "--- ${label}: ${name} (${CNV_NAMESPACE}) ---"

  local available
  available=$(oc get deployment "${name}" -n "${CNV_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")

  if [[ "${available}" == "True" ]]; then
    local ready
    ready=$(oc get deployment "${name}" -n "${CNV_NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "")
    echo "PASS (Available, ${ready} ready)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (Available=${available:-not found})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_daemonset() {
  local name="$1"
  local label="$2"

  echo ""
  echo "--- ${label}: ${name} (${CNV_NAMESPACE}) ---"

  local counts desired ready unavailable
  counts=$(oc get daemonset "${name}" -n "${CNV_NAMESPACE}" \
    -o jsonpath='{.status.desiredNumberScheduled}|{.status.numberReady}|{.status.numberUnavailable}' 2>/dev/null || echo "")

  if [[ -z "${counts}" ]]; then
    echo "FAIL (daemonset not found)" >&2
    FAILED=$((FAILED + 1))
    return
  fi

  IFS='|' read -r desired ready unavailable <<< "${counts}"
  unavailable="${unavailable:-0}"

  if [[ -n "${desired}" && "${desired}" -gt 0 && "${ready}" == "${desired}" && "${unavailable}" == "0" ]]; then
    echo "PASS (${ready}/${desired} ready)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (${ready:-0}/${desired:-0} ready, ${unavailable} unavailable)" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_condition() {
  local resource="$1"
  local condition_type="$2"
  local expected="$3"
  local label="$4"

  echo ""
  echo "--- ${label}: ${condition_type} ---"

  local status
  status=$(oc get "${resource}" -n "${CNV_NAMESPACE}" \
    -o jsonpath="{.items[0].status.conditions[?(@.type==\"${condition_type}\")].status}" 2>/dev/null || echo "")

  if [[ "${status}" == "${expected}" ]]; then
    echo "PASS (${condition_type}: ${status})"
    PASSED=$((PASSED + 1))
  else
    local reason
    reason=$(oc get "${resource}" -n "${CNV_NAMESPACE}" \
      -o jsonpath="{.items[0].status.conditions[?(@.type==\"${condition_type}\")].message}" 2>/dev/null || echo "")
    echo "FAIL (${condition_type}: ${status:-not found}, expected ${expected}${reason:+ — ${reason}})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_phase() {
  local resource="$1"
  local expected="$2"
  local label="$3"

  echo ""
  echo "--- ${label}: phase ---"

  local phase
  phase=$(oc get "${resource}" -A \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

  if [[ "${phase}" == "${expected}" ]]; then
    echo "PASS (phase: ${phase})"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (phase: ${phase:-not found}, expected ${expected})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_cnv_csv() {
  echo ""
  echo "--- CSV: kubevirt-hyperconverged (${CNV_NAMESPACE}) ---"

  local csv
  csv=$(oc get csv -n "${CNV_NAMESPACE}" -l '!olm.copiedFrom' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep '^kubevirt-hyperconverged' || echo "")

  if [[ -z "${csv}" ]]; then
    echo "FAIL (no kubevirt-hyperconverged CSV found)" >&2
    FAILED=$((FAILED + 1))
    return
  fi

  local name phase
  IFS='|' read -r name phase <<< "${csv}"

  if [[ "${phase}" == "Succeeded" ]]; then
    echo "PASS (${name}, phase: Succeeded)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (${name}, phase: ${phase:-unknown})" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_no_failing_pods() {
  echo ""
  echo "--- Pods: none failing in ${CNV_NAMESPACE} ---"

  local bad
  bad=$(oc get pods -n "${CNV_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -vE '\|(Running|Succeeded)$' || echo "")

  if [[ -z "${bad}" ]]; then
    local total
    total=$(oc get pods -n "${CNV_NAMESPACE}" -o name 2>/dev/null | wc -l)
    echo "PASS (${total} pod(s), all Running/Succeeded)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (not Running/Succeeded):" >&2
    echo "${bad}" | sed 's/|/ /' | sed 's/^/  /' >&2
    FAILED=$((FAILED + 1))
  fi
}

check_container_restarts() {
  echo ""
  echo "--- Pods: no crash-looping containers ---"

  local crashing
  crashing=$(oc get pods -n "${CNV_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"|"}{end}{"\n"}{end}' 2>/dev/null \
    | grep -c 'CrashLoopBackOff' || true)

  if [[ "${crashing:-0}" -eq 0 ]]; then
    echo "PASS (no CrashLoopBackOff containers)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (${crashing} pod(s) with CrashLoopBackOff containers)" >&2
    oc get pods -n "${CNV_NAMESPACE}" 2>/dev/null | grep 'CrashLoopBackOff' | sed 's/^/  /' >&2
    FAILED=$((FAILED + 1))
  fi
}

check_virt_nodes() {
  echo ""
  echo "=== Virtualization-Capable Nodes ==="

  local nodes
  nodes=$(oc get nodes -l kubevirt.io/schedulable=true \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

  echo ""
  echo "--- Nodes with kubevirt.io/schedulable=true ---"

  if [[ -z "${nodes}" ]]; then
    echo "FAIL (no virtualization-schedulable nodes found)" >&2
    FAILED=$((FAILED + 1))
    return
  fi

  local count
  count=$(wc -w <<< "${nodes}")
  echo "PASS (${count} node(s): ${nodes})"
  PASSED=$((PASSED + 1))

  for node in ${nodes}; do
    echo ""
    echo "--- Node: ${node} ---"

    local devices
    devices=$(oc get node "${node}" \
      -o jsonpath='{.status.allocatable.devices\.kubevirt\.io/kvm}' 2>/dev/null || echo "")

    if [[ -n "${devices}" && "${devices}" != "0" ]]; then
      echo "  devices.kubevirt.io/kvm=${devices}"
      echo "PASS"
      PASSED=$((PASSED + 1))
    else
      echo "  devices.kubevirt.io/kvm: ${devices:-MISSING} (no hardware virtualization exposed)" >&2
      echo "FAIL" >&2
      FAILED=$((FAILED + 1))
    fi
  done
}

check_api_served() {
  local resource="$1"
  local label="$2"

  echo ""
  echo "--- API: ${label} (${resource}) ---"

  if oc get "${resource}" -A -o name >/dev/null 2>&1; then
    local count
    count=$(oc get "${resource}" -A -o name 2>/dev/null | wc -l)
    echo "PASS (API served, ${count} object(s))"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (API not served — CRD missing or apiserver unavailable)" >&2
    FAILED=$((FAILED + 1))
  fi
}

check_vm_health() {
  echo ""
  echo "--- VirtualMachineInstances: none failed ---"

  local vmis
  vmis=$(oc get vmi -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")

  if [[ -z "${vmis}" ]]; then
    echo "PASS (no VMIs on cluster)"
    PASSED=$((PASSED + 1))
    return
  fi

  local bad
  bad=$(grep -vE '\|(Running|Succeeded|Scheduling|Scheduled|Pending)$' <<< "${vmis}" || echo "")

  if [[ -z "${bad}" ]]; then
    local total
    total=$(grep -c . <<< "${vmis}")
    echo "PASS (${total} VMI(s), none Failed/Unknown)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (VMIs in a bad phase):" >&2
    echo "${bad}" | sed 's/|/ /' | sed 's/^/  /' >&2
    FAILED=$((FAILED + 1))
  fi
}

echo "========================================="
echo "  OpenShift Virtualization (CNV) Checks"
echo "  Namespace: ${CNV_NAMESPACE}"
echo "========================================="

if ! oc get namespace "${CNV_NAMESPACE}" >/dev/null 2>&1; then
  echo ""
  echo "FAIL (namespace ${CNV_NAMESPACE} not found — is OpenShift Virtualization installed?)" >&2
  exit 1
fi

# --- Operator Health ---

echo ""
echo "=== Operator Health ==="

check_deployment "hco-operator" "HyperConverged Cluster Operator"
check_deployment "hco-webhook" "HCO Webhook"
check_deployment "virt-operator" "KubeVirt Operator"
check_deployment "cdi-operator" "Containerized Data Importer Operator"
check_deployment "cluster-network-addons-operator" "Cluster Network Addons Operator"
check_deployment "ssp-operator" "Scheduling, Scale and Performance Operator"
check_deployment "hostpath-provisioner-operator" "Hostpath Provisioner Operator"
check_deployment "aaq-operator" "Applications Aware Quota Operator"
check_deployment "kubevirt-migration-operator" "KubeVirt Migration Operator"

check_cnv_csv

# --- Control Plane ---

echo ""
echo "=== Virtualization Control Plane ==="

check_deployment "virt-api" "KubeVirt API"
check_deployment "virt-controller" "KubeVirt Controller"
check_deployment "virt-exportproxy" "KubeVirt Export Proxy"
check_deployment "virt-template-validator" "VM Template Validator"
check_deployment "kubevirt-apiserver-proxy" "KubeVirt API Server Proxy"
check_deployment "kubevirt-console-plugin" "KubeVirt Console Plugin"
check_deployment "kubevirt-migration-controller" "KubeVirt Migration Controller"

# --- Data Plane (DaemonSets) ---

echo ""
echo "=== Virtualization Data Plane ==="

check_daemonset "virt-handler" "KubeVirt Node Handler"
check_daemonset "bridge-marker" "Bridge Marker"
check_daemonset "kube-cni-linux-bridge-plugin" "Linux Bridge CNI Plugin"

# --- Storage & Data Import ---

echo ""
echo "=== Storage & Data Import ==="

check_deployment "cdi-apiserver" "CDI API Server"
check_deployment "cdi-deployment" "CDI Controller"
check_deployment "cdi-uploadproxy" "CDI Upload Proxy"

# --- Networking ---

echo ""
echo "=== Networking ==="

check_deployment "kubemacpool-cert-manager" "KubeMacPool Cert Manager"
check_deployment "kubemacpool-mac-controller-manager" "KubeMacPool MAC Controller"
check_deployment "kubevirt-ipam-controller-manager" "KubeVirt IPAM Controller"

# --- Custom Resource Readiness ---

echo ""
echo "=== Custom Resource Readiness ==="

check_condition "hyperconverged" "Available" "True" "HyperConverged"
check_condition "hyperconverged" "ReconcileComplete" "True" "HyperConverged"
check_condition "hyperconverged" "Progressing" "False" "HyperConverged"
check_condition "hyperconverged" "Degraded" "False" "HyperConverged"
check_condition "hyperconverged" "Upgradeable" "True" "HyperConverged"

check_phase "kubevirt" "Deployed" "KubeVirt"
check_condition "kubevirt" "Available" "True" "KubeVirt"
check_condition "kubevirt" "Degraded" "False" "KubeVirt"

check_phase "cdi" "Deployed" "CDI"
check_condition "cdi" "Available" "True" "CDI"

check_condition "networkaddonsconfig" "Available" "True" "NetworkAddonsConfig"
check_condition "networkaddonsconfig" "Degraded" "False" "NetworkAddonsConfig"

check_condition "ssp" "Available" "True" "SSP"
check_condition "ssp" "Degraded" "False" "SSP"

# --- Virtualization APIs ---

echo ""
echo "=== Virtualization APIs ==="

check_api_served "virtualmachines" "VirtualMachine"
check_api_served "virtualmachineinstances" "VirtualMachineInstance"
check_api_served "datavolumes" "DataVolume"

# --- Nodes ---

check_virt_nodes

# --- Workload Health ---

echo ""
echo "=== Workload Health ==="

check_no_failing_pods
check_container_restarts
check_vm_health

# --- Summary ---

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
