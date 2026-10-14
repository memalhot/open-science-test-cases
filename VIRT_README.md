# Virtualization Test Outline

What has been tested on OpenShift Virtualization (CNV), and what passed.

All runs are against `oac-dev-workload0`, namespace `mm-test` (the networking suite defaults to `vm-test`). Guest images are CirrOS (`quay.io/kubevirt/cirros-container-disk-demo`) for networking and Fedora Linux 41 Cloud Edition (`quay.io/containerdisks/fedora:41`) for everything that needs a real disk. VM disks land on `pure-fb-nfsv4` (provisioner `pxd.portworx.com`), which is what CDI picks on its own.

The test scripts run entirely as the logged-in user — no `--as system:admin` anywhere — so what they prove is what a real project user can actually do. The one exception is the migration RBAC grant, which a cluster admin applies once per namespace; see [Finding 2](#finding-2-no-shipped-role-delegates-live-migration).

Detail for every suite, including configuration variables and how each check works, is in [vm-testing/README.md](vm-testing/README.md).

## Test Cases

| Test Case | Description | Category | Completion | Notes | Link |
|-----------|-------------|----------|------------|-------|------|
| OpenShift Virtualization Checks | Validates CNV health: virt/CDI/networking Deployments and DaemonSets, HyperConverged, KubeVirt, CDI, NetworkAddonsConfig and SSP conditions, and that the VirtualMachine, VirtualMachineInstance, and DataVolume APIs are served | Platform Readiness | Done | All checks passed | [component-checks/oc-virt-checks.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/oc-virt-checks.sh) |
| VM Network Tests | Boots a CirrOS VM on an ephemeral `containerDisk` and verifies pod-network connectivity from inside the guest: egress ICMP, DNS resolution, and HTTP, plus inbound access and file transfer over `virtctl ssh`/`scp` | Virtualization | Done | 6 passed, 0 failed | [vm-testing/test-vm.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-testing/test-vm.sh) |
| VM Persistent Storage Tests | Provisions a VM root disk as a PVC through CDI, boots a Fedora guest from it, writes a marker inside the guest, then fully stops and restarts the VM and reads the marker back; also reports guest-agent, RWX and `LiveMigratable` status | Virtualization | Done | 9 passed, 0 failed | [vm-testing/test-vm-storage.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-testing/test-vm-storage.sh) |
| VM Live Migration Tests | Boots a VM on an RWX PVC, starts a heartbeat inside the guest, migrates it to another node, and verifies it moved without rebooting: same VMI object, unchanged kernel `boot_id`, disk and data intact, and guest pause within budget | Virtualization | Done | 13 passed, 0 failed. Migrated between nodes in 2s (PreCopy) with 0.189s guest-visible downtime | [vm-testing/test-vm-migration.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-testing/test-vm-migration.sh) |
| VM Disk Clone Tests | Asks the same StorageClass to clone a disk five ways — a non-cloning control, a bare CSI clone, a CDI clone with no hints, a forced host-assisted copy, and a forced snapshot clone — to locate which layer cloning breaks at | Virtualization | Done | **Fails on this cluster, by design** — 2 of 5 phases succeeded. Reproduces the broken clone path and confirms the snapshot workaround; see [Finding 1](#finding-1-cloning-is-broken-on-pure-fb-nfsv4) | [vm-issues/test-vm-clone.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-issues/test-vm-clone.sh) |

## VM Performance Compared With Pods

The test cases above check that VMs work. These measurements show what running inside a VM costs. Each one runs the same workload from a pod and from a KubeVirt VM on the same node, then compares the two.

They were run with the [AI UAT harness](https://github.com/asanaullah/ai-uat-harness/tree/tests) on `oac-dev-workload0` on 2026-10-12:

- **Where:** namespace `uat-project`, on the two GPU nodes `moc-r4pcc02u05` and `moc-r4pcc02u09`.
- **Size:** every pod and VM had 16 CPU and 32Gi of memory, with requests equal to limits.
- **Repeats:** each entry is a single run.

| Harness test | What it measures | Definition | Description |
|--------------|------------------|------------|-------------|
| `iperf3` | TCP bandwidth from pod to pod | [test_lib/iperf3.yaml](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/iperf3.yaml) | [README §4](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/README.md#4-iperf3) |
| `iperf3-virt` | TCP bandwidth between a pod and a VM, in both directions | [test_lib/iperf3-virt.yaml](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/iperf3-virt.yaml) | [README §14](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/README.md#14-iperf3-virt) |
| `fio` | Storage throughput, IOPS and latency from a pod | [test_lib/fio.yaml](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/fio.yaml) | [README §15](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/README.md#15-fio) |
| `fio-virt` | The same, from inside a VM | [test_lib/fio-virt.yaml](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/fio-virt.yaml) | [README §16](https://github.com/asanaullah/ai-uat-harness/blob/tests/test_lib/README.md#16-fio-virt) |

The network pair ran from [examples/iperf3-virt.yaml](https://github.com/asanaullah/ai-uat-harness/blob/tests/examples/iperf3-virt.yaml) and the storage pair from [examples/fio-virt.yaml](https://github.com/asanaullah/ai-uat-harness/blob/tests/examples/fio-virt.yaml).

### Network: How It Was Measured

- **Same node.** Both tests ran at node scope, which the harness runs separately on each node in the cluster config, pinned with `nodeSelector`. Client and server were on the same node, so the traffic stayed inside the node and pod to pod is the baseline for the VM figures.
- **Pod to pod.** An `iperf3 -s` server pod and a client pod, both `docker.io/networkstatic/iperf3:latest`, connected through a headless Service on port 5201.
- **Pod to VM and VM to pod.** The server is a KubeVirt VM booted from `quay.io/containerdisks/fedora:latest`, with 16 cores, 32Gi, and a virtio interface with multiqueue on the pod network (masquerade). cloud-init installs `iperf3` and starts `iperf3 --server --daemon`. The client is the same pod image. "VM to pod" entries add `--reverse`, so the VM sends.
- **Each entry.** `iperf3` runs for 10 seconds, omits the first 2, and uses 1, 2, 4, 8 or 16 parallel streams. The figure recorded is the receiver's total, `sum_received.bits_per_second`, shown in Gbit/s.
- **VM start-up** is how long the first client waited for port 5201 on the VM to accept connections. The client keeps trying for up to 480 seconds.

### Network: Results

Bandwidth is in Gbit/s. The share columns give the VM figure as a share of pod to pod.

**`moc-r4pcc02u05`**

| Streams | Pod to pod | Pod to VM | VM to pod | Pod to VM share | VM to pod share |
|---------|------------|-----------|-----------|-----------------|-----------------|
| 1 | 19.0 | 15.0 | 15.3 | 79% | 81% |
| 2 | 36.4 | 23.8 | 26.3 | 65% | 72% |
| 4 | 76.5 | 50.3 | 45.5 | 66% | 59% |
| 8 | 130.2 | 97.1 | 87.4 | 75% | 67% |
| 16 | 224.9 | 119.5 | 123.9 | 53% | 55% |

**`moc-r4pcc02u09`**

| Streams | Pod to pod | Pod to VM | VM to pod | Pod to VM share | VM to pod share |
|---------|------------|-----------|-----------|-----------------|-----------------|
| 1 | 11.9 | 4.1 | 7.4 | 34% | 62% |
| 2 | 22.1 | 9.7 | 11.3 | 44% | 51% |
| 4 | 42.5 | 17.9 | 23.8 | 42% | 56% |
| 8 | 82.2 | 36.2 | 35.5 | 44% | 43% |
| 16 | 143.9 | 55.1 | 54.3 | 38% | 38% |

**VM start-up** (first client's wait for port 5201)

| Node | Wait |
|------|------|
| `moc-r4pcc02u05` | 31 s |
| `moc-r4pcc02u09` | 54 s |

What the numbers show:

- **KubeVirt costs network bandwidth on both nodes.** The VM path reaches 53–81% of pod to pod on `moc-r4pcc02u05` and 34–62% on `moc-r4pcc02u09`, and the share is lowest at 16 streams on both.
- **`moc-r4pcc02u05` is faster than `moc-r4pcc02u09` in every row, pod to pod included.** The two nodes differ in CPU sleep states: they are off on `moc-r4pcc02u05` and on on `moc-r4pcc02u09`. These runs do not show whether that is the cause.

### Storage: How It Was Measured

- **Placement.** Both tests ran at cluster scope with one node per set (`setSize: 1`, `setSelection: all`), which ran them on each node in turn.
- **Pod (`fio`).** A `golang:1.26` pod builds fio from tag `fio-3.43` and runs it in `/uat_scratchpad/fio-data` on the claim `uat-project-storage` (storage class `pure-fb-nfsv4`).
- **VM (`fio-virt`).** A Fedora VM (`quay.io/containerdisks/fedora:latest`, 16 cores, 32Gi) gets the claim `uat-project-storage-virt`, same storage class, as a second virtio disk. cloud-init formats that disk XFS if it is blank, mounts it at `/uat_workspace`, builds fio from the same tag and starts `fio --server`. A client pod (`golang:1.26`, 16 CPU, 32Gi) builds fio too and sends each job to the VM through a headless Service on port 8765. The jobs run in `/uat_workspace`.
- **Job settings, the same for every entry.** `ioengine=psync`, `direct=1`, `size=1G` per job, 30 seconds time-based, `group_reporting`, `unlink=1`. Sequential write and read use 1M blocks, random write and read use 4k blocks, each with 1 job and with 16 jobs.
- **What is recorded.** Throughput (`bw_bytes` / 10^6, shown as MB/s), IOPS, and completion latency at the 50th and 99th percentiles (`clat_ns`, shown in ms). VM share is VM MB/s as a share of pod MB/s.
- **Start-up times.** "fio build" is the time to build fio in the pod and in the VM's client pod. "VM ready after" is how long the client waited for the VM's fio server on port 8765, for up to 480 seconds.

### Storage: Results

- **VM cost on storage is smaller than on the network.** The VM reaches 55–107% of the pod, against 34–81% for iperf3. Large sequential I/O at 16 jobs is nearly equal (83–107%); the larger gaps are in single-job and random-write entries.
- **Random write at 16 jobs is the VM's weakest point on both nodes:** 61% and 68% of the pod, with p99 latency rising from about 1 ms to about 7 ms.
- **The single-file concern didn't show up for sequential I/O.** 16 jobs into one VM disk image kept pace with 16 separate files from the pod.
- **`moc-r4pcc02u09` is slower again, in the pod baseline too.** At 16 jobs it reaches 59% of `moc-r4pcc02u05` for sequential write and 54% for sequential read. Since the storage backend is shared, this points at the node, as the network results did.

**`moc-r4pcc02u05`**

| Entry | Pod MB/s | VM MB/s | VM share | Pod IOPS | VM IOPS | Pod p50 / p99 ms | VM p50 / p99 ms |
|-------|----------|---------|----------|----------|---------|------------------|-----------------|
| seq write, 1 job | 319 | 285 | 89% | 305 | 272 | 3.13 / 4.62 | 3.49 / 4.95 |
| seq write, 16 jobs | 3,211 | 3,036 | 95% | 3,062 | 2,896 | 5.14 / 7.11 | 5.41 / 7.57 |
| seq read, 1 job | 1,109 | 910 | 82% | 1,058 | 868 | 0.91 / 1.58 | 1.11 / 1.83 |
| seq read, 16 jobs | 2,759 | 2,300 | 83% | 2,631 | 2,194 | 6.06 / 9.24 | 6.91 / 13.43 |
| rand write, 1 job | 5.9 | 4.7 | 78% | 1,450 | 1,136 | 0.64 / 1.50 | 0.86 / 1.45 |
| rand write, 16 jobs | 90.7 | 55.7 | 61% | 22,135 | 13,610 | 0.69 / 1.09 | 0.96 / 6.72 |
| rand read, 1 job | 14.8 | 9.9 | 67% | 3,615 | 2,415 | 0.21 / 0.95 | 0.33 / 0.92 |
| rand read, 16 jobs | 116.6 | 103.2 | 89% | 28,458 | 25,202 | 0.54 / 1.19 | 0.63 / 1.14 |

**`moc-r4pcc02u09`**

| Entry | Pod MB/s | VM MB/s | VM share | Pod IOPS | VM IOPS | Pod p50 / p99 ms | VM p50 / p99 ms |
|-------|----------|---------|----------|----------|---------|------------------|-----------------|
| seq write, 1 job | 301 | 214 | 71% | 287 | 204 | 3.36 / 4.62 | 4.69 / 6.32 |
| seq write, 16 jobs | 1,895 | 1,861 | 98% | 1,807 | 1,774 | 8.59 / 13.04 | 8.36 / 16.06 |
| seq read, 1 job | 790 | 567 | 72% | 753 | 541 | 1.27 / 1.94 | 1.79 / 2.51 |
| seq read, 16 jobs | 1,492 | 1,593 | 107% | 1,423 | 1,519 | 10.94 / 20.84 | 10.16 / 18.74 |
| rand write, 1 job | 4.1 | 3.7 | 89% | 1,008 | 898 | 0.99 / 1.25 | 1.09 / 1.84 |
| rand write, 16 jobs | 68.4 | 46.4 | 68% | 16,699 | 11,320 | 0.91 / 1.50 | 1.25 / 6.85 |
| rand read, 1 job | 11.2 | 6.2 | 55% | 2,735 | 1,506 | 0.32 / 0.91 | 0.59 / 1.20 |
| rand read, 16 jobs | 97.9 | 84.1 | 86% | 23,897 | 20,527 | 0.66 / 1.27 | 0.77 / 1.38 |

**Start-up**

| Node | fio build (pod / VM client) | VM ready after |
|------|-----------------------------|----------------|
| `moc-r4pcc02u05` | 6 s / 6 s | 56 s |
| `moc-r4pcc02u09` | 10 s / 10 s | 79 s |

