#!/usr/bin/env bash
# Automated smoke test of the running Gemma 4 endpoint (mirrors TESTING.md).
#   ./test.sh                 # run the core checks (models, chat, GPU residency)
#   ./test.sh --stream        # also run a streaming check
#   ./test.sh --gpu           # also run nvidia-smi inside the pod
#   ./test.sh --mode kserve   # override SERVE_MODE for this run (else config.conf/env)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
parse_mode_flag "$@"; set -- ${REST_ARGS[@]+"${REST_ARGS[@]}"}
load_config
need curl
need python3

DO_STREAM=0; DO_GPU=0
for a in "$@"; do
  case "$a" in
    --stream) DO_STREAM=1 ;;
    --gpu)    DO_GPU=1 ;;
    *) die "unknown flag: $a" ;;
  esac
done

pass=0; fail=0
ok()   { printf '%s  PASS%s %s\n' "$c_grn" "$c_rst" "$*"; pass=$((pass+1)); }
bad()  { printf '%s  FAIL%s %s\n' "$c_red" "$c_rst" "$*"; fail=$((fail+1)); }

# --- 0. endpoint + pod ---
URL="$(route_url)"; [ -n "$URL" ] || die "no route found in $NAMESPACE — is it deployed?"
info "Endpoint: $URL"

ready="$(oc get pod -l "$APP_LABEL" -n "$NAMESPACE" \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
[ "$ready" = "true" ] && ok "pod is Ready" || bad "pod not Ready (got '${ready:-none}')"

# --- 1. list models ---
models="$(curl -sk --max-time 30 "$URL/v1/models" || true)"
if printf '%s' "$models" | python3 -c "import sys,json; d=json.load(sys.stdin); ids=[m['id'] for m in d.get('data',[])]; sys.exit(0 if '$SERVED_NAME' in ids else 1)" 2>/dev/null; then
  ok "/v1/models lists '$SERVED_NAME'"
else
  bad "/v1/models did not list '$SERVED_NAME' (response: ${models:0:200})"
fi

# --- 2. chat completion ---
body="$(printf '{"model":"%s","messages":[{"role":"user","content":"Write a Python function that reverses a linked list."}],"max_tokens":200,"temperature":0.2}' "$SERVED_NAME")"
resp="$(curl -sk --max-time 120 "$URL/v1/chat/completions" \
  -H 'Content-Type: application/json' -d "$body" || true)"
content="$(printf '%s' "$resp" | python3 -c "import sys,json;
try:
  d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])
except Exception: pass" 2>/dev/null)"
if [ -n "$content" ]; then
  ok "chat completion returned content (${#content} chars)"
  printf '       %s...\n' "$(printf '%s' "$content" | head -n 2 | tr '\n' ' ' | cut -c1-100)"
else
  bad "chat completion returned no content (response: ${resp:0:200})"
fi

# --- 3. streaming (optional) ---
if [ "$DO_STREAM" -eq 1 ]; then
  sbody="$(printf '{"model":"%s","stream":true,"messages":[{"role":"user","content":"Count from 1 to 5."}],"max_tokens":40}' "$SERVED_NAME")"
  # Capture first, THEN grep: piping curl straight into `grep -q` makes grep
  # close the pipe on first match -> curl dies with SIGPIPE -> pipefail reports
  # the pipeline as failed even though chunks arrived (false negative).
  schunks="$(curl -Nsk --max-time 60 "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$sbody" || true)"
  if printf '%s' "$schunks" | grep -q '^data:'; then
    ok "streaming produced SSE chunks ($(printf '%s' "$schunks" | grep -c '^data:') lines)"
  else
    bad "streaming produced no SSE chunks"
  fi
fi

# --- 4. GPU residency (optional) ---
if [ "$DO_GPU" -eq 1 ]; then
  pod="$(pod_name)"
  if [ -n "$pod" ] && oc exec "$pod" -n "$NAMESPACE" -- nvidia-smi >/tmp/gemma4-smi.txt 2>/dev/null; then
    gpus="$(grep -c 'MiB /' /tmp/gemma4-smi.txt || true)"
    ok "nvidia-smi ok — $gpus GPU(s) visible in pod"
    grep -E 'H100|MiB /' /tmp/gemma4-smi.txt | sed 's/^/       /' || true
  else
    bad "could not run nvidia-smi in the pod"
  fi
fi

echo
info "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
