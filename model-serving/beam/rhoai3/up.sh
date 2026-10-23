#!/usr/bin/env bash
# Stand up Beam 1.0 on vLLM, tensor-parallel across both GPU nodes via Ray.
# RHOAI 3.x variant — see ../rhoai2/up.sh for the 2.x one.
#
#   ./up.sh                   # image -> PVC -> seed weights -> RayCluster -> route
#   ./up.sh --no-wait         # apply everything and return immediately
#   ./up.sh --skip-seed       # weights are already on the PVC; go straight to serving
#   ./up.sh --rebuild-image   # rebuild the serving image even if it exists
#
# Config comes from ../common/config.conf (env vars of the same name win).
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"
load_config

WAIT=1
SKIP_SEED=0
REBUILD_IMAGE=0
for arg in "$@"; do
  case "$arg" in
    --no-wait)       WAIT=0 ;;
    --skip-seed)     SKIP_SEED=1 ;;
    --rebuild-image) REBUILD_IMAGE=1 ;;
    *) die "unknown argument: $arg (expected --no-wait, --skip-seed or --rebuild-image)" ;;
  esac
done

info "Preflight"
check_variant_matches_cluster
check_gpu_capacity

ensure_project
ensure_serving_image "$REBUILD_IMAGE"
ensure_hf_secret
ensure_weights_pvc

if [ "$SKIP_SEED" -eq 0 ]; then
  seed_weights "$WAIT"
else
  info "--skip-seed given; assuming weights are already at $MODEL_PATH"
fi

info "Creating RayCluster (head: $HEAD_GPUS GPU + vLLM driver; $WORKER_REPLICAS worker x $WORKER_GPUS GPU)"
render raycluster.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -

# KubeRay's own networkpolicy-controller writes a head policy admitting only
# 10001/8265/8443, so without this the route to vLLM silently times out — and
# only reveals itself after the model has finished loading.
info "Allowing ingress to vLLM on 8000 (KubeRay's head NetworkPolicy does not)"
render networkpolicy.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -

info "Creating external service and route"
render endpoint.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -

if [ "$WAIT" -eq 0 ]; then
  info "Applied. --no-wait given; not blocking on model load."
  exit 0
fi

wait_for_serving
print_ready_banner
