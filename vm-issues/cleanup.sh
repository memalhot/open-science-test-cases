#!/usr/bin/env bash
set -euo pipefail

# Removes anything the four VM test suites can leave behind: networking,
# storage and migration in ../vm-testing, and the clone test in this directory.
# The GPU suite has its own cleanup at ../vm-testing/gpu/cleanup.sh.
#
# All of them clean up after themselves on exit, so this is for the cases where
# that did not happen: a run killed with Ctrl-C before its trap fired, a run
# left in place on purpose with KEEP_VM=1 or KEEP_RESOURCES=1, or a disk that
# would not release because a dead CDI worker pod was still holding it.
#
# It deletes by exact name, never by "everything in the namespace", so it is
# safe to run in a namespace that also holds real work.
#
# Like the tests themselves, this runs as the logged-in user. The one thing a
# project user cannot do is clear an orphaned VolumeAttachment, which is what
# pins a leaked PV in Released; pass --admin to do that part with
# `--as system:admin`.

usage() {
  cat <<EOF
Usage: ./cleanup.sh [--dry-run] [--admin] [-n NAMESPACE]

  --dry-run      List what would be deleted, delete nothing.
  --admin        Also clear orphaned VolumeAttachments and Released PVs left by
                 these tests, using --as system:admin. Needs cluster-admin.
  -n NAMESPACE   Namespace to clean. May be repeated. Defaults to the ones the
                 tests use: mm-test (storage, migration, clone) and vm-test
                 (networking), skipping any that do not exist.

Environment:
  NAMESPACE / PROJECT   Same as -n, for consistency with the test scripts.
  EXTRA_VMS             Extra VM names to remove, space separated.
  EXTRA_DVS             Extra DataVolume names to remove.
  EXTRA_PVCS            Extra PVC names to remove.
  WAIT                  Seconds to wait for disks to release (default 180).
EOF
}

DRY_RUN=0
ADMIN=0
NAMESPACES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --admin)   ADMIN=1; shift ;;
    -n)        [ $# -ge 2 ] || { echo "-n needs a namespace"; exit 1; }
               NAMESPACES+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "Unknown argument: $1"; echo; usage; exit 1 ;;
  esac
done

# An explicitly named namespace wins; otherwise sweep the ones the tests
# default to. test-vm.sh uses vm-test while the other three use mm-test.
if [ "${#NAMESPACES[@]}" -eq 0 ]; then
  if [ -n "${NAMESPACE:-${PROJECT:-}}" ]; then
    NAMESPACES=("${NAMESPACE:-${PROJECT}}")
  else
    NAMESPACES=(mm-test vm-test)
  fi
fi

WAIT="${WAIT:-180}"

# Every object the suites create, by the name each one uses by default.
#   test-vm.sh            self-test-vm
#   net-test-vm.yaml      net-test-vm, and the net-test-ssh Service it creates
#                         alongside the VM for the port-forward step
#   test-vm-storage.sh    pvc-test-vm + its rootdisk
#   test-vm-migration.sh  migrate-test-vm + its rootdisk
#   test-vm-clone.sh      the clone-test-* disks
VMS=(self-test-vm net-test-vm pvc-test-vm migrate-test-vm)
DVS=(pvc-test-vm-rootdisk migrate-test-vm-rootdisk \
     clone-test-source clone-test-smart clone-test-copy clone-test-snapshot)
PVCS=(clone-test-csi)
SERVICES=(net-test-ssh)

# read -ra rather than bare expansion: the EXTRA_* variables are space
# separated by design, but an unquoted expansion would also glob.
read -ra _extra <<< "${EXTRA_VMS:-}";  [ "${#_extra[@]}" -gt 0 ] && VMS+=("${_extra[@]}")
read -ra _extra <<< "${EXTRA_DVS:-}";  [ "${#_extra[@]}" -gt 0 ] && DVS+=("${_extra[@]}")
read -ra _extra <<< "${EXTRA_PVCS:-}"; [ "${#_extra[@]}" -gt 0 ] && PVCS+=("${_extra[@]}")

FOUND=0
DELETED=0
STUCK=()

if [ "${DRY_RUN}" = "1" ]; then
  echo "DRY RUN — nothing will be deleted."
  echo ""
fi

# Delete unless this is a dry run; either way, say so.
run() { # run <description> <command...>
  local desc="$1"; shift
  FOUND=$((FOUND + 1))
  if [ "${DRY_RUN}" = "1" ]; then
    echo "  would delete  ${desc}"
    return 0
  fi
  echo "  deleting      ${desc}"
  if "$@" >/dev/null 2>&1; then
    DELETED=$((DELETED + 1))
  else
    echo "                (delete call failed; it may already be going)"
  fi
}

exists() { # exists <kind> <name> <namespace>
  oc get "$1" "$2" -n "$3" >/dev/null 2>&1
}

command -v oc >/dev/null 2>&1 || { echo "Required binary 'oc' not found in PATH."; exit 1; }

# PV names are recorded before the PVCs go, so the orphan check at the end has
# something to look for once the claims are gone.
OUR_PVS=()

for ns in "${NAMESPACES[@]}"; do
  if ! oc get namespace "${ns}" >/dev/null 2>&1; then
    echo "=== ${ns}: not present, skipping ==="
    echo ""
    continue
  fi

  echo "=== ${ns} ==="

  # Note the PVs behind every disk this suite owns, before anything is removed.
  for name in "${DVS[@]}" "${PVCS[@]}"; do
    pv="$(oc get pvc "${name}" -n "${ns}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")"
    [ -n "${pv}" ] && OUR_PVS+=("${pv}")
  done

  # Migrations first: they reference a VMI, and deleting them before the VM
  # keeps the migration controller from acting on a half-removed VM.
  for mig in $(oc get vmim -n "${ns}" -o name 2>/dev/null || true); do
    vmi_name="$(oc get "${mig}" -n "${ns}" -o jsonpath='{.spec.vmiName}' 2>/dev/null || echo "")"
    for vm in "${VMS[@]}"; do
      if [ "${vmi_name}" = "${vm}" ]; then
        run "${mig} (migration of ${vmi_name})" \
          oc delete "${mig}" -n "${ns}" --ignore-not-found --wait=false
      fi
    done
  done

  for vm in "${VMS[@]}"; do
    if exists vm "${vm}" "${ns}"; then
      run "vm/${vm}" oc delete vm "${vm}" -n "${ns}" --ignore-not-found --wait=false
    fi
    # A VMI with no VM above it is left over from a VM that was removed while
    # its guest was still running.
    if exists vmi "${vm}" "${ns}" && ! exists vm "${vm}" "${ns}"; then
      run "vmi/${vm} (orphaned)" oc delete vmi "${vm}" -n "${ns}" --ignore-not-found --wait=false
    fi
  done

  for svc in "${SERVICES[@]}"; do
    if exists service "${svc}" "${ns}"; then
      run "service/${svc}" oc delete service "${svc}" -n "${ns}" --ignore-not-found
    fi
  done

  # DataVolumes own their PVCs, so removing the DV reclaims the disk.
  for dv in "${DVS[@]}"; do
    if exists dv "${dv}" "${ns}"; then
      run "dv/${dv}" oc delete dv "${dv}" -n "${ns}" --ignore-not-found --wait=false
    fi
  done

  # PVCs with no DataVolume above them, plus any PVC whose DataVolume is gone
  # but which outlived it.
  for pvc in "${DVS[@]}" "${PVCS[@]}"; do
    if exists pvc "${pvc}" "${ns}" && ! exists dv "${pvc}" "${ns}"; then
      run "pvc/${pvc}" oc delete pvc "${pvc}" -n "${ns}" --ignore-not-found --wait=false
    fi
  done

  echo ""
done

if [ "${DRY_RUN}" = "1" ]; then
  echo "========================================="
  echo "  ${FOUND} object(s) would be deleted."
  echo "========================================="
  exit 0
fi

if [ "${FOUND}" -eq 0 ]; then
  echo "Nothing to clean up."
else
  # ---------------------------------------------------------------------------
  # Wait for the disks to actually go. A PVC that will not release is the whole
  # reason this script needs to do more than call oc delete.
  # ---------------------------------------------------------------------------
  echo "Waiting up to ${WAIT}s for disks to be released..."
  deadline=$(( $(date +%s) + WAIT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    STUCK=()
    for ns in "${NAMESPACES[@]}"; do
      oc get namespace "${ns}" >/dev/null 2>&1 || continue
      for name in "${DVS[@]}" "${PVCS[@]}"; do
        exists pvc "${name}" "${ns}" && STUCK+=("${ns}/${name}")
      done
    done
    [ "${#STUCK[@]}" -eq 0 ] && break
    sleep 5
  done

  if [ "${#STUCK[@]}" -eq 0 ]; then
    echo "All disks released."
  else
    # -------------------------------------------------------------------------
    # A PVC holds the pvc-protection finalizer for exactly as long as some pod
    # references it, so the pods still naming it are the ones pinning it. CDI's
    # clone-source pods carry no ownerReferences and so are never garbage
    # collected; if the node also cannot unmount the volume they sit
    # Terminating forever, and force is the only way out.
    # -------------------------------------------------------------------------
    echo ""
    echo "=== Disks still present; finding what is holding them ==="
    for entry in "${STUCK[@]}"; do
      ns="${entry%%/*}"
      pvc="${entry#*/}"
      echo "  ${entry}"
      for pod in $(oc get pods -n "${ns}" -o name 2>/dev/null || true); do
        claims="$(oc get "${pod}" -n "${ns}" \
          -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null || echo "")"
        printf '%s' "${claims}" | tr ' ' '\n' | grep -qx "${pvc}" || continue

        phase="$(oc get "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
        terminating="$(oc get "${pod}" -n "${ns}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")"
        echo "    held by ${pod##*/} (${phase:-unknown}${terminating:+, Terminating})"

        # Only force out a pod that is already finished or already on its way
        # out. A Running one may be doing something, and that is the user's
        # call rather than this script's.
        if [ "${phase}" = "Running" ] && [ -z "${terminating}" ]; then
          echo "    still Running — leaving it alone. Remove it yourself if it is stale:"
          echo "      oc delete ${pod} -n ${ns}"
          continue
        fi
        run "${pod##*/} (holding ${pvc})" \
          oc delete "${pod}" -n "${ns}" --force --grace-period=0 --ignore-not-found
      done
    done

    echo ""
    echo "Waiting another ${WAIT}s for the disks to release..."
    remaining=()
    deadline=$(( $(date +%s) + WAIT ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
      remaining=()
      for entry in "${STUCK[@]}"; do
        ns="${entry%%/*}"; pvc="${entry#*/}"
        exists pvc "${pvc}" "${ns}" && remaining+=("${entry}")
      done
      [ "${#remaining[@]}" -eq 0 ] && break
      sleep 5
    done
    if [ "${#remaining[@]}" -eq 0 ]; then
      echo "All disks released."
    else
      echo "WARN  still present: ${remaining[*]}"
      echo "      Inspect with: oc describe pvc <name> -n <namespace>"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Forcing a pod out whose volume the node never unmounted leaves the
# VolumeAttachment behind. Its attacher finalizer stops the PV being reclaimed,
# so the volume leaks while showing as Released. Deleting the VolumeAttachment
# is normally enough on its own — the PV's Delete reclaim policy then takes
# over within about half a minute.
# -----------------------------------------------------------------------------
echo ""
echo "=== Checking for leaked volumes ==="

ORPHANS=()
for pv in $(printf '%s\n' "${OUR_PVS[@]:-}" | sort -u); do
  [ -n "${pv}" ] || continue
  status="$(oc get pv "${pv}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  [ -n "${status}" ] || continue   # already gone, which is the good case
  echo "  pv/${pv}: ${status}"
  if [ "${status}" = "Released" ] || [ "${status}" = "Failed" ]; then
    ORPHANS+=("${pv}")
  fi
done

if [ "${#ORPHANS[@]}" -eq 0 ]; then
  echo "  No leaked volumes."
else
  VAS=()
  for pv in "${ORPHANS[@]}"; do
    for va in $(oc get volumeattachment -o name 2>/dev/null || true); do
      va_pv="$(oc get "${va}" -o jsonpath='{.spec.source.persistentVolumeName}' 2>/dev/null || echo "")"
      [ "${va_pv}" = "${pv}" ] && VAS+=("${va##*/}")
    done
  done

  if [ "${ADMIN}" = "1" ]; then
    for va in "${VAS[@]:-}"; do
      [ -n "${va}" ] || continue
      run "volumeattachment/${va}" oc delete volumeattachment "${va}" --as system:admin --wait=false
    done
    echo "  Waiting for the PVs to be reclaimed..."
    sleep 30
    for pv in "${ORPHANS[@]}"; do
      if oc get pv "${pv}" >/dev/null 2>&1; then
        run "pv/${pv} (not reclaimed on its own)" oc delete pv "${pv}" --as system:admin --wait=false
      else
        echo "  pv/${pv}: reclaimed."
      fi
    done
  else
    echo ""
    echo "  These are leaked and need cluster-admin to clear:"
    for pv in "${ORPHANS[@]}"; do echo "    pv/${pv}"; done
    for va in "${VAS[@]:-}"; do [ -n "${va}" ] && echo "    volumeattachment/${va}"; done
    echo ""
    echo "  Re-run with --admin to clear them, or by hand:"
    for va in "${VAS[@]:-}"; do
      [ -n "${va}" ] && echo "    oc delete volumeattachment ${va} --as system:admin"
    done
    echo "  Deleting the VolumeAttachment is usually enough; the PV's Delete"
    echo "  reclaim policy removes it within about half a minute."
  fi
fi

echo ""
echo "========================================="
echo "  ${DELETED} of ${FOUND} object(s) deleted."
echo "========================================="
echo "Done!"
