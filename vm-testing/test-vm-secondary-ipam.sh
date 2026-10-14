#!/usr/bin/env bash
set -euo pipefail

# Automated proof of how VMs and containers share — and exhaust — a secondary
# network's address pool, and of how little an ordinary user can see while it
# happens.
#
# The pod network is not the pool that runs out. With the default hostPrefix of
# /23 a node has 510 pod addresses against a max-pods of 250, so the kubelet
# refuses to schedule long before IPAM refuses to allocate. A secondary network
# is hand-sized by definition, is shared between VMs and containers, and has no
# per-node headroom at all — which makes it the realistic exhaustion case and a
# cheap one to produce.
#
# Everything here runs as the logged-in user except the IPPool reads in step 6,
# which are the documented admin exception; see ADMIN_IPPOOL_READ below.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
NAD_NAME="${NAD_NAME:-ipam-test-net}"
VM_PREFIX="${VM_PREFIX:-ipam-claimant}"
CONTROL_POD="${CONTROL_POD:-ipam-claimant-container}"

# whereabouts on a real node bridge is what this cluster actually runs
# (portworx/storage-network), so it is the default. ovn needs no bridge and is
# the fallback for clusters without one, but OVN layer2 keeps its allocations in
# the northbound database where nothing can read them, so the attribution half
# of this test degrades to "not observable" there.
IPAM_BACKEND="${IPAM_BACKEND:-whereabouts}"
BRIDGE_NAME="${BRIDGE_NAME:-br-storage}"

# Deliberately disjoint from the bridge's real subnet (10.9.4.0/24 here), which
# carries live Portworx storage traffic. whereabouts allocates from whatever
# range it is told; exhausting a pool does not need working L2, so a range that
# collides with nothing is strictly better. /29 gives 6 usable addresses.
TEST_RANGE="${TEST_RANGE:-10.9.250.0/29}"

# Hard stop, so a mistyped range can never spawn VMs without bound.
MAX_CLAIMANTS="${MAX_CLAIMANTS:-12}"
CLAIM_TIMEOUT="${CLAIM_TIMEOUT:-90}"     # seconds a VM may take to get an address
LEAK_CYCLES="${LEAK_CYCLES:-3}"          # force-delete rounds in the leak check
VM_MEMORY="${VM_MEMORY:-256Mi}"          # CirrOS needs very little
CONTROL_IMAGE="${CONTROL_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"
VM_IMAGE="${VM_IMAGE:-quay.io/kubevirt/cirros-container-disk-demo}"

# The one admin exception, and it is read-only: whereabouts IPPool objects are
# cluster-scoped and no namespace role can reach them, so step 6 reads them with
# an explicit impersonation on a non-mutating get. Set to 0 to skip and see what
# an unprivileged operator actually has to work with.
ADMIN_IPPOOL_READ="${ADMIN_IPPOOL_READ:-1}"

KEEP_NET="${KEEP_NET:-0}"                # 1 leaves the NAD and claimants in place

PASSED=0
FAILED=0
CLAIMED_VMS=()

pass() { echo " passed  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  failed $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  warning  $1"; }

cleanup() {
  echo ""
  echo "=== Cleaning up resources ==="
  if [ "${KEEP_NET}" = "1" ]; then
    echo "KEEP_NET=1, leaving the network and claimants in place. Delete with:"
    echo "  oc delete vm -l ipam-test=${NAD_NAME} -n ${NAMESPACE}"
    echo "  oc delete pod ${CONTROL_POD} -n ${NAMESPACE} --ignore-not-found"
    echo "  oc delete net-attach-def ${NAD_NAME} -n ${NAMESPACE}"
  else
    oc delete vm -l "ipam-test=${NAD_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
    oc delete pod "${CONTROL_POD}" -n "${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
    # The NAD goes last: deleting it while claimants still hold addresses leaves
    # whereabouts with allocations it can never reconcile.
    oc delete vm -l "ipam-test=${NAD_NAME}" -n "${NAMESPACE}" --ignore-not-found --timeout=120s 2>/dev/null || true
    oc delete net-attach-def "${NAD_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  fi
  echo "Done!"
}

# Usable addresses in a CIDR, excluding network and broadcast, which whereabouts
# never hands out for IPv4.
usable_in_cidr() { # usable_in_cidr <cidr>
  local prefix="${1##*/}"
  echo $(( (1 << (32 - prefix)) - 2 ))
}

# The authoritative record of what CNI allocated, written by Multus onto the pod
# itself. Using this rather than the VMI's status.interfaces matters: the VMI
# only learns its secondary address from qemu-guest-agent, which the CirrOS
# image does not have, so the VMI would report nothing while the address was in
# fact allocated.
#
# Read via `-o json` and fromjson rather than piping a jsonpath result into jq:
# the annotation's value is itself a JSON array, so jq would parse it as its own
# input and the fromjson would then fail on an already-decoded value.
pod_secondary_ip() { # pod_secondary_ip <pod>
  oc get pod "$1" -n "${NAMESPACE}" -o json 2>/dev/null \
    | jq -r --arg nad "${NAMESPACE}/${NAD_NAME}" \
        '(.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]")
         | (fromjson? // []) | .[] | select(.name==$nad) | .ips[0] // empty' 2>/dev/null || true
}

launcher_pod() { # launcher_pod <vm name>
  oc get pods -n "${NAMESPACE}" -l "vm.kubevirt.io/name=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

echo "========================================="
echo "  VM Secondary-Network IPAM Test"
echo "  Namespace:  ${NAMESPACE}"
echo "  Network:    ${NAD_NAME} (${IPAM_BACKEND})"
echo "  Range:      ${TEST_RANGE}"
[ "${IPAM_BACKEND}" = "whereabouts" ] && echo "  Bridge:     ${BRIDGE_NAME}"
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

# Checked up front rather than three VMs later. No shipped role grants this —
# clusterrole/edit has no rule for the resource and clusterrole/admin grants only
# get/list/watch — so without the one-time grant the test cannot start.
if [ "$(oc auth can-i create network-attachment-definitions -n "${NAMESPACE}" 2>/dev/null | tail -1)" != "yes" ]; then
  echo "failed Cannot create NetworkAttachmentDefinitions in ${NAMESPACE}."
  echo "   No shipped role grants this. A cluster admin applies the grant once:"
  echo ""
  echo "     oc process --local -f ipam-rbac.yaml \\"
  echo "       -p NAMESPACE=${NAMESPACE} \\"
  echo "       -p USER_NAME=\$(oc whoami) \\"
  echo "       | oc apply --as system:admin -f -"
  echo ""
  exit 1
fi
echo "permission to create secondary networks: granted"

case "${IPAM_BACKEND}" in
  whereabouts)
    # A bridge CNI plugin pointed at a bridge that does not exist fails at
    # attach time, after IPAM has already allocated — which would look exactly
    # like a leak and poison the whole result. Verified up front instead.
    if [ "$(oc auth can-i get nodenetworkstates 2>/dev/null | tail -1)" = "yes" ]; then
      BRIDGE_NODES="$(oc get nns -o json 2>/dev/null | jq -r --arg b "${BRIDGE_NAME}" \
        '[.items[] | select([.status.currentState.interfaces[]? | select(.name==$b and .state=="up")] | length > 0) | .metadata.name] | length')"
      TOTAL_NODES="$(oc get nns -o json 2>/dev/null | jq -r '.items | length')"
      if [ "${BRIDGE_NODES:-0}" -eq 0 ]; then
        echo "failed Bridge '${BRIDGE_NAME}' is not up on any node."
        echo "   Available bridges:"
        oc get nns -o json 2>/dev/null | jq -r '.items[] | .metadata.name as $n
          | .status.currentState.interfaces[]? | select(.type=="linux-bridge" or .type=="ovs-bridge")
          | "     \($n)  \(.name)  \(.type)  \(.state)"' || true
        echo "   Or re-run with IPAM_BACKEND=ovn, which needs no bridge."
        exit 1
      fi
      echo "bridge ${BRIDGE_NAME}: up on ${BRIDGE_NODES}/${TOTAL_NODES} nodes"
      # A bridge on only some nodes makes claimant scheduling a lottery, which
      # would show up as spurious allocation failures.
      [ "${BRIDGE_NODES}" -lt "${TOTAL_NODES}" ] && \
        warn "bridge is not on every node — claimants scheduled elsewhere will fail to attach for that reason, not for exhaustion"
    else
      warn "cannot read NodeNetworkStates, so bridge '${BRIDGE_NAME}' is unverified"
    fi
    ;;
  ovn)
    warn "IPAM_BACKEND=ovn: OVN layer2 allocations live in the northbound database, so step 6 cannot attribute addresses to holders at all"
    ;;
  *)
    echo "failed IPAM_BACKEND must be 'whereabouts' or 'ovn' (got '${IPAM_BACKEND}')."
    exit 1
    ;;
esac

# Refuse an unreasonably large pool. The test fills whatever it is given, so a
# fat-fingered /16 would mean thousands of VMs.
PREFIX_LEN="${TEST_RANGE##*/}"
if [ "${PREFIX_LEN}" -lt 28 ]; then
  echo "failed TEST_RANGE ${TEST_RANGE} is larger than /28. This test fills the pool it is given; refusing."
  exit 1
fi
USABLE="$(usable_in_cidr "${TEST_RANGE}")"
echo "range ${TEST_RANGE}: ${USABLE} usable addresses"

if [ "${USABLE}" -ge "${MAX_CLAIMANTS}" ]; then
  echo "failed MAX_CLAIMANTS (${MAX_CLAIMANTS}) must exceed the usable count (${USABLE}) or exhaustion can never be reached."
  exit 1
fi

# Silently reusing leftovers would let a half-full pool pass the count check.
if oc get net-attach-def "${NAD_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 \
   || [ -n "$(oc get vm -l "ipam-test=${NAD_NAME}" -n "${NAMESPACE}" -o name 2>/dev/null)" ]; then
  echo "failed Leftovers from a previous run exist in ${NAMESPACE}. Remove them first:"
  echo "   oc delete vm -l ipam-test=${NAD_NAME} -n ${NAMESPACE}"
  echo "   oc delete net-attach-def ${NAD_NAME} -n ${NAMESPACE}"
  exit 1
fi
echo "no leftover objects from a previous run"

trap cleanup EXIT

echo ""
echo "=== 1. Creating the secondary network ==="

if [ "${IPAM_BACKEND}" = "whereabouts" ]; then
  NAD_CONFIG="$(jq -nc --arg name "${NAD_NAME}" --arg br "${BRIDGE_NAME}" --arg range "${TEST_RANGE}" \
    '{cniVersion:"0.3.1", name:$name, type:"bridge", bridge:$br,
      ipam:{type:"whereabouts", range:$range}}')"
else
  NAD_CONFIG="$(jq -nc --arg name "${NAD_NAME}" --arg range "${TEST_RANGE}" \
    '{cniVersion:"0.3.1", name:$name, type:"ovn-k8s-cni-overlay",
      topology:"layer2", subnets:$range, netAttachDefName:("'"${NAMESPACE}"'/"+$name)}')"
fi

cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAMESPACE}
spec:
  config: '${NAD_CONFIG}'
EOF
pass "An ordinary user with the one-time grant can define a secondary network"

# Create one claimant VM and wait for CNI to either give it an address or refuse.
# Returns 0 with CLAIM_IP set, or 1 with CLAIM_REASON set.
CLAIM_IP=""
CLAIM_REASON=""
claim_one_vm() { # claim_one_vm <index>
  local idx="$1" vm="${VM_PREFIX}-$1" pod="" ip="" deadline
  CLAIM_IP=""; CLAIM_REASON=""

  cat <<EOF | oc apply -n "${NAMESPACE}" -f - >/dev/null
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm}
  namespace: ${NAMESPACE}
  labels:
    ipam-test: ${NAD_NAME}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${vm}
        ipam-test: ${NAD_NAME}
    spec:
      domain:
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          interfaces:
          - name: default
            masquerade: {}
          - name: secondary
            bridge: {}
          rng: {}
        resources:
          requests:
            memory: ${VM_MEMORY}
      networks:
      - name: default
        pod: {}
      - name: secondary
        multus:
          networkName: ${NAD_NAME}
      volumes:
      - name: containerdisk
        containerDisk:
          image: ${VM_IMAGE}
EOF

  deadline=$(( $(date +%s) + CLAIM_TIMEOUT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    pod="$(launcher_pod "${vm}")"
    if [ -n "${pod}" ]; then
      ip="$(pod_secondary_ip "${pod}")"
      if [ -n "${ip}" ]; then
        CLAIM_IP="${ip%%/*}"
        return 0
      fi
    fi
    sleep 3
  done

  # No address inside the budget. The reason lives in the pod's events, not its
  # status: the pod sits in ContainerCreating while CNI retries forever.
  if [ -n "${pod}" ]; then
    CLAIM_REASON="$(oc get events -n "${NAMESPACE}" \
      --field-selector "involvedObject.name=${pod}" \
      -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null \
      | grep -iE 'failed|error|ipam|allocat' | tail -3 || true)"
  fi
  [ -z "${CLAIM_REASON}" ] && CLAIM_REASON="(no event explaining the failure)"
  return 1
}

echo ""
echo "=== 2. Filling the pool with VMs ==="
echo "Expecting ${USABLE} successful claims, then a refusal."

GRANTED=0
REFUSED_AT=0
for i in $(seq 1 "${MAX_CLAIMANTS}"); do
  echo "  claimant ${i}..."
  if claim_one_vm "${i}"; then
    GRANTED=$((GRANTED + 1))
    CLAIMED_VMS+=("${VM_PREFIX}-${i}")
    echo "    got ${CLAIM_IP}"
  else
    REFUSED_AT="${i}"
    echo "    refused after ${CLAIM_TIMEOUT}s"
    break
  fi
done

echo ""
echo "  granted: ${GRANTED}, refused at claimant: ${REFUSED_AT:-none}"

if [ "${GRANTED}" -gt 0 ]; then
  pass "VMs receive addresses from the secondary subnet (${GRANTED} allocated)"
else
  fail "VMs receive addresses from the secondary subnet (none allocated)"
  echo "  Last failure reason: ${CLAIM_REASON}"
  exit 1
fi

if [ "${GRANTED}" -eq "${USABLE}" ]; then
  pass "Allocation count matches the usable size of ${TEST_RANGE} (${USABLE})"
else
  fail "Allocation count matches the usable size of ${TEST_RANGE} (expected ${USABLE}, got ${GRANTED})"
  # Not a formality. Fewer means addresses were already lost or reserved;
  # more means the IPAM plugin is handing out network or broadcast addresses.
fi

if [ "${REFUSED_AT}" -ne 0 ]; then
  pass "Exhaustion is refused rather than silently satisfied"
else
  fail "Exhaustion is refused (hit MAX_CLAIMANTS=${MAX_CLAIMANTS} without a refusal)"
fi

echo ""
echo "--- Refusal as the user sees it ---"
echo "${CLAIM_REASON}"
echo "-----------------------------------"

# Whether an operator can diagnose this from the error alone, or has to already
# know what to suspect.
if printf '%s' "${CLAIM_REASON}" | grep -qiE 'no ip addresses available|could not allocate ip|exhaust|range is full|no free'; then
  pass "The refusal message names address exhaustion"
else
  fail "The refusal message names address exhaustion"
  warn "the pod reports only a generic CNI failure, so exhaustion has to be inferred"
fi

echo ""
echo "=== 3. Containers draw from the same pool ==="

# The interaction claim, in one pair of steps: a plain pod, no KubeVirt
# involved, annotated onto the same network while VMs hold every address.
cat <<EOF | oc apply -n "${NAMESPACE}" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CONTROL_POD}
  namespace: ${NAMESPACE}
  labels:
    ipam-test: ${NAD_NAME}
  annotations:
    k8s.v1.cni.cncf.io/networks: ${NAD_NAME}
spec:
  containers:
  - name: idle
    image: ${CONTROL_IMAGE}
    command: ["sleep", "infinity"]
    resources:
      requests:
        memory: 64Mi
        cpu: 10m
EOF

CONTROL_IP=""
DEADLINE=$(( $(date +%s) + CLAIM_TIMEOUT ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  CONTROL_IP="$(pod_secondary_ip "${CONTROL_POD}")"
  [ -n "${CONTROL_IP}" ] && break
  sleep 3
done

if [ -z "${CONTROL_IP}" ]; then
  pass "A container is refused by the same exhausted pool the VMs filled"
else
  fail "A container is refused by the same exhausted pool (it got ${CONTROL_IP}, so the pools are separate)"
fi

echo ""
echo "Deleting one VM and seeing whether the container takes the freed address..."
FREED_VM="${CLAIMED_VMS[0]}"
oc delete vm "${FREED_VM}" -n "${NAMESPACE}" --timeout=120s >/dev/null 2>&1 || true
CLAIMED_VMS=("${CLAIMED_VMS[@]:1}")

# The pod is still in ContainerCreating and Multus keeps retrying, so no
# recreate is needed — it picks the address up on its own.
CONTROL_IP=""
DEADLINE=$(( $(date +%s) + CLAIM_TIMEOUT ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  CONTROL_IP="$(pod_secondary_ip "${CONTROL_POD}")"
  [ -n "${CONTROL_IP}" ] && break
  sleep 3
done

if [ -n "${CONTROL_IP}" ]; then
  pass "Deleting a VM frees an address a container immediately takes (${CONTROL_IP%%/*})"
else
  fail "Deleting a VM frees an address a container can take"
  warn "the address a VM released did not become usable within ${CLAIM_TIMEOUT}s — possible leak on graceful delete"
fi

echo ""
echo "=== 4. Graceful release ==="

# Reclaim the container's address so the pool state is known before the leak
# check, and confirm the VM path releases cleanly too.
oc delete pod "${CONTROL_POD}" -n "${NAMESPACE}" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true

if claim_one_vm "refill-graceful"; then
  pass "An address released by a gracefully deleted VM is reusable (${CLAIM_IP})"
  CLAIMED_VMS+=("${VM_PREFIX}-refill-graceful")
else
  fail "An address released by a gracefully deleted VM is reusable"
  echo "  ${CLAIM_REASON}"
fi

echo ""
echo "=== 5. Ungraceful release — the leak check ==="

# A VM whose node fails, or whose pod is force-deleted, never runs the CNI DEL
# that returns its address. If the allocation is not reconciled some other way,
# every such event permanently shrinks the pool. This is the failure that
# actually bites in production, because nothing reports it.
LEAK_OK=1
cycle=0
if [ "${#CLAIMED_VMS[@]}" -eq 0 ]; then
  warn "no claimant VM left to force-delete, skipping the leak check"
  LEAK_CYCLES=0
fi
VICTIM="${CLAIMED_VMS[0]:-}"
for cycle in $(seq 1 "${LEAK_CYCLES}"); do
  VICTIM_POD="$(launcher_pod "${VICTIM}")"
  if [ -z "${VICTIM_POD}" ]; then
    warn "cycle ${cycle}: no virt-launcher pod for ${VICTIM}, skipping"
    continue
  fi
  BEFORE_IP="$(pod_secondary_ip "${VICTIM_POD}")"
  echo "  cycle ${cycle}: force-deleting ${VICTIM_POD} (held ${BEFORE_IP:-unknown})"
  oc delete pod "${VICTIM_POD}" -n "${NAMESPACE}" --force --grace-period=0 >/dev/null 2>&1 || true

  # runStrategy: Always respawns it. If the old allocation leaked, the new pod
  # finds the pool full and never gets an address.
  AFTER_IP=""
  DEADLINE=$(( $(date +%s) + CLAIM_TIMEOUT ))
  while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    NEW_POD="$(launcher_pod "${VICTIM}")"
    if [ -n "${NEW_POD}" ] && [ "${NEW_POD}" != "${VICTIM_POD}" ]; then
      AFTER_IP="$(pod_secondary_ip "${NEW_POD}")"
      [ -n "${AFTER_IP}" ] && break
    fi
    sleep 3
  done

  if [ -n "${AFTER_IP}" ]; then
    echo "    recovered with ${AFTER_IP}"
  else
    echo "    did not get an address back"
    LEAK_OK=0
    break
  fi
done

if [ "${LEAK_CYCLES}" -eq 0 ]; then
  fail "A force-deleted virt-launcher pod gets its address back (not exercised)"
  fail "Pool size is unchanged after ungraceful deletes (not exercised)"
elif [ "${LEAK_OK}" = "1" ]; then
  pass "A force-deleted virt-launcher pod gets its address back (${LEAK_CYCLES} cycles)"
  pass "Pool size is unchanged after ${LEAK_CYCLES} ungraceful deletes"
else
  fail "A force-deleted virt-launcher pod gets its address back (leaked on cycle ${cycle})"
  fail "Pool size is unchanged after ungraceful deletes"
  warn "each node failure or force-delete permanently costs this network one address"
fi

echo ""
echo "=== 6. Attribution — who is holding the addresses ==="

# Not pass/fail. This is the operational question the whole test exists to
# answer: when a secondary network fills up, can you find out who filled it?
echo ""
echo "Holders visible to an ordinary namespace user (by pod annotation):"
oc get pods -n "${NAMESPACE}" -o json 2>/dev/null | jq -r \
  --arg nad "${NAMESPACE}/${NAD_NAME}" '
  .items[]
  | . as $p
  | ($p.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]")
  | (fromjson? // [])
  | .[] | select(.name==$nad)
  | "  \(if $p.metadata.labels["kubevirt.io"]=="virt-launcher" then "VM       " else "container" end)  \(.ips[0] // "-")  \($p.metadata.labels["vm.kubevirt.io/name"] // $p.metadata.name)"' \
  || echo "  (none)"

echo ""
if [ "$(oc auth can-i list ippools --all-namespaces 2>/dev/null | tail -1)" = "yes" ]; then
  echo "This user can list whereabouts IPPools directly."
else
  warn "this user cannot list whereabouts IPPools — the only object that records the"
  warn "  authoritative allocation table is cluster-scoped and out of reach, so an"
  warn "  ordinary operator can only infer pool state by counting annotated pods"
fi

if [ "${IPAM_BACKEND}" = "whereabouts" ] && [ "${ADMIN_IPPOOL_READ}" = "1" ]; then
  echo ""
  echo "Authoritative allocation table (read with --as system:admin; see README):"
  # Documented exception to the no-impersonation rule. This is a non-mutating
  # get, used only to show what the unprivileged view above is missing.
  if ! oc get ippools -A --as system:admin -o json 2>/dev/null | jq -r \
      --arg range "${TEST_RANGE}" '
      .items[] | select(.spec.range==$range)
      | "  pool \(.metadata.namespace)/\(.metadata.name)  range \(.spec.range)",
        (.spec.allocations // {} | to_entries[] | "    .\(.key)  \(.value.podref // "?")")' ; then
    warn "the admin IPPool read failed — set ADMIN_IPPOOL_READ=0 to skip it"
  fi
elif [ "${IPAM_BACKEND}" = "ovn" ]; then
  warn "OVN layer2 keeps allocations in the northbound database; there is no object to read, at any privilege level"
fi

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "========================================="

if [ "${FAILED}" -eq 0 ]; then
  echo "  VERIFICATION SUCCESS: the secondary pool is shared between VMs and"
  echo "   containers, fills predictably, refuses legibly, and releases addresses"
  echo "   on both graceful and ungraceful teardown."
else
  echo "failed VERIFICATION FAILED: see the failed lines above."
  echo ""
  echo "Current claimants:"
  oc get vm,pod -l "ipam-test=${NAD_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
  echo ""
  echo "Re-run with KEEP_NET=1 to keep the network and claimants for inspection."
  exit 1
fi
