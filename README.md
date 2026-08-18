# open-science-test-cases

A collection of test cases and examples for open science workflows and deployments.

Before any of the inference, UI, or fine tuning tests can be run, the model must be deployed first.

## Test Cases

| Test Case | Description | Category | Link |
|-----------|-------------|----------|------|
| Model Serving | OpenShift deployment scripts and YAML manifests for deploying a model serving endpoint with vLLM, including ConfigMaps, Secrets, Services, and Routes | Model Serving | [model-serving/granite-model](https://github.com/memalhot/open-science-test-cases/tree/main/model-serving/granite-model) |
| Inference Benchmark | Automated sweep benchmark using [inference-benchmarker](https://github.com/huggingface/inference-benchmarker) to detect max throughput and measure latency across request rates | Inference | [inference/benchmark.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Inference Tests | Manual curl-based inference tests covering chat completions, text completions, sequential and concurrent throughput | Inference | [inference/test-inference.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Extended Inference Tests | Validation suite: content correctness, schema validation, determinism, streaming, error handling, latency SLO, stop sequences | Inference | [inference/test-inference-extended.sh](https://github.com/memalhot/open-science-test-cases/tree/main/inference) |
| Open WebUI | Public chat UI for interacting with the deployed model, using [Open WebUI](https://github.com/endpoints/open-webui) on OpenShift | Endpoints | [endpoints/open-webui](https://github.com/memalhot/open-science-test-cases/tree/main/endpoints/open-webui) |
| Fine-Tuning | QLoRA fine-tuning of Granite 3.0 8B Instruct on OpenShift using a Kubeflow PyTorchJob, with configurable datasets and training parameters | Fine-Tuning | [fine-tuning](https://github.com/memalhot/open-science-test-cases/tree/main/fine-tuning) |
| Component Checks | Validates operator health, DataScienceCluster readiness, GPU node labels, required pods, and networking for the target OpenShift cluster | Platform Readiness | [component-checks](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks) |
| Label & Taint Checks | Verifies GPU node labels (NFD, gpu.count, gpu.product, gpu.memory) and taints (nvidia.com/gpu.product:NoSchedule) to ensure proper GPU isolation | Platform Readiness | [component-checks/taint-checks.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/taint-checks.sh) |
| Negative / Failure-Mode Tests | Verifies that resource over-requests go Pending (not silently queued), pod deletions complete cleanly, and no workloads are stuck Terminating or orphaned Pending | Platform Readiness | [component-checks/negative-tests.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/negative-tests.sh) |

