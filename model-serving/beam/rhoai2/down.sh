#!/usr/bin/env bash
# Tear down the Beam serving stack (RHOAI 2.25 variant).
#
#   ./down.sh               # delete the RayCluster, NetworkPolicy, route, service, seed Job
#   ./down.sh --weights     # also delete the 294GB weight PVC
#
# The weight PVC is kept by default on purpose: re-seeding it is a 294GB
# download, and `./up.sh --skip-seed` brings the whole stack back in minutes.
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"
load_config

DROP_WEIGHTS=0
for arg in "$@"; do
  case "$arg" in
    --weights) DROP_WEIGHTS=1 ;;
    *) die "unknown argument: $arg (expected --weights)" ;;
  esac
done

del() {
  info "Deleting $1/$2"
  oc delete "$1" "$2" -n "$NAMESPACE" --ignore-not-found --as system:admin >/dev/null
}

del route beam-infer
del service beam-external
del networkpolicy beam-head-vllm
del raycluster "$CLUSTER_NAME"
del job beam-seed

# The CodeFlare controller owns the SA, CA secret, OAuth secret/service, its
# two routes and the head/worker NetworkPolicies, all with ownerReferences on
# the RayCluster — deleting the cluster garbage-collects them. Only our own
# beam-head-vllm policy (above) has to go explicitly.
info "Waiting for Ray pods to terminate"
oc wait --for=delete pod -l "ray.io/cluster=${CLUSTER_NAME}" \
  -n "$NAMESPACE" --timeout=300s >/dev/null 2>&1 || true

leftover=$(oc get networkpolicy,secret,serviceaccount -n "$NAMESPACE" \
  -l "ray.io/cluster=${CLUSTER_NAME}" -o name 2>/dev/null | grep -c . || true)
if [ "${leftover:-0}" -gt 0 ]; then
  warn "$leftover CodeFlare-owned object(s) still present; garbage collection may lag:"
  oc get networkpolicy,secret,serviceaccount -n "$NAMESPACE" \
    -l "ray.io/cluster=${CLUSTER_NAME}" -o name 2>/dev/null | sed 's/^/        /'
fi

if [ "$DROP_WEIGHTS" -eq 1 ]; then
  del pvc beam-weights
  warn "Weight PVC deleted — the next ./up.sh re-downloads 294GB."
else
  info "Kept PVC beam-weights (re-deploy with: ./up.sh --skip-seed)"
fi

info "Done."
