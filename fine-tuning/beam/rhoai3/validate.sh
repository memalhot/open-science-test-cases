#!/bin/bash
# Validate the Beam LoRA fine-tuning recipe against a RHOAI 3.x cluster.
#
#   ./validate.sh              # capacity + manifests + (if the image exists) data pipeline
#   ./validate.sh --no-pod     # skip the in-cluster checks, don't need the training image
#
# This exists because Beam is too large to fine-tune on most clusters:
# Reflection's LoRA SFT recipe wants 8x B300 or 32x H100, and the BF16 base
# weights alone are 1003GB. Everything that CAN be verified without that
# hardware is verified here — cluster prerequisites, manifest correctness,
# LoRA target resolution against the real checkpoint, and the Harmony data
# pipeline — so the only untested variable left is the GPU count.
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"

RUN_POD=1
[[ "${1:-}" == "--no-pod" ]] && RUN_POD=0

echo "========================================="
echo "  Beam LoRA SFT — recipe validation (${VARIANT_NAME})"
echo "  Project: ${PROJECT}"
echo "========================================="

echo ""
echo "=== Prerequisites ==="
check_variant_matches_cluster

# Trainer v2: one TrainJob CRD plus reusable runtime blueprints.
if oc get crd trainjobs.trainer.kubeflow.org >/dev/null 2>&1; then
  pass "Kubeflow Trainer v2 (TrainJob CRD) installed"
else
  fail "TrainJob CRD missing — install the Kubeflow Trainer / RHOAI training component"
fi

if oc get clustertrainingruntime torch-distributed >/dev/null 2>&1; then
  pass "ClusterTrainingRuntime 'torch-distributed' available"
else
  fail "ClusterTrainingRuntime 'torch-distributed' not found"
fi

# Training Operator v1 is supported only through RHOAI 3.5 Full Support, so on
# a 3.x cluster it may or may not still be around. Either way it is not what
# this recipe uses — but it decides whether ../rhoai2/ would also run here.
if oc get crd pytorchjobs.kubeflow.org >/dev/null 2>&1; then
  note "legacy PyTorchJob CRD also present — ../rhoai2/ would run on this cluster too"
else
  note "legacy PyTorchJob CRD absent — ../rhoai2/ will NOT run here, and neither will ../../granite or ../../qwen"
fi

check_storage

echo ""
echo "=== Capacity ==="
check_capacity

echo ""
echo "=== Manifests ==="
oc project "${PROJECT}" >/dev/null 2>&1 || true
dryrun_template "${VARIANT_DIR}/trainjob.yaml" \
  -p IMAGE="${IMAGE}" -p MODEL_ID="${MODEL_ID}" \
  -p NUM_NODES="${NUM_NODES}" -p GPUS_PER_NODE="${GPUS_PER_NODE}"
dryrun_template "${COMMON_DIR}/seed-job.yaml" \
  -p IMAGE="${IMAGE}" -p MODEL_ID="${MODEL_ID}"

echo ""
echo "=== Data pipeline and LoRA targets ==="
if [[ ${RUN_POD} -eq 0 ]]; then
  note "--no-pod given; skipping the in-cluster checks"
else
  run_validation_pod
fi

echo ""
echo "========================================="
echo "  Validation: ${PASSED} passed, ${FAILED} failed"
echo "========================================="
[[ ${FAILED} -gt 0 ]] && exit 1
exit 0
