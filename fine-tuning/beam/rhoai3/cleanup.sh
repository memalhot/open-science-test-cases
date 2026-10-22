#!/bin/bash
# Remove the Beam fine-tuning resources (RHOAI 3.x).
#
#   ./cleanup.sh             # TrainJob, seed Job and validation leftovers
#   ./cleanup.sh --weights   # also the 1.2TB weight PVC
#   ./cleanup.sh --all       # everything, including the trained adapter
#
# The weight PVC survives by default: re-seeding it is a ~1003GB download.
VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$VARIANT_DIR/../common/lib.sh"

DROP_WEIGHTS=0
DROP_OUTPUT=0
for arg in "$@"; do
  case "$arg" in
    --weights) DROP_WEIGHTS=1 ;;
    --all)     DROP_WEIGHTS=1; DROP_OUTPUT=1 ;;
    *) echo "unknown argument: $arg (expected --weights or --all)" >&2; exit 1 ;;
  esac
done

oc project "${PROJECT}" >/dev/null

oc delete trainjob "${JOB_NAME}" -n "${PROJECT}" --ignore-not-found --as system:admin
oc delete job beam-train-seed -n "${PROJECT}" --ignore-not-found --as system:admin
oc delete pod beam-validate -n "${PROJECT}" --ignore-not-found --as system:admin
oc delete configmap beam-validate-src -n "${PROJECT}" --ignore-not-found --as system:admin

if [[ ${DROP_WEIGHTS} -eq 1 ]]; then
  oc delete pvc "${WEIGHTS_PVC}" -n "${PROJECT}" --ignore-not-found --as system:admin
  echo "Weight PVC deleted — the next ./fine-tune.sh re-downloads ~${BASE_WEIGHTS_GB}GB."
else
  echo "Kept PVC ${WEIGHTS_PVC} (re-run with: ./fine-tune.sh --skip-seed)"
fi

if [[ ${DROP_OUTPUT} -eq 1 ]]; then
  oc delete pvc "${OUTPUT_PVC}" -n "${PROJECT}" --ignore-not-found --as system:admin
  echo "Output PVC deleted — any trained adapter is gone."
else
  echo "Kept PVC ${OUTPUT_PVC} (holds the trained adapter)"
fi

echo "Done."
