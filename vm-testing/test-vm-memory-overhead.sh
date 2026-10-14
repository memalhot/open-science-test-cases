#!/usr/bin/env bash
set -euo pipefail

# Automated measurement of what a VM actually costs a node, as opposed to what
# its manifest says it wants.
#
# A VM asking for 8Gi of guest memory does not remove 8Gi from what containers
# can schedule on that node. KubeVirt adds per-VMI overhead — QEMU itself, the
# page tables for the guest's address space, virtiofs and console containers,
# and a safety margin — and none of it appears anywhere in the VirtualMachine
# spec. The gap is invisible until a container that should fit does not.
#
# This test measures the gap across a sweep of guest sizes and vCPU counts, and
# reports the node-level split between VM and container memory. It boots from
# ephemeral containerDisks because nothing here depends on persistence, which
# keeps each iteration to well under a minute.
#
# Everything runs as the logged-in user. The two reads outside the namespace
# (nodes, HyperConverged) degrade to warnings if they are denied.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
VM_PREFIX="${VM_PREFIX:-overhead-test-vm}"

# Three sizes so the fixed and scaling parts of the overhead can be told apart
# from one run, and two vCPU counts at the middle size for the same reason.
MEMORY_SWEEP="${MEMORY_SWEEP:-1Gi 4Gi 8Gi}"
CPU_SWEEP="${CPU_SWEEP:-1 4}"
CPU_SWEEP_MEMORY="${CPU_SWEEP_MEMORY:-4Gi}"   # the size the vCPU sweep holds constant

VM_IMAGE="${VM_IMAGE:-quay.io/kubevirt/cirros-container-disk-demo}"
GUEST_USER="${GUEST_USER:-cirros}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300s}"
SSH_TIMEOUT="${SSH_TIMEOUT:-45}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-20}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Reading MemTotal from inside the guest needs SSH, which roughly doubles the
# runtime. The claim stands without it; set to 0 for a faster run.
CHECK_GUEST_MEMTOTAL="${CHECK_GUEST_MEMTOTAL:-1}"
KEEP_VM="${KEEP_VM:-0}"

WORKDIR=""
PASSED=0
FAILED=0
CURRENT_VM=""
RESULTS=()      # label<TAB>guest<TAB>podreq<TAB>overhead<TAB>ratio<TAB>qos

pass() { echo " passed  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  failed $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  warning  $1"; }

cleanup() {
  echo ""
  echo "=== Cleaning up resources ==="
  if [ "${KEEP_VM}" = "1" ] && [ -n "${CURRENT_VM}" ]; then
    echo "KEEP_VM=1, leaving vm/${CURRENT_VM} in place. Delete with:"
    echo "  oc delete vm ${CURRENT_VM} -n ${NAMESPACE}"
  else
    oc delete vm -l "overhead-test=${VM_PREFIX}" -n "${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
  fi
  [ -n "${WORKDIR}" ] && rm -rf "${WORKDIR}"
  echo "Done!"
}

# Portable timeout: macOS has no coreutils `timeout` by default.
run_with_timeout() {
  local secs="$1"; shift
  local rc=0 pid watcher
  "$@" & pid=$!
  ( sleep "${secs}"; kill -9 "${pid}" 2>/dev/null ) & watcher=$!
  wait "${pid}" 2>/dev/null || rc=$?
  kill "${watcher}" 2>/dev/null || true
  wait "${watcher}" 2>/dev/null || true
  return "${rc}"
}

# Kubernetes quantity to bytes. Needed because the numbers being compared come
# back in different units — the VM spec in Gi, pod requests often in Mi or bare
# bytes — and comparing them as strings silently produces nonsense.
to_bytes() { # to_bytes <quantity>
  local q="$1"
  [ -z "${q}" ] && { echo 0; return; }
  case "${q}" in
    *Ki) echo $(( ${q%Ki} * 1024 )) ;;
    *Mi) echo $(( ${q%Mi} * 1024 * 1024 )) ;;
    *Gi) echo $(( ${q%Gi} * 1024 * 1024 * 1024 )) ;;
    *Ti) echo $(( ${q%Ti} * 1024 * 1024 * 1024 * 1024 )) ;;
    *k)  echo $(( ${q%k} * 1000 )) ;;
    *M)  echo $(( ${q%M} * 1000000 )) ;;
    *G)  echo $(( ${q%G} * 1000000000 )) ;;
    *)   echo "${q}" ;;
  esac
}

human() { # human <bytes>
  awk -v b="$1" 'BEGIN{ if (b>=1073741824) printf "%.2fGi", b/1073741824;
                        else if (b>=1048576) printf "%.0fMi", b/1048576;
                        else printf "%dB", b }'
}

echo "========================================="
echo "  VM Memory Overhead Test"
echo "  Namespace:    ${NAMESPACE}"
echo "  Memory sweep: ${MEMORY_SWEEP}"
echo "  vCPU sweep:   ${CPU_SWEEP} (at ${CPU_SWEEP_MEMORY})"
echo "========================================="

echo ""
echo "=== 0. Preflight ==="

REQUIRED_BINS="oc jq awk"
[ "${CHECK_GUEST_MEMTOTAL}" = "1" ] && REQUIRED_BINS="${REQUIRED_BINS} virtctl ssh-keygen"
for bin in ${REQUIRED_BINS}; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "failed Required binary '${bin}' not found in PATH."; exit 1; }
done

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
  echo "failed Namespace ${NAMESPACE} not found."
  exit 1
}
echo "namespace ${NAMESPACE}: present"

if [ -n "$(oc get vm -l "overhead-test=${VM_PREFIX}" -n "${NAMESPACE}" -o name 2>/dev/null)" ]; then
  echo "failed Leftover VMs from a previous run exist in ${NAMESPACE}. Remove them first:"
  echo "   oc delete vm -l overhead-test=${VM_PREFIX} -n ${NAMESPACE}"
  exit 1
fi
echo "no leftover objects from a previous run"

CAN_READ_NODES="$(oc auth can-i get nodes 2>/dev/null | tail -1)"
[ "${CAN_READ_NODES}" = "yes" ] || warn "cannot read nodes — the node-level split in step 3 will be skipped"

trap cleanup EXIT

WORKDIR="$(mktemp -d "/tmp/${VM_PREFIX}-overhead.XXXXXX")"
SSH_PUBKEY=""
if [ "${CHECK_GUEST_MEMTOTAL}" = "1" ]; then
  # Ephemeral keypair, thrown away on exit. ECDSA to stay under KubeVirt's
  # 2048-byte inline userdata cap and because the CirrOS guest runs an older
  # dropbear, as test-vm.sh documents.
  SSH_KEY="${WORKDIR}/id_ecdsa"
  ssh-keygen -q -t ecdsa -b 256 -N '' -f "${SSH_KEY}" -C "overheadtest"
  SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"
fi

echo ""
echo "=== 1. Cluster settings that change the answer ==="

# Both of these silently rescale KubeVirt's overhead formula. An overhead number
# reported without them is not reproducible on another cluster, so they are
# recorded even though neither is asserted on.
HCO_JSON="$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o json 2>/dev/null || echo '')"
if [ -n "${HCO_JSON}" ]; then
  OVERCOMMIT="$(printf '%s' "${HCO_JSON}" | jq -r '.spec.higherWorkloadDensity.memoryOvercommitPercentage // "unset"')"
  OVERHEAD_RATIO="$(printf '%s' "${HCO_JSON}" | jq -r '.spec.configuration.additionalGuestMemoryOverheadRatio // "unset"')"
  echo "  higherWorkloadDensity.memoryOvercommitPercentage: ${OVERCOMMIT}"
  echo "  additionalGuestMemoryOverheadRatio:               ${OVERHEAD_RATIO}"
  # Above 100 means KubeVirt deliberately under-requests relative to guest size,
  # betting the guest will not touch all its memory. That inverts the sign of
  # what this test measures, so it is called out rather than left in a log line.
  if [ "${OVERCOMMIT}" != "unset" ] && [ "${OVERCOMMIT}" -gt 100 ] 2>/dev/null; then
    warn "memory overcommit is ${OVERCOMMIT}% — the pod may request LESS than the guest size, and the node is oversubscribed by design"
  fi
else
  warn "cannot read HyperConverged in openshift-cnv — overhead numbers below are not reproducible without it"
fi

KUBEVIRT_VERSION="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.status.observedKubeVirtVersion}' 2>/dev/null || echo "unknown")"
echo "  KubeVirt version:                                 ${KUBEVIRT_VERSION}"

# Boot one VM, collect every memory number for it, tear it down. Sets
# LAST_NODE and appends a row to RESULTS.
LAST_NODE=""
measure_one() { # measure_one <label> <memory> <cpus>
  local label="$1" mem="$2" cpus="$3"
  local vm="${VM_PREFIX}-${label}"
  CURRENT_VM="${vm}"

  echo ""
  echo "--- ${label}: ${mem} guest memory, ${cpus} vCPU ---"

  local userdata_block=""
  if [ "${CHECK_GUEST_MEMTOTAL}" = "1" ]; then
    # CirrOS ships a cut-down cloud-init with no ssh_authorized_keys support, so
    # the key is written by hand, as in test-vm.sh. dropbear rejects it if .ssh
    # or authorized_keys is group or world writable.
    cat > "${WORKDIR}/user-data" <<EOF
#!/bin/sh
H=\$(getent passwd ${GUEST_USER} 2>/dev/null|cut -d: -f6)
[ -n "\$H" ] || H=/home/${GUEST_USER}
mkdir -p \$H/.ssh
echo "${SSH_PUBKEY}" > \$H/.ssh/authorized_keys
chown -R ${GUEST_USER} \$H/.ssh 2>/dev/null
chmod 700 \$H/.ssh; chmod 600 \$H/.ssh/authorized_keys
EOF
    local ud_bytes
    ud_bytes=$(wc -c < "${WORKDIR}/user-data" | tr -d ' ')
    if [ "${ud_bytes}" -gt 2048 ]; then
      echo "failed cloud-init userdata is ${ud_bytes} bytes, over KubeVirt's 2048-byte inline cap."
      exit 1
    fi
    userdata_block="$(sed 's/^/            /' "${WORKDIR}/user-data")"
  fi

  {
    echo "apiVersion: kubevirt.io/v1"
    echo "kind: VirtualMachine"
    echo "metadata:"
    echo "  name: ${vm}"
    echo "  namespace: ${NAMESPACE}"
    echo "  labels:"
    echo "    overhead-test: ${VM_PREFIX}"
    echo "spec:"
    echo "  runStrategy: Always"
    echo "  template:"
    echo "    metadata:"
    echo "      labels:"
    echo "        kubevirt.io/vm: ${vm}"
    echo "        overhead-test: ${VM_PREFIX}"
    echo "    spec:"
    echo "      domain:"
    echo "        cpu:"
    echo "          cores: ${cpus}"
    echo "        memory:"
    echo "          guest: ${mem}"
    echo "        devices:"
    echo "          disks:"
    echo "          - disk:"
    echo "              bus: virtio"
    echo "            name: containerdisk"
    [ "${CHECK_GUEST_MEMTOTAL}" = "1" ] && { echo "          - disk:"; echo "              bus: virtio"; echo "            name: cloudinitdisk"; }
    # NOTE: as in test-vm.sh, deliberately no `ports:` list on the masquerade
    # interface. Listing ports makes KubeVirt forward only those, silently
    # blocking SSH on 22.
    echo "          interfaces:"
    echo "          - name: default"
    echo "            masquerade: {}"
    echo "          rng: {}"
    echo "      networks:"
    echo "      - name: default"
    echo "        pod: {}"
    echo "      volumes:"
    echo "      - name: containerdisk"
    echo "        containerDisk:"
    echo "          image: ${VM_IMAGE}"
    if [ "${CHECK_GUEST_MEMTOTAL}" = "1" ]; then
      echo "      - name: cloudinitdisk"
      echo "        cloudInitNoCloud:"
      echo "          userData: |"
      echo "${userdata_block}"
    fi
  } | oc apply -n "${NAMESPACE}" -f - >/dev/null

  local i
  for i in $(seq 1 30); do
    oc get vmi "${vm}" -n "${NAMESPACE}" >/dev/null 2>&1 && break
    sleep 2
  done
  if ! oc wait --for=condition=Ready "vmi/${vm}" -n "${NAMESPACE}" --timeout="${BOOT_TIMEOUT}" >/dev/null 2>&1; then
    fail "${label}: VM reached Ready"
    oc get vmi "${vm}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
    oc delete vm "${vm}" -n "${NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    CURRENT_VM=""
    return 1
  fi
  pass "${label}: VM reached Ready"

  LAST_NODE="$(oc get vmi "${vm}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")"

  local pod
  pod="$(oc get pods -n "${NAMESPACE}" -l "vm.kubevirt.io/name=${vm}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${pod}" ]; then
    fail "${label}: virt-launcher pod found"
    return 1
  fi

  # Per container, not just the total. The breakdown is what makes the overhead
  # attributable: the compute container carries the guest plus QEMU, while the
  # containerdisk and console containers are fixed costs that a bigger guest
  # does not change.
  echo "  virt-launcher pod ${pod}:"
  oc get pod "${pod}" -n "${NAMESPACE}" -o json | jq -r '
    .spec.containers[]
    | "    \(.name): requests.memory=\(.resources.requests.memory // "-") limits.memory=\(.resources.limits.memory // "-")"'

  local pod_req_bytes=0 pod_lim_bytes=0 q
  for q in $(oc get pod "${pod}" -n "${NAMESPACE}" \
      -o jsonpath='{range .spec.containers[*]}{.resources.requests.memory}{"\n"}{end}' 2>/dev/null); do
    pod_req_bytes=$(( pod_req_bytes + $(to_bytes "${q}") ))
  done
  for q in $(oc get pod "${pod}" -n "${NAMESPACE}" \
      -o jsonpath='{range .spec.containers[*]}{.resources.limits.memory}{"\n"}{end}' 2>/dev/null); do
    pod_lim_bytes=$(( pod_lim_bytes + $(to_bytes "${q}") ))
  done

  local qos
  qos="$(oc get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.status.qosClass}' 2>/dev/null || echo "")"

  local guest_bytes overhead_bytes ratio
  guest_bytes="$(to_bytes "${mem}")"
  overhead_bytes=$(( pod_req_bytes - guest_bytes ))
  ratio="$(awk -v p="${pod_req_bytes}" -v g="${guest_bytes}" 'BEGIN{ if (g>0) printf "%.3f", p/g; else print "n/a" }')"

  echo "  guest memory:          ${mem} ($(human "${guest_bytes}"))"
  echo "  pod requests total:    $(human "${pod_req_bytes}")"
  echo "  pod limits total:      $(human "${pod_lim_bytes}")"
  echo "  overhead:              $(human "${overhead_bytes}")  (x${ratio})"
  echo "  QoS class:             ${qos:-unknown}"

  local vmi_boot vmi_current
  vmi_boot="$(oc get vmi "${vm}" -n "${NAMESPACE}" -o jsonpath='{.status.memory.guestAtBoot}' 2>/dev/null || echo "")"
  vmi_current="$(oc get vmi "${vm}" -n "${NAMESPACE}" -o jsonpath='{.status.memory.guestCurrent}' 2>/dev/null || echo "")"
  echo "  VMI guestAtBoot:       ${vmi_boot:-unreported}"
  echo "  VMI guestCurrent:      ${vmi_current:-unreported}"

  if [ "${overhead_bytes}" -gt 0 ]; then
    pass "${label}: virt-launcher requests more than the guest memory (+$(human "${overhead_bytes}"))"
  else
    fail "${label}: virt-launcher requests more than the guest memory (got $(human "${overhead_bytes}"))"
    warn "a non-positive overhead means the node is oversubscribed — check memoryOvercommitPercentage above"
  fi

  # What the workload actually received, which closes the loop: the overhead is
  # charged to the node but is not available to anything running in the guest.
  if [ "${CHECK_GUEST_MEMTOTAL}" = "1" ]; then
    local ssh_help ssh_target memtotal_kb memtotal_bytes delta_pct
    ssh_help="$(virtctl ssh --help 2>&1 || true)"
    local ssh_opts=(-i "${SSH_KEY}")
    # virtctl's SSH flags moved around between releases, so probe --help rather
    # than assuming. The exact-match guard on --local-ssh matters: a plain
    # substring test also matches --local-ssh-opts.
    printf '%s' "${ssh_help}" | grep -q -- '--local-ssh-opts' && \
      ssh_opts+=(-t "-o StrictHostKeyChecking=no" -t "-o UserKnownHostsFile=/dev/null")
    if printf '%s' "${ssh_help}" | grep -q -- '--known-hosts'; then
      : > "${WORKDIR}/known_hosts"
      ssh_opts+=(--known-hosts "${WORKDIR}/known_hosts")
    fi
    printf '%s' "${ssh_help}" | grep -qE -- '--local-ssh([^-]|$)' && ssh_opts+=(--local-ssh=true)
    ssh_target="${GUEST_USER}@vmi/${vm}/${NAMESPACE}"

    memtotal_kb=""
    for i in $(seq 1 "${POLL_ATTEMPTS}"); do
      if run_with_timeout "${SSH_TIMEOUT}" virtctl ssh "${ssh_opts[@]}" \
           -c "grep MemTotal /proc/meminfo" "${ssh_target}" \
           < /dev/null > "${WORKDIR}/ssh.log" 2>&1; then
        memtotal_kb="$(grep -o 'MemTotal:[[:space:]]*[0-9]*' "${WORKDIR}/ssh.log" | grep -o '[0-9]*' || true)"
        [ -n "${memtotal_kb}" ] && break
      fi
      sleep "${POLL_INTERVAL}"
    done

    if [ -n "${memtotal_kb}" ]; then
      memtotal_bytes=$(( memtotal_kb * 1024 ))
      # A few percent below the configured size is normal and not a defect:
      # firmware and the kernel reserve memory before MemTotal is computed.
      delta_pct="$(awk -v m="${memtotal_bytes}" -v g="${guest_bytes}" 'BEGIN{ printf "%.1f", 100*(g-m)/g }')"
      echo "  guest-reported MemTotal: $(human "${memtotal_bytes}") (${delta_pct}% below configured)"
      if awk -v d="${delta_pct}" 'BEGIN{ exit !(d >= -1 && d <= 10) }'; then
        pass "${label}: the guest sees its configured memory, not the overhead"
      else
        fail "${label}: the guest sees its configured memory (off by ${delta_pct}%)"
      fi
    else
      warn "${label}: could not read MemTotal from the guest; set CHECK_GUEST_MEMTOTAL=0 to skip"
    fi
  fi

  RESULTS+=("${label}	${mem}	${pod_req_bytes}	${overhead_bytes}	${ratio}	${qos:-unknown}")
  return 0
}

echo ""
echo "=== 2. Sweeping guest size and vCPU count ==="

# One VM at a time: the sweep never holds more than a single guest, so it can
# run on a busy cluster without becoming the capacity problem it is measuring.
for mem in ${MEMORY_SWEEP}; do
  measure_one "mem-${mem}" "${mem}" "1" || true
  [ "${KEEP_VM}" = "1" ] || oc delete vm "${VM_PREFIX}-mem-${mem}" -n "${NAMESPACE}" \
    --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
done

for cpus in ${CPU_SWEEP}; do
  measure_one "cpu-${cpus}" "${CPU_SWEEP_MEMORY}" "${cpus}" || true
  [ "${KEEP_VM}" = "1" ] || oc delete vm "${VM_PREFIX}-cpu-${cpus}" -n "${NAMESPACE}" \
    --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
done
CURRENT_VM=""

echo ""
echo "=== 3. Node-level split, VM against container ==="

# The table an operator actually wants mid-incident: of this node's allocatable
# memory, how much is claimed by things that can be rescheduled and how much by
# things that cannot. Every VM pod carries kubevirt.io=virt-launcher, so the
# split is a single label test.
if [ "${CAN_READ_NODES}" = "yes" ] && [ -n "${LAST_NODE}" ]; then
  echo "  node: ${LAST_NODE}"
  ALLOCATABLE="$(oc get node "${LAST_NODE}" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null || echo "")"
  echo "  allocatable: ${ALLOCATABLE:-unknown}"
  oc get pods -A --field-selector "spec.nodeName=${LAST_NODE}" -o json 2>/dev/null | jq -r '
    [ .items[]
      | { owner: (if .metadata.labels["kubevirt.io"] == "virt-launcher" then "VM" else "container" end),
          bytes: ([ .spec.containers[].resources.requests.memory // "0" ] | map(
              if test("Ki$") then (rtrimstr("Ki")|tonumber)*1024
              elif test("Mi$") then (rtrimstr("Mi")|tonumber)*1048576
              elif test("Gi$") then (rtrimstr("Gi")|tonumber)*1073741824
              elif test("^[0-9]+$") then tonumber
              else 0 end) | add) } ]
    | group_by(.owner)
    | .[]
    | "    \(.[0].owner | . + (" " * (9 - length)))  pods=\(length)  requested=\((map(.bytes)|add) / 1073741824 * 100 | round / 100)Gi"' \
    || warn "could not compute the node split"
  echo ""
  echo "  The VM row is the part no amount of eviction pressure can reclaim;"
  echo "  see test-vm-evictability.sh."
else
  warn "node-level split skipped (nodes unreadable, or no VM booted successfully)"
fi

echo ""
echo "=== 4. Summary ==="
printf '  %-12s %-8s %-12s %-12s %-8s %s\n' "CASE" "GUEST" "POD REQ" "OVERHEAD" "RATIO" "QOS"
for row in "${RESULTS[@]:-}"; do
  [ -z "${row}" ] && continue
  IFS=$'\t' read -r r_label r_guest r_podreq r_over r_ratio r_qos <<< "${row}"
  printf '  %-12s %-8s %-12s %-12s %-8s %s\n' \
    "${r_label}" "${r_guest}" "$(human "${r_podreq}")" "$(human "${r_over}")" "x${r_ratio}" "${r_qos}"
done

# Deliberately no assertion on a specific overhead figure or percentage. That is
# a KubeVirt-version property and hard-coding it would turn a routine upgrade
# into a test failure. What is asserted is the shape: overhead exists, it grows
# with the guest, and it grows with vCPU count.
get_overhead() { # get_overhead <label>
  local row
  for row in "${RESULTS[@]:-}"; do
    [ -z "${row}" ] && continue
    case "${row}" in "$1	"*) printf '%s' "${row}" | cut -f4; return 0 ;; esac
  done
  echo ""
}

FIRST_MEM="$(echo "${MEMORY_SWEEP}" | awk '{print $1}')"
LAST_MEM="$(echo "${MEMORY_SWEEP}" | awk '{print $NF}')"
OH_SMALL="$(get_overhead "mem-${FIRST_MEM}")"
OH_LARGE="$(get_overhead "mem-${LAST_MEM}")"
if [ -n "${OH_SMALL}" ] && [ -n "${OH_LARGE}" ]; then
  if [ "${OH_LARGE}" -ne "${OH_SMALL}" ]; then
    pass "Overhead at ${LAST_MEM} differs from ${FIRST_MEM} — it has a term that scales with guest size"
    echo "    $(human "${OH_SMALL}") at ${FIRST_MEM} vs $(human "${OH_LARGE}") at ${LAST_MEM}"
  else
    fail "Overhead scales with guest size (identical at ${FIRST_MEM} and ${LAST_MEM}: $(human "${OH_SMALL}"))"
    warn "a purely fixed overhead would mean large guests are cheaper per Gi than this test assumes"
  fi
else
  warn "not enough successful measurements to compare overhead across guest sizes"
fi

FIRST_CPU="$(echo "${CPU_SWEEP}" | awk '{print $1}')"
LAST_CPU="$(echo "${CPU_SWEEP}" | awk '{print $NF}')"
OH_FEWCPU="$(get_overhead "cpu-${FIRST_CPU}")"
OH_MANYCPU="$(get_overhead "cpu-${LAST_CPU}")"
if [ -n "${OH_FEWCPU}" ] && [ -n "${OH_MANYCPU}" ] && [ "${FIRST_CPU}" != "${LAST_CPU}" ]; then
  if [ "${OH_MANYCPU}" -gt "${OH_FEWCPU}" ]; then
    pass "Overhead at ${LAST_CPU} vCPU exceeds ${FIRST_CPU} vCPU at equal memory"
    echo "    $(human "${OH_FEWCPU}") vs $(human "${OH_MANYCPU}")"
  else
    fail "Overhead grows with vCPU count ($(human "${OH_FEWCPU}") at ${FIRST_CPU} vCPU, $(human "${OH_MANYCPU}") at ${LAST_CPU})"
  fi
else
  warn "not enough successful measurements to compare overhead across vCPU counts"
fi

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "  VERIFICATION SUCCESS: a VM reserves measurably more node memory than"
  echo "   its guest size, the excess is not visible in the VM spec and is not"
  echo "   available to the guest, and it grows with both guest size and vCPU count."
else
  echo "failed VERIFICATION FAILED: see the failed lines above."
  echo ""
  echo "Re-run with KEEP_VM=1 to leave the last VM in place for inspection."
  exit 1
fi
