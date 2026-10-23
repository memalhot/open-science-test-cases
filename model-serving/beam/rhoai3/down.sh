#!/usr/bin/env bash
# Tear down the Beam serving stack (RHOAI 3.x variant).
#
#   ./down.sh               # delete the RayCluster, NetworkPolicy, route, service, seed Job
#   ./down.sh --weights     # also delete the 294GB weight PVC
#
# The weight PVC is kept by default on purpose: re-seeding it is a 294GB
# download, and `./up.sh --skip-seed` brings the whole stack back in minutes
# as long as it survives.
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

# Give KubeRay a moment to reap the head/worker pods so a follow-up ./up.sh
# doesn't race two clusters' pods for the same GPUs.
info "Waiting for Ray pods to terminate"
oc wait --for=delete pod -l "ray.io/cluster=${CLUSTER_NAME}" \
  -n "$NAMESPACE" --timeout=300s >/dev/null 2>&1 || true

if [ "$DROP_WEIGHTS" -eq 1 ]; then
  del pvc beam-weights
  warn "Weight PVC deleted — the next ./up.sh re-downloads 294GB."
else
  info "Kept PVC beam-weights (re-deploy with: ./up.sh --skip-seed)"
fi

info "Done."
