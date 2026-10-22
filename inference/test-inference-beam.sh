#!/bin/bash
# Inference test suite for Reflection Beam 1.0 (501B-A23B).
#
# Endpoint-agnostic: point it at the on-cluster deployment or at any hosted
# provider that speaks the OpenAI API.
#
#   ./test-inference-beam.sh                              # discover the route in $PROJECT
#   BASE_URL=https://... ./test-inference-beam.sh         # explicit endpoint
#   BASE_URL=https://openrouter.ai/api API_KEY=sk-... \
#     MODEL_NAME=reflection/beam-1.0-501b-a23b ./test-inference-beam.sh
#
# Beyond the usual OpenAI-API coverage this exercises the things that are
# particular to Beam: the Harmony analysis/final channel split, the five
# reasoning-effort levels, tool calling through the `beam` parser, and the
# absence of leaked Harmony control tokens in user-visible content.
set -euo pipefail

PROJECT=${PROJECT:-mm-test}
MODEL_NAME=${MODEL_NAME:-beam}
ROUTE_NAME=${ROUTE_NAME:-beam-infer}
BASE_URL=${BASE_URL:-}
API_KEY=${API_KEY:-}
# Beam reasons before answering, and the analysis channel is billed as output
# tokens. A 20-token budget — fine for Qwen or Granite — yields an empty `final`
# channel here, so every test that needs an actual answer gets real headroom.
MAX_TOKENS=${MAX_TOKENS:-2048}
RESULTS_DIR=${RESULTS_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results"}

if [[ -z "${BASE_URL}" ]]; then
  BASE_URL=$(oc get route "${ROUTE_NAME}" -n "${PROJECT}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
  if [[ -z "${BASE_URL}" ]]; then
    echo "Error: no BASE_URL given and no route '${ROUTE_NAME}' in project '${PROJECT}'" >&2
    exit 1
  fi
fi
BASE_URL="${BASE_URL%/}"

CURL_AUTH=()
if [[ -n "${API_KEY}" ]]; then
  CURL_AUTH=(-H "Authorization: Bearer ${API_KEY}")
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_DIR="${RESULTS_DIR}/${TIMESTAMP}-beam"
mkdir -p "${RUN_DIR}"

PASSED=0
FAILED=0
SKIPPED=0

pass() { echo "  PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $*" >&2; FAILED=$((FAILED + 1)); }
skip() { echo "  SKIP  $*"; SKIPPED=$((SKIPPED + 1)); }

# POST a payload, record the body, assert the HTTP status.
run_test() {
  local name="$1" endpoint="$2" payload="$3" expected_code="${4:-200}"

  echo ""
  echo "--- ${name} ---"

  local start_ms end_ms elapsed_ms response http_code body
  start_ms=$(date +%s%N)
  response=$(curl -sk --max-time 900 -w "\n%{http_code}" "${BASE_URL}${endpoint}" \
    -H "Content-Type: application/json" "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    -d "${payload}" 2>&1)
  end_ms=$(date +%s%N)
  elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))

  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')
  echo "${body}" > "${RUN_DIR}/${name}.json"

  if [[ "${http_code}" == "${expected_code}" ]]; then
    pass "HTTP ${http_code} (${elapsed_ms}ms)"
  else
    fail "HTTP ${http_code}, expected ${expected_code} (${elapsed_ms}ms)"
  fi
  echo "  Response: $(echo "${body}" | head -c 200)"
}

run_get_test() {
  local name="$1" endpoint="$2" expected_code="${3:-200}"

  echo ""
  echo "--- ${name} ---"

  local response http_code body
  response=$(curl -sk --max-time 60 -w "\n%{http_code}" "${BASE_URL}${endpoint}" \
    "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" 2>&1)
  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')
  echo "${body}" > "${RUN_DIR}/${name}.json"

  if [[ "${http_code}" == "${expected_code}" ]]; then
    pass "HTTP ${http_code}"
  else
    fail "HTTP ${http_code}, expected ${expected_code}"
  fi
  echo "  Response: $(echo "${body}" | head -c 200)"
}

# Read a dotted path out of a recorded response. Prints the value, or nothing
# (and returns 1) if the path is absent.
jpath() {
  local name="$1" field="$2"
  python3 -c "
import json, sys
data = json.load(open('${RUN_DIR}/${name}.json'))
obj = data
for k in '${field}'.split('.'):
    obj = obj[int(k)] if isinstance(obj, list) else obj[k]
if obj is None:
    sys.exit(1)
print(obj if not isinstance(obj, (dict, list)) else json.dumps(obj))
" 2>/dev/null
}

assert_contains() {
  local name="$1" pattern="$2"
  if grep -qi -- "${pattern}" "${RUN_DIR}/${name}.json" 2>/dev/null; then
    pass "content contains '${pattern}'"
  else
    fail "content does not contain '${pattern}'"
  fi
}

assert_json_field() {
  local name="$1" field="$2"
  if jpath "${name}" "${field}" >/dev/null; then
    pass "field '${field}' present"
  else
    fail "field '${field}' missing"
  fi
}

# The assistant's user-visible answer. vLLM's `--reasoning-parser beam` splits
# the Harmony channels, so `content` holds only the `final` channel.
answer_of() { jpath "$1" "choices.0.message.content"; }

# The `analysis` channel. vLLM names it reasoning_content; OpenRouter and some
# other providers name it reasoning. Accept either so the same suite can run
# against a hosted endpoint unchanged.
reasoning_of() {
  jpath "$1" "choices.0.message.reasoning_content" || jpath "$1" "choices.0.message.reasoning"
}

echo "========================================="
echo "  Beam 1.0 Inference Tests"
echo "  Model:    ${MODEL_NAME}"
echo "  Endpoint: ${BASE_URL}"
echo "  Auth:     $([[ -n "${API_KEY}" ]] && echo "bearer token" || echo "none")"
echo "========================================="

# ===========================================
# 1. API availability
# ===========================================

echo ""
echo "=== API Availability ==="

# /health and /ready are vLLM's own endpoints; hosted gateways don't serve them.
# Probe once and gate rather than reporting spurious failures against a provider.
NATIVE_VLLM=0
if [[ "$(curl -sk --max-time 30 -o /dev/null -w '%{http_code}' "${BASE_URL}/health" || true)" == "200" ]]; then
  NATIVE_VLLM=1
fi

if [[ ${NATIVE_VLLM} -eq 1 ]]; then
  run_get_test "health-check" "/health"
  run_get_test "readiness-check" "/ready"
else
  echo ""
  skip "/health (endpoint is not a bare vLLM server — hosted gateway?)"
  skip "/ready (same)"
fi

run_get_test "list-models" "/v1/models"
assert_contains "list-models" "${MODEL_NAME}"

# ===========================================
# 2. Chat completions
# ===========================================

echo ""
echo "=== Chat Completions ==="

run_test "chat-simple" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "What is 2+2?"}],
  "max_tokens": '"${MAX_TOKENS}"'
}'

run_test "chat-system-prompt" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant. Answer concisely."},
    {"role": "user", "content": "What is the capital of France?"}
  ],
  "max_tokens": '"${MAX_TOKENS}"'
}'

run_test "chat-multi-turn" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "user", "content": "My name is Alice."},
    {"role": "assistant", "content": "Hello Alice! How can I help you today?"},
    {"role": "user", "content": "What is my name?"}
  ],
  "max_tokens": '"${MAX_TOKENS}"'
}'
assert_contains "chat-multi-turn" "Alice"

# ===========================================
# 3. Harmony channel separation
# ===========================================
#
# Beam emits a Harmony-format stream: an `analysis` channel carrying the chain
# of thought, then a `final` channel carrying the answer, terminated by the
# <|return|> control token. The server is responsible for splitting those apart
# (`--reasoning-parser beam` in vLLM). If it isn't wired up, the symptom is
# subtle but serious: raw control tokens and private reasoning get served to
# clients inside `content`.

echo ""
echo "=== Harmony Channels ==="

run_test "harmony-channels" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "A rope burns unevenly in exactly 60 minutes. How do you measure 45 minutes with two such ropes? Answer briefly."}],
  "max_tokens": '"${MAX_TOKENS}"',
  "temperature": 0
}'

if reasoning_of "harmony-channels" >/dev/null; then
  pass "analysis channel exposed separately (reasoning_content/reasoning)"
else
  fail "no analysis channel in the response — is --reasoning-parser beam enabled?"
fi

if [[ -n "$(answer_of "harmony-channels" || true)" ]]; then
  pass "final channel non-empty"
else
  fail "final channel empty (raise MAX_TOKENS, or the parser swallowed the answer)"
fi

echo ""
echo "--- harmony-no-token-leak ---"
# <|start|>, <|channel|>, <|message|>, <|return|>, <|call|> are Harmony framing.
# None of them should ever reach a client in `content`.
leaked=0
for tok in '<|start|>' '<|channel|>' '<|message|>' '<|return|>' '<|call|>' 'analysis<|' ; do
  if answer_of "harmony-channels" 2>/dev/null | grep -qF -- "${tok}"; then
    echo "    leaked token: ${tok}"
    leaked=1
  fi
done
if [[ ${leaked} -eq 0 ]]; then
  pass "no Harmony control tokens in content"
else
  fail "Harmony control tokens leaked into content"
fi

# ===========================================
# 4. Reasoning effort
# ===========================================
#
# Beam takes five effort levels. Beyond "the server accepts the parameter", the
# meaningful check is that it actually changes behaviour: more effort should
# mean a longer analysis channel. We compare the cheapest against the most
# expensive rather than asserting a strict ordering across all five, which is
# sampling noise as much as signal.

echo ""
echo "=== Reasoning Effort ==="

declare -A effort_tokens
for effort in low medium high xhigh max; do
  run_test "effort-${effort}" "/v1/chat/completions" '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Is 9533 a prime number? Show your conclusion only."}],
    "reasoning_effort": "'"${effort}"'",
    "max_tokens": '"${MAX_TOKENS}"',
    "temperature": 0
  }'
  effort_tokens[$effort]="$(jpath "effort-${effort}" "usage.completion_tokens" || echo 0)"
  echo "  completion_tokens: ${effort_tokens[$effort]}"
done

echo ""
echo "--- effort-scales-with-level ---"
low_t="${effort_tokens[low]:-0}"
max_t="${effort_tokens[max]:-0}"
if [[ "${low_t}" -gt 0 && "${max_t}" -gt "${low_t}" ]]; then
  pass "reasoning_effort changes output length (low=${low_t} < max=${max_t} tokens)"
elif [[ "${low_t}" -eq 0 || "${max_t}" -eq 0 ]]; then
  fail "could not read completion_tokens for one or both levels"
else
  fail "reasoning_effort had no effect (low=${low_t}, max=${max_t}) — is it being passed through?"
fi

# ===========================================
# 5. Tool calling
# ===========================================
#
# Beam stops on <|call|> when it decides to invoke a tool; the server's
# `beam` tool-call parser turns that into OpenAI-shaped tool_calls.

echo ""
echo "=== Tool Calling ==="

run_test "tool-call" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "What is the weather in Boston right now? Use the tool."}],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get the current weather for a city.",
      "parameters": {
        "type": "object",
        "properties": {
          "city": {"type": "string", "description": "City name"},
          "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
        },
        "required": ["city"]
      }
    }
  }],
  "tool_choice": "auto",
  "max_tokens": '"${MAX_TOKENS}"',
  "temperature": 0
}'

tool_name="$(jpath "tool-call" "choices.0.message.tool_calls.0.function.name" || true)"
if [[ "${tool_name}" == "get_weather" ]]; then
  pass "model called get_weather"
else
  fail "expected a get_weather tool call, got '${tool_name:-none}'"
fi

echo ""
echo "--- tool-call-arguments-valid-json ---"
if jpath "tool-call" "choices.0.message.tool_calls.0.function.arguments" 2>/dev/null \
   | python3 -c "
import json, sys
args = json.loads(sys.stdin.read())
assert 'city' in args, 'required property city missing'
assert 'boston' in str(args['city']).lower(), f'unexpected city: {args[\"city\"]}'
print(json.dumps(args))
" 2>/dev/null; then
  pass "tool arguments are valid JSON matching the schema"
else
  fail "tool arguments were not valid JSON matching the declared schema"
fi

echo ""
echo "--- tool-call-finish-reason ---"
finish="$(jpath "tool-call" "choices.0.finish_reason" || true)"
if [[ "${finish}" == "tool_calls" ]]; then
  pass "finish_reason is tool_calls"
else
  fail "finish_reason is '${finish:-none}', expected tool_calls"
fi

# Feed the tool result back: the model must consume the tool message and
# produce a final answer rather than looping on another call.
run_test "tool-roundtrip" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "user", "content": "What is the weather in Boston right now? Use the tool."},
    {"role": "assistant", "tool_calls": [{
      "id": "call_1", "type": "function",
      "function": {"name": "get_weather", "arguments": "{\"city\": \"Boston\", \"unit\": \"celsius\"}"}
    }]},
    {"role": "tool", "tool_call_id": "call_1", "content": "{\"temp_c\": 12, \"conditions\": \"light rain\"}"}
  ],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get the current weather for a city.",
      "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
    }
  }],
  "max_tokens": '"${MAX_TOKENS}"',
  "temperature": 0
}'
assert_contains "tool-roundtrip" "12"

# ===========================================
# 6. Structured output
# ===========================================

echo ""
echo "=== Structured Output ==="

run_test "structured-json-schema" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Extract the fields: Ada Lovelace was born in 1815 in London."}],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "person",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "name": {"type": "string"},
          "birth_year": {"type": "integer"},
          "city": {"type": "string"}
        },
        "required": ["name", "birth_year", "city"],
        "additionalProperties": false
      }
    }
  },
  "max_tokens": '"${MAX_TOKENS}"',
  "temperature": 0
}'

echo ""
echo "--- structured-output-conforms ---"
if answer_of "structured-json-schema" 2>/dev/null | python3 -c "
import json, sys
obj = json.loads(sys.stdin.read())
assert set(obj) == {'name', 'birth_year', 'city'}, f'unexpected keys: {sorted(obj)}'
assert isinstance(obj['birth_year'], int), 'birth_year is not an integer'
assert obj['birth_year'] == 1815, f'wrong birth_year: {obj[\"birth_year\"]}'
print(json.dumps(obj))
" 2>/dev/null; then
  pass "response conforms to the requested JSON schema"
else
  fail "response did not conform: $(answer_of "structured-json-schema" 2>/dev/null | head -c 160)"
fi

# ===========================================
# 7. Content validation
# ===========================================

echo ""
echo "=== Content Validation ==="

run_test "content-math" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "What is 7 * 8? Reply with just the number."}],
  "max_tokens": '"${MAX_TOKENS}"',
  "temperature": 0
}'
assert_contains "content-math" "56"

run_test "content-capital" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [
    {"role": "system", "content": "Answer in one word only."},
    {"role": "user", "content": "What is the capital of Japan?"}
  ],
  "max_tokens": '"${MAX_TOKENS}"',
  "temperature": 0
}'
assert_contains "content-capital" "Tokyo"

# Beam is tuned for agentic coding, so a code task is a more representative
# probe of the deployment than trivia alone.
run_test "content-code" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Write a Python function named is_palindrome that takes a string and returns True if it reads the same forwards and backwards, ignoring case and non-alphanumeric characters. Output only the code."}],
  "max_tokens": '"${MAX_TOKENS}"',
  "temperature": 0
}'

echo ""
echo "--- content-code-executes ---"
# Run the generated function against known cases. The snippet is model output,
# so it executes in an isolated temp dir with `python3 -I` (no site-packages
# imports from cwd, no inherited environment).
code_dir="${RUN_DIR}/generated-code"
mkdir -p "${code_dir}"
answer_of "content-code" 2>/dev/null \
  | sed -n '/```/,/```/p' | sed '/```/d' > "${code_dir}/snippet.py" || true
# Fall back to the raw answer when the model didn't use a fenced block.
if [[ ! -s "${code_dir}/snippet.py" ]]; then
  answer_of "content-code" 2>/dev/null > "${code_dir}/snippet.py" || true
fi
cat > "${code_dir}/check.py" <<'PYCHECK'
import sys
ns = {}
exec(open(sys.argv[1]).read(), ns)
f = ns["is_palindrome"]
assert f("A man, a plan, a canal: Panama") is True
assert f("hello") is False
assert f("") is True
print("ok")
PYCHECK
if python3 -I "${code_dir}/check.py" "${code_dir}/snippet.py" >/dev/null 2>&1; then
  pass "generated is_palindrome passes its test cases"
else
  fail "generated code did not run or failed its test cases (see ${code_dir}/)"
fi

# ===========================================
# 8. Long context
# ===========================================
#
# Beam advertises a 1,048,576-token window, but the deployment's --max-model-len
# is what actually binds. This is a needle-in-a-haystack at a size that fits the
# default 32k deployment; raise NEEDLE_FILLER_KB to probe a larger window.

echo ""
echo "=== Long Context ==="

NEEDLE_FILLER_KB=${NEEDLE_FILLER_KB:-48}
needle_payload="${RUN_DIR}/long-context-request.json"
python3 -I - "${needle_payload}" "${MODEL_NAME}" "${NEEDLE_FILLER_KB}" "${MAX_TOKENS}" <<'PYGEN'
import json, sys

out_path, model, filler_kb, max_tokens = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
# Distinct numbered lines so the model cannot pattern-match its way to the
# needle; it has to actually retrieve it.
filler = "\n".join(
    f"Record {i:06d}: routine telemetry entry, no action required."
    for i in range(filler_kb * 1024 // 64)
)
half = len(filler) // 2
haystack = (
    filler[:half]
    + "\nRecord 999999: the maintenance passphrase is quicksilver-harbor-31.\n"
    + filler[half:]
)
payload = {
    "model": model,
    "messages": [
        {"role": "user", "content":
            haystack + "\n\nWhat is the maintenance passphrase mentioned above? Reply with just the passphrase."}
    ],
    "max_tokens": max_tokens,
    "temperature": 0,
}
with open(out_path, "w") as fh:
    json.dump(payload, fh)
PYGEN

echo ""
echo "--- long-context-needle (${NEEDLE_FILLER_KB}KB haystack) ---"
lc_response=$(curl -sk --max-time 900 -w "\n%{http_code}" "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
  --data-binary "@${needle_payload}" 2>&1)
lc_code=$(echo "${lc_response}" | tail -1)
echo "${lc_response}" | sed '$d' > "${RUN_DIR}/long-context-needle.json"

if [[ "${lc_code}" != "200" ]]; then
  fail "HTTP ${lc_code} — the haystack may exceed the deployment's --max-model-len"
elif answer_of "long-context-needle" 2>/dev/null | grep -qi "quicksilver-harbor-31"; then
  prompt_tokens="$(jpath "long-context-needle" "usage.prompt_tokens" || echo "?")"
  pass "retrieved the needle from a ${prompt_tokens}-token prompt"
else
  fail "needle not retrieved: $(answer_of "long-context-needle" 2>/dev/null | head -c 120)"
fi

# ===========================================
# 9. Schema validation
# ===========================================

echo ""
echo "=== Schema Validation ==="

run_test "schema-chat" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Hello."}],
  "max_tokens": '"${MAX_TOKENS}"'
}'
assert_json_field "schema-chat" "id"
assert_json_field "schema-chat" "object"
assert_json_field "schema-chat" "choices.0.message.role"
assert_json_field "schema-chat" "choices.0.message.content"
assert_json_field "schema-chat" "choices.0.finish_reason"
assert_json_field "schema-chat" "usage.prompt_tokens"
assert_json_field "schema-chat" "usage.completion_tokens"
assert_json_field "schema-chat" "usage.total_tokens"

# ===========================================
# 10. Streaming (SSE)
# ===========================================

echo ""
echo "=== Streaming ==="

echo ""
echo "--- streaming-chat ---"
stream_resp=$(curl -sk --max-time 900 "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
  -d '{
    "model": "'"${MODEL_NAME}"'",
    "messages": [{"role": "user", "content": "Count from 1 to 5."}],
    "max_tokens": '"${MAX_TOKENS}"',
    "stream": true
  }' 2>&1)
echo "${stream_resp}" > "${RUN_DIR}/streaming-chat.txt"

chunk_count=$(echo "${stream_resp}" | grep -c "^data: " || true)
has_done=$(echo "${stream_resp}" | grep -c "data: \[DONE\]" || true)
if [[ ${chunk_count} -gt 1 && ${has_done} -ge 1 ]]; then
  pass "${chunk_count} SSE chunks, [DONE] terminator present"
else
  fail "chunks=${chunk_count}, done=${has_done}"
fi

echo ""
echo "--- streaming-reasoning-deltas ---"
# The analysis channel must stream in its own delta field, not interleaved into
# content — a client rendering only `content` should never see the reasoning.
if echo "${stream_resp}" | grep -q '"reasoning_content"\|"reasoning"'; then
  pass "analysis channel streams as its own delta field"
else
  fail "no reasoning deltas in the stream — is --reasoning-parser beam enabled?"
fi

echo ""
echo "--- streaming-no-token-leak ---"
# Separate -e patterns, not one alternation: -F is literal, so `\|` inside a
# single pattern would be searched for verbatim and never match.
if echo "${stream_resp}" | grep -qF -e '<|return|>' -e '<|channel|>' -e '<|message|>' -e '<|start|>'; then
  fail "Harmony control tokens present in the SSE stream"
else
  pass "no Harmony control tokens in the stream"
fi

# ===========================================
# 11. Determinism
# ===========================================

echo ""
echo "=== Determinism ==="

echo ""
echo "--- determinism-temperature-zero ---"
responses=()
for i in $(seq 1 3); do
  resp=$(curl -sk --max-time 900 "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "What is 12 + 13? Reply with just the number."}],
      "max_tokens": '"${MAX_TOKENS}"',
      "temperature": 0,
      "reasoning_effort": "low"
    }')
  content=$(echo "${resp}" | python3 -c \
    "import json,sys; print((json.load(sys.stdin)['choices'][0]['message'].get('content') or '').strip())" \
    2>/dev/null || echo "ERROR")
  responses+=("${content}")
  echo "  Run ${i}: ${content}"
done
if [[ "${responses[0]}" == "${responses[1]}" && "${responses[1]}" == "${responses[2]}" ]]; then
  pass "all 3 responses identical at temperature 0"
else
  # Worth distinguishing: an MoE at TP>1 can be non-deterministic through expert
  # routing and reduction order even at temperature 0, so this is informative
  # rather than necessarily a defect.
  fail "responses differ across runs (expected for MoE+TP in some configs; check the answers are all correct)"
fi

# ===========================================
# 12. Error handling
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

run_test "error-invalid-reasoning-effort" "/v1/chat/completions" '{
  "model": "'"${MODEL_NAME}"'",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 10,
  "reasoning_effort": "extreme"
}' 400

# ===========================================
# 13. Concurrency
# ===========================================

echo ""
echo "=== Concurrency ==="

echo ""
echo "--- concurrent (5 parallel requests) ---"
PIDS=()
CONCURRENT_DIR="${RUN_DIR}/concurrent"
mkdir -p "${CONCURRENT_DIR}"
for i in $(seq 1 5); do
  curl -sk --max-time 900 -o "${CONCURRENT_DIR}/resp-${i}.json" -w "%{http_code} %{time_total}\n" \
    "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "Say the number '"${i}"' and nothing else."}],
      "max_tokens": '"${MAX_TOKENS}"',
      "reasoning_effort": "low"
    }' > "${CONCURRENT_DIR}/status-${i}.txt" 2>&1 &
  PIDS+=($!)
done
concurrent_failures=0
for i in $(seq 1 5); do
  wait "${PIDS[$((i-1))]}" || true
  status=$(cat "${CONCURRENT_DIR}/status-${i}.txt" 2>/dev/null || echo "000 0")
  echo "  Request ${i}: ${status}"
  code=$(echo "${status}" | awk '{print $1}')
  if [[ "${code}" != "200" ]]; then
    concurrent_failures=$((concurrent_failures + 1))
  fi
done
if [[ ${concurrent_failures} -eq 0 ]]; then
  pass "all 5 concurrent requests succeeded"
else
  fail "${concurrent_failures}/5 concurrent requests failed"
fi

# --- Summary ---

echo ""
echo "========================================="
echo "  Beam Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
echo "  Output:  ${RUN_DIR}"
echo "========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
