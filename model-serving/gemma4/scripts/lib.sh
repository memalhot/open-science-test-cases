#!/usr/bin/env bash
# Shared helpers for up.sh / down.sh / test.sh. Source this; do not run directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_DIR="$ROOT_DIR/base"
OVERLAY_DIR="$ROOT_DIR/overlays/current"
APP_LABEL="app=gemma4-vllm"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%sxx%s  %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# Load config.conf, then let any pre-set environment variables win.
load_config() {
  need oc
  local cfg="${CONFIG_FILE:-$SCRIPT_DIR/config.conf}"
  [ -f "$cfg" ] || die "config not found: $cfg"
  local before; before="$(mktemp)"; declare -px >"$before"
  # shellcheck disable=SC1090
  set -a; source "$cfg"; set +a
  # Re-apply anything that was already exported in the environment (env > file).
  # shellcheck disable=SC1090
  source "$before"; rm -f "$before"
  : "${NAMESPACE:?}" "${IMAGE:?}" "${MODEL_ID:?}" "${SERVED_NAME:?}" \
    "${TP_SIZE:?}" "${MAX_MODEL_LEN:?}" "${GPU_MEM_UTIL:?}" \
    "${GPU_COUNT:?}" "${STORAGE_SIZE:?}"
  HF_TOKEN="${HF_TOKEN:-}"
  [ "$TP_SIZE" = "$GPU_COUNT" ] || warn "TP_SIZE ($TP_SIZE) != GPU_COUNT ($GPU_COUNT) — vLLM will likely fail to start."
}

route_url() {
  local host
  host="$(oc get route gemma4-vllm -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [ -n "$host" ] && printf 'https://%s' "$host"
}

pod_name() {
  oc get pod -l "$APP_LABEL" -n "$NAMESPACE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
