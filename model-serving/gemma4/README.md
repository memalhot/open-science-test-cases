# Gemma 4 vLLM serving — cluster validation

Goal: prove this cluster can stand up a Gemma 4 model for inference serving.
Scope: internal smoke test, **not** the customer deliverable. Single model,
2×H100 (tensor-parallel), no encryption/auth.

> Status: validated on `api-oac-prod` 2026-08-24 (PASS), then torn down.
> Repeatable via `scripts/` (kustomize base + up/down/test). Full procedure and
> success criteria: **TEST-PLAN.md**. Manual curl reference: **TESTING.md**.

Target: namespace `eldritchjs-sandbox` on `api-oac-prod` (MOC/NERC OAC).

## What the pre-flight probe already confirmed
- GPU pods schedule in this namespace and are NOT Kueue-gated (got an H100).
- Egress to `huggingface.co` works (HTTP 200).
- Weight-CDN egress still UNCONFIRMED (see pre-flight step 0).

## Model: google/gemma-4-31B-it (VERIFIED on HF)
- License **Apache 2.0**, **UNGATED** — no license click-through, no gated-repo
  token permission needed. HF token is optional (kept only for rate limits).
- 30.7B dense params, BF16 (~62GB weights). Too tight for one 80GB H100 once KV
  cache is added -> served with **tensor-parallel across 2x H100**.
- Repo id is **case-sensitive**: capital `B` in `31B`.
- Alternative if we ever want it on a single GPU: the QAT checkpoint
  `google/gemma-4-31B-it-qat-w4a16-ct` (compressed-tensors for vLLM, ~1/4 size).

## Open items to resolve BEFORE applying
1. **HF token (optional)** — create the `hf-token` secret (see
   02-hf-secret.example.yaml). Not strictly required for this public Apache
   model, but improves download reliability/rate limits. A plain fine-grained
   READ token is enough; no gated permission needed.
2. ~~vLLM image tag~~ RESOLVED — pinned to `vllm/vllm-openai:gemma4` (CUDA 12.9).
   This tag bundles transformers>=5.5.0; generic `:latest` fails to load the
   gemma4 architecture. (`:gemma4-cu130` exists but needs a newer driver.)
3. **External image pull** — confirm the cluster can pull `vllm/vllm-openai`
   from docker.io (no blocking ImageContentSourcePolicy). RHOAI ships a
   supported vLLM ServingRuntime we can fall back to if docker.io is blocked.
   (Only truly verifiable at run time; pre-flight step in the runbook.)

## Runbook

Manifests are now a kustomize base driven by `scripts/config.conf`. See
**TEST-PLAN.md** for the full procedure. Quick version:

    cd scripts
    $EDITOR config.conf         # set namespace, TP_SIZE/GPU_COUNT, MODEL_ID, ...
    ./up.sh                    # apply + wait for Ready + print endpoint
    ./test.sh                  # smoke test (models, chat, GPU); --stream --gpu

Manual equivalent: `oc apply -k base` (defaults) or `oc apply -k overlays/current`.

## Teardown

    cd scripts
    ./down.sh                  # FULL: release GPUs AND delete weight cache
    ./down.sh --keep-cache     # release GPUs, keep PVC for a fast re-run

## Notes / decisions
- Plain Deployment + Route (not KServe) chosen for a fast dev spike. KServe is
  available and is the "proper" path if this graduates beyond a smoke test.
- One model per vLLM server: multi-model later = N of these, or MIG/time-slice
  to pack several on fewer GPUs.
- Success criteria: pod Ready, `/v1/models` lists `gemma-4`, chat completion
  returns coherent text generated on the H100.
