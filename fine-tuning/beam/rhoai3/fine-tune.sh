#!/bin/bash
# Submit the Beam 1.0 LoRA SFT TrainJob (RHOAI 3.x) and stream its logs.
#
#   ./validate.sh      # ALWAYS run this first — see ../README.md
#   ./fine-tune.sh     # seed weights (once), submit the TrainJob, follow logs
#   ./fine-tune.sh --skip-seed
#
# Refuses to submit when the cluster has fewer GPUs than the recipe needs,
# because the failure mode otherwise is a TrainJob that sits Pending forever
# while holding a 1.2TB PVC. Override with FORCE=1 if you know better.
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"

FORCE="${FORCE:-0}"
SKIP_SEED=0
for arg in "$@"; do
  case "$arg" in
    --skip-seed) SKIP_SEED=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

oc project "${PROJECT}" >/dev/null
print_params

if ! capacity_ok; then
  echo "Cluster has ${AVAILABLE_GPUS} allocatable GPU(s); this recipe needs ${NEEDED_GPUS}." >&2
  echo "" >&2
  echo "Beam's BF16 base weights are ${BASE_WEIGHTS_GB}GB — more than the aggregate GPU" >&2
  echo "memory available here — so the run cannot complete, not merely run slowly." >&2
  echo "Run ./validate.sh for the full picture." >&2
  if [[ "${FORCE}" != "1" ]]; then
    echo "" >&2
    echo "Refusing to submit. Set FORCE=1 to override." >&2
    exit 1
  fi
  echo "FORCE=1 set — submitting anyway." >&2
  echo ""
fi

if [[ ${SKIP_SEED} -eq 0 ]]; then
  seed_weights
else
  echo "--skip-seed given; assuming weights are at ${MODEL_PATH}"
fi

echo ""
echo "Cleaning up any previous run..."
oc delete trainjob "${JOB_NAME}" -n "${PROJECT}" --ignore-not-found --as system:admin >/dev/null
sleep 2

echo "Submitting TrainJob..."
oc process -n "${PROJECT}" -f "${VARIANT_DIR}/trainjob.yaml" \
  -p JOB_NAME="${JOB_NAME}" \
  -p IMAGE="${IMAGE}" \
  -p MODEL_ID="${MODEL_ID}" \
  -p MODEL_PATH="${MODEL_PATH}" \
  -p DATASET_NAME="${DATASET_NAME}" \
  -p NUM_NODES="${NUM_NODES}" \
  -p GPUS_PER_NODE="${GPUS_PER_NODE}" \
  -p NUM_EPOCHS="${NUM_EPOCHS}" \
  -p LEARNING_RATE="${LEARNING_RATE}" \
  -p BATCH_SIZE="${BATCH_SIZE}" \
  -p GRAD_ACCUM="${GRAD_ACCUM}" \
  -p MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH}" \
  -p LORA_RANK="${LORA_RANK}" \
  -p LORA_ALPHA="${LORA_ALPHA}" \
  -p LORA_TARGET_REGEX="${LORA_TARGET_REGEX}" \
  -p WEIGHTS_PVC="${WEIGHTS_PVC}" \
  -p OUTPUT_PVC="${OUTPUT_PVC}" \
  | oc apply --as system:admin -n "${PROJECT}" -f -

echo ""
echo "Submitted. Monitor with:"
echo "  oc get trainjob ${JOB_NAME} -n ${PROJECT}"
echo "  oc get pods -l trainer.kubeflow.org/trainjob-name=${JOB_NAME} -n ${PROJECT}"
echo ""

follow_rank_zero "trainer.kubeflow.org/trainjob-name=${JOB_NAME}" || exit 1

STATUS=$(oc get trainjob "${JOB_NAME}" -n "${PROJECT}" \
  -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null || echo "Unknown")
echo ""
echo "Final TrainJob status: ${STATUS}"
if [[ "${STATUS}" == "Complete" ]]; then
  echo ""
  echo "Fine-tuning complete. Adapter is on PVC ${OUTPUT_PVC} at /output/${JOB_NAME}."
  echo "To serve it, either merge it into the base weights or load it as a LoRA"
  echo "adapter in the vLLM runtime (see ../../../model-serving/beam/README.md)."
fi
