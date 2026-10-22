#!/usr/bin/env bash
# Shared helpers for the RHOAI 2.x and RHOAI 3.x Beam deployments.
#
# Source this from a variant's up.sh/down.sh/test.sh, which must set
# VARIANT_DIR to its own directory first:
#
#     VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     source "$VARIANT_DIR/../common/lib.sh"
#
# Everything that does not depend on the RHOAI generation lives here; the
# per-version differences are in each variant's yaml/ and its own up.sh.
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${VARIANT_DIR:?VARIANT_DIR must be set before sourcing lib.sh}"
# RHOAI generation this variant targets; used only for the preflight warning.
VARIANT_NAME="$(basename "$VARIANT_DIR")"

CLUSTER_NAME=beam
ROUTE_NAME=beam-infer

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%sxx%s  %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# Load config.conf, then let any pre-set environment variables win.
load_config() {
  need oc
  local cfg="${CONFIG_FILE:-$COMMON_DIR/config.conf}"
  # A bare CONFIG_FILE name (no slash) is resolved next to the shared config,
  # so `CONFIG_FILE=config.foo.conf ./up.sh` works from any directory.
  if [ ! -f "$cfg" ] && [ "${cfg##*/}" = "$cfg" ] && [ -f "$COMMON_DIR/$cfg" ]; then
    cfg="$COMMON_DIR/$cfg"
  fi
  [ -f "$cfg" ] || die "config not found: $cfg"
  # Values already set in the environment must win over the file. Snapshot the
  # env-provided keys as PLAIN assignments and re-apply after sourcing. (Using
  # `declare -px` does NOT work: `declare` inside a function makes the vars
  # function-local, so they vanish on return.)
  local __k __snap; __snap="$(mktemp)"
  for __k in NAMESPACE MODEL_ID SERVED_NAME IMAGE TP_SIZE HEAD_GPUS WORKER_GPUS \
             WORKER_REPLICAS RAY_VERSION MAX_MODEL_LEN GPU_MEM_UTIL MOE_BACKEND \
             KV_CACHE_DTYPE STORAGE_SIZE STORAGE_CLASS NCCL_IB_DISABLE \
             NCCL_SOCKET_IFNAME HF_TOKEN LOCAL_QUEUE; do
    [ -n "${!__k+x}" ] && printf '%s=%q\n' "$__k" "${!__k}" >>"$__snap"
  done
  # shellcheck disable=SC1090
  set -a; source "$cfg"; source "$__snap"; set +a
  rm -f "$__snap"

  : "${NAMESPACE:?}" "${MODEL_ID:?}" "${SERVED_NAME:?}" "${IMAGE:?}" \
    "${TP_SIZE:?}" "${HEAD_GPUS:?}" "${WORKER_GPUS:?}" "${WORKER_REPLICAS:?}" \
    "${MAX_MODEL_LEN:?}" "${GPU_MEM_UTIL:?}" "${STORAGE_SIZE:?}"
  HF_TOKEN="${HF_TOKEN:-}"
  MOE_BACKEND="${MOE_BACKEND:-}"
  KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"
  RAY_VERSION="${RAY_VERSION:-2.49.0}"
  STORAGE_CLASS="${STORAGE_CLASS:-pure-fb-nfsv4}"
  NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-1}"
  NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-eth0}"
  LOCAL_QUEUE="${LOCAL_QUEUE:-}"

  # The TP group is formed from the head pod's GPUs plus every worker pod's.
  # A mismatch here doesn't fail fast on its own — vLLM hangs waiting for ranks
  # that never join, which is a miserable thing to debug 40 minutes into a
  # model load.
  local total=$(( HEAD_GPUS + WORKER_REPLICAS * WORKER_GPUS ))
  [ "$TP_SIZE" -eq "$total" ] || die \
    "TP_SIZE ($TP_SIZE) must equal HEAD_GPUS + WORKER_REPLICAS*WORKER_GPUS ($total)"

  # PVC subpath the weights live under; basename of the HF repo id.
  MODEL_SUBPATH="${MODEL_ID##*/}"
  MODEL_PATH="/models/${MODEL_SUBPATH}"
}

# Render a template: substitute __PLACEHOLDERS__ from the loaded config.
# Looks in the variant's yaml/ first, then the shared common/yaml/, so a
# variant can override any shared manifest by adding a file of the same name.
render() {
  local f
  if   [ -f "$VARIANT_DIR/yaml/$1" ]; then f="$VARIANT_DIR/yaml/$1"
  elif [ -f "$COMMON_DIR/yaml/$1" ];  then f="$COMMON_DIR/yaml/$1"
  else die "template not found in $VARIANT_DIR/yaml or $COMMON_DIR/yaml: $1"
  fi
  sed -e "s|__NAMESPACE__|${NAMESPACE}|g" \
      -e "s|__IMAGE__|${IMAGE}|g" \
      -e "s|__MODEL_ID__|${MODEL_ID}|g" \
      -e "s|__MODEL_SUBPATH__|${MODEL_SUBPATH}|g" \
      -e "s|__MODEL_PATH__|${MODEL_PATH}|g" \
      -e "s|__SERVED_NAME__|${SERVED_NAME}|g" \
      -e "s|__TP_SIZE__|${TP_SIZE}|g" \
      -e "s|__HEAD_GPUS__|${HEAD_GPUS}|g" \
      -e "s|__WORKER_GPUS__|${WORKER_GPUS}|g" \
      -e "s|__WORKER_REPLICAS__|${WORKER_REPLICAS}|g" \
      -e "s|__RAY_VERSION__|${RAY_VERSION}|g" \
      -e "s|__MAX_MODEL_LEN__|${MAX_MODEL_LEN}|g" \
      -e "s|__GPU_MEM_UTIL__|${GPU_MEM_UTIL}|g" \
      -e "s|__MOE_BACKEND__|${MOE_BACKEND}|g" \
      -e "s|__KV_CACHE_DTYPE__|${KV_CACHE_DTYPE}|g" \
      -e "s|__STORAGE_SIZE__|${STORAGE_SIZE}|g" \
      -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
      -e "s|__NCCL_IB_DISABLE__|${NCCL_IB_DISABLE}|g" \
      -e "s|__NCCL_SOCKET_IFNAME__|${NCCL_SOCKET_IFNAME}|g" \
      -e "s|__LOCAL_QUEUE__|${LOCAL_QUEUE}|g" \
      "$f" \
    | queue_label_filter
}

# Drop the Kueue queue-name label entirely when LOCAL_QUEUE is unset. Leaving
# it present but empty is worse than omitting it: Kueue treats a labelled
# workload as one it manages, so an empty queue name means the RayCluster is
# admitted to nothing and the pods never appear, with no error on the object.
queue_label_filter() {
  if [ -z "${LOCAL_QUEUE}" ]; then
    grep -v 'kueue\.x-k8s\.io/queue-name'
  else
    cat
  fi
}

# Best-effort RHOAI generation, from the operator CSV version ("3.5.2" -> 3).
detected_rhoai_major() {
  oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -oE '^rhods-operator\.[0-9]+' | head -1 | cut -d. -f2
}

# Warn (don't fail) when the variant doesn't match the cluster. Guessing wrong
# produces failures a long way from the cause — a RayCluster that never gets
# its oauth sidecar, or a TrainJob the cluster has no controller for.
check_variant_matches_cluster() {
  local want="${VARIANT_NAME#rhoai}" got
  got="$(detected_rhoai_major)"
  if [ -z "$got" ]; then
    warn "could not detect the RHOAI version (no rhods-operator CSV); assuming this is a ${VARIANT_NAME} cluster"
  elif [ "$got" != "$want" ]; then
    warn "this is the ${VARIANT_NAME} variant but the cluster reports RHOAI ${got}.x — use ../rhoai${got}/ instead"
  else
    info "  RHOAI ${got}.x detected; matches the ${VARIANT_NAME} variant"
  fi
}

# Shared preflight: KubeRay present, and enough GPUs for one TP group.
check_gpu_capacity() {
  oc get crd rayclusters.ray.io >/dev/null 2>&1 \
    || die "RayCluster CRD not found — the KubeRay operator is not installed on this cluster"

  local gpus
  gpus=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
    | awk 'NF {sum += $1} END {print sum+0}')
  [ "$gpus" -ge "$TP_SIZE" ] \
    || die "cluster has $gpus allocatable GPU(s) but TP_SIZE=$TP_SIZE needs that many at once"
  info "  KubeRay present; $gpus GPU(s) allocatable cluster-wide (need $TP_SIZE)"
}

ensure_project() {
  if ! oc get project "$NAMESPACE" >/dev/null 2>&1; then
    info "Creating project $NAMESPACE"
    oc new-project "$NAMESPACE" >/dev/null
  fi
}

ensure_hf_secret() {
  if [ -n "$HF_TOKEN" ]; then
    info "Applying hf-token secret"
    oc create secret generic hf-token --from-literal=token="$HF_TOKEN" \
      -n "$NAMESPACE" --dry-run=client -o yaml | oc apply --as system:admin -f - >/dev/null
  else
    info "No HF_TOKEN set — skipping secret (Beam is Apache-2.0 and ungated)."
  fi
}

ensure_weights_pvc() {
  info "Ensuring weight PVC ($STORAGE_SIZE on $STORAGE_CLASS, RWX)"
  render weights-pvc.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -
}

# Stage the weights and (unless $1 is 0) block until the Job finishes.
seed_weights() {
  local wait="${1:-1}"
  info "Seeding weights ($MODEL_ID -> $MODEL_PATH)"
  oc delete job beam-seed -n "$NAMESPACE" --ignore-not-found --as system:admin >/dev/null
  render seed-job.yaml | oc apply --as system:admin -n "$NAMESPACE" -f -
  [ "$wait" -eq 1 ] || return 0

  info "Waiting for the seed Job (294GB across 53 shards — expect 30-90 min)..."
  echo "      follow it:  oc logs -f job/beam-seed -n $NAMESPACE"
  # `oc wait` only watches one condition, so a failed Job would sit here until
  # the timeout rather than reporting. Poll for either terminal state.
  local deadline; deadline=$(( $(date +%s) + 14400 ))
  while :; do
    if [ "$(oc get job beam-seed -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)" = "True" ]; then
      info "Seed complete."; return 0
    fi
    if [ "$(oc get job beam-seed -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)" = "True" ]; then
      die "seed Job failed — oc logs job/beam-seed -n $NAMESPACE"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "seed Job did not finish within 4h"
    sleep 30
  done
}

# Block until the Ray head pod is Ready, which (because of the vLLM sidecar's
# startupProbe) means the TP group formed and the model finished loading.
wait_for_serving() {
  info "Waiting for the Ray pods to be scheduled..."
  oc wait --for=condition=PodScheduled pod \
    -l "ray.io/cluster=${CLUSTER_NAME}" -n "$NAMESPACE" --timeout=600s >/dev/null \
    || die "Ray pods never scheduled — check GPU availability: oc get pods -l ray.io/cluster=$CLUSTER_NAME -n $NAMESPACE"

  info "Waiting for vLLM to load the model and report healthy..."
  echo "      this is the slow part: 294GB of weights over a TCP-backed TP group"
  echo "      follow it:  oc logs -f \$(oc get pod -l ray.io/cluster=$CLUSTER_NAME,ray.io/node-type=head -n $NAMESPACE -o name) -c vllm -n $NAMESPACE"
  oc wait --for=condition=Ready pod \
    -l "ray.io/cluster=${CLUSTER_NAME},ray.io/node-type=head" -n "$NAMESPACE" --timeout=5400s \
    || die "head pod never became Ready — inspect the vllm container logs"
}

route_url() {
  local host
  host="$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [ -n "$host" ] && printf 'https://%s' "$host"
  # Always succeed: a missing route yields empty output, not a non-zero exit.
  # Callers do `URL="$(route_url)"` under `set -e`, where a non-zero return
  # silently kills the whole script.
  return 0
}

head_pod() {
  oc get pod -n "$NAMESPACE" \
    -l "ray.io/cluster=${CLUSTER_NAME},ray.io/node-type=head" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Smoke-test helpers, shared by both variants' test.sh.
# These cover the deployment topology only. Model behaviour (Harmony channels,
# reasoning effort, tool calls, long context) is ../../../../inference's job.
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0
pass() { echo "  PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $*" >&2; FAILED=$((FAILED + 1)); }

# Sets HEAD to the head pod name; returns 1 if there isn't one.
smoke_ray_topology() {
  echo
  echo "=== Ray topology ==="

  HEAD="$(head_pod)"
  if [ -z "$HEAD" ]; then
    fail "no Ray head pod found (is the cluster up?)"
    return 1
  fi
  pass "head pod: $HEAD"

  local ray_gpus
  ray_gpus="$(oc exec -n "$NAMESPACE" "$HEAD" -c ray-head -- \
    python3 -c 'import ray; ray.init(address="127.0.0.1:6379", log_to_driver=False); print(int(ray.cluster_resources().get("GPU", 0)))' \
    2>/dev/null | tr -d '\r')"
  if [ "${ray_gpus:-0}" -eq "$TP_SIZE" ]; then
    pass "Ray cluster advertises $ray_gpus GPUs (= TP_SIZE)"
  else
    fail "Ray cluster advertises ${ray_gpus:-?} GPUs, expected $TP_SIZE"
  fi

  # The entire point of the Ray topology is that one TP group spans two
  # machines. If both pods landed on the same node the deployment is not
  # testing what we think it is (and could not have fit the weights anyway).
  local nodes
  nodes="$(oc get pods -n "$NAMESPACE" -l "ray.io/cluster=${CLUSTER_NAME}" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)"
  if [ "${nodes:-0}" -ge 2 ]; then
    pass "TP group spans $nodes nodes"
  else
    fail "all Ray pods are on ${nodes:-0} node(s) — expected the group to span 2"
  fi
}

# Sets URL to the route; returns 1 if there isn't one.
smoke_api() {
  echo
  echo "=== API ==="

  URL="$(route_url)"
  if [ -z "$URL" ]; then
    fail "route $ROUTE_NAME has no host yet"
    return 1
  fi
  pass "endpoint: $URL"

  local code models
  code="$(curl -sk -o /dev/null -w '%{http_code}' "${URL}/health" || true)"
  [ "$code" = "200" ] && pass "/health -> 200" || fail "/health -> ${code:-no response}"

  models="$(curl -sk "${URL}/v1/models" || true)"
  if printf '%s' "$models" | grep -q "\"$SERVED_NAME\""; then
    pass "/v1/models lists '$SERVED_NAME'"
  else
    fail "/v1/models did not list '$SERVED_NAME': $(printf '%s' "$models" | head -c 200)"
  fi
}

smoke_completion() {
  echo
  echo "=== Completion ==="

  local resp content
  resp="$(curl -sk "${URL}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "'"${SERVED_NAME}"'",
      "messages": [{"role": "user", "content": "What is 7 * 8? Reply with just the number."}],
      "max_tokens": 2048,
      "temperature": 0
    }' || true)"

  content="$(printf '%s' "$resp" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"].get("content") or "")' \
    2>/dev/null || true)"

  if printf '%s' "$content" | grep -q '56'; then
    pass "chat completion answered correctly: $(printf '%s' "$content" | head -c 60)"
  else
    fail "chat completion wrong or empty: $(printf '%s' "$resp" | head -c 200)"
  fi
}

smoke_summary() {
  echo
  echo "========================================="
  echo "  Results: ${PASSED} passed, ${FAILED} failed"
  echo "========================================="
  [ "$FAILED" -gt 0 ] && return 1
  echo
  echo "  Next:  cd ../../../../inference && BASE_URL=${URL} ./test-inference-beam.sh"
  return 0
}

print_ready_banner() {
  local url; url="$(route_url)"
  info "Ready. Endpoint: ${url:-<route pending>}"
  echo
  echo "  Smoke test:  ./test.sh"
  echo "  Full suite:  (cd ../../../../inference && BASE_URL=${url} MODEL_NAME=${SERVED_NAME} ./test-inference-beam.sh)"
  echo "  Variant:     ${VARIANT_NAME}"
  echo "  Model:       $MODEL_ID  (served as '$SERVED_NAME')"
  echo "  Parallelism: TP=$TP_SIZE over Ray — $HEAD_GPUS GPU on the head + $WORKER_REPLICAS x $WORKER_GPUS on workers"
  echo "  Context:     $MAX_MODEL_LEN tokens (Beam supports up to 1048576; raise MAX_MODEL_LEN until the KV cache no longer fits)"
  echo "  Ray status:  oc exec -n $NAMESPACE \$(oc get pod -l ray.io/cluster=$CLUSTER_NAME,ray.io/node-type=head -n $NAMESPACE -o name) -c ray-head -- ray status"
}
