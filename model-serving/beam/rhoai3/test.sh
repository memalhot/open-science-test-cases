#!/usr/bin/env bash
# Deployment smoke test for the Beam Ray stack (RHOAI 3.x variant).
#
# Checks what is specific to this deployment topology — that the Ray cluster
# really formed across two nodes and that the API answers. The assertions
# themselves live in ../common/lib.sh and are shared with the rhoai2 variant.
#
# For model-behaviour coverage (Harmony channels, reasoning effort, tool calls,
# long context, errors) run the full suite instead:
#
#     cd ../../../../inference && BASE_URL=<url> ./test-inference-beam.sh
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"
load_config

echo "========================================="
echo "  Beam deployment smoke test (${VARIANT_NAME})"
echo "  Namespace: $NAMESPACE"
echo "========================================="

smoke_ray_topology || { smoke_summary; exit 1; }

# The 3.x operator mutates the head pod too, just differently from CodeFlare:
# its raycluster-mtls controller adds the cert volumes and RAY_TLS_* env, a
# wait-for-tls-ip-san init container, and a kube-rbac-proxy sidecar — but no
# oauth-proxy. Seeing one of those means this is really a 2.x cluster with the
# CodeFlare operator injecting it, in which case ../rhoai2/ is the variant you
# want.
containers="$(oc get pod "$HEAD" -n "$NAMESPACE" \
  -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}' 2>/dev/null)"
if printf '%s' "$containers" | grep -q 'oauth-proxy'; then
  fail "head pod carries an oauth-proxy sidecar (${containers}) — this looks like RHOAI 2.x; use ../rhoai2/"
else
  pass "head containers as declared: ${containers}"
fi

# --- NetworkPolicy ---------------------------------------------------------
echo
echo "=== NetworkPolicy ==="

if oc get networkpolicy beam-head-vllm -n "$NAMESPACE" >/dev/null 2>&1; then
  pass "beam-head-vllm present (reopens 8000; KubeRay's head policy does not allow it)"
else
  fail "beam-head-vllm missing — the route to vLLM will time out"
fi

smoke_api || { smoke_summary; exit 1; }
smoke_completion
smoke_summary
