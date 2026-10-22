#!/usr/bin/env bash
# Deployment smoke test for the Beam Ray stack (RHOAI 2.25 variant).
#
# The shared topology/API/completion assertions live in ../common/lib.sh. What
# this adds are checks for the 2.x-only machinery that the rhoai3 variant has
# no equivalent of, and that are the likeliest things to be silently wrong:
# the CodeFlare mTLS injection reaching the vLLM sidecar, and the NetworkPolicy
# that reopens port 8000.
#
# For model-behaviour coverage run the full suite instead:
#     cd ../../../../inference && BASE_URL=<url> ./test-inference-beam.sh
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"
load_config

echo "========================================="
echo "  Beam deployment smoke test (${VARIANT_NAME})"
echo "  Namespace: $NAMESPACE"
echo "========================================="

smoke_ray_topology || { smoke_summary; exit 1; }

# --- CodeFlare injection ---------------------------------------------------
echo
echo "=== CodeFlare injection (RHOAI 2.x) ==="

head_json="$(oc get pod "$HEAD" -n "$NAMESPACE" -o json 2>/dev/null || echo '{}')"

if printf '%s' "$head_json" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(c["name"]=="oauth-proxy" for c in d.get("spec",{}).get("containers",[])) else 1)' \
  2>/dev/null; then
  pass "oauth-proxy sidecar injected on the head"
else
  # Not fatal — an admin may have set rayDashboardOAuthEnabled=false — but it
  # does mean this cluster is not behaving the way this variant assumes.
  fail "no oauth-proxy sidecar (rayDashboardOAuthEnabled disabled, or not a 2.x cluster)"
fi

if printf '%s' "$head_json" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(c["name"]=="create-cert" for c in d.get("spec",{}).get("initContainers",[])) else 1)' \
  2>/dev/null; then
  pass "create-cert init container injected (mTLS on)"
  MTLS=1
else
  echo "  NOTE  no create-cert init container — mTLS appears disabled on this cluster"
  MTLS=0
fi

# This is the one that actually bites. The CodeFlare webhook writes the TLS env
# into container index 0 only, so a sidecar gets nothing; we set it by hand in
# yaml/raycluster.yaml. If that ever drifts, the driver cannot reach the GCS.
if [ "$MTLS" -eq 1 ]; then
  if printf '%s' "$head_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want = {"RAY_USE_TLS", "RAY_TLS_SERVER_CERT", "RAY_TLS_SERVER_KEY", "RAY_TLS_CA_CERT"}
for c in d.get("spec", {}).get("containers", []):
    if c["name"] == "vllm":
        have = {e["name"] for e in c.get("env", [])}
        missing = want - have
        sys.exit(1 if missing else 0)
sys.exit(1)
' 2>/dev/null; then
    pass "vLLM sidecar carries the RAY_TLS_* env (webhook only does container 0)"
  else
    fail "vLLM sidecar is missing RAY_TLS_* env — it cannot reach a TLS-enabled GCS"
  fi

  if oc exec -n "$NAMESPACE" "$HEAD" -c vllm -- \
       sh -c 'test -r /home/ray/workspace/tls/server.crt && test -r /home/ray/workspace/tls/ca.crt' \
       >/dev/null 2>&1; then
    pass "vLLM sidecar can read the injected certificates"
  else
    fail "vLLM sidecar cannot read /home/ray/workspace/tls/* — cert volumes not mounted"
  fi
fi

# --- NetworkPolicy ---------------------------------------------------------
echo
echo "=== NetworkPolicy ==="

if oc get networkpolicy beam-head-vllm -n "$NAMESPACE" >/dev/null 2>&1; then
  pass "beam-head-vllm present (reopens 8000; CodeFlare's head policy does not allow it)"
else
  fail "beam-head-vllm missing — the route to vLLM will time out"
fi

smoke_api || { smoke_summary; exit 1; }
smoke_completion
smoke_summary
