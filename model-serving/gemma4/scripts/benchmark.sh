#!/usr/bin/env bash
# Load-test the running Gemma 4 endpoint from a SEPARATE in-cluster pod using
# guidellm (https://github.com/vllm-project/guidellm).
#   ./benchmark.sh                       # sweep, 60s, 256-in/128-out tokens
#   BENCH_MAX_SECONDS=120 ./benchmark.sh # longer run
#   SERVE_MODE=kserve ./benchmark.sh     # target the kserve endpoint
#
# Runs guidellm in its own pod and points it at the ClusterIP Service directly
# (plain HTTP — no router/TLS in the path), so the numbers reflect real
# client->server behavior. Mode-aware: resolves the right Service per SERVE_MODE.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

# --- tunable workload (env-overridable) ---
RATE_TYPE="${BENCH_RATE_TYPE:-sweep}"       # sweep | constant | throughput | ...
MAX_SECONDS="${BENCH_MAX_SECONDS:-60}"
PROMPT_TOKENS="${BENCH_PROMPT_TOKENS:-256}"
OUTPUT_TOKENS="${BENCH_OUTPUT_TOKENS:-128}"

# --- resolve the in-cluster target by serving mode ---
case "$SERVE_MODE" in
  lazy)   SVC="gemma4-vllm";     PORT=8000 ;;   # the lazy ClusterIP Service
  kserve) SVC="gemma4-external"; PORT=80  ;;    # the external Service up.sh creates (80->8080)
esac
TARGET="http://${SVC}.${NAMESPACE}.svc.cluster.local:${PORT}"

# The endpoint must already be up (this benchmarks it; it doesn't deploy it).
oc get svc "$SVC" -n "$NAMESPACE" >/dev/null 2>&1 \
  || die "Service '$SVC' not found in $NAMESPACE — is the $SERVE_MODE endpoint up? Run ./up.sh first."

info "Benchmarking $TARGET"
info "  model=$SERVED_NAME  tokenizer=$MODEL_ID  rate=$RATE_TYPE  ${MAX_SECONDS}s  ${PROMPT_TOKENS}in/${OUTPUT_TOKENS}out"

# Fresh run each time.
oc delete job gemma4-benchmark -n "$NAMESPACE" --ignore-not-found >/dev/null
sed -e "s|__TARGET__|${TARGET}|g" \
    -e "s|__SERVED_NAME__|${SERVED_NAME}|g" \
    -e "s|__MODEL_ID__|${MODEL_ID}|g" \
    -e "s|__RATE_TYPE__|${RATE_TYPE}|g" \
    -e "s|__MAX_SECONDS__|${MAX_SECONDS}|g" \
    -e "s|__PROMPT_TOKENS__|${PROMPT_TOKENS}|g" \
    -e "s|__OUTPUT_TOKENS__|${OUTPUT_TOKENS}|g" \
    "$SCRIPT_DIR/benchmark-pod.yaml" \
  | oc apply -n "$NAMESPACE" -f -

info "Waiting for the benchmark pod to start (pulls the guidellm image + tokenizer)..."
oc wait --for=condition=ready pod -l app=gemma4-benchmark -n "$NAMESPACE" --timeout=180s \
  || warn "pod not Ready yet — streaming logs anyway"

info "Streaming guidellm output (the summary table prints at the end)..."
oc logs -f job/gemma4-benchmark -n "$NAMESPACE" || true

echo
if oc wait --for=condition=complete job/gemma4-benchmark -n "$NAMESPACE" --timeout=10s >/dev/null 2>&1; then
  info "Benchmark complete. (Clean up with: oc delete job gemma4-benchmark -n $NAMESPACE)"
else
  warn "Benchmark job did not report 'complete'. Inspect:"
  warn "  oc logs job/gemma4-benchmark -n $NAMESPACE"
  warn "  oc describe job gemma4-benchmark -n $NAMESPACE"
fi
