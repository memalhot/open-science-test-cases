#!/usr/bin/env bash
# Tear down the Gemma 4 vLLM serving to stop GPU (and optionally storage) charges.
#   ./down.sh              # FULL teardown: releases GPUs AND deletes the weight cache
#   ./down.sh --keep-cache # release GPUs but KEEP the model-cache PVC (fast re-run)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

KEEP_CACHE=0
[ "${1:-}" = "--keep-cache" ] && KEEP_CACHE=1

if [ "$SERVE_MODE" = "lazy" ]; then
  info "Deleting compute (deployment, service, route, pods) in $NAMESPACE"
  oc delete deployment,service,route,pod -l "$APP_LABEL" -n "$NAMESPACE" --ignore-not-found
else
  info "Deleting KServe serving (inferenceservice, runtime, seed job, route) in $NAMESPACE"
  # Deleting the InferenceService cascades to its predictor Deployment/pods.
  oc delete inferenceservice gemma4 -n "$NAMESPACE" --ignore-not-found
  oc delete servingruntime gemma4-vllm-runtime -n "$NAMESPACE" --ignore-not-found
  oc delete job gemma4-seed -n "$NAMESPACE" --ignore-not-found
  oc delete route "$ROUTE_NAME" -n "$NAMESPACE" --ignore-not-found
  oc delete service gemma4-external -n "$NAMESPACE" --ignore-not-found
fi

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

oc get deployment,pod,service,route,pvc -n "$NAMESPACE" -l "$APP_LABEL" 2>/dev/null || true
