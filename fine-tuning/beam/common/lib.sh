#!/usr/bin/env bash
# Shared helpers for the RHOAI 2.x and RHOAI 3.x Beam fine-tuning recipes.
#
# Source from a variant's script, which must set VARIANT_DIR first:
#
#     VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     source "$VARIANT_DIR/../common/lib.sh"
#
# Everything here is generation-independent: capacity arithmetic, the weight
# seed, and the CPU-only validation pod. The training CR itself (TrainJob vs
# PyTorchJob) and how you follow its logs live in each variant.
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${VARIANT_DIR:?VARIANT_DIR must be set before sourcing lib.sh}"
BEAM_DIR="$(cd "$COMMON_DIR/.." && pwd)"
VARIANT_NAME="$(basename "$VARIANT_DIR")"

PROJECT=${PROJECT:-mm-test}
JOB_NAME="${JOB_NAME:-beam-lora-sft}"
IMAGE="${IMAGE:-quay.io/memalhot/beam-fine-tune:latest}"
MODEL_ID="${MODEL_ID:-reflection/Beam-1.0-501B-A23B}"
MODEL_PATH="${MODEL_PATH:-/weights/Beam-1.0-501B-A23B}"
DATASET_NAME="${DATASET_NAME:-HuggingFaceH4/Multilingual-Thinking}"
NUM_NODES="${NUM_NODES:-4}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
NUM_EPOCHS="${NUM_EPOCHS:-1}"
LEARNING_RATE="${LEARNING_RATE:-1e-4}"
BATCH_SIZE="${BATCH_SIZE:-1}"
GRAD_ACCUM="${GRAD_ACCUM:-8}"
MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-4096}"
LORA_RANK="${LORA_RANK:-16}"
LORA_ALPHA="${LORA_ALPHA:-32}"
WEIGHTS_PVC="${WEIGHTS_PVC:-beam-train-weights}"
OUTPUT_PVC="${OUTPUT_PVC:-beam-train-output}"
# Attention + the three dense MLP layers (269 modules). See train.py for the
# full module map and the opt-in variant that also adapts the 37,632 expert
# projections.
DEFAULT_LORA_TARGETS='.*(self_attn\.(q|k|v|o|gate)_proj|layers\.[0-2]\.mlp\.(gate|up|down)_proj)$'
LORA_TARGET_REGEX=${LORA_TARGET_REGEX:-${DEFAULT_LORA_TARGETS}}
# Beam's BF16 base weights, in GB. The number the capacity check is really about.
BASE_WEIGHTS_GB=1003

PASSED=0
FAILED=0
pass() { echo "  PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $*" >&2; FAILED=$((FAILED + 1)); }
note() { echo "  NOTE  $*"; }

# Best-effort RHOAI generation, from the operator CSV version ("3.5.2" -> 3).
detected_rhoai_major() {
  oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -oE '^rhods-operator\.[0-9]+' | head -1 | cut -d. -f2
}

check_variant_matches_cluster() {
  local want="${VARIANT_NAME#rhoai}" got
  got="$(detected_rhoai_major)"
  if [ -z "$got" ]; then
    note "could not detect the RHOAI version (no rhods-operator CSV); assuming ${VARIANT_NAME}"
  elif [ "$got" != "$want" ]; then
    fail "this is the ${VARIANT_NAME} recipe but the cluster reports RHOAI ${got}.x — use ../rhoai${got}/"
  else
    pass "RHOAI ${got}.x detected; matches the ${VARIANT_NAME} recipe"
  fi
}

check_storage() {
  if oc get storageclass pure-fb-nfsv4 -o name >/dev/null 2>&1; then
    pass "RWX storage class pure-fb-nfsv4 present (needed: all nodes mount the weights)"
  else
    fail "no pure-fb-nfsv4 storage class — the recipe needs an RWX class for shared weights"
  fi
}

# The gap. Prints the arithmetic either way, because "it didn't fit" is the
# single most useful thing this whole directory has to say on most clusters.
check_capacity() {
  local needed available capable gpu_mem total_gb
  needed=$((NUM_NODES * GPUS_PER_NODE))
  available=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
    | awk 'NF {sum += $1} END {print sum+0}')
  capable=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
    | awk -v n="${GPUS_PER_NODE}" 'NF && $1 >= n {c++} END {print c+0}')
  gpu_mem=$(oc get nodes -o jsonpath='{.items[*].metadata.labels.nvidia\.com/gpu\.memory}' \
    | tr ' ' '\n' | sort -rn | head -1)
  gpu_mem=${gpu_mem:-0}
  total_gb=$(( available * gpu_mem / 1024 ))

  echo "  recipe target        : ${NUM_NODES} nodes x ${GPUS_PER_NODE} GPUs = ${needed} GPUs"
  echo "  cluster allocatable  : ${available} GPUs (${capable} node(s) with >= ${GPUS_PER_NODE} each)"
  echo "  aggregate GPU memory : ~${total_gb} GB"
  echo "  BF16 base weights    : ${BASE_WEIGHTS_GB} GB before optimizer state, activations or adapters"

  if [ "$available" -ge "$needed" ] && [ "$capable" -ge "$NUM_NODES" ]; then
    pass "cluster can run the full recipe"
  else
    fail "cluster cannot run the full recipe — ${available}/${needed} GPUs, ${capable}/${NUM_NODES} eligible nodes"
    if [ "$total_gb" -lt "$BASE_WEIGHTS_GB" ]; then
      note "aggregate GPU memory (~${total_gb} GB) is below the ${BASE_WEIGHTS_GB} GB of base weights:"
      note "no sharding, offload or sequence-length reduction makes this fit."
    fi
  fi
}

# Hard gate used by fine-tune.sh. Returns non-zero when the cluster is short.
capacity_ok() {
  local needed available
  needed=$((NUM_NODES * GPUS_PER_NODE))
  available=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
    | awk 'NF {sum += $1} END {print sum+0}')
  AVAILABLE_GPUS="$available"
  NEEDED_GPUS="$needed"
  [ "$available" -ge "$needed" ]
}

# oc process + server-side dry run for one template. Server-side is the real
# check: it runs CRD schema validation and admission webhooks without creating
# anything, which is what catches a mistyped field or a bad quantity.
dryrun_template() {
  local tpl="$1"; shift
  local name; name="$(basename "$tpl")"
  if oc process -n "${PROJECT}" -f "$tpl" "$@" >/dev/null 2>"${TMPDIR:-/tmp}/beam-process.err"; then
    pass "${name} processes cleanly"
  else
    fail "${name} failed to process:"
    sed 's/^/        /' "${TMPDIR:-/tmp}/beam-process.err" >&2
    return 1
  fi
  if oc process -n "${PROJECT}" -f "$tpl" "$@" \
     | oc apply --dry-run=server --as system:admin -n "${PROJECT}" -f - \
       >/dev/null 2>"${TMPDIR:-/tmp}/beam-dryrun.err"; then
    pass "${name} accepted by the API server (dry-run)"
  else
    fail "${name} rejected by the API server:"
    sed 's/^/        /' "${TMPDIR:-/tmp}/beam-dryrun.err" >&2
  fi
}

# CPU-only pod that checks the LoRA targets against the real checkpoint index
# and renders the dataset through Beam's chat template. Downloads no weights.
run_validation_pod() {
  local pod=beam-validate
  oc delete pod "$pod" -n "${PROJECT}" --ignore-not-found --as system:admin >/dev/null 2>&1 || true
  oc delete configmap beam-validate-src -n "${PROJECT}" --ignore-not-found --as system:admin >/dev/null 2>&1 || true

  oc create configmap beam-validate-src -n "${PROJECT}" \
    --from-file=train.py="${BEAM_DIR}/train.py" \
    --from-file=validate_in_cluster.py="${BEAM_DIR}/validate_in_cluster.py" \
    --as system:admin >/dev/null

  # No GPU request and no GPU toleration: this pod only reads the checkpoint
  # index and the tokenizer, so it must not occupy a GPU node.
  cat <<EOF | oc apply --as system:admin -n "${PROJECT}" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels: { app: beam-train }
spec:
  restartPolicy: Never
  containers:
    - name: validate
      image: ${IMAGE}
      command: ["python3", "/src/validate_in_cluster.py"]
      env:
        - { name: MODEL_ID, value: "${MODEL_ID}" }
        - { name: DATASET_NAME, value: "${DATASET_NAME}" }
        - { name: LORA_TARGET_REGEX, value: '${LORA_TARGET_REGEX}' }
        - { name: MAX_SEQ_LENGTH, value: "${MAX_SEQ_LENGTH}" }
        - { name: HOME, value: "/tmp" }
        - { name: HF_HOME, value: "/tmp/hf" }
        - { name: PYTHONPATH, value: "/src" }
      resources:
        requests: { cpu: "2", memory: 8Gi }
        limits: { memory: 16Gi }
      volumeMounts:
        - { name: src, mountPath: /src }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: src
      configMap: { name: beam-validate-src }
    - name: tmp
      emptyDir: {}
EOF

  echo "  running checks in pod ${pod}..."
  local deadline phase reason
  deadline=$(( $(date +%s) + 600 ))
  phase=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    phase=$(oc get pod "$pod" -n "${PROJECT}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    reason=$(oc get pod "$pod" -n "${PROJECT}" \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
    case "${reason}" in
      ErrImagePull|ImagePullBackOff|InvalidImageName)
        # The expected outcome when the training image hasn't been built yet.
        # Worth reporting as such, not as a pipeline failure.
        fail "cannot pull ${IMAGE} (${reason}) — build and push it first:"
        echo "        podman build -t ${IMAGE} -f Containerfile .." >&2
        echo "        podman push ${IMAGE}" >&2
        phase="ImageError"
        break
        ;;
    esac
    [ "${phase}" = "Succeeded" ] || [ "${phase}" = "Failed" ] && break
    sleep 5
  done

  case "${phase}" in
    Succeeded) oc logs "$pod" -n "${PROJECT}" | sed 's/^/  /'; pass "in-cluster checks passed" ;;
    Failed)    oc logs "$pod" -n "${PROJECT}" 2>/dev/null | sed 's/^/  /' || true
               fail "in-cluster checks failed" ;;
    ImageError) ;;
    *)         fail "validation pod did not finish within 10m (phase=${phase:-unknown})" ;;
  esac

  oc delete pod "$pod" -n "${PROJECT}" --ignore-not-found --as system:admin >/dev/null 2>&1 || true
  oc delete configmap beam-validate-src -n "${PROJECT}" --ignore-not-found --as system:admin >/dev/null 2>&1 || true
}

# Stage the BF16 base weights onto the weight PVC and wait for completion.
seed_weights() {
  echo "Seeding base weights (~${BASE_WEIGHTS_GB}GB; hours, and resumable)..."
  oc delete job beam-train-seed -n "${PROJECT}" --ignore-not-found --as system:admin >/dev/null
  oc process -n "${PROJECT}" -f "${COMMON_DIR}/seed-job.yaml" \
    -p IMAGE="${IMAGE}" \
    -p MODEL_ID="${MODEL_ID}" \
    -p MODEL_PATH="${MODEL_PATH}" \
    -p WEIGHTS_PVC="${WEIGHTS_PVC}" \
    | oc apply --as system:admin -n "${PROJECT}" -f -
  echo "  follow it:  oc logs -f job/beam-train-seed -n ${PROJECT}"
  echo "  Waiting for the seed Job..."
  local deadline; deadline=$(( $(date +%s) + 86400 ))
  while :; do
    if [ "$(oc get job beam-train-seed -n "${PROJECT}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)" = "True" ]; then
      echo "  Seed complete."; return 0
    fi
    if [ "$(oc get job beam-train-seed -n "${PROJECT}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)" = "True" ]; then
      echo "Error: seed Job failed — oc logs job/beam-train-seed -n ${PROJECT}" >&2; exit 1
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { echo "Error: seed did not finish within 24h" >&2; exit 1; }
    sleep 60
  done
}

# Follow rank 0's logs. $1 is the label selector that identifies the job's pods.
follow_rank_zero() {
  local selector="$1" pod phase
  echo "Waiting for rank 0 to start..."
  for (( i=1; i<=120; i++ )); do
    pod=$(oc get pods -n "${PROJECT}" -l "$selector" \
      --sort-by=.metadata.name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${pod}" ]; then
      phase=$(oc get pod "${pod}" -n "${PROJECT}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      case "${phase}" in
        Running)
          echo "Rank 0 is running. Streaming logs (Ctrl+C detaches; the job continues):"
          echo ""
          oc logs -f "${pod}" -n "${PROJECT}" || true
          return 0 ;;
        Succeeded) echo "Training already completed."; return 0 ;;
        Failed)
          echo "Error: rank 0 failed" >&2
          oc logs "${pod}" -n "${PROJECT}" 2>/dev/null || true
          return 1 ;;
      esac
      echo "  Attempt ${i}/120: ${pod} is ${phase:-Pending}..."
    else
      echo "  Attempt ${i}/120: no pods yet..."
    fi
    sleep 30
  done
}

print_params() {
  echo "=== Beam 1.0 LoRA SFT (${VARIANT_NAME}) ==="
  echo "Job name:       ${JOB_NAME}"
  echo "Image:          ${IMAGE}"
  echo "Base model:     ${MODEL_ID}"
  echo "Dataset:        ${DATASET_NAME}"
  echo "Topology:       ${NUM_NODES} nodes x ${GPUS_PER_NODE} GPUs"
  echo "Epochs / LR:    ${NUM_EPOCHS} / ${LEARNING_RATE}"
  echo "Batch / accum:  ${BATCH_SIZE} / ${GRAD_ACCUM}"
  echo "LoRA:           r=${LORA_RANK} alpha=${LORA_ALPHA}"
  echo "Max seq length: ${MAX_SEQ_LENGTH}"
  echo ""
}
