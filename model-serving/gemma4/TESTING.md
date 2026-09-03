# How to test the Gemma 4 serving endpoint yourself

> Prefer the automated runner: `cd scripts && ./test.sh` (add `--stream --gpu`).
> The steps below are the manual equivalents / for poking at it by hand.

The server speaks the OpenAI-compatible API. Model is served under the name
`gemma-4` (the `--served-model-name`), on an edge-TLS route.

## 0. Get the endpoint URL

The Route name depends on the serving mode it was deployed with (`lazy` uses
`gemma4-vllm`; `kserve` uses `gemma4-infer`):

    # lazy (default):
    URL="https://$(oc get route gemma4-vllm -n eldritchjs-sandbox -o jsonpath='{.spec.host}')"
    # kserve:
    URL="https://$(oc get route gemma4-infer -n eldritchjs-sandbox -o jsonpath='{.spec.host}')"
    echo "$URL"

(The router uses its default cert, so add `-k` to curl to skip cert validation.)
Everything below is identical across modes — same OpenAI API, same `gemma-4`
model name.

## 1. Is it alive? List the model

    curl -sk "$URL/v1/models" | python3 -m json.tool

Expect a JSON object listing id "gemma-4". If you get this, routing + server are up.

## 2. A chat completion (the real inference test)

    curl -sk "$URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{
        "model": "gemma-4",
        "messages": [
          {"role": "user", "content": "Write a Python function that reverses a linked list."}
        ],
        "max_tokens": 300,
        "temperature": 0.2
      }' | python3 -m json.tool

Expect a coherent code answer in choices[0].message.content.

## 3. Streaming (token-by-token)

    curl -Nsk "$URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"gemma-4","stream":true,
           "messages":[{"role":"user","content":"Count from 1 to 10."}]}'

You'll see `data: {...}` SSE chunks, ending with `data: [DONE]`.

## 4. Using the OpenAI Python client (optional)

    pip install openai
    python3 - <<'PY'
    from openai import OpenAI
    import os
    client = OpenAI(base_url=os.environ["URL"] + "/v1", api_key="not-needed")
    r = client.chat.completions.create(
        model="gemma-4",
        messages=[{"role":"user","content":"Explain a hash map in one sentence."}],
    )
    print(r.choices[0].message.content)
    PY

(No auth is configured on this dev endpoint, so any api_key string works.)

## 5. Confirm it's really running on the GPUs

The pod label differs by mode (`lazy`: `app=gemma4-vllm`; `kserve`:
`serving.kserve.io/inferenceservice=gemma4`):

    # lazy:
    POD=$(oc get pod -l app=gemma4-vllm -n eldritchjs-sandbox -o jsonpath='{.items[0].metadata.name}')
    # kserve:
    POD=$(oc get pod -l serving.kserve.io/inferenceservice=gemma4 -n eldritchjs-sandbox -o jsonpath='{.items[0].metadata.name}')
    oc exec "$POD" -n eldritchjs-sandbox -- nvidia-smi

You should see 2 H100s with the vLLM process resident and GPU memory in use.

## 6. Watch server logs / throughput

    oc logs -f "$POD" -n eldritchjs-sandbox      # $POD from step 5 (both modes)

vLLM logs per-request latency, tokens/s, and KV-cache usage.

## What "it works" looks like
- Step 1 returns the model list (HTTP 200).
- Step 2 returns a coherent, on-topic completion.
- Step 5 shows both H100s with memory allocated to the vLLM process.

## 7. Load-test / benchmark it (guidellm, from a separate pod)

To measure throughput and latency under load — not just "does it answer" — run
`benchmark.sh`. It launches [guidellm](https://github.com/vllm-project/guidellm)
in its **own** pod and points it at the endpoint's in-cluster ClusterIP Service
(plain HTTP, no router/TLS in the path), so the numbers reflect real client→server
behavior over the cluster network rather than localhost.

    cd scripts
    ./benchmark.sh                        # 'sweep': auto-varies concurrency, 60s, 256-in/128-out
    BENCH_MAX_SECONDS=120 ./benchmark.sh  # run each rate longer
    BENCH_RATE_TYPE=throughput ./benchmark.sh   # push max throughput instead of a sweep

The endpoint must already be up (`./up.sh` first) — this benchmarks it, it doesn't
deploy it. It's mode-aware: `lazy` targets Service `gemma4-vllm:8000`, `kserve`
targets the external Service `gemma4-external:80`.

**Tunables (env vars):** `BENCH_RATE_TYPE` (`sweep`|`constant`|`throughput`|…),
`BENCH_MAX_SECONDS`, `BENCH_PROMPT_TOKENS`, `BENCH_OUTPUT_TOKENS`.

guidellm loads the tokenizer from the real HF repo id (`--processor`, since the
served name `gemma-4` isn't an HF id) to build the synthetic prompts. The script
streams the run and prints guidellm's summary table at the end — read
requests/sec, TTFT (time to first token), inter-token latency, and end-to-end
latency per concurrency level from that table. The full JSON is written to
`/tmp/guidellm-results.json` inside the pod.

The benchmark Job is left in place so you can re-read its logs
(`oc logs job/gemma4-benchmark -n eldritchjs-sandbox`); `./down.sh` removes it.

## When you're done — tear it down (stop GPU charges)

    cd scripts
    ./down.sh                # full: release GPUs AND delete the weight cache
    ./down.sh --keep-cache   # release GPUs, keep the PVC for a fast re-run

`--keep-cache` preserves the ~62 GB weight cache so the next `./up.sh` skips the
download (warm start). See TEST-PLAN.md §6 for full details.
