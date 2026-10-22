#!/usr/bin/env bash
# Stand up Beam 1.0 on vLLM, tensor-parallel across both GPU nodes via Ray.
# RHOAI 2.25 variant — see ../rhoai3/up.sh for the 3.x one.
#
#   ./up.sh                 # PVC -> seed weights -> RayCluster -> NetworkPolicy -> route
#   ./up.sh --no-wait       # apply everything and return immediately
#   ./up.sh --skip-seed     # weights are already on the PVC; go straight to serving
#
# Config comes from ../common/config.conf (env vars of the same name win).
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"
load_config

WAIT=1
SKIP_SEED=0
for arg in "$@"; do
  case "$arg" in
    --no-wait)   WAIT=0 ;;
    --skip-seed) SKIP_SEED=1 ;;
    *) die "unknown argument: $arg (expected --no-wait or --skip-seed)" ;;
  esac
done

info "Preflight"
check_variant_matches_cluster
check_gpu_capacity

# --- RHOAI 2.x specific preflight ------------------------------------------
# The CodeFlare operator is what injects the mTLS certs and the oauth-proxy
# sidecar this variant is written around. If it is absent (component Removed,
# or an already-migrated cluster) the RayCluster still comes up, but the
# by-hand RAY_TLS_* env on the vLLM sidecar then points at files nothing
# creates — so say so clearly rather than failing inside the driver.
if oc get deployment -n redhat-ods-applications -l app.kubernetes.io/name=codeflare-operator \
     -o name 2>/dev/null | grep -q . \
   || oc get deployment codeflare-operator-manager -n redhat-ods-applications >/dev/null 2>&1; then
  info "  CodeFlare operator present (mTLS + oauth-proxy will be injected)"
else
  warn "CodeFlare operator not found. If mTLS is disabled or the component is Removed,"
  warn "the vLLM sidecar's RAY_TLS_* settings are inert and Ray will talk plaintext —"
  warn "that works, but confirm it is what you expect before trusting the topology."
fi

if [ -n "$LOCAL_QUEUE" ]; then
  oc get localqueue "$LOCAL_QUEUE" -n "$NAMESPACE" >/dev/null 2>&1 \
    || die "LOCAL_QUEUE='$LOCAL_QUEUE' does not exist in $NAMESPACE (oc get localqueue -n $NAMESPACE)"
  info "  Kueue LocalQueue '$LOCAL_QUEUE' found"
else
  info "  No LOCAL_QUEUE set — relying on a cluster default LocalQueue, if any"
fi

ensure_project
ensure_hf_secret
ensure_weights_pvc

if [ "$SKIP_SEED" -eq 0 ]; then
  seed_weights "$WAIT"
else
  info "--skip-seed given; assuming weights are already at $MODEL_PATH"
fi

info "Creating RayCluster (head: $HEAD_GPUS GPU + vLLM driver; $WORKER_REPLICAS worker x $WORKER_GPUS GPU)"
render raycluster.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -

# Must exist before anything tries to reach the endpoint: CodeFlare's own head
# NetworkPolicy does not admit 8000, so without this the route silently times
# out. Applied after the RayCluster so the CodeFlare policy it complements is
# already in place; order does not actually matter, since policies are additive.
info "Allowing ingress to vLLM on 8000 (CodeFlare's head NetworkPolicy does not)"
render networkpolicy.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -

info "Creating external service and route"
render endpoint.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -

if [ "$WAIT" -eq 0 ]; then
  info "Applied. --no-wait given; not blocking on model load."
  exit 0
fi

wait_for_serving
print_ready_banner
echo "  Dashboard:   CodeFlare also publishes its own route (oc get route -n $NAMESPACE | grep ray)"
