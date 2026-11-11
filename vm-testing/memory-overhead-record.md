# VM memory overhead: what was measured

One run of [`test-vm-memory-overhead.sh`](test-vm-memory-overhead.sh). The
overhead figure is a property of a KubeVirt build and of two HyperConverged
settings, so this describes one combination, not the platform in general.

```
TESTED_CLUSTER=oac-dev-workload0
TESTED_CNV=kubevirt-hyperconverged-operator.v4.22.16
TESTED_NAMESPACE=project-ajamias-testing
TESTED_IMAGE=quay.io/kubevirt/cirros-container-disk-demo
TESTED_NODE=moc-r4pac21u03-s3
OVERCOMMIT_PERCENTAGE=unset
ADDITIONAL_OVERHEAD_RATIO=unset
FIXED_OVERHEAD=268Mi
PER_VCPU_OVERHEAD=8Mi
```

## What it tested

How much more node memory does a VM reserve than its guest size, and does that
excess grow with the guest?

It matters because the gap is invisible. A VM asking for 8Gi does not remove
8Gi from what containers can schedule on that node, and nothing in the
VirtualMachine spec says what it does remove.

## How it tested

1. Boot a CirrOS VM on an ephemeral containerDisk at each of 1Gi, 4Gi and 8Gi
   guest memory, one vCPU, one VM at a time.
2. Boot two more at a fixed 4Gi with 1 and 4 vCPU, to separate a vCPU term
   from a memory term.
3. For each, read `requests.memory` from every container of the live
   virt-launcher pod and subtract the configured guest size.
4. Record the HyperConverged settings that rescale the formula, since a figure
   without them is not reproducible elsewhere.

Overhead is measured from the running pod, not from any formula or
documentation. Guest sizes and vCPU counts are the only variables.

## The result

**The overhead is fixed at 268Mi. It does not grow with the guest.**

| Case | Guest | vCPU | compute requests | Overhead | Ratio |
|------|-------|------|------------------|----------|-------|
| mem-1gi | 1Gi | 1 | 1292Mi | 269Mi | ×1.263 |
| mem-4gi | 4Gi | 1 | 4364Mi | 269Mi | ×1.066 |
| mem-8gi | 8Gi | 1 | 8460Mi | 269Mi | ×1.033 |
| cpu-1 | 4Gi | 1 | 4364Mi | 269Mi | ×1.066 |
| cpu-4 | 4Gi | 4 | 4388Mi | 293Mi | ×1.072 |

The arithmetic is exact: 1024+268, 4096+268, 8192+268. The extra ~1Mi in the
overhead column is the containerdisk container, which requests a flat `1M`.

Because the cost is fixed, the *ratio* falls as the guest grows. A 1Gi VM costs
26% more than it claims; an 8Gi VM costs 3.3%. **Small VMs are the expensive
ones per Gi**, which is the opposite of the intuition the script was built
around.

vCPU count does add a term: at a constant 4Gi, going from 1 to 4 vCPU moved the
request from 4364Mi to 4388Mi — 24Mi for three vCPUs, about 8Mi each.

Every VM landed in Burstable QoS, and KubeVirt set `limits` at twice `requests`
in every case. The 8Gi VM carried a 16.56Gi memory limit that nothing in its
spec mentions.

### The 12 assertions

Two per case — the VM booted, and its pod requested more than the guest size —
plus two comparisons at the end. Eleven passed.

| # | Case | Assertion | |
|---|------|-----------|---|
| 1 | mem-1gi | VM reached Ready | pass |
| 2 | mem-1gi | Pod requests more than the guest memory | pass |
| 3 | mem-4gi | VM reached Ready | pass |
| 4 | mem-4gi | Pod requests more than the guest memory | pass |
| 5 | mem-8gi | VM reached Ready | pass |
| 6 | mem-8gi | Pod requests more than the guest memory | pass |
| 7 | cpu-1 | VM reached Ready | pass |
| 8 | cpu-1 | Pod requests more than the guest memory | pass |
| 9 | cpu-4 | VM reached Ready | pass |
| 10 | cpu-4 | Pod requests more than the guest memory | pass |
| 11 | sweep | Overhead at 8Gi differs from 1Gi — it scales with guest size | **fail** |
| 12 | sweep | Overhead at 4 vCPU exceeds 1 vCPU at equal memory | pass |

Assertions 1–10 establish that overhead exists and is positive at every size.
A non-positive result there would mean the node is oversubscribed by design,
which is why the script checks the overcommit percentage first.

Assertion 11 is the failure, and it is the finding. The script asserts that
overhead has a term growing with guest size. On this build it has none.

## Why it happened

**The request is computed, not declared.** virt-controller sets the
virt-launcher pod's memory request to the guest size plus an overhead it
calculates — QEMU itself, the per-VMI infrastructure, and a safety margin. None
of it appears in the VirtualMachine spec, which is why the gap is invisible
until a container that should fit does not.

**Why the overhead does not scale with the guest.** The part of the formula
that would scale is page tables, which cost roughly 2MiB per GiB of guest
address space. Across 1Gi to 8Gi that is about 14Mi, and 14Mi would have been
visible against an otherwise exact constant. Nothing moved. Either this build
omits a guest-proportional term or it is folded into the fixed figure;
distinguishing the two needs the KubeVirt source for 4.22.16, not an
observation from outside.

**Why the vCPU term is real.** 8Mi per vCPU is small but it is not noise: the
memory term is constant to the byte across three guest sizes, so a 24Mi shift
with vCPU count is clearly attributable.

**Why the assertion failed rather than the platform.** The script's closing
comment reasons that hard-coding an overhead figure would turn a routine
upgrade into a test failure, and asserts the *shape* instead. The shape turned
out to be just as much a version property as the figure. Whether to relax
assertion 11 to "overhead exists and grows with vCPU count", or keep it as a
tripwire for a future build that reintroduces a scaling term, has not been
decided.

**The result is stable across an upgrade.** These figures are byte-identical to
a run on 2026-11-04 under CNV 4.22.12, with both HCO settings unset then too.

## What it does not show

- **That the guest cannot see the overhead.** Run with
  `CHECK_GUEST_MEMTOTAL=0`. The namespace NetworkPolicy admits ingress only
  from pods in the same namespace, and `virtctl ssh` arrives via the
  hostNetwork virt-handler in `openshift-cnv`, so the SSH cannot complete here.
- **Anything above 8Gi.** A term appearing only at larger address spaces would
  not have been seen.
- **Why limits are twice requests.** Observed in every case, not explained by
  anything in the VM spec.
- **Any node but `moc-r4pac21u03-s3`**, where all five VMs were scheduled.
- **That the overhead is unreclaimable.** That claim belongs to
  [`evictability-record.md`](evictability-record.md), which measures it
  directly.

## Reproducing

```bash
cd vm-testing
NAMESPACE=project-ajamias-testing CHECK_GUEST_MEMTOTAL=0 ./test-vm-memory-overhead.sh
```

About four minutes, leaves nothing behind. Drop `CHECK_GUEST_MEMTOTAL=0` only
where `virtctl ssh` works; where it does not, each VM spends roughly seventeen
minutes in the retry loop before giving up with a warning.
