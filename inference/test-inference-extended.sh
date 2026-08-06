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
RUN_DIR="${RESULTS_DIR}/${TIMESTAMP}-extended"
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
  echo "${body}"
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
  echo "${body}"
}

assert_contains() {
  local name="$1"
  local file="${RUN_DIR}/${name}.json"
  local pattern="$2"

  if grep -qi "${pattern}" "${file}" 2>/dev/null; then
    echo "  Content check '${pattern}': PASS"
    PASSED=$((PASSED + 1))
  else
    echo "  Content check '${pattern}': FAIL (not found in response)" >&2
    FAILED=$((FAILED + 1))
  fi
}

assert_json_field() {
  local name="$1"
  local file="${RUN_DIR}/${name}.json"
  local field="$2"

  if python3 -c "
import json, sys
data = json.load(open('${file}'))
keys = '${field}'.split('.')
obj = data
for k in keys:
    if isinstance(obj, list):
        obj = obj[int(k)]
    else:
        obj = obj[k]
print(obj)
" 2>/dev/null; then
    echo "  Field '${field}': PASS"
    PASSED=$((PASSED + 1))
  else
    echo "  Field '${field}': FAIL (missing or not accessible)" >&2
    FAILED=$((FAILED + 1))
  fi
}

echo "========================================="
echo "  Extended Inference Tests"
echo "  Model: ${MODEL_NAME}"
echo "  Endpoint: ${MODEL_URL}"
echo "========================================="

# ===========================================
# 1. Health & readiness endpoints
# ===========================================

echo ""
echo "=== Health & Readiness ==="

run_get_test "health-check" "/health"
run_get_test "readiness-check" "/ready" 200

# ===========================================
# 2. Response content validation
# ===========================================

echo ""
echo "=== Content Validation ==="

run_test "content-math" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "What is 7 * 8? Reply with just the number."}],
  "max_tokens": 10,
  "temperature": 0
}'
assert_contains "content-math" "56"

run_test "content-capital" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "system", "content": "Answer in one word only."},
    {"role": "user", "content": "What is the capital of Japan?"}
  ],
  "max_tokens": 10,
  "temperature": 0
}'
assert_contains "content-capital" "Tokyo"

run_test "content-recall" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "user", "content": "My favorite color is blue."},
    {"role": "assistant", "content": "That is a nice color!"},
    {"role": "user", "content": "What is my favorite color?"}
  ],
  "max_tokens": 20,
  "temperature": 0
}'
assert_contains "content-recall" "blue"

# ===========================================
# 3. Response schema validation
# ===========================================

echo ""
echo "=== Schema Validation ==="

run_test "schema-chat" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Hello."}],
  "max_tokens": 10
}'
assert_json_field "schema-chat" "id"
assert_json_field "schema-chat" "object"
assert_json_field "schema-chat" "choices.0.message.role"
assert_json_field "schema-chat" "choices.0.message.content"
assert_json_field "schema-chat" "choices.0.finish_reason"
assert_json_field "schema-chat" "usage.prompt_tokens"
assert_json_field "schema-chat" "usage.completion_tokens"
assert_json_field "schema-chat" "usage.total_tokens"

run_test "schema-completions" "/v1/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "prompt": "Hello",
  "max_tokens": 10
}'
assert_json_field "schema-completions" "id"
assert_json_field "schema-completions" "choices.0.text"
assert_json_field "schema-completions" "usage.prompt_tokens"

# ===========================================
# 4. Determinism (temperature=0)
# ===========================================

echo ""
echo "=== Determinism ==="

echo ""
echo "--- determinism-temperature-zero ---"
responses=()
for i in $(seq 1 3); do
  resp=$(curl -sk "${MODEL_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "What is 12 + 13? Reply with just the number."}],
      "max_tokens": 10,
      "temperature": 0
    }')
  content=$(echo "${resp}" | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "ERROR")
  responses+=("${content}")
  echo "  Run ${i}: ${content}"
done
if [[ "${responses[0]}" == "${responses[1]}" && "${responses[1]}" == "${responses[2]}" ]]; then
  echo "PASS (all 3 responses identical)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (responses differ across runs)" >&2
  FAILED=$((FAILED + 1))
fi

# ===========================================
# 5. Token limit enforcement
# ===========================================

echo ""
echo "=== Token Limits ==="

run_test "token-limit-1" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Write a very long essay about the history of computing."}],
  "max_tokens": 5
}'
echo ""
echo "--- token-limit-check ---"
token_count=$(python3 -c "
import json
data = json.load(open('${RUN_DIR}/token-limit-1.json'))
print(data.get('usage', {}).get('completion_tokens', -1))
" 2>/dev/null || echo "-1")
if [[ "${token_count}" -gt 0 && "${token_count}" -le 10 ]]; then
  echo "PASS (completion_tokens=${token_count}, max_tokens=5)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (completion_tokens=${token_count}, expected <=10 for max_tokens=5)" >&2
  FAILED=$((FAILED + 1))
fi

# ===========================================
# 6. Streaming (SSE)
# ===========================================

echo ""
echo "=== Streaming ==="

echo ""
echo "--- streaming-chat ---"
stream_resp=$(curl -sk "${MODEL_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Say hello."}],
    "max_tokens": 20,
    "stream": true
  }' 2>&1)
echo "${stream_resp}" > "${RUN_DIR}/streaming-chat.txt"

chunk_count=$(echo "${stream_resp}" | grep -c "^data: " || true)
has_done=$(echo "${stream_resp}" | grep -c "data: \[DONE\]" || true)

if [[ ${chunk_count} -gt 1 && ${has_done} -ge 1 ]]; then
  echo "PASS (${chunk_count} SSE chunks, [DONE] present)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (chunks=${chunk_count}, done=${has_done})" >&2
  FAILED=$((FAILED + 1))
fi

echo ""
echo "--- streaming-has-role-in-first-chunk ---"
first_chunk=$(echo "${stream_resp}" | grep "^data: {" | head -1 | sed 's/^data: //')
has_role=$(echo "${first_chunk}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
delta = data.get('choices', [{}])[0].get('delta', {})
print('yes' if 'role' in delta else 'no')
" 2>/dev/null || echo "no")
if [[ "${has_role}" == "yes" ]]; then
  echo "PASS (first chunk contains role)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (first chunk missing role)" >&2
  FAILED=$((FAILED + 1))
fi

# ===========================================
# 7. Error handling
# ===========================================

echo ""
echo "=== Error Handling ==="

run_test "error-wrong-model" "/v1/chat/completions" '{
  "model": "nonexistent-model",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 10
}' 404

run_test "error-empty-messages" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [],
  "max_tokens": 10
}' 400

run_test "error-missing-messages" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "max_tokens": 10
}' 400

run_test "error-negative-max-tokens" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": -1
}' 400

run_test "error-invalid-temperature" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 10,
  "temperature": 5.0
}' 400

# ===========================================
# 8. Large input context
# ===========================================

echo ""
echo "=== Large Input ==="

echo ""
echo "--- large-input-context ---"
long_prompt=$(python3 -c "print('Repeat after me: hello. ' * 200)")
start_ms=$(date +%s%N)
large_resp=$(curl -sk -w "\n%{http_code}" "${MODEL_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "'"${long_prompt}"'"}],
    "max_tokens": 20
  }' 2>&1)
end_ms=$(date +%s%N)
elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))
http_code=$(echo "${large_resp}" | tail -1)
body=$(echo "${large_resp}" | sed '$d')
echo "${body}" > "${RUN_DIR}/large-input-context.json"
if [[ "${http_code}" -eq 200 ]]; then
  echo "PASS (HTTP ${http_code}, ${elapsed_ms}ms)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (HTTP ${http_code}, ${elapsed_ms}ms)" >&2
  FAILED=$((FAILED + 1))
fi

# ===========================================
# 9. Latency SLO check
# ===========================================

echo ""
echo "=== Latency SLO ==="

LATENCY_SLO_MS=${LATENCY_SLO_MS:-10000}

echo ""
echo "--- latency-slo (threshold: ${LATENCY_SLO_MS}ms) ---"
start_ms=$(date +%s%N)
curl -sk -o /dev/null "${MODEL_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Say yes."}],
    "max_tokens": 5,
    "temperature": 0
  }'
end_ms=$(date +%s%N)
elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))
if [[ ${elapsed_ms} -le ${LATENCY_SLO_MS} ]]; then
  echo "PASS (${elapsed_ms}ms <= ${LATENCY_SLO_MS}ms)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (${elapsed_ms}ms > ${LATENCY_SLO_MS}ms)" >&2
  FAILED=$((FAILED + 1))
fi

# ===========================================
# 10. Stop sequence
# ===========================================

echo ""
echo "=== Stop Sequences ==="

run_test "stop-sequence" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Count from 1 to 20, one number per line."}],
  "max_tokens": 200,
  "stop": ["5"]
}'
echo ""
echo "--- stop-sequence-check ---"
finish_reason=$(python3 -c "
import json
data = json.load(open('${RUN_DIR}/stop-sequence.json'))
print(data['choices'][0]['finish_reason'])
" 2>/dev/null || echo "unknown")
if [[ "${finish_reason}" == "stop" ]]; then
  echo "PASS (finish_reason=stop)"
  PASSED=$((PASSED + 1))
else
  echo "FAIL (finish_reason=${finish_reason}, expected 'stop')" >&2
  FAILED=$((FAILED + 1))
fi

# --- Summary ---

echo ""
echo "========================================="
echo "  Extended Results: ${PASSED} passed, ${FAILED} failed"
echo "  Output:  ${RUN_DIR}"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
