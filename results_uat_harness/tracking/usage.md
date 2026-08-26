# Test GPU Usage & Runtime

GPU usage = GPUs requested per server pod (per node). Non-GPU tests (t1 platform-check, t3 iperf3, t10 ping) are excluded.

Time is **per node** (u05, u09). Nodes run sequentially, so a whole-test wall clock (u05 + gap + u09) overstates the real compute — these columns show each node's own cycle.

Method: per node, from the first dag-step folder creation to the last dag-step `junit.xml` write, measured on the aggregator PVC (project + peer aggregators). Exceptions:
- t2 (component): single pod, no junit-anchored sweep folder — timed from Kubernetes events (~6s, fast host-file checks).
- t4 (dev-env): single-step notebook writes its folder + junit only at the end, so it isn't junit-anchored; times are approximate from the run gap.
- t5 (kserve): failed both attempts; run 2 duration provided manually. Single project-scoped ISVC, not per-node.
- t11/t12 peer rows: peer pods (server + load) write no junit; they run concurrently with the project side, so timed from peer-server folder creation to the concurrent project-side last junit.

| Test | GPU/node | Runs | u05 time | u09 time | GPU-min |
|------|----------|------|----------|----------|---------|
| t2 (component)               | 4 | 2 | ~6s/run       | ~6s/run   | ~1.6  |
| t4 (dev-env)                 | 4 | 1 | ~6–7m*        | ~6–7m*    | ~54.2 |
| t5 (kserve)                  | 1 | 2 | run 1 failed  | run 2 19m (failed) | 19.0 |
| t6 (guidellm)                | 1 | 1 | 7m36s         | 9m29s     | 17.1  |
| t7 (inference-perf)          | 1 | 1 | 6m21s         | 8m07s     | 14.5  |
| t8 (chunked-prefill)         | 4 | 1 | 10m44s        | 21m43s    | 129.8 |
| t9 (llm-d-local)             | 4 | 1 | 18m31s†       | 17m06s    | 142.5 |
| t11-project (peer-load-high) | 2 | 1 | 6m26s         | 6m12s     | 25.3  |
| t11-peer (peer-load-high)    | 2 | 1 | 7m22s         | 8m57s     | 32.6  |
| t12-project (peer-load-low)  | 2 | 1 | 6m18s         | 6m13s     | 25.0  |
| t12-peer (peer-load-low)     | 2 | 1 | 8m03s         | 9m08s     | 34.4  |
| **Total**                    |   |   |               |           | **~496** |

**Total ≈ 496 GPU-minutes ≈ 8.3 GPU-hours.** GPU-min = GPUs/node × time, summed over both nodes × runs. Kserve counts run 2 only (run 1 duration unknown); t4 uses the estimated ~6.8m/node.

\* t4 dev-env is a single-step notebook test. Unlike the sweep tests, it doesn't create its result folder at pod start and stream files as it runs — it creates the folder *and* writes `junit.xml` together at the end, so folder mtime equals junit mtime (folder→junit measures ~1s, not the real runtime). t4's pod events have also aged out of the cluster, so there's no schedule/completion timestamp to anchor the start. The ~6–7m figure is inferred from the gap between the u05 and u09 folder-creation times (u05 ~00:42:41 → u09 ~00:49:28 ≈ 6m47s): the nodes were run sequentially, so u09 couldn't start until u05 finished, making u05's runtime ≈ that gap. u09's own runtime is unmeasured and assumed similar.
† Includes the u05 Init:Error retry loop before the good run.
