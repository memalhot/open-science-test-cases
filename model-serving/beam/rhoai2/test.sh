#!/usr/bin/env bash
# Deployment smoke test for the Beam Ray stack (RHOAI 2.25 variant).
#
# The shared topology/API/completion assertions live in ../common/lib.sh. What
# this adds are checks for the 2.x-only machinery that the rhoai3 variant has
# no equivalent of, and that are the likeliest things to be silently wrong:
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

# The webhook writes the TLS env into container index 0 only. vLLM runs there
# now, so this should hold without us copying anything by hand — which is
# exactly why it is worth asserting: if the serving process were ever moved
# back out of container 0, it would silently lose its credentials and fail to
# reach a TLS-enabled GCS.
if [ "$MTLS" -eq 1 ]; then
  if printf '%s' "$head_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want = {"RAY_USE_TLS", "RAY_TLS_SERVER_CERT", "RAY_TLS_SERVER_KEY", "RAY_TLS_CA_CERT"}
for c in d.get("spec", {}).get("containers", []):
    if c["name"] == "ray-head":
        have = {e["name"] for e in c.get("env", [])}
        missing = want - have
        sys.exit(1 if missing else 0)
sys.exit(1)
' 2>/dev/null; then
    pass "serving container carries the RAY_TLS_* env (webhook injects container 0)"
  else
    fail "ray-head is missing RAY_TLS_* env — it cannot reach a TLS-enabled GCS"
  fi

  # --as system:admin: the Ray pods run under the operator's run-as-ray-user
  # SCC, so a plain `oc exec` is rejected and this would read as a missing
  # cert mount rather than a permissions problem.
  if oc exec -n "$NAMESPACE" "$HEAD" -c ray-head --as system:admin -- \
       sh -c 'test -r /home/ray/workspace/tls/server.crt && test -r /home/ray/workspace/tls/ca.crt' \
       >/dev/null 2>&1; then
    pass "serving container can read the injected certificates"
  else
    fail "ray-head cannot read /home/ray/workspace/tls/* — cert volumes not mounted"
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
