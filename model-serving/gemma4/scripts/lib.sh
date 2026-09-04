#!/usr/bin/env bash
# Shared helpers for up.sh / down.sh / test.sh. Source this; do not run directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_DIR="$ROOT_DIR/base"
COMPONENTS_DIR="$ROOT_DIR/components"
OVERLAY_DIR="$ROOT_DIR/overlays/current"
# APP_LABEL and ROUTE_NAME depend on SERVE_MODE; set by load_config.

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%sxx%s  %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# Extract an optional `--mode lazy|kserve` (or `--mode=lazy`) from a script's
# arguments and set SERVE_MODE from it. Call this BEFORE load_config: SERVE_MODE
# set here is snapshotted by load_config and so overrides config.conf, exactly
# like an env var would (env/config remain the default when no flag is passed).
# The remaining, non-mode arguments are returned in the global array REST_ARGS so
# the caller can restore them with:  set -- ${REST_ARGS[@]+"${REST_ARGS[@]}"}
# (that expansion is empty-array-safe under `set -u` on bash 3.2 / macOS).
parse_mode_flag() {
  REST_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)   shift; [ "$#" -gt 0 ] || die "--mode needs a value (lazy|kserve)"
                SERVE_MODE="$1" ;;
      --mode=*) SERVE_MODE="${1#--mode=}" ;;
      *)        REST_ARGS+=("$1") ;;
    esac
    shift
  done
}

# Load config.conf, then let any pre-set environment variables win.
load_config() {
  need oc
  local cfg="${CONFIG_FILE:-$SCRIPT_DIR/config.conf}"
  # Convenience: a bare CONFIG_FILE name (no slash) is resolved next to the
  # scripts, so `CONFIG_FILE=config.quantized.conf ./up.sh` works from anywhere,
  # not only from the scripts dir.
  if [ ! -f "$cfg" ] && [ "${cfg##*/}" = "$cfg" ] && [ -f "$SCRIPT_DIR/$cfg" ]; then
    cfg="$SCRIPT_DIR/$cfg"
  fi
  [ -f "$cfg" ] || die "config not found: $cfg"
  # Values already set in the environment must win over the file (e.g.
  #   SERVE_MODE=kserve ./up.sh). Snapshot the env-provided config keys as PLAIN
  # assignments and re-apply them after sourcing the file. (Re-sourcing
  # `declare -px` output does NOT work here: `declare` inside a function creates
  # function-local vars that vanish on return, so the env values were lost.)
  local __k __snap; __snap="$(mktemp)"
  for __k in NAMESPACE SERVE_MODE IMAGE MODEL_ID SERVED_NAME TP_SIZE \
             MAX_MODEL_LEN GPU_MEM_UTIL GPU_COUNT STORAGE_SIZE HF_TOKEN \
             MIN_REPLICAS MAX_REPLICAS SCALE_METRIC SCALE_TARGET; do
    [ -n "${!__k+x}" ] && printf '%s=%q\n' "$__k" "${!__k}" >>"$__snap"
  done
  # shellcheck disable=SC1090
  set -a; source "$cfg"; source "$__snap"; set +a
  rm -f "$__snap"
  : "${NAMESPACE:?}" "${IMAGE:?}" "${MODEL_ID:?}" "${SERVED_NAME:?}" \
    "${TP_SIZE:?}" "${MAX_MODEL_LEN:?}" "${GPU_MEM_UTIL:?}" \
    "${GPU_COUNT:?}" "${STORAGE_SIZE:?}"
  HF_TOKEN="${HF_TOKEN:-}"
  # Autoscaling knobs default to a fixed single replica (no HPA) so a config.conf
  # predating these keys keeps its original behavior.
  MIN_REPLICAS="${MIN_REPLICAS:-1}"
  MAX_REPLICAS="${MAX_REPLICAS:-1}"
  SCALE_METRIC="${SCALE_METRIC:-cpu}"
  SCALE_TARGET="${SCALE_TARGET:-60}"
  [ "$MAX_REPLICAS" -ge "$MIN_REPLICAS" ] \
    || die "MAX_REPLICAS ($MAX_REPLICAS) must be >= MIN_REPLICAS ($MIN_REPLICAS)"
  case "$SCALE_METRIC" in
    cpu|memory) ;;
    *) die "invalid SCALE_METRIC '$SCALE_METRIC' (RawDeployment HPA supports 'cpu' or 'memory'; concurrency/rps need Knative, vLLM metrics need KEDA)" ;;
  esac
  # Default to the original mechanism so pre-existing configs keep working.
  SERVE_MODE="${SERVE_MODE:-lazy}"
  case "$SERVE_MODE" in
    lazy)
      APP_LABEL="app=gemma4-vllm"
      ROUTE_NAME="gemma4-vllm"
      ;;
    kserve)
      # RawDeployment predictor pods carry this KServe label; the route is the
      # external edge route up.sh creates for the InferenceService. The route name
      # deliberately differs from the isvc name ('gemma4'): a route sharing the
      # isvc's name gets pruned by KServe while the isvc reconciles (it's a
      # cluster-local isvc), so we use a distinct name it never touches.
      APP_LABEL="serving.kserve.io/inferenceservice=gemma4"
      ROUTE_NAME="gemma4-infer"
      ;;
    *)
      die "invalid SERVE_MODE '$SERVE_MODE' (expected 'lazy' or 'kserve')"
      ;;
  esac
  # PVC subpath the weights live under (kserve seed + storageUri); basename of id.
  MODEL_SUBPATH="${MODEL_ID##*/}"
  [ "$TP_SIZE" = "$GPU_COUNT" ] || warn "TP_SIZE ($TP_SIZE) != GPU_COUNT ($GPU_COUNT) — vLLM will likely fail to start."
}

route_url() {
  local host
  host="$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [ -n "$host" ] && printf 'https://%s' "$host"
  # Always succeed: a missing route yields empty output, not a non-zero exit. The
  # bare `[ -n "$host" ] && ...` above returns 1 when host is empty, and callers
  # use `URL="$(route_url)"` under `set -e` — a non-zero return there silently
  # kills the whole script (no error), which once made test.sh exit blank.
  return 0
}

pod_name() {
  oc get pod -l "$APP_LABEL" -n "$NAMESPACE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
