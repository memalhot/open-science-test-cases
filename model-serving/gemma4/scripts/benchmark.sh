#!/usr/bin/env bash
# Load-test the running Gemma 4 endpoint from a SEPARATE in-cluster pod. Two tools
# are supported (pick with --tool or BENCH_TOOL); both hit the ClusterIP Service
# directly (plain HTTP, no router/TLS), so numbers reflect real client->server
# behavior over the cluster network.
#   guidellm       https://github.com/vllm-project/guidellm      (default; sweep)
#   inference-perf https://github.com/kubernetes-sigs/inference-perf (constant rate)
#
#   ./benchmark.sh                          # guidellm sweep, 60s, 256-in/128-out
#   ./benchmark.sh --tool inference-perf    # inference-perf, constant BENCH_RATE q/s
#   ./benchmark.sh --mode kserve            # override SERVE_MODE (else config.conf/env)
#   BENCH_MAX_SECONDS=120 ./benchmark.sh    # longer run
#
# Mode-aware: resolves the right Service per SERVE_MODE. The endpoint must already
# be up (this benchmarks it; it doesn't deploy it).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
parse_mode_flag "$@"; set -- ${REST_ARGS[@]+"${REST_ARGS[@]}"}
load_config

# --- tool selection (--tool wins over BENCH_TOOL) ---
TOOL="${BENCH_TOOL:-guidellm}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)   shift; [ "$#" -gt 0 ] || die "--tool needs a value (guidellm|inference-perf)"
              TOOL="$1" ;;
    --tool=*) TOOL="${1#--tool=}" ;;
    *)        die "unknown flag: $1" ;;
  esac
  shift
done
case "$TOOL" in guidellm|inference-perf) ;; *) die "invalid --tool '$TOOL' (guidellm|inference-perf)" ;; esac

# --- tunable workload (env-overridable) ---
# guidellm: RATE_TYPE feeds `--profile kind=...` (sweep|throughput|synchronous —
# stick to these; constant/poisson also need a rate and aren't wired up).
RATE_TYPE="${BENCH_RATE_TYPE:-sweep}"
# inference-perf: a single constant rate in requests/sec (guidellm sweeps instead).
RATE="${BENCH_RATE:-8}"
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

info "Benchmarking $TARGET  (tool=$TOOL)"

# Fresh run each time — both tools use Job/ConfigMap named gemma4-benchmark[-config].
oc delete job gemma4-benchmark -n "$NAMESPACE" --ignore-not-found >/dev/null
oc delete configmap gemma4-benchmark-config -n "$NAMESPACE" --ignore-not-found >/dev/null

if [ "$TOOL" = "guidellm" ]; then
  info "  model=$SERVED_NAME  tokenizer=$MODEL_ID  profile=$RATE_TYPE  ${MAX_SECONDS}s  ${PROMPT_TOKENS}in/${OUTPUT_TOKENS}out"
  sed -e "s|__TARGET__|${TARGET}|g" \
      -e "s|__SERVED_NAME__|${SERVED_NAME}|g" \
      -e "s|__MODEL_ID__|${MODEL_ID}|g" \
      -e "s|__RATE_TYPE__|${RATE_TYPE}|g" \
      -e "s|__MAX_SECONDS__|${MAX_SECONDS}|g" \
      -e "s|__PROMPT_TOKENS__|${PROMPT_TOKENS}|g" \
      -e "s|__OUTPUT_TOKENS__|${OUTPUT_TOKENS}|g" \
      "$SCRIPT_DIR/benchmark-pod.yaml" \
    | oc apply -n "$NAMESPACE" -f -
  progress_note="a sweep runs ~10 sub-benchmarks; the summary tables print at the end"
  results_note="Full JSON/CSV live in the pod at /tmp/benchmarks.{json,csv}"
  results_glob="/tmp/benchmarks.json"
else
  info "  model=$SERVED_NAME  tokenizer=$MODEL_ID  rate=${RATE}q/s  ${MAX_SECONDS}s  ${PROMPT_TOKENS}in/${OUTPUT_TOKENS}out"
  sed -e "s|__TARGET__|${TARGET}|g" \
      -e "s|__SERVED_NAME__|${SERVED_NAME}|g" \
      -e "s|__MODEL_ID__|${MODEL_ID}|g" \
      -e "s|__RATE__|${RATE}|g" \
      -e "s|__MAX_SECONDS__|${MAX_SECONDS}|g" \
      -e "s|__PROMPT_TOKENS__|${PROMPT_TOKENS}|g" \
      -e "s|__OUTPUT_TOKENS__|${OUTPUT_TOKENS}|g" \
      "$SCRIPT_DIR/benchmark-inferenceperf.yaml" \
    | oc apply -n "$NAMESPACE" -f -
  progress_note="runs the constant-rate stage; the summary table prints at the end"
  results_note="Reports written in the pod under /tmp/reports-*/"
  results_glob="/tmp/reports-*"
fi

info "Waiting for the benchmark pod to start (pulls the $TOOL image + tokenizer)..."
oc wait --for=condition=ready pod -l app=gemma4-benchmark -n "$NAMESPACE" --timeout=240s \
  || warn "pod not Ready yet — streaming logs anyway"

info "Streaming $TOOL output ($progress_note)..."
# `oc logs -f` frequently drops ("unexpected EOF") before a multi-minute run
# finishes — that is NOT a job failure, so don't treat the stream ending as done.
oc logs -f job/gemma4-benchmark -n "$NAMESPACE" 2>/dev/null || true

# The stream may have ended early; poll the Job's own conditions for the real
# outcome (fast when already done, waits when the stream just dropped mid-run).
info "Waiting for the benchmark Job to finish..."
final=""; deadline=$(( $(date +%s) + 1800 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  final="$(oc get job gemma4-benchmark -n "$NAMESPACE" \
    -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{"\n"}{end}' \
    2>/dev/null | grep -E 'Complete|Failed' | head -1 || true)"
  [ -n "$final" ] && break
  sleep 5
done

echo
if [ "$final" = "Complete" ]; then
  info "===== final results (re-printed in case the stream dropped) ====="
  oc logs job/gemma4-benchmark -n "$NAMESPACE" 2>/dev/null | tail -45
  echo
  bpod="$(oc get pod -l app=gemma4-benchmark -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  info "Benchmark complete. $results_note:"
  [ -n "$bpod" ] && info "  oc cp $NAMESPACE/$bpod:$results_glob ./  (copy results out before teardown)"
  info "  Clean up: oc delete job gemma4-benchmark -n $NAMESPACE   (or ./down.sh)"
else
  warn "Benchmark Job did not complete (${final:-still running/timed out}). Inspect:"
  warn "  oc logs job/gemma4-benchmark -n $NAMESPACE"
  warn "  oc describe job gemma4-benchmark -n $NAMESPACE"
fi
