#!/usr/bin/env bash
# Tear down the Gemma 4 vLLM serving to stop GPU (and optionally storage) charges.
#   ./down.sh              # FULL teardown: releases GPUs AND deletes the weight cache
#   ./down.sh --keep-cache # release GPUs but KEEP the model-cache PVC (fast re-run)
# Teardown covers BOTH serving modes, so --mode is unnecessary (accepted, ignored).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
parse_mode_flag "$@"; set -- ${REST_ARGS[@]+"${REST_ARGS[@]}"}
load_config

KEEP_CACHE=0
for a in "$@"; do
  case "$a" in
    --keep-cache) KEEP_CACHE=1 ;;
    *) die "unknown flag: $a" ;;
  esac
done

# Delete BOTH modes' compute unconditionally, regardless of the SERVE_MODE in the
# environment. Teardown's whole job is to stop GPU charges, so it must never leave
# a predictor running just because it was invoked with the "wrong" mode: running
# `./down.sh` (defaulting to lazy) against a kserve deploy would otherwise skip the
# predictor — leaving 2 GPUs held — while still deleting the shared PVC out from
# under it. Every delete is --ignore-not-found, so removing what isn't there is a
# harmless no-op.
info "Deleting compute for BOTH serving modes in $NAMESPACE (releases GPUs)"
# lazy: Deployment/Service/pods carry app=gemma4-vllm.
oc delete deployment,service,pod -l app=gemma4-vllm -n "$NAMESPACE" --ignore-not-found
# kserve: deleting the InferenceService cascades to its predictor Deployment/pods.
oc delete inferenceservice gemma4 -n "$NAMESPACE" --ignore-not-found
oc delete servingruntime gemma4-vllm-runtime -n "$NAMESPACE" --ignore-not-found
# The autoscaling HPA is owned by the isvc (cascades above), but delete by name too
# in case the isvc was already gone when a prior teardown was interrupted.
oc delete hpa gemma4-predictor -n "$NAMESPACE" --ignore-not-found
oc delete job gemma4-seed -n "$NAMESPACE" --ignore-not-found
oc delete service gemma4-external -n "$NAMESPACE" --ignore-not-found
# Routes by name — lazy: gemma4-vllm; kserve: gemma4-infer; legacy colliding: gemma4.
oc delete route gemma4-vllm gemma4-infer gemma4 -n "$NAMESPACE" --ignore-not-found

# Remove any leftover benchmark Job + its inference-perf ConfigMap (benchmark.sh).
oc delete job gemma4-benchmark -n "$NAMESPACE" --ignore-not-found
oc delete configmap gemma4-benchmark-config -n "$NAMESPACE" --ignore-not-found

# ConfigMap from the generator carries a hash suffix; match by name prefix.
for cm in $(oc get configmap -n "$NAMESPACE" -o name 2>/dev/null | grep 'gemma4-params' || true); do
  oc delete "$cm" -n "$NAMESPACE" --ignore-not-found
done

if [ "$KEEP_CACHE" -eq 1 ]; then
  warn "Keeping PVC model-cache (weight cache preserved for a fast re-run)."
else
  info "Deleting weight-cache PVC (model-cache)"
  oc delete pvc model-cache -n "$NAMESPACE" --ignore-not-found
fi

oc delete secret hf-token -n "$NAMESPACE" --ignore-not-found

info "Verifying no GPU is still held in $NAMESPACE"
held="$(oc get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' \
  2>/dev/null | grep -c '[0-9]' || true)"
if [ "${held:-0}" -eq 0 ]; then
  info "Teardown complete — 0 GPUs held."
else
  warn "$held pod(s) still request a GPU — check: oc get pods -n $NAMESPACE"
fi

oc get inferenceservice,deployment,pod,service,route,pvc -n "$NAMESPACE" 2>/dev/null || true
