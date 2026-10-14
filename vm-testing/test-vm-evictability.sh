#!/usr/bin/env bash
set -euo pipefail

# Automated proof that a VM's cost to its neighbours is not just its size but
# its immovability.
#
# test-vm-memory-overhead.sh measures how much node memory a VM takes. This
# measures how hard it is to get back. Under pressure the platform reclaims
# memory by evicting pods; a container yields and is rescheduled elsewhere, and
# a VM either refuses outright or has to be live migrated, which is slow,
# bandwidth-hungry and conditional on storage that supports it.
#
# The decisive experiment would drive a node into real memory pressure, which
# on a shared cluster evicts other people's workloads. This script does not do
# that. It measures evictability directly through the Eviction API and the
# scheduling metadata that determines eviction order, touching only objects it
# created itself. Memory pressure is only the trigger; evictability is the
# mechanism, and the mechanism is what differs between a VM and a pod. The
# pressure-based variant is written up as a manual procedure in README.md and
# is deliberately not scripted.
#
# Everything here runs as the logged-in user. pods/eviction create is already in
# clusterrole/edit, so unlike live migration this needs no RBAC grant.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
VM_NAME="${VM_NAME:-evict-test-vm}"
DV_NAME="${DV_NAME:-${VM_NAME}-rootdisk}"
CONTROL_NAME="${CONTROL_NAME:-evict-test-control}"

# rwx + evictionStrategy: LiveMigrate is the migratable VM. rwo with no eviction
# strategy is the pinned one. Running both back to back is the point: the
# contrast between them is the finding, not either number alone.
TEST_BOTH_MODES="${TEST_BOTH_MODES:-1}"
DISK_MODE="${DISK_MODE:-rwx}"            # used when TEST_BOTH_MODES=0

SOURCE_MODE="${SOURCE_MODE:-registry}"   # registry, because cloning is broken here
IMAGE_URL="${IMAGE_URL:-docker://quay.io/containerdisks/fedora:41}"
GUEST_USER="${GUEST_USER:-fedora}"
DISK_SIZE="${DISK_SIZE:-10Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
VM_MEMORY="${VM_MEMORY:-2Gi}"
CONTROL_IMAGE="${CONTROL_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"

DV_TIMEOUT="${DV_TIMEOUT:-900}"
DV_STALL="${DV_STALL:-240}"              # see test-vm-storage.sh: a broken import retry-loops forever
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300s}"
EVICTION_TIMEOUT="${EVICTION_TIMEOUT:-180}"
KEEP_VM="${KEEP_VM:-0}"

PASSED=0
FAILED=0
SUMMARY=()   # mode<TAB>outcome<TAB>detail

pass() { echo " passed  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  failed $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  warning  $1"; }

cleanup() {
  echo ""
  echo "=== Cleaning up resources ==="
  if [ "${KEEP_VM}" = "1" ]; then
    echo "KEEP_VM=1, leaving the VM, disk and control pod in place. Delete with:"
    echo "  oc delete vm ${VM_NAME} -n ${NAMESPACE}"
    echo "  oc delete dv ${DV_NAME} -n ${NAMESPACE}"
    echo "  oc delete deployment ${CONTROL_NAME} -n ${NAMESPACE}"
  else
    oc delete deployment "${CONTROL_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
    oc delete vm "${VM_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
    # Deleting the DataVolume reclaims the PVC it provisioned.
    oc delete dv "${DV_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
  fi
  echo "Done!"
}

launcher_pod() {
  oc get pods -n "${NAMESPACE}" -l "vm.kubevirt.io/name=${VM_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Send a real Eviction to the API server and report what came back. The raw
# subresource is used rather than `oc adm drain` on purpose: drain also cordons
# the node, which needs patch on nodes and is cluster-admin only, and it would
# disturb every other workload on the host. This touches exactly one pod.
EVICT_RC=0
EVICT_OUT=""
evict_pod() { # evict_pod <pod>
  local pod="$1"
  EVICT_OUT=""; EVICT_RC=0
  EVICT_OUT="$(printf '%s' \
    "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"${pod}\",\"namespace\":\"${NAMESPACE}\"}}" \
    | oc create --raw "/api/v1/namespaces/${NAMESPACE}/pods/${pod}/eviction" -f - 2>&1)" || EVICT_RC=$?
  return 0
}

# PodDisruptionBudgets whose selector matches a pod. KubeVirt creates one named
# kubevirt-disruption-budget-<vmi> for every migratable VMI; an ordinary
# Deployment pod has none unless someone wrote one.
pdbs_for_pod() { # pdbs_for_pod <pod>
  local pod="$1" labels
  labels="$(oc get pod "${pod}" -n "${NAMESPACE}" -o json 2>/dev/null | jq -c '.metadata.labels // {}')"
  oc get pdb -n "${NAMESPACE}" -o json 2>/dev/null | jq -r --argjson l "${labels}" '
    .items[]
    | select((.spec.selector.matchLabels // {}) | to_entries
             | all(. as $e | $l[$e.key] == $e.value))
    | "    \(.metadata.name)  minAvailable=\(.spec.minAvailable // "-")  maxUnavailable=\(.spec.maxUnavailable // "-")  allowedDisruptions=\(.status.disruptionsAllowed // "?")"'
}

echo "========================================="
echo "  VM Evictability Test"
echo "  Namespace: ${NAMESPACE}"
echo "  Modes:     $([ "${TEST_BOTH_MODES}" = "1" ] && echo "rwx (migratable) and rwo (pinned)" || echo "${DISK_MODE}")"
echo "========================================="

echo ""
echo "=== 0. Preflight ==="

for bin in oc jq; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "failed Required binary '${bin}' not found in PATH."; exit 1; }
done

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
  echo "failed Namespace ${NAMESPACE} not found."
  exit 1
}
echo "namespace ${NAMESPACE}: present"

# Checked up front rather than after a VM has been built. This one is in
# clusterrole/edit, so it should already be true.
if [ "$(oc auth can-i create pods/eviction -n "${NAMESPACE}" 2>/dev/null | tail -1)" != "yes" ]; then
  echo "failed Cannot create pods/eviction in ${NAMESPACE}, which is the whole test."
  echo "   This verb is part of clusterrole/edit, so its absence means the account"
  echo "   has something narrower than edit on this namespace."
  exit 1
fi
echo "permission to evict pods: granted"

for kind in vm dv; do
  if oc get "${kind}" "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 \
     || oc get "${kind}" "${DV_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "failed Leftover ${kind} from a previous run exists in ${NAMESPACE}. Remove it first:"
    echo "   oc delete vm ${VM_NAME} dv ${DV_NAME} -n ${NAMESPACE} --ignore-not-found"
    exit 1
  fi
done
oc get deployment "${CONTROL_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 && {
  echo "failed Leftover deployment ${CONTROL_NAME} exists. Remove it first:"
  echo "   oc delete deployment ${CONTROL_NAME} -n ${NAMESPACE}"
  exit 1
}
echo "no leftover objects from a previous run"

trap cleanup EXIT

# Provision the root disk, boot the VM, and return once it is Ready.
# Sets VM_NODE and LAUNCHER.
VM_NODE=""
LAUNCHER=""
build_vm() { # build_vm <access mode> <eviction strategy or empty>
  local access="$1" strategy="$2"

  echo ""
  echo "--- Provisioning a ${access} root disk ---"
  {
    echo "apiVersion: cdi.kubevirt.io/v1beta1"
    echo "kind: DataVolume"
    echo "metadata:"
    echo "  name: ${DV_NAME}"
    echo "  namespace: ${NAMESPACE}"
    echo "spec:"
    echo "  source:"
    echo "    registry:"
    echo "      url: ${IMAGE_URL}"
    # node pull reuses the kubelet's registry credentials and trust, so the
    # importer needs no pull secret of its own.
    echo "      pullMethod: node"
    echo "  storage:"
    [ -n "${STORAGE_CLASS}" ] && echo "    storageClassName: ${STORAGE_CLASS}"
    echo "    accessModes:"
    echo "    - ${access}"
    echo "    resources:"
    echo "      requests:"
    echo "        storage: ${DISK_SIZE}"
  } | oc apply -n "${NAMESPACE}" -f - >/dev/null

  # Same stall detector as test-vm-storage.sh: a broken import does not set
  # phase=Failed, it retry-loops, so the only signal is that nothing moves.
  local phase="" progress="" state last_state="" last_change deadline stalled=0
  last_change=$(date +%s)
  deadline=$(( last_change + DV_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    phase="$(oc get dv "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    case "${phase}" in Succeeded|Failed) break ;; esac
    progress="$(oc get dv "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.progress}' 2>/dev/null || echo "")"
    echo "  phase=${phase:-<none>} progress=${progress:-n/a}"
    state="${phase}/${progress}"
    if [ "${state}" != "${last_state}" ]; then
      last_state="${state}"; last_change=$(date +%s)
    elif [ $(( $(date +%s) - last_change )) -ge "${DV_STALL}" ]; then
      echo "  no progress for ${DV_STALL}s — treating as stalled"
      stalled=1; break
    fi
    sleep 5
  done

  if [ "${phase}" != "Succeeded" ]; then
    fail "Root disk provisioned (${access}: phase ${phase:-<none>}$([ "${stalled}" = "1" ] && echo ", stalled"))"
    oc describe pvc "${DV_NAME}" -n "${NAMESPACE}" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/  /' || true
    return 1
  fi
  pass "Root disk provisioned (${access})"

  local actual_modes
  actual_modes="$(oc get pvc "${DV_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || echo "")"
  echo "  PVC access modes: ${actual_modes}"
  if ! printf '%s' "${actual_modes}" | grep -qw "${access}"; then
    warn "asked for ${access} but got ${actual_modes}; the storage class substituted a mode and this run's conclusion may not match its label"
  fi

  echo ""
  echo "--- Booting the VM ---"
  {
    echo "apiVersion: kubevirt.io/v1"
    echo "kind: VirtualMachine"
    echo "metadata:"
    echo "  name: ${VM_NAME}"
    echo "  namespace: ${NAMESPACE}"
    echo "spec:"
    echo "  runStrategy: Always"
    echo "  template:"
    echo "    metadata:"
    echo "      labels:"
    echo "        kubevirt.io/vm: ${VM_NAME}"
    echo "    spec:"
    [ -n "${strategy}" ] && echo "      evictionStrategy: ${strategy}"
    echo "      domain:"
    echo "        cpu:"
    echo "          cores: 1"
    echo "        devices:"
    echo "          disks:"
    echo "          - disk:"
    echo "              bus: virtio"
    echo "            name: rootdisk"
    echo "          interfaces:"
    echo "          - name: default"
    echo "            masquerade: {}"
    echo "          rng: {}"
    echo "        resources:"
    echo "          requests:"
    echo "            memory: ${VM_MEMORY}"
    echo "      networks:"
    echo "      - name: default"
    echo "        pod: {}"
    echo "      volumes:"
    echo "      - name: rootdisk"
    echo "        persistentVolumeClaim:"
    echo "          claimName: ${DV_NAME}"
  } | oc apply -n "${NAMESPACE}" -f - >/dev/null

  local i
  for i in $(seq 1 30); do
    oc get vmi "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 && break
    sleep 2
  done
  if ! oc wait --for=condition=Ready "vmi/${VM_NAME}" -n "${NAMESPACE}" --timeout="${BOOT_TIMEOUT}" >/dev/null 2>&1; then
    fail "VM reached Ready (${access})"
    oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
    return 1
  fi
  pass "VM reached Ready (${access})"

  VM_NODE="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"
  LAUNCHER="$(launcher_pod)"
  echo "  node: ${VM_NODE:-unknown}, virt-launcher: ${LAUNCHER:-unknown}"
  return 0
}

# A container pod on the same node, with the same memory request, so the
# comparison is between two workloads competing for one pool rather than
# between a workload and an abstraction.
build_control() {
  echo ""
  echo "--- Starting the control container on ${VM_NODE} ---"
  cat <<EOF | oc apply -n "${NAMESPACE}" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CONTROL_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${CONTROL_NAME}
  template:
    metadata:
      labels:
        app: ${CONTROL_NAME}
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${VM_NODE}
      containers:
      - name: idle
        image: ${CONTROL_IMAGE}
        command: ["sleep", "infinity"]
        resources:
          requests:
            memory: ${VM_MEMORY}
            cpu: 10m
EOF
  if ! oc wait --for=condition=Ready pod -l "app=${CONTROL_NAME}" -n "${NAMESPACE}" --timeout=180s >/dev/null 2>&1; then
    fail "Control container reached Ready on ${VM_NODE}"
    oc get pods -l "app=${CONTROL_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
    return 1
  fi
  CONTROL_POD="$(oc get pods -n "${NAMESPACE}" -l "app=${CONTROL_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  pass "Control container is Ready on the same node as the VM"
  return 0
}

describe_pod() { # describe_pod <label> <pod>
  local label="$1" pod="$2" qos pc pcv reqs
  qos="$(oc get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.status.qosClass}' 2>/dev/null || echo "")"
  pc="$(oc get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.priorityClassName}' 2>/dev/null || echo "")"
  pcv="$(oc get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.priority}' 2>/dev/null || echo "")"
  reqs="$(oc get pod "${pod}" -n "${NAMESPACE}" -o json 2>/dev/null \
    | jq -r '[.spec.containers[].resources.requests.memory // "-"] | join("+")')"
  echo "  ${label}"
  echo "    pod:           ${pod}"
  echo "    QoS class:     ${qos:-unknown}"
  echo "    priorityClass: ${pc:-<none>} (${pcv:-0})"
  echo "    mem requests:  ${reqs}"
  echo "    matching PDBs:"
  local p; p="$(pdbs_for_pod "${pod}")"
  if [ -n "${p}" ]; then echo "${p}"; else echo "      (none)"; fi
}

run_mode() { # run_mode <rwx|rwo>
  local mode="$1" access strategy label
  if [ "${mode}" = "rwx" ]; then
    access="ReadWriteMany"; strategy="LiveMigrate"; label="migratable"
  else
    # No evictionStrategy at all. This is the default a user gets who never
    # thought about it, and on RWO storage it is the only honest setting:
    # LiveMigrate on a disk that cannot be shared just makes eviction hang.
    access="ReadWriteOnce"; strategy=""; label="pinned"
  fi

  echo ""
  echo "========================================="
  echo "  Mode: ${mode} (${label})"
  echo "========================================="

  build_vm "${access}" "${strategy}" || { SUMMARY+=("${mode}	setup-failed	VM did not come up"); return 1; }
  build_control || { SUMMARY+=("${mode}	setup-failed	control pod did not come up"); return 1; }

  echo ""
  echo "=== Eviction-ordering inputs ==="
  describe_pod "VM (virt-launcher)" "${LAUNCHER}"
  describe_pod "Control container" "${CONTROL_POD}"

  local vm_pdbs control_pdbs
  vm_pdbs="$(pdbs_for_pod "${LAUNCHER}")"
  control_pdbs="$(pdbs_for_pod "${CONTROL_POD}")"
  if [ "${mode}" = "rwx" ]; then
    if [ -n "${vm_pdbs}" ] && [ -z "${control_pdbs}" ]; then
      pass "${mode}: a PDB protects the VM and none protects the container"
    else
      fail "${mode}: a PDB protects the VM and none protects the container"
      warn "without a PDB the VM has no disruption protection beyond its eviction strategy"
    fi
  fi

  # The memory requests have to match or the comparison proves nothing. Note
  # this is the control pod against the VM's *guest* size, not against the
  # virt-launcher pod's total, which is larger — see test-vm-memory-overhead.sh.
  local control_req
  control_req="$(oc get pod "${CONTROL_POD}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[0].resources.requests.memory}')"
  if [ "${control_req}" = "${VM_MEMORY}" ]; then
    pass "${mode}: both workloads request ${VM_MEMORY} of guest/container memory"
  else
    fail "${mode}: both workloads request the same memory (control got ${control_req})"
  fi

  echo ""
  echo "=== Evicting the control container ==="
  local uid_before
  uid_before="$(oc get pod "${CONTROL_POD}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  evict_pod "${CONTROL_POD}"
  echo "  API response (rc=${EVICT_RC}): ${EVICT_OUT:-<empty>}"

  if [ "${EVICT_RC}" -eq 0 ]; then
    pass "${mode}: the control container's eviction is accepted"
  else
    fail "${mode}: the control container's eviction is accepted"
  fi

  local deadline gone=0
  deadline=$(( $(date +%s) + EVICTION_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if ! oc get pod "${CONTROL_POD}" -n "${NAMESPACE}" >/dev/null 2>&1; then gone=1; break; fi
    sleep 3
  done
  if [ "${gone}" = "1" ]; then
    pass "${mode}: the control container terminated — its memory was reclaimable"
  else
    fail "${mode}: the control container terminated within ${EVICTION_TIMEOUT}s"
  fi

  # Rescheduling is the second half of "reclaimable": the memory came back to
  # the cluster, not just to this node.
  if oc wait --for=condition=Available "deployment/${CONTROL_NAME}" -n "${NAMESPACE}" --timeout=180s >/dev/null 2>&1; then
    pass "${mode}: the Deployment replaced the evicted container"
  else
    fail "${mode}: the Deployment replaced the evicted container"
  fi

  echo ""
  echo "=== Evicting the VM ==="

  # Captured before, because every branch below is distinguished by whether
  # these survived. boot_id is read from the VMI's own object rather than over
  # SSH so this test needs no guest credentials; the VMI UID plus the launcher
  # pod identity is enough to tell migration from a reboot.
  local vmi_uid_before launcher_before node_before
  vmi_uid_before="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  launcher_before="${LAUNCHER}"
  node_before="${VM_NODE}"

  evict_pod "${LAUNCHER}"
  echo "  API response (rc=${EVICT_RC}): ${EVICT_OUT:-<empty>}"

  # Three outcomes, all informative, so the script branches rather than
  # assuming one. Which one happens is the result.
  if [ "${EVICT_RC}" -ne 0 ] && printf '%s' "${EVICT_OUT}" | grep -qiE 'too many requests|disruption budget|429'; then
    echo "  outcome: REFUSED by a PodDisruptionBudget"
    pass "${mode}: the VM does not simply yield its memory on request"
    SUMMARY+=("${mode}	refused	PDB rejected the eviction (429)")
    if [ "${mode}" = "rwx" ]; then
      pass "${mode}: the migratable VM survived the eviction attempt"
    fi
  else
    echo "  outcome: eviction accepted, watching what happened to the guest"
    sleep 10
    local vmi_uid_after launcher_after node_after vmi_present=1
    oc get vmi "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || vmi_present=0

    # Give a migration time to land before concluding anything.
    local d; d=$(( $(date +%s) + EVICTION_TIMEOUT ))
    while [ "$(date +%s)" -lt "${d}" ]; do
      launcher_after="$(launcher_pod)"
      [ -n "${launcher_after}" ] && [ "${launcher_after}" != "${launcher_before}" ] && break
      sleep 5
    done
    launcher_after="$(launcher_pod)"
    vmi_uid_after="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
    node_after="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"

    echo "    VMI uid:  ${vmi_uid_before:-<none>} -> ${vmi_uid_after:-<none>}"
    echo "    node:     ${node_before:-<none>} -> ${node_after:-<none>}"
    echo "    launcher: ${launcher_before:-<none>} -> ${launcher_after:-<none>}"

    if [ -n "${vmi_uid_after}" ] && [ "${vmi_uid_before}" = "${vmi_uid_after}" ]; then
      # Same VMI object means the guest was never destroyed. The memory moved
      # to another node rather than being released, which is the point: nothing
      # was reclaimed, the cost was relocated.
      echo "  outcome: LIVE MIGRATED — same VMI, guest never stopped"
      pass "${mode}: the VM survived the eviction by moving rather than yielding"
      local mig_mode mig_time
      mig_mode="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState.mode}' 2>/dev/null || echo "")"
      mig_time="$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.migrationState.endTimestamp}' 2>/dev/null || echo "")"
      echo "    migration mode: ${mig_mode:-unreported}, ended: ${mig_time:-unreported}"
      SUMMARY+=("${mode}	migrated	guest moved ${node_before} -> ${node_after}, memory relocated not released")
    elif [ "${vmi_present}" = "0" ] || [ "${vmi_uid_before}" != "${vmi_uid_after}" ]; then
      echo "  outcome: GUEST KILLED — the VMI was destroyed and recreated"
      if [ "${mode}" = "rwo" ]; then
        pass "${mode}: a pinned VM cannot move, so eviction costs the guest"
      else
        fail "${mode}: a migratable VM should not be destroyed by an eviction"
      fi
      SUMMARY+=("${mode}	killed	VMI destroyed; anything in guest RAM was lost")
    else
      echo "  outcome: unchanged — the eviction was accepted but nothing happened"
      warn "${mode}: accepted eviction with no observable effect within ${EVICTION_TIMEOUT}s"
      SUMMARY+=("${mode}	no-op	accepted but the guest did not move or restart")
    fi
  fi

  echo ""
  echo "=== Node-level reclaimability on ${node_before} ==="
  # The number this whole test exists to produce: the share of a node's
  # requested memory that eviction cannot free.
  if [ "$(oc auth can-i get nodes 2>/dev/null | tail -1)" = "yes" ] && [ -n "${node_before}" ]; then
    oc get pods -A --field-selector "spec.nodeName=${node_before}" -o json 2>/dev/null | jq -r '
      [ .items[]
        | { owner: (if .metadata.labels["kubevirt.io"] == "virt-launcher" then "not-reclaimable (VM)" else "reclaimable (container)" end),
            bytes: ([ .spec.containers[].resources.requests.memory // "0" ] | map(
                if test("Ki$") then (rtrimstr("Ki")|tonumber)*1024
                elif test("Mi$") then (rtrimstr("Mi")|tonumber)*1048576
                elif test("Gi$") then (rtrimstr("Gi")|tonumber)*1073741824
                elif test("^[0-9]+$") then tonumber
                else 0 end) | add) } ]
      | group_by(.owner) | .[]
      | "    \(.[0].owner)  pods=\(length)  requested=\((map(.bytes)|add) / 1073741824 * 100 | round / 100)Gi"' \
      || warn "could not compute the node split"
  else
    warn "node-level split skipped (nodes unreadable)"
  fi

  echo ""
  echo "--- Tearing down mode ${mode} ---"
  oc delete deployment "${CONTROL_NAME}" -n "${NAMESPACE}" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
  oc delete vm "${VM_NAME}" -n "${NAMESPACE}" --ignore-not-found --timeout=180s >/dev/null 2>&1 || true
  oc delete dv "${DV_NAME}" -n "${NAMESPACE}" --ignore-not-found --timeout=180s >/dev/null 2>&1 || true
  return 0
}

if [ "${TEST_BOTH_MODES}" = "1" ]; then
  run_mode rwx || true
  run_mode rwo || true
else
  run_mode "${DISK_MODE}" || true
fi

echo ""
echo "=== Summary ==="
printf '  %-6s %-14s %s\n' "MODE" "OUTCOME" "DETAIL"
for row in "${SUMMARY[@]:-}"; do
  [ -z "${row}" ] && continue
  IFS=$'\t' read -r s_mode s_outcome s_detail <<< "${row}"
  printf '  %-6s %-14s %s\n' "${s_mode}" "${s_outcome}" "${s_detail}"
done

# The contrast is the finding. Identical outcomes in both modes would mean
# storage access mode does not actually determine a VM's behaviour under
# disruption, which would be worth knowing and is not what is expected.
if [ "${TEST_BOTH_MODES}" = "1" ] && [ "${#SUMMARY[@]}" -ge 2 ]; then
  OUT_RWX="$(printf '%s\n' "${SUMMARY[@]}" | awk -F'\t' '$1=="rwx"{print $2}' | head -1)"
  OUT_RWO="$(printf '%s\n' "${SUMMARY[@]}" | awk -F'\t' '$1=="rwo"{print $2}' | head -1)"
  if [ -n "${OUT_RWX}" ] && [ -n "${OUT_RWO}" ] && [ "${OUT_RWX}" != "${OUT_RWO}" ]; then
    pass "The pinned VM's eviction outcome differs from the migratable one (${OUT_RWO} vs ${OUT_RWX})"
  else
    fail "The pinned VM's eviction outcome differs from the migratable one (both: ${OUT_RWX:-?})"
  fi
fi

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "  VERIFICATION SUCCESS: a container yields its memory on request and is"
  echo "   rescheduled; a VM either refuses or relocates, so its share of a node"
  echo "   is not reclaimable the way a container's is."
else
  echo "failed VERIFICATION FAILED: see the failed lines above."
  echo ""
  echo "Re-run with KEEP_VM=1 to leave the VM and control pod in place."
  exit 1
fi
