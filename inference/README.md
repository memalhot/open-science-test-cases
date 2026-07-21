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

## Files

| File | Purpose |
|---|---|
| `benchmark.sh` | Automated sweep benchmark using inference-benchmarker |
| `test-inference.sh` | Manual curl-based inference tests |
| `results/` | Timestamped benchmark and test results |