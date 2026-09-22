# New GPU Node Test Pods

GPU pods for the two nodes newly added to oac-prod-workload0: `moc-r4pcc04u12`
and `moc-r4pcc04u16` (4x H100-80GB-HBM3 each).

Each pod is pinned to one node and requests 1 GPU. Reaching `Running` proves the
node takes GPU work end to end — taint tolerated, device plugin allocates the
GPU, NVIDIA container hooks fire, and the RHOAI workbench image starts. The pods
then idle; no workload is run. Exec in to inspect the GPU.

## Usage

```bash
cd new-nodes

oc apply -f gpu-node-test.yaml -n mm-test --as system:admin
oc get pods -l app=gpu-node-test -n mm-test -o wide
oc exec gpu-node-test-moc-r4pcc04u12 -n mm-test -- nvidia-smi
oc delete -f gpu-node-test.yaml -n mm-test --as system:admin
```

First start takes ~3 minutes while the image pulls; the pods stay up until
deleted, so they also hold a GPU reserved on each node for manual testing.

## Image

`jupyter-pytorch-cuda-py312-ubi9:2025.1` from the RHOAI imagestream in
`redhat-ods-applications`, referenced through the internal registry:

```
image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/jupyter-pytorch-cuda-py312-ubi9:2025.1
```

Every service account can pull it — the `cluster-image-pullers` binding grants
`system:image-puller` on that namespace to `system:serviceaccounts`.

## Result — 2026-09-22

Both pods scheduled and reached `Running` on their target node with a GPU
attached:

| Node | Pod | GPU seen in pod | Driver | ECC uncorrected |
|------|-----|-----------------|--------|-----------------|
| `moc-r4pcc04u12` | `gpu-node-test-moc-r4pcc04u12` | NVIDIA H100 80GB HBM3, 81559 MiB | 595.91.07 | 0 |
| `moc-r4pcc04u16` | `gpu-node-test-moc-r4pcc04u16` | NVIDIA H100 80GB HBM3, 81559 MiB | 595.91.07 | 0 |

Both nodes are `Ready`, advertise 4 allocatable `nvidia.com/gpu`, and carry the
`nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3:NoExecute` taint.

## Notes

- Applying the manifest prints PodSecurity `restricted:latest` warnings. They are
  warnings only — the namespace runs these pods fine. Do not add
  `capabilities.drop: ["ALL"]` to silence them: it makes the NVIDIA CDI hook fail
  with `CreateContainerError`.
- Images must be fully qualified on these nodes; short names fail with
  `ImageInspectError`.
- prod and dev have similarly named nodes, so pass `--context` (or check
  `oc whoami --show-server`) before applying.
