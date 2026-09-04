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

## 7. Load-test / benchmark it (from a separate pod)

To measure throughput and latency under load — not just "does it answer" — run
`benchmark.sh`. It launches a load-test tool in its **own** pod and points it at
the endpoint's in-cluster ClusterIP Service (plain HTTP, no router/TLS in the
path), so the numbers reflect real client→server behavior over the cluster network
rather than localhost.

    cd scripts
    ./benchmark.sh                          # guidellm 'sweep': auto-varies concurrency, 60s, 256-in/128-out
    ./benchmark.sh --tool inference-perf    # inference-perf: constant BENCH_RATE q/s
    BENCH_MAX_SECONDS=120 ./benchmark.sh    # run longer
    BENCH_RATE_TYPE=throughput ./benchmark.sh   # guidellm: push max throughput instead of a sweep

The endpoint must already be up (`./up.sh` first) — this benchmarks it, it doesn't
deploy it. It's mode-aware: `lazy` targets Service `gemma4-vllm:8000`, `kserve`
targets the external Service `gemma4-external:80`.

**Two tools, pick with `--tool` (or `BENCH_TOOL`):**

- **[guidellm](https://github.com/vllm-project/guidellm)** (default) — runs a
  *sweep* of ~10 sub-benchmarks that ramp concurrency to find peak throughput.
  Invoked as `guidellm run --backend kind=openai_http,... --profile kind=sweep
  --data kind=synthetic_text,... --tokenizer kind=huggingface_auto,model=<HF id>`.
  Results write to `/tmp/benchmarks.{json,csv}` in the pod
  (`GUIDELLM__DEFAULT_RESULTS_DIR=/tmp`, since the default `/results` isn't
  writable under the random UID).
- **[inference-perf](https://github.com/kubernetes-sigs/inference-perf)**
  (`--tool inference-perf`) — config-file driven (a mounted ConfigMap); runs one
  *constant rate* stage of `BENCH_RATE` req/s. Uses its `random` synthetic datagen
  over `/v1/completions` (that generator supports the completion API, not chat).
  Reports write to `/tmp/reports-*/` in the pod.

Both load the tokenizer from the real HF repo id (the served name `gemma-4` isn't
an HF id) to build synthetic prompts of the target length. The script streams the
run and prints the tool's summary table(s) at the end — read requests/sec, TTFT
(time to first token), inter-token latency (ITL/TPOT), and end-to-end latency from
that table.

**Tunables (env vars):** `BENCH_MAX_SECONDS`, `BENCH_PROMPT_TOKENS`,
`BENCH_OUTPUT_TOKENS` (both tools); `BENCH_RATE_TYPE`
(`sweep`|`throughput`|`synchronous`, guidellm only); `BENCH_RATE` (req/s,
inference-perf only).

The benchmark Job (and, for inference-perf, its ConfigMap) is left in place so you
can re-read its logs (`oc logs job/gemma4-benchmark -n eldritchjs-sandbox`);
`./down.sh` removes both.

## 8. Quantized single-GPU variant

The `w4a16` QAT checkpoint runs at TP=1 on **one** H100 — same API, same tests,
half the GPUs. It's a ready-made config selected with `CONFIG_FILE` (resolved next
to the scripts, so you can run from anywhere):

    cd scripts
    CONFIG_FILE=config.quantized.conf ./up.sh
    CONFIG_FILE=config.quantized.conf ./test.sh --gpu     # check 5 shows ONE H100
    CONFIG_FILE=config.quantized.conf ./down.sh

Everything above (sections 1–7) works unchanged — the model is still served as
`gemma-4`. vLLM auto-detects the compressed-tensors quantization (you'll see
`Using MarlinLinearKernel for CompressedTensorsWNA16` in the pod log); no
`--quantization` flag is set. Weights load in ~20 GiB, so a single 80 GB H100 has
ample room for the KV cache. Env vars still win over the file, e.g. add
`SERVE_MODE=kserve` to run it through the KServe path.

## 9. Watch it autoscale (kserve)

In `kserve` mode the predictor scales horizontally when `MAX_REPLICAS >
MIN_REPLICAS` — KServe creates a native HPA. The quantized variant is the natural
demo on a 2-GPU box (TP=1 → 1 GPU/replica, so 1→2 fits in two GPUs):

    cd scripts
    CONFIG_FILE=config.quantized.conf MAX_REPLICAS=2 ./up.sh --mode kserve

Watch the HPA and pods in one terminal:

    oc get hpa,pods -l serving.kserve.io/inferenceservice=gemma4 \
      -n eldritchjs-sandbox -w

Drive load in another (raises the metric past `SCALE_TARGET` → scale-out):

    CONFIG_FILE=config.quantized.conf ./benchmark.sh --mode kserve

You should see the HPA go `REPLICAS 1 → 2`, a second `gemma4-predictor-*` pod
schedule on the other GPU and reach `1/1`, then settle back toward `MIN_REPLICAS`
after load stops (HPA stabilization window, ~5 min). Confirm the rescale reason:

    oc describe hpa gemma4-predictor -n eldritchjs-sandbox | sed -n '/Events:/,$p'
    # -> SuccessfulRescale ... reason: cpu resource utilization ... above target

**Heads-up:** the HPA scales on **CPU** here (metrics-server only). A quantized,
GPU-bound model can be so CPU-light that it never crosses a 60% CPU target — that
demonstrates the *mechanism* but may not trip a scale-out under a light sweep. To
force a demo scale-out, lower the target through the same knob the config exposes:

    oc patch inferenceservice gemma4 -n eldritchjs-sandbox --type=merge \
      -p '{"spec":{"predictor":{"scaleTarget":12}}}'   # KServe propagates it to the HPA

The production-grade signal (`vllm:num_requests_running` via KEDA, or
concurrency/RPS via Knative) needs extra platform components — see README.

## When you're done — tear it down (stop GPU charges)

    cd scripts
    ./down.sh                # full: release GPUs AND delete the weight cache
    ./down.sh --keep-cache   # release GPUs, keep the PVC for a fast re-run

`--keep-cache` preserves the ~62 GB weight cache so the next `./up.sh` skips the
download (warm start). See TEST-PLAN.md §6 for full details.
