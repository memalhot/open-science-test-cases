#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-granite-model}
TOKENIZER=${TOKENIZER:-ibm-granite/granite-3.0-8b-instruct}
BENCHMARK_KIND=${BENCHMARK_KIND:-sweep}
DURATION=${DURATION:-120s}
WARMUP=${WARMUP:-60s}
MAX_VUS=${MAX_VUS:-128}
NUM_RATES=${NUM_RATES:-10}
RESULTS_DIR=${RESULTS_DIR:-"${SCRIPT_DIR}/results"}
MODEL_URL=${MODEL_URL:-}

# Prompt/decode token settings for each run type
PROMPT_OPTIONS=${PROMPT_OPTIONS:-"num_tokens=200,max_tokens=250,min_tokens=150,variance=10"}
DECODE_OPTIONS=${DECODE_OPTIONS:-"num_tokens=100,max_tokens=150,min_tokens=50,variance=10"}

# Source HF token for tokenizer download
CREDENTIALS_FILE="${SCRIPT_DIR}/../model-serving/granite-model/credentials.env"
if [[ -f "${CREDENTIALS_FILE}" ]]; then
  source "${CREDENTIALS_FILE}"
  export HF_TOKEN="${ACCESS_TOKEN:-}"
fi

if ! command -v inference-benchmarker &>/dev/null; then
  echo "Error: inference-benchmarker not found in PATH" >&2
  echo "Install with: cargo install --git https://github.com/huggingface/inference-benchmarker/" >&2
  exit 1
fi

# Discover model endpoint from OpenShift route if not provided
if [[ -z "${MODEL_URL}" ]]; then
  echo "Discovering model endpoint..."
  MODEL_URL=$(oc get route "${MODEL_NAME}" -n "${PROJECT}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
  if [[ -z "${MODEL_URL}" ]]; then
    echo "Error: could not find route '${MODEL_NAME}' in project '${PROJECT}'" >&2
    echo "Set MODEL_URL directly if running outside the cluster." >&2
    exit 1
  fi
fi
echo "Model endpoint: ${MODEL_URL}"

# Verify model is responding with a real completion request
echo "Verifying model is responding..."
RESPONSE=$(curl -sk -w "\n%{http_code}" "${MODEL_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Say hello."}],
    "max_tokens": 10
  }')
HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
if [[ "${HTTP_CODE}" -ne 200 ]]; then
  echo "Error: model returned HTTP ${HTTP_CODE}, expected 200" >&2
  echo "Check: oc get inferenceservice ${MODEL_NAME} -n ${PROJECT}" >&2
  exit 1
fi
echo "Model is responding."

# Create timestamped results directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_DIR="${RESULTS_DIR}/${TIMESTAMP}"
mkdir -p "${RUN_DIR}"

cat > "${RUN_DIR}/config.json" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "model_url": "${MODEL_URL}",
  "model_name": "${MODEL_NAME}",
  "tokenizer": "${TOKENIZER}",
  "benchmark_kind": "${BENCHMARK_KIND}",
  "duration": "${DURATION}",
  "warmup": "${WARMUP}",
  "max_vus": "${MAX_VUS}",
  "num_rates": "${NUM_RATES}",
  "prompt_options": "${PROMPT_OPTIONS}",
  "decode_options": "${DECODE_OPTIONS}"
}
EOF

echo "Results directory: ${RUN_DIR}"
echo ""
echo "========================================="
echo "  Benchmark: ${BENCHMARK_KIND}"
echo "  Duration: ${DURATION}, Warmup: ${WARMUP}"
echo "  Max VUs: ${MAX_VUS}, Num rates: ${NUM_RATES}"
echo "========================================="

cd "${RUN_DIR}"

inference-benchmarker \
  --tokenizer-name "${TOKENIZER}" \
  --model-name "${MODEL_NAME}" \
  --url "${MODEL_URL}" \
  --benchmark-kind "${BENCHMARK_KIND}" \
  --max-vus "${MAX_VUS}" \
  --duration "${DURATION}" \
  --warmup "${WARMUP}" \
  --num-rates "${NUM_RATES}" \
  --prompt-options "${PROMPT_OPTIONS}" \
  --decode-options "${DECODE_OPTIONS}" \
  --no-console \
  2>&1 | tee benchmark.log

echo ""
echo "========================================="
echo "  Benchmark complete"
echo "  Results: ${RUN_DIR}"
echo "========================================="
