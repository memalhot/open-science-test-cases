# open-science-test-cases

A collection of test cases and examples for open science workflows and deployments.

## Test Cases

| Test Case | Description | Category | Link |
|-----------|-------------|----------|------|
| Model Serving | OpenShift deployment scripts and YAML manifests for deploying a model serving endpoint with vLLM, including ConfigMaps, Secrets, Services, and Routes | Model Serving | [model-serving/granite-model](https://github.com/memalhot/open-science-test-cases/tree/main/model-serving/granite-model) |
| Inference Benchmark | Automated sweep benchmark using [inference-benchmarker](https://github.com/huggingface/inference-benchmarker) to detect max throughput and measure latency across request rates | Inference | [inference/benchmark.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Inference Tests | Manual curl-based inference tests covering chat completions, text completions, sequential and concurrent throughput | Inference | [inference/test-inference.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |

