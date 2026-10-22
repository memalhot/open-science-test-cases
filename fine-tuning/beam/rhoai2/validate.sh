#!/bin/bash
# Validate the Beam LoRA fine-tuning recipe against a RHOAI 2.25 cluster.
#
#   ./validate.sh              # capacity + manifests + (if the image exists) data pipeline
#   ./validate.sh --no-pod     # skip the in-cluster checks, don't need the training image
#
# Same purpose as ../rhoai3/validate.sh: Beam is too large to fine-tune on
# most clusters (8x B300 or 32x H100; 1003GB of BF16 base weights), so verify
# everything that does not need that hardware. What differs here is the
# training stack being checked — Training Operator v1 and Kueue admission
# rather than Trainer v2 runtimes.
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"

LOCAL_QUEUE="${LOCAL_QUEUE:-}"
WORKER_REPLICAS=$(( NUM_NODES - 1 ))
RUN_POD=1
[[ "${1:-}" == "--no-pod" ]] && RUN_POD=0

echo "========================================="
echo "  Beam LoRA SFT — recipe validation (${VARIANT_NAME})"
echo "  Project: ${PROJECT}"
echo "========================================="

echo ""
echo "=== Prerequisites ==="
check_variant_matches_cluster

# Training Operator v1: one CRD per framework.
if oc get crd pytorchjobs.kubeflow.org >/dev/null 2>&1; then
  pass "Kubeflow Training Operator v1 (PyTorchJob CRD) installed"
else
  fail "PyTorchJob CRD missing — enable the trainingoperator component in the DataScienceCluster"
fi

if oc get crd trainjobs.trainer.kubeflow.org >/dev/null 2>&1; then
  note "Trainer v2 (TrainJob CRD) also present — ../rhoai3/ would run here too, and is the better choice"
fi

# On 2.x, distributed workloads are normally admitted through Kueue. A
# PyTorchJob that is never admitted just sits there with no pods and no event
# on the object itself, which is a confusing way to spend an afternoon.
if oc get crd clusterqueues.kueue.x-k8s.io >/dev/null 2>&1; then
  pass "Kueue installed"
  if [[ -n "${LOCAL_QUEUE}" ]]; then
    if oc get localqueue "${LOCAL_QUEUE}" -n "${PROJECT}" >/dev/null 2>&1; then
      pass "LocalQueue '${LOCAL_QUEUE}' exists in ${PROJECT}"
    else
      fail "LOCAL_QUEUE='${LOCAL_QUEUE}' not found in ${PROJECT} (oc get localqueue -n ${PROJECT})"
    fi
  else
    queues=$(oc get localqueue -n "${PROJECT}" -o name 2>/dev/null | wc -l)
    note "no LOCAL_QUEUE set; ${queues} LocalQueue(s) exist in ${PROJECT}. If admission is"
    note "mandatory on this cluster and there is no default, the job will never start."
  fi
else
  note "Kueue not installed — nothing will gate admission"
fi

check_storage

echo ""
echo "=== Capacity ==="
check_capacity
note "PyTorchJob splits this as 1 Master + ${WORKER_REPLICAS} Worker replicas"

echo ""
echo "=== Manifests ==="
oc project "${PROJECT}" >/dev/null 2>&1 || true
dryrun_template "${VARIANT_DIR}/pytorchjob.yaml" \
  -p IMAGE="${IMAGE}" -p MODEL_ID="${MODEL_ID}" \
  -p WORKER_REPLICAS="${WORKER_REPLICAS}" -p GPUS_PER_NODE="${GPUS_PER_NODE}" \
  -p LOCAL_QUEUE="${LOCAL_QUEUE}"
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
