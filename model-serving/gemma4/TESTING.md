# How to test the Gemma 4 serving endpoint yourself

> Prefer the automated runner: `cd scripts && ./test.sh` (add `--stream --gpu`).
> The steps below are the manual equivalents / for poking at it by hand.

The server speaks the OpenAI-compatible API. Model is served under the name
`gemma-4` (the `--served-model-name`), on an edge-TLS route.

## 0. Get the endpoint URL

    URL="https://$(oc get route gemma4-vllm -n eldritchjs-sandbox -o jsonpath='{.spec.host}')"
    echo "$URL"

(The router uses its default cert, so add `-k` to curl to skip cert validation.)

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

    POD=$(oc get pod -l app=gemma4-vllm -n eldritchjs-sandbox -o jsonpath='{.items[0].metadata.name}')
    oc exec "$POD" -n eldritchjs-sandbox -- nvidia-smi

You should see 2 H100s with the vLLM process resident and GPU memory in use.

## 6. Watch server logs / throughput

    oc logs -f deploy/gemma4-vllm -n eldritchjs-sandbox

vLLM logs per-request latency, tokens/s, and KV-cache usage.

## What "it works" looks like
- Step 1 returns the model list (HTTP 200).
- Step 2 returns a coherent, on-topic completion.
- Step 5 shows both H100s with memory allocated to the vLLM process.

## When you're done — tear it down (stop GPU charges)

    cd scripts
    ./down.sh                # full: release GPUs AND delete the weight cache
    ./down.sh --keep-cache   # release GPUs, keep the PVC for a fast re-run

`--keep-cache` preserves the ~62 GB weight cache so the next `./up.sh` skips the
download (warm start). See TEST-PLAN.md §6 for full details.
