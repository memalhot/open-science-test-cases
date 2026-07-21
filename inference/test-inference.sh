#!/bin/bash
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-granite-model}
MODEL_URL=${MODEL_URL:-}
RESULTS_DIR=${RESULTS_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results"}

if [[ -z "${MODEL_URL}" ]]; then
  MODEL_URL=$(oc get route "${MODEL_NAME}" -n "${PROJECT}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
  if [[ -z "${MODEL_URL}" ]]; then
    echo "Error: could not find route '${MODEL_NAME}' in project '${PROJECT}'" >&2
    exit 1
  fi
fi
echo "Model endpoint: ${MODEL_URL}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_DIR="${RESULTS_DIR}/${TIMESTAMP}-manual"
mkdir -p "${RUN_DIR}"

PASSED=0
FAILED=0

run_test() {
  local name="$1"
  local endpoint="$2"
  local payload="$3"
  local expected_code="${4:-200}"

  echo ""
  echo "--- ${name} ---"

  local start_ms
  start_ms=$(date +%s%N)

  local response
  response=$(curl -sk -w "\n%{http_code}" "${MODEL_URL}${endpoint}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>&1)

  local end_ms
  end_ms=$(date +%s%N)
  local elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))

  local http_code
  http_code=$(echo "${response}" | tail -1)
  local body
  body=$(echo "${response}" | sed '$d')

  echo "${body}" > "${RUN_DIR}/${name}.json"

  if [[ "${http_code}" -eq "${expected_code}" ]]; then
    echo "PASS (HTTP ${http_code}, ${elapsed_ms}ms)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (HTTP ${http_code}, expected ${expected_code}, ${elapsed_ms}ms)" >&2
    FAILED=$((FAILED + 1))
  fi

  echo "  Response: $(echo "${body}" | head -c 200)"
}

run_get_test() {
  local name="$1"
  local endpoint="$2"
  local expected_code="${3:-200}"

  echo ""
  echo "--- ${name} ---"

  local start_ms
  start_ms=$(date +%s%N)

  local response
  response=$(curl -sk -w "\n%{http_code}" "${MODEL_URL}${endpoint}" 2>&1)

  local end_ms
  end_ms=$(date +%s%N)
  local elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))

  local http_code
  http_code=$(echo "${response}" | tail -1)
  local body
  body=$(echo "${response}" | sed '$d')

  echo "${body}" > "${RUN_DIR}/${name}.json"

  if [[ "${http_code}" -eq "${expected_code}" ]]; then
    echo "PASS (HTTP ${http_code}, ${elapsed_ms}ms)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (HTTP ${http_code}, expected ${expected_code}, ${elapsed_ms}ms)" >&2
    FAILED=$((FAILED + 1))
  fi

  echo "  Response: $(echo "${body}" | head -c 200)"
}

echo "========================================="
echo "  Inference Tests"
echo "  Model: ${MODEL_NAME}"
echo "  Endpoint: ${MODEL_URL}"
echo "========================================="

# --- API availability ---

run_get_test "list-models" "/v1/models"

# --- Chat completions ---

run_test "chat-simple" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "What is 2+2?"}],
  "max_tokens": 20
}'

run_test "chat-system-prompt" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant. Answer concisely."},
    {"role": "user", "content": "What is the capital of France?"}
  ],
  "max_tokens": 20
}'

run_test "chat-multi-turn" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "user", "content": "My name is Alice."},
    {"role": "assistant", "content": "Hello Alice! How can I help you today?"},
    {"role": "user", "content": "What is my name?"}
  ],
  "max_tokens": 20
}'

run_test "chat-long-output" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Write a short paragraph about open source software."}],
  "max_tokens": 200
}'

run_test "chat-temperature-zero" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "What is 10 * 15?"}],
  "max_tokens": 20,
  "temperature": 0
}'

run_test "chat-temperature-high" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Tell me a joke."}],
  "max_tokens": 100,
  "temperature": 1.0
}'

# --- Text completions ---

run_test "completions-simple" "/v1/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "prompt": "The quick brown fox",
  "max_tokens": 30
}'

# --- Throughput test (sequential requests) ---

echo ""
echo "--- throughput-sequential (10 requests) ---"
total_ms=0
throughput_failures=0
for i in $(seq 1 10); do
  start_ms=$(date +%s%N)
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" "${MODEL_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "Say yes."}],
      "max_tokens": 5
    }')
  end_ms=$(date +%s%N)
  elapsed=$(( (end_ms - start_ms) / 1000000 ))
  total_ms=$((total_ms + elapsed))
  if [[ "${http_code}" -ne 200 ]]; then
    throughput_failures=$((throughput_failures + 1))
  fi
  echo "  Request ${i}: HTTP ${http_code}, ${elapsed}ms"
done
avg_ms=$((total_ms / 10))
echo "  Average: ${avg_ms}ms, Failures: ${throughput_failures}/10"
if [[ ${throughput_failures} -eq 0 ]]; then
  echo "PASS"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (${throughput_failures} failures)" >&2
  FAILED=$((FAILED + 1))
fi

# --- Concurrent requests ---

echo ""
echo "--- throughput-concurrent (5 parallel requests) ---"
PIDS=()
CONCURRENT_DIR="${RUN_DIR}/concurrent"
mkdir -p "${CONCURRENT_DIR}"
for i in $(seq 1 5); do
  curl -sk -o "${CONCURRENT_DIR}/resp-${i}.json" -w "%{http_code} %{time_total}\n" \
    "${MODEL_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "Say the number '"${i}"'."}],
      "max_tokens": 10
    }' > "${CONCURRENT_DIR}/status-${i}.txt" 2>&1 &
  PIDS+=($!)
done
concurrent_failures=0
for i in $(seq 1 5); do
  wait "${PIDS[$((i-1))]}" || true
  status=$(cat "${CONCURRENT_DIR}/status-${i}.txt" 2>/dev/null || echo "000 0")
  echo "  Request ${i}: ${status}"
  code=$(echo "${status}" | awk '{print $1}')
  if [[ "${code}" -ne 200 ]]; then
    concurrent_failures=$((concurrent_failures + 1))
  fi
done
if [[ ${concurrent_failures} -eq 0 ]]; then
  echo "PASS"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (${concurrent_failures}/5 failed)" >&2
  FAILED=$((FAILED + 1))
fi

# --- Summary ---

echo ""
echo "========================================="
echo "  Results: ${PASSED} passed, ${FAILED} failed"
echo "  Output:  ${RUN_DIR}"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
