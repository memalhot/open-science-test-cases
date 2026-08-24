# Inference Benchmarking

Benchmark and test a deployed model's inference performance using [inference-benchmarker](https://github.com/huggingface/inference-benchmarker) and manual curl-based tests.

## Prerequisites

- `oc` CLI, logged in to an OpenShift cluster with a deployed model (see [model-serving](../model-serving/granite-model))
- Rust toolchain (`cargo`) installed
- `credentials.env` in `model-serving/granite-model/` with a HuggingFace access token (for tokenizer download)

### Install inference-benchmarker

```bash
sudo dnf install gcc-c++ openssl-devel pkg-config
cargo install --git https://github.com/huggingface/inference-benchmarker/
export PATH="$HOME/.cargo/bin:$PATH"
```

## Benchmark

Runs a sweep benchmark that automatically detects max throughput and tests across multiple request rates:

```bash
./benchmark.sh
```

The script auto-discovers the model endpoint from the OpenShift route. Results are saved to `results/<timestamp>/`.

### Configuration

All parameters are configurable via environment variables:

| Variable | Default | Description |
|---|---|---|
| `PROJECT` | `mm-test` | OpenShift project |
| `MODEL_NAME` | `granite-model` | Model name as registered in vLLM |
| `TOKENIZER` | `ibm-granite/granite-3.0-8b-instruct` | HuggingFace tokenizer |
| `MODEL_URL` | (auto-discovered) | Override to skip route lookup |
| `BENCHMARK_KIND` | `sweep` | Benchmark type (`sweep`, `throughput`, `optimum`) |
| `DURATION` | `120s` | Duration of each benchmark step |
| `WARMUP` | `60s` | Warmup duration |
| `MAX_VUS` | `128` | Maximum virtual users |
| `NUM_RATES` | `10` | Number of rate levels to sweep |

Example with custom settings:

```bash
DURATION=30s WARMUP=10s NUM_RATES=3 ./benchmark.sh
```

## Manual Inference Tests

Runs a suite of curl-based tests covering API availability, chat completions, text completions, and throughput:

```bash
./test-inference.sh
```

Tests include:
- Model listing (`GET /v1/models`)
- Chat completions (simple, system prompt, multi-turn, temperature variations)
- Text completions
- Sequential throughput (10 requests)
- Concurrent throughput (5 parallel requests)

Results are saved to `results/<timestamp>-manual/`.

## Extended Inference Tests

Runs a deeper validation suite covering health checks, content correctness, schema validation, determinism, token limit enforcement, streaming (SSE), error handling, large input context, latency SLO, and stop sequences:

```bash
./test-inference-extended.sh
```

Tests include:
- Health & readiness endpoints (`/health`, `/ready`)
- Content validation (math, factual recall, multi-turn memory)
- Response schema validation (chat completions and text completions fields)
- Determinism check (3 identical runs at `temperature=0`)
- Token limit enforcement (`max_tokens` respected)
- Streaming SSE (chunk count, `[DONE]` marker, role in first chunk)
- Error handling (wrong model 404, empty/missing messages 400, invalid params 400)
- Large input context (~200 repeated sentences)
- Latency SLO check (configurable via `LATENCY_SLO_MS`, default 10000ms)
- Stop sequence behavior (`finish_reason=stop`)

Results are saved to `results/<timestamp>-extended/`.

## Qwen Inference Tests

Runs inference tests against the deployed Qwen2.5-3B-Instruct model, covering API availability, chat completions, content validation, schema checks, determinism, streaming, error handling, and throughput:

```bash
./test-inference-qwen.sh
```

Tests include:
- Health & readiness endpoints (`/health`, `/ready`) and model listing
- Chat completions (simple, system prompt, multi-turn, temperature variations)
- Content validation (math, factual recall, multi-turn memory)
- Text completions
- Response schema validation (chat and text completions fields)
- Determinism check (3 identical runs at `temperature=0`)
- Streaming SSE (chunk count, `[DONE]` marker, role in first chunk)
- Error handling (wrong model, empty/missing messages, invalid params)
- Sequential throughput (10 requests) and concurrent throughput (5 parallel)

Results are saved to `results/<timestamp>-qwen/`.

## Files

| File | Purpose |
|---|---|
| `benchmark.sh` | Automated sweep benchmark using inference-benchmarker |
| `test-inference.sh` | Manual curl-based inference tests |
| `test-inference-extended.sh` | Extended validation suite (content, schema, streaming, errors, SLO) |
| `test-inference-qwen.sh` | Qwen model inference tests (API, content, schema, streaming, throughput) |
| `results/` | Timestamped benchmark and test results |