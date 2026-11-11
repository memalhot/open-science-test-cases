# VM evictability: what was measured

One run of [`test-vm-evictability.sh`](test-vm-evictability.sh). Eviction
behaviour depends on the KubeVirt build, the VM's eviction strategy, and
whether its disk lets it migrate, so this describes one combination, not the
platform in general.

```
TESTED_CLUSTER=oac-dev-workload0
TESTED_CNV=kubevirt-hyperconverged-operator.v4.22.16
TESTED_NAMESPACE=project-ajamias-testing
TESTED_STORAGECLASS=pure-fb-nfsv4 (pxd.portworx.com, default)
TESTED_NODE=moc-r4pac22u29-s3
CLUSTER_EVICTION_STRATEGY=LiveMigrate
RWX_OUTCOME=live-migrated
RWO_OUTCOME=eviction-denied-no-movement
```

## What it tested

When the platform asks a workload to give up its node, does a VM comply the way
a container does?

Asked twice: once of a VM that can move (ReadWriteMany disk,
`evictionStrategy: LiveMigrate`), once of a VM that cannot (ReadWriteOnce
disk). A container on the same node is the control.

## How it tested

Per mode:

1. Provision a root disk, check the PVC came back with the access mode asked
   for.
2. Boot a 2Gi Fedora VM on it.
3. Start a control container on the same node, also requesting 2Gi.
4. Call the Eviction API on the container, then on the VM's virt-launcher pod.
5. Watch the VMI uid, launcher pod name and node to tell migration from
   restart from nothing.
6. Sum memory requests on the node, split by the `kubevirt.io=virt-launcher`
   label.

It uses the Eviction API, not real memory pressure. Filling a node would evict
other tenants, so that variant stays a manual procedure in the README.

## The result

**A container yields its node. A VM does not.**

| | Eviction API said | What happened |
|---|---|---|
| Control container | `201 Success` | Terminated, replaced. Memory reclaimed. |
| VM, RWX | denied: *Eviction triggered evacuation* | Live migrated. New launcher pod, same VMI uid, `PreCopy`. Memory moved, not freed. |
| VM, RWO | denied: *not live-migratable* | Nothing. Same pod, same node. Memory not freed and not moved. |

On `moc-r4pac22u29-s3`, one VM held 2.27Gi that eviction could not reclaim,
against 88 container pods holding 15.66Gi that it could — 12.7% of the node's
requested memory, unreclaimable.

### The 18 assertions

Nine in `rwx`, eight in `rwo` (the PDB check runs only in `rwx`), one comparing
them. Sixteen passed.

| # | Mode | Assertion | |
|---|------|-----------|---|
| 1 | rwx | PVC came back ReadWriteMany | pass |
| 2 | rwx | VM reached Ready | pass |
| 3 | rwx | Control container Ready on the VM's node | pass |
| 4 | rwx | A PDB protects the VM, none protects the container | **fail** |
| 5 | rwx | Both workloads request the same 2Gi | pass |
| 6 | rwx | Container eviction accepted | pass |
| 7 | rwx | Container terminated — memory reclaimable | pass |
| 8 | rwx | Deployment replaced the container | pass |
| 9 | rwx | VM survived by moving rather than yielding | pass |
| 10 | rwo | PVC came back ReadWriteOnce | pass |
| 11 | rwo | VM reached Ready | pass |
| 12 | rwo | Control container Ready on the VM's node | pass |
| 13 | rwo | Both workloads request the same 2Gi | pass |
| 14 | rwo | Container eviction accepted | pass |
| 15 | rwo | Container terminated — memory reclaimable | pass |
| 16 | rwo | Deployment replaced the container | pass |
| 17 | rwo | VM survived by moving rather than yielding | pass\* |
| 18 | both | Pinned and migratable VMs behave differently | **fail** |

Most of these are scaffolding. 1–3, 5, 10–13 check that the comparison is fair:
right access mode, same node, same memory. 6–8 and 14–16 are the container
baseline — the same call, same node, same size, succeeding every time.

That leaves four that say anything. 4 is a real failure. 18 is an artifact of
the bug below. And **17 passed when it should not have**: the pinned VM
survived, but not by moving — nothing moved.

## Why it happened

**The denial is the protection.** KubeVirt runs a webhook,
`virt-launcher-eviction-interceptor.kubevirt.io`, on every virt-launcher
eviction. It never lets one through. What it does instead depends on whether
the guest can move:

- **Can move:** it rejects the eviction and starts an evacuation. The caller
  sees a failure, the guest sees a live migration. That is why RWX shows a
  denied call and a moved VM at once — and why the node gains nothing, since
  the memory went to another node rather than being freed.
- **Cannot move:** it rejects the eviction, and that is all it can do. That is
  RWO.

**Why RWO cannot move.** Migration runs source and destination at the same
time, so the disk must mount on two nodes at once. ReadWriteOnce cannot. The
access mode decides this, not any VM setting.

**Why the "pinned" VM still had an eviction strategy.** The script sets none
for RWO on purpose, calling it the default a user gets who never sets one. On
this cluster that is not the default — KubeVirt sets it globally:

```
spec.configuration.evictionStrategy: LiveMigrate
```

So the RWO VM inherited `LiveMigrate` and hit the second branch above. A VM
with genuinely no eviction strategy was not tested, and cannot be here without
a per-VM override.

**Why no PDB appeared.** On this build the webhook does the protecting, not a
per-VMI PodDisruptionBudget. Assertion 4 checks for the older mechanism. The
protection exists; it is just not a PDB.

## Two bugs in the script

**The RWO outcome is reported wrongly.** It printed `LIVE MIGRATED — same VMI,
guest never stopped` for a VM that did not move: the webhook said not
live-migratable, and the launcher pod and node were unchanged. The classifier
only checks whether the VMI uid stayed the same, which a refused eviction
satisfies. Its third branch, "accepted but nothing happened", is unreachable —
it requires the uid to be both unchanged and absent.

This caused failure 18 and the false pass on 17. Pinned and migratable VMs do
differ here; the test put both in one bucket, then failed for finding no
difference.

**The destination node is read too early.** RWX reported
`moc-r4pac22u29-s3 -> moc-r4pac22u29-s3` for a migration that happened. The
wait loop exits when the launcher pod name changes and reads `.status.nodeName`
straight away, before it updates. The migration is not in doubt — new pod, same
uid, `PreCopy` — only the destination.

## What it does not show

- Behaviour under real memory pressure. This is the Eviction API, not the
  kubelet.
- What a drain does. `oc adm drain` needs more than namespace edit.
- A VM with no eviction strategy — prevented by the cluster default.
- Any node but `moc-r4pac22u29-s3`.
- Current overhead figures. [`memory-overhead-record.md`](memory-overhead-record.md)
  was taken on CNV 4.22.12; the cluster is now on 4.22.16.

## Reproducing

```bash
cd vm-testing
NAMESPACE=project-ajamias-testing ./test-vm-evictability.sh
```

About nine minutes, mostly CDI importing the root disk twice. Leaves nothing
behind. Needs `pods/eviction`, which `clusterrole/edit` includes.
