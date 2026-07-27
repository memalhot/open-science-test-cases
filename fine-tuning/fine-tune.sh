#!/bin/bash
set -euo pipefail

PROJECT=mm-test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS="${SCRIPT_DIR}/../model-serving/granite-model/credentials.env"

if [[ ! -f "${CREDENTIALS}" ]]; then
  echo "Error: credentials.env not found at ${CREDENTIALS}" >&2
  exit 1
fi
source "${CREDENTIALS}"

oc project "${PROJECT}"

# ---- Configuration (override via environment variables) ----
JOB_NAME="${JOB_NAME:-granite-fine-tune}"
BASE_MODEL_PATH="${BASE_MODEL_PATH:-models/granite-3.0-8b-instruct}"
OUTPUT_PATH="${OUTPUT_PATH:-models/granite-3.0-8b-instruct-finetuned}"
DATASET_NAME="${DATASET_NAME:-tatsu-lab/alpaca}"
NUM_EPOCHS="${NUM_EPOCHS:-3}"
LEARNING_RATE="${LEARNING_RATE:-2e-4}"
BATCH_SIZE="${BATCH_SIZE:-4}"
LORA_RANK="${LORA_RANK:-16}"
MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH:-2048}"
GPU_COUNT="${GPU_COUNT:-1}"

echo "=== Granite Fine-Tuning Job ==="
echo "Job name:       ${JOB_NAME}"
echo "Base model:     ${BASE_MODEL_PATH}"
echo "Output path:    ${OUTPUT_PATH}"
echo "Dataset:        ${DATASET_NAME}"
echo "Epochs:         ${NUM_EPOCHS}"
echo "Learning rate:  ${LEARNING_RATE}"
echo "Batch size:     ${BATCH_SIZE}"
echo "LoRA rank:      ${LORA_RANK}"
echo "Max seq length: ${MAX_SEQ_LENGTH}"
echo "GPUs:           ${GPU_COUNT}"
echo ""

# Clean up any previous run with the same name
echo "Cleaning up previous job (if any)..."
oc delete pytorchjob "${JOB_NAME}" --ignore-not-found --as system:admin
oc delete configmap "${JOB_NAME}-script" --ignore-not-found --as system:admin
sleep 2

echo "Deploying fine-tuning job..."
oc process -f "${SCRIPT_DIR}/fine-tune-job.yaml" \
  -p JOB_NAME="${JOB_NAME}" \
  -p BASE_MODEL_PATH="${BASE_MODEL_PATH}" \
  -p OUTPUT_PATH="${OUTPUT_PATH}" \
  -p DATASET_NAME="${DATASET_NAME}" \
  -p NUM_EPOCHS="${NUM_EPOCHS}" \
  -p LEARNING_RATE="${LEARNING_RATE}" \
  -p BATCH_SIZE="${BATCH_SIZE}" \
  -p LORA_RANK="${LORA_RANK}" \
  -p MAX_SEQ_LENGTH="${MAX_SEQ_LENGTH}" \
  -p GPU_COUNT="${GPU_COUNT}" \
  | oc apply --as system:admin -f -

echo ""
echo "Job submitted. Monitor with:"
echo "  oc get pytorchjob ${JOB_NAME}"
echo "  oc logs -f ${JOB_NAME}-master-0"
echo ""

# Wait for the job pod to appear
echo "Waiting for training pod to start..."
MAX_ATTEMPTS=90
POLL_INTERVAL=60
for (( i=1; i<=MAX_ATTEMPTS; i++ )); do
  POD_STATUS=$(oc get pod "${JOB_NAME}-master-0" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "${POD_STATUS}" == "Running" ]]; then
    echo "Training pod is running."
    echo "Streaming logs (Ctrl+C to detach — job continues in cluster):"
    echo ""
    oc logs -f "${JOB_NAME}-master-0" || true
    break
  elif [[ "${POD_STATUS}" == "Succeeded" ]]; then
    echo "Training already completed."
    break
  elif [[ "${POD_STATUS}" == "Failed" ]]; then
    echo "Error: training pod failed" >&2
    oc logs "${JOB_NAME}-master-0" 2>/dev/null || true
    exit 1
  fi
  echo "  Attempt ${i}/${MAX_ATTEMPTS}: pod status='${POD_STATUS:-Pending}', retrying in ${POLL_INTERVAL}s..."
  sleep "${POLL_INTERVAL}"
done

# Check final status
JOB_STATUS=$(oc get pytorchjob "${JOB_NAME}" -o jsonpath='{.status.conditions[-1:].type}' 2>/dev/null || echo "Unknown")
echo ""
echo "Final job status: ${JOB_STATUS}"

if [[ "${JOB_STATUS}" == "Succeeded" ]]; then
  echo ""
  echo "Fine-tuning complete!"
  echo "Adapter saved to: s3://${OUTPUT_PATH}"
  echo ""
  echo "To serve the fine-tuned model, merge the adapter with the base model"
  echo "or update your ServingRuntime to load the adapter at inference time."
fi
