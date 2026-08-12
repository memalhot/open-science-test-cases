#!/bin/bash
set -euo pipefail

PASSED=0
FAILED=0

check_node_label() {
  local node="$1"
  local label="$2"

  local labels_json
  labels_json=$(oc get node "${node}" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "{}")

  local value
  value=$(echo "${labels_json}" | python3 -c "
import sys, json
labels = json.load(sys.stdin)
print(labels.get('${label}', ''))" 2>/dev/null || echo "")

  if [[ -n "${value}" ]]; then
    echo "  ${label}=${value}"
    return 0
  else
    echo "  ${label} MISSING" >&2
    return 1
  fi
}

check_node_taint() {
  local node="$1"
  local expected_key="$2"
  local expected_effect="$3"

  local taints_json
  taints_json=$(oc get node "${node}" -o jsonpath='{.spec.taints}' 2>/dev/null || echo "null")

  local found
  found=$(echo "${taints_json}" | python3 -c "
import sys, json
taints = json.load(sys.stdin) or []
for t in taints:
    if t.get('key') == '${expected_key}' and t.get('effect') == '${expected_effect}':
        print('yes')
        break
" 2>/dev/null || echo "")

  if [[ "${found}" == "yes" ]]; then
    echo "  taint ${expected_key}:${expected_effect} present"
    return 0
  else
    echo "  taint ${expected_key}:${expected_effect} MISSING" >&2
    return 1
  fi
}

echo "========================================="
echo "  GPU Node Label & Taint Checks"
echo "========================================="

gpu_nodes=$(oc get nodes -l nvidia.com/gpu.present=true \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [[ -z "${gpu_nodes}" ]]; then
  echo ""
  echo "FAIL (no nodes with nvidia.com/gpu.present=true found)" >&2
  FAILED=$((FAILED + 1))

  echo ""
  echo "========================================="
  echo "  Results: ${PASSED} passed, ${FAILED} failed"
  echo "========================================="
  exit 1
fi

for node in ${gpu_nodes}; do
  echo ""
  echo "--- Node: ${node} ---"

  # --- Labels ---

  echo ""
  echo "  Labels:"

  nfd_ok=false
  if oc get node "${node}" -o jsonpath='{.metadata.labels}' 2>/dev/null \
      | grep -qE '"feature\.node\.kubernetes\.io/pci-10de\.present"|"feature\.node\.kubernetes\.io/pci-0302_10de\.present"'; then
    nfd_ok=true
  fi

  if ${nfd_ok}; then
    echo "  NFD PCI label: present"
  else
    echo "  NFD PCI label: MISSING (expected pci-10de.present or pci-0302_10de.present)" >&2
  fi

  label_ok=true
  check_node_label "${node}" "nvidia.com/gpu.count" || label_ok=false
  check_node_label "${node}" "nvidia.com/gpu.product" || label_ok=false
  check_node_label "${node}" "nvidia.com/gpu.memory" || label_ok=false

  if ${nfd_ok} && ${label_ok}; then
    echo "PASS (labels)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (labels)" >&2
    FAILED=$((FAILED + 1))
  fi

  # --- Taints ---

  echo ""
  echo "  Taints:"

  taint_ok=true
  check_node_taint "${node}" "nvidia.com/gpu.product" "NoSchedule" || taint_ok=false

  if ${taint_ok}; then
    echo "PASS (taints)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (taints)" >&2
    FAILED=$((FAILED + 1))
  fi
done

# --- Summary ---

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
