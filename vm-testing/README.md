# VM Testing

Seven test suites for OpenShift Virtualization.

Does virtualization work?

- **Networking** (`test-vm.sh`, `net-test-vm.yaml`) — a CirrOS VM on an ephemeral `containerDisk`, checking egress and inbound reachability.
- **Persistent storage** (`test-vm-storage.sh`) — a Fedora VM on a CDI-provisioned PVC, checking that guest data survives a stop/start.
- **Live migration** (`test-vm-migration.sh`) — the same VM moved between nodes while running, checking that the guest never reboots.
- **Disk cloning** (`test-vm-clone.sh`) — no VM at all; asks the same StorageClass to clone a disk four different ways and reports which, if any, work.

What do VMs do to everything else on the cluster?

- **Secondary-network IPAM** (`test-vm-secondary-ipam.sh`) — fills a small secondary network with VMs, then checks that containers draw from the same pool, that exhaustion is legible, and that addresses come back.
- **Memory overhead** (`test-vm-memory-overhead.sh`) — measures how much more node memory a VM reserves than its guest size, across a sweep of sizes and vCPU counts.
- **Evictability** (`test-vm-evictability.sh`) — evicts a VM and an equivalent container pod and compares what the platform does with each.

Each test deletes what it created on exit. `cleanup.sh` is there for when that did not happen — see [The cleanup script](#the-cleanup-script) at the end.

## Prerequisites

Most suites require `oc` and `virtctl`, authenticated to the target cluster, with OpenShift Virtualization installed (see `component-checks/oc-virt-checks.sh`). `test-vm-clone.sh` needs only `oc`, since it never boots a guest; so do `test-vm-secondary-ipam.sh` and `test-vm-evictability.sh`, which never log into a guest. The three interaction suites also need `jq`. `virtctl` is not bundled with `oc`; get its download URL with:

```bash
oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o jsonpath='{.spec.links[*].href}'
```

The scripts run as the logged-in user, so what they prove is what a real project user can actually do. Creating VMs, DataVolumes and PVCs works with ordinary namespace edit rights, and so does evicting a pod (`pods/eviction` is part of `clusterrole/edit`). Two things do not: **migration** and **defining a secondary network**, each of which needs a one-time RBAC grant below.

There is exactly one `--as system:admin` in the suite, in `test-vm-secondary-ipam.sh`, on a non-mutating read; see [the secondary-network RBAC section](#one-time-secondary-network-rbac) for why it is there and how to turn it off.

### One-time: migration RBAC

KubeVirt ships no role that delegates migration. Neither `kubevirt.io:edit` nor `kubevirt.io:admin` includes the `virtualmachines/migrate` subresource or `create` on `VirtualMachineInstanceMigration` — both only get `get`/`list`/`watch` — so it is cluster-admin-only until granted explicitly. Without it `virtctl migrate` fails with:

```
virtualmachines.subresources.kubevirt.io "my-vm" is forbidden: User "you@example.com"
cannot update resource "virtualmachines/migrate" in API group "subresources.kubevirt.io"
```

`migrate-rbac.yaml` creates a namespaced Role and RoleBinding granting exactly the two permissions needed. A cluster admin applies it once per namespace:

```bash
oc process --local -f migrate-rbac.yaml \
  -p NAMESPACE=mm-test \
  -p USER_NAME=$(oc whoami) \
  | oc apply --as system:admin -f -
```

`--local` matters: without it `oc process` tries to create a `processedtemplates` object in `default` and is denied.

| Rule | Grants |
|------|--------|
| `subresources.kubevirt.io` → `virtualmachines/migrate` : `update` | what `virtctl migrate` calls |
| `kubevirt.io` → `virtualmachineinstancemigrations` : `get,list,watch,create,delete` | the object-based path used by `test-vm-migration.sh`; `delete` also covers `virtctl migrate-cancel` |

Verify, then remove when no longer wanted:

```bash
oc auth can-i update virtualmachines/migrate -n mm-test          # yes
oc auth can-i create virtualmachineinstancemigrations -n mm-test # yes

oc delete role,rolebinding vm-live-migrator -n mm-test --as system:admin
```

Applied on `oac-dev-workload0` for `memalhot@redhat.com` in `mm-test`. Confirmed scoped — the same check in another namespace returns `no`.

### One-time: secondary-network RBAC

`test-vm-secondary-ipam.sh` needs to create a `NetworkAttachmentDefinition`, and no shipped role allows that. `clusterrole/edit` has no rule for the resource at all; `clusterrole/admin` grants only read:

```bash
oc get clusterrole admin -o json \
  | jq -r '.rules[] | select(.apiGroups[]? == "k8s.cni.cncf.io")
           | [(.resources|join(",")), (.verbs|join(","))] | @tsv'
# network-attachment-definitions    watch,list,get
```

So a project admin can see every secondary network in their namespace and define none of them. `ipam-rbac.yaml` grants exactly the missing verbs, namespaced, and a cluster admin applies it once:

```bash
oc process --local -f ipam-rbac.yaml \
  -p NAMESPACE=mm-test \
  -p USER_NAME=$(oc whoami) \
  | oc apply --as system:admin -f -
```

`--local` matters for the same reason it does above: without it `oc process` tries to create a `processedtemplates` object in `default` and is denied.

| Rule | Grants |
|------|--------|
| `k8s.cni.cncf.io` → `network-attachment-definitions` : `get,list,watch,create,delete` | defining the test network, and cleaning it up afterwards |

Verify, then remove when no longer wanted:

```bash
oc auth can-i create network-attachment-definitions -n mm-test   # yes

oc delete role,rolebinding vm-secondary-net-admin -n mm-test --as system:admin
```

#### The one admin read, and why it is an exception

The grant above deliberately does **not** cover whereabouts `IPPool` objects. Those record which address is held by which pod, they are cluster-scoped, and no namespaced Role can reach them:

```
$ oc get ippools -A
Error from server (Forbidden): ippools.whereabouts.cni.cncf.io is forbidden:
User "..." cannot list resource "ippools" ... at the cluster scope
```

That denial is not an obstacle to the test, it is one of its results — it is why an ordinary operator cannot tell a full pool from a leaking one. So step 6 of the script prints two views: first the holders an unprivileged user can infer by reading pod annotations, then the authoritative allocation table read with an explicit `--as system:admin`. The impersonation is scoped to that single non-mutating `oc get`, and `ADMIN_IPPOOL_READ=0` drops it entirely, leaving only the view a real user has.

---

# VM Network Testing

Verifies that OpenShift Virtualization can run a VM with working pod-network connectivity. Boots a minimal CirrOS VM and checks outbound IP reachability, DNS resolution, and inbound access through a port forward.

Confirmed working on the OAC dev cluster.

## Usage

```bash
cd vm-testing
oc apply -f net-test-vm.yaml
```

Requires `oc` and `virtctl`, authenticated to the target cluster, with OpenShift Virtualization installed (see `component-checks/oc-virt-checks.sh`).

## Steps

1. **Create the VM** — `oc apply -f net-test-vm.yaml` creates `net-test-vm`, a CirrOS VM (`quay.io/kubevirt/cirros-container-disk-demo`) on a `containerDisk` volume with a masquerade interface on the default pod network.

2. **Wait for it to boot** — `oc get vmi net-test-vm` until the phase is `Running`.

3. **Open a console** — `virtctl console net-test-vm`, then log in with the credentials printed on the CirrOS login banner.

4. **Test outbound IP** — `ping -c 3 8.8.8.8`

5. **Test DNS** — `ping google.com` or `curl -I google.com`

6. **Exit the console** — `Ctrl+]`

7. **Test inbound connectivity** — port-forward to the VM and check the port is reachable:

   ```bash
   oc port-forward svc/net-test-ssh 2222:22
   ```

   Then in another terminal:

   ```bash
   nc -zv 127.0.0.1 2222
   ```

## Cleanup

```bash
oc delete -f net-test-vm.yaml
```

## Notes

The `net-test-ssh` Service used in step 7 is not included in this directory — create a Service selecting `kubevirt.io/vm: net-test-vm` on port 22 before running the port forward.

---

# VM Persistent Storage Testing

`test-vm.sh` boots from a `containerDisk`, which is a copy-on-write overlay discarded when the VMI stops — it proves compute and networking work and nothing about storage. `test-vm-storage.sh` covers the gap: it provisions a real PVC root disk through CDI, boots a Fedora guest off it, writes a unique marker inside the guest, fully stops and restarts the VM, and reads the marker back.

```bash
cd vm-testing
./test-vm-storage.sh
```

Takes roughly 3-4 minutes end to end and deletes everything it created on exit.

## What it asserts

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | DataVolume reaches `Succeeded` | CDI actually provisions a disk. `oc-virt-checks.sh` only confirms the CDI operators are `Available`, which is a weaker claim |
| 2 | PVC is `Bound` at the requested size | The StorageClass serves VM disks, not just pod volumes |
| 3 | VMI `volumeStatus` shows `rootdisk` backed by the PVC | The VM really booted off persistent storage, not an ephemeral disk |
| 4 | Guest answers `virtctl ssh` | cloud-init ran and the image is a usable guest |
| 5 | Marker written and `sync`ed in-guest | Data reached the disk, not just the page cache |
| 6 | VMI object is deleted after `virtctl stop` | The guest and its virt-launcher pod were genuinely torn down |
| 7 | VM restarts and reaches `Ready` | — |
| 8 | PVC UID is unchanged | The disk was reused, not silently reprovisioned |
| 9 | Marker reads back after the restart | **The actual persistence claim** |

It also reports, without failing: whether `qemu-guest-agent` is connected, whether the disk is `ReadWriteMany`, and the VMI's `LiveMigratable` condition — the three prerequisites a live-migration test needs.

## Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `NAMESPACE` | `mm-test` | also honours `PROJECT` |
| `SOURCE_MODE` | `registry` | `registry` imports a container disk; `datasource` clones an SSP golden image |
| `IMAGE_URL` | `docker://quay.io/containerdisks/fedora:41` | used when `SOURCE_MODE=registry` |
| `DATA_SOURCE` | `fedora` | used when `SOURCE_MODE=datasource`; `oc get datasource -n openshift-virtualization-os-images` lists them |
| `GUEST_USER` | `fedora` | `cloud-user` for the `rhel*` images |
| `DISK_SIZE` | `10Gi` | must be at least the source image size when cloning |
| `STORAGE_CLASS`, `ACCESS_MODE` | unset | unset means CDI picks from the StorageProfile, which is what a real user gets |
| `DV_STALL` | `240` | seconds of no progress before the disk provisioning step is called stalled |
| `KEEP_VM` | `0` | `1` leaves the VM and disk in place for `virtctl console` |

## Result: 9 passed, 0 failed

Run against `mm-test` on `oac-dev-workload0`, Fedora Linux 41 Cloud Edition on a 10Gi `pure-fb-nfsv4` PVC. Import took about 20 seconds; the marker survived the stop/start; the guest agent connected, the disk came back RWX, and the VMI reported `LiveMigratable=True`.

## Known issue: cloning is broken on `pure-fb-nfsv4`

`SOURCE_MODE=registry` is the default because `SOURCE_MODE=datasource` does not work on this cluster, and the failure is silent — the DataVolume never reports `Failed`, it retry-loops indefinitely. The two strategies CDI will choose on its own both fail:

- **`csi-clone`** — the PVC event reads `rpc error: code = Unimplemented desc = volume cloning is not supported for FlashBlade`. The StorageProfile nonetheless advertises `cloneStrategy: csi-clone`, so CDI keeps choosing a strategy the driver cannot serve.
- **host-assisted `copy`** (forced with the `cdi.kubevirt.io/cloneType: copy` annotation) — gets further, standing up a source pod and an upload server, then the upload server dies untarring onto the target: `error unarchiving to /data: exit status 2`, and the clone restarts from the beginning.

A third strategy, **`snapshot`**, does work — see [VM Disk Clone Testing](#vm-disk-clone-testing) below, which tests all three and confirms the snapshot path produces a correctly sized, bound RWX disk. The fix is to set `spec.cloneStrategy: snapshot` on `storageprofile/pure-fb-nfsv4` in the GitOps repo; it is currently unset, so `csi-clone` is just CDI's default for this provisioner.

This affects more than this test. Cloning a golden image is the path the console's **Create VirtualMachine → from template** button takes, so provisioning a VM through the UI on the default StorageClass hangs with no error surfaced to the user. Worth raising with whoever owns the Pure/Portworx CSI configuration.

The `DV_STALL` detector exists because of this: it fails the test in about four minutes with the CDI worker pod logs attached, rather than spinning for the full `DV_TIMEOUT`.

---

# VM Live Migration Testing

Live migration is what makes node maintenance survivable for VM users. Drains, cluster upgrades and MachineConfig rollouts all evict VMs; without it, each of those hard-kills the guest and loses whatever was in RAM. `test-vm-migration.sh` boots a VM on an RWX PVC, starts a heartbeat inside the guest, migrates it to another node, and checks that the same kernel came out the other side.

```bash
cd vm-testing
./test-vm-migration.sh
```

Takes roughly 3-4 minutes end to end and deletes everything it created on exit.

## What it asserts

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | DataVolume reaches `Succeeded` | Setup — the disk must exist before anything can move |
| 2 | Root disk is `ReadWriteMany` | A shared disk is the precondition; an RWO disk pins the VM to one node |
| 3 | VM boots and reaches `Ready` | — |
| 4 | Guest answers `virtctl ssh` before migrating | Establishes a working baseline to compare against |
| 5 | In-guest heartbeat starts | Setup for the downtime measurement |
| 6 | VMI reports `LiveMigratable=True` | KubeVirt's own up-front verdict. If false, its `reason` names the blocker and the test stops there rather than failing obscurely later |
| 7 | Migration reaches `Succeeded` | The `VirtualMachineInstanceMigration` finished, `migrationState.failed` is not set |
| 8 | VM is on a different node | It actually moved |
| 9 | VMI UID is unchanged | The object was not deleted and recreated |
| 10 | Guest answers SSH after migrating | It is still usable |
| 11 | **Guest `boot_id` is unchanged** | **The decisive check** — see below |
| 12 | Marker file still readable | The disk followed the VM to the new node |
| 13 | Longest heartbeat gap is under `DOWNTIME_BUDGET` | The pause was short enough to call this *live* migration |

### Why `boot_id`

A VM that crashes and reboots onto another node also ends up "running, on a different node, reachable over SSH" — it would pass a naive node-name check while having lost everything in RAM, which is the exact failure live migration is supposed to prevent. The kernel regenerates `/proc/sys/kernel/random/boot_id` on every boot and holds it stable for the life of a running kernel, so carrying the same value across the migration is what actually proves the guest never stopped.

### How downtime is measured

The guest appends `date +%s.%N` to a file every 50ms. When it is paused for the final switchover it stops executing, so the largest gap between consecutive samples is the outage as the guest itself experienced it — no network in the path. The measurement cannot resolve a pause much shorter than the heartbeat interval plus scheduler jitter.

Note that total migration time and downtime are different numbers. Memory is copied while the guest keeps running; only the final switchover pauses it. The script reports both.

## Configuration

Shares the disk and image variables with `test-vm-storage.sh` (`SOURCE_MODE`, `IMAGE_URL`, `DISK_SIZE`, `STORAGE_CLASS`, `ACCESS_MODE`, `GUEST_USER`, `DV_STALL`, `KEEP_VM`), plus:

| Variable | Default | Notes |
|----------|---------|-------|
| `VM_NAME` | `migrate-test-vm` | — |
| `MIGRATION_TIMEOUT` | `600` | seconds to wait for the migration to finish |
| `DOWNTIME_BUDGET` | `5` | seconds the guest may stop executing and still pass |
| `HEARTBEAT_INTERVAL` | `0.05` | guest sampling interval, and the floor on measurement resolution |
| `MEMORY` | `2Gi` | migration transfer time scales with this |

## Result: 13 passed, 0 failed

Run against `mm-test` on `oac-dev-workload0`:

- migrated `moc-r4pac22u27-s1` → `moc-r4pac22u29-s3`, mode `PreCopy`
- total migration 2 seconds for a 2Gi guest
- **guest-visible downtime 0.189s** across 276 heartbeat samples
- `boot_id` unchanged, VMI UID unchanged, marker file intact

## Why the script does not use `virtctl migrate`

The script creates the `VirtualMachineInstanceMigration` object directly with `oc create`. That triggers the same operation through a plain CRD write, so the migration is visible as a normal Kubernetes object the script can watch, name in its cleanup, and report `migrationState` from. It also keeps the whole test on one credential path — `virtctl` has no `--as` flag, so anything it does cannot be reasoned about separately from the logged-in user. The permission is checked in preflight rather than three minutes later, after a VM has been built; see [migration RBAC](#one-time-migration-rbac) above.

## Possible extension

The current downtime number is what the guest experienced. It does not measure *network* continuity, which is a separate question: with masquerade binding the virt-launcher pod IP changes on migration, so measuring that properly needs a Service in front of the VM and an external prober, and the result would fold in OVN-Kubernetes endpoint reprogramming time as well as the migration itself. Worth adding if inbound connection survival is something you need to claim.
---

# VM Secondary-Network IPAM Testing

The pod network is not the address pool that runs out. With this cluster's `hostPrefix` of /23 a node has 510 pod addresses against a `max-pods` of 250, so the kubelet refuses to schedule long before IPAM refuses to allocate — filling it would need 250 pods on one node and would prove the wrong thing. A secondary network is hand-sized by definition, is shared between VMs and containers, and has no per-node headroom at all, which makes it both the realistic exhaustion case and a cheap one to produce.

`test-vm-secondary-ipam.sh` creates a small secondary network, fills it with VMs until allocation fails, puts a plain container pod against the same pool, and then checks whether addresses actually come back — on a graceful delete and, more importantly, on a force-delete that skips the CNI teardown.

```bash
cd vm-testing
./test-vm-secondary-ipam.sh
```

Takes roughly 4-6 minutes. Needs the [one-time secondary-network RBAC grant](#one-time-secondary-network-rbac). Requires `oc` and `jq`; no `virtctl`, because nothing logs into a guest.

## What it asserts

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | An ordinary user with the grant can define a secondary network | Establishes the baseline the grant exists to provide |
| 2 | VMs receive addresses from the secondary subnet | Setup — and confirms the bridge attachment works end to end |
| 3 | The number allocated matches the usable size of the range | Fewer means addresses were already lost or reserved; more means the IPAM plugin is handing out network or broadcast addresses |
| 4 | Exhaustion is refused rather than silently satisfied | — |
| 5 | The refusal message names address exhaustion | Decides whether an operator can diagnose this from the error, or has to already suspect the cause |
| 6 | A container is refused by the same pool the VMs filled | **The interaction claim** — one pool, two workload types, no isolation between them |
| 7 | Deleting a VM frees an address a container immediately takes | The two are interchangeable consumers, not just coincidental neighbours |
| 8 | An address released by a gracefully deleted VM is reusable | The ordinary path works |
| 9 | A force-deleted virt-launcher pod gets its address back | **The leak check** — see below |
| 10 | Pool size is unchanged after `LEAK_CYCLES` ungraceful deletes | A single-slot loss can be a transient the IPAM reclaims on a timer; a repeated one cannot |

It also reports, without failing: every current holder of an address split into VM and container, and whether the authoritative allocation table is readable at all.

### Why the force-delete matters more than the graceful one

A VM whose node fails, or whose virt-launcher pod is force-deleted, never runs the CNI `DEL` that returns its address. If nothing reconciles the orphaned allocation, every such event permanently shrinks the pool, and nothing reports it — the address is held by no pod, so no amount of looking at running workloads will find it. Steps 8 and 9 are the same operation under the two teardown paths, and the difference between them is the whole finding.

### Why the pod annotation and not the VMI status

The script reads allocated addresses from the virt-launcher pod's `k8s.v1.cni.cncf.io/network-status` annotation, which Multus writes, rather than from `vmi.status.interfaces`. The VMI only learns its secondary address from `qemu-guest-agent`, which the CirrOS image does not ship, so the VMI would report nothing while the address was in fact allocated — the test would see a leak that was not there.

## Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `NAMESPACE` | `mm-test` | also honours `PROJECT` |
| `IPAM_BACKEND` | `whereabouts` | `whereabouts` needs a node bridge and is what this cluster runs; `ovn` needs nothing but cannot show holders at all |
| `BRIDGE_NAME` | `br-storage` | `whereabouts` only; verified up front against `NodeNetworkState` |
| `TEST_RANGE` | `10.9.250.0/29` | 6 usable addresses. Must be /28 or smaller or the script refuses |
| `MAX_CLAIMANTS` | `12` | hard stop; must exceed the usable count or exhaustion can never be reached |
| `CLAIM_TIMEOUT` | `90` | seconds a VM may take to get an address before it counts as refused |
| `LEAK_CYCLES` | `3` | force-delete rounds in the leak check |
| `ADMIN_IPPOOL_READ` | `1` | `0` drops the one `--as system:admin` read |
| `KEEP_NET` | `0` | `1` leaves the network and claimants up |

### On choosing `TEST_RANGE`

The default is deliberately disjoint from the bridge's real subnet. On `oac-dev-workload0` `br-storage` carries live Portworx storage traffic on `10.9.4.0/24`, with `portworx/storage-network` allocating from `.200`-`.250`; a test that filled addresses in that subnet would be competing with production. whereabouts allocates from whatever range it is told, and exhausting a pool does not require working L2, so a range that collides with nothing costs nothing and is strictly safer.

## Finding

See [Finding 3](../VIRT_README.md#finding-3-secondary-networks-cannot-be-created-or-audited-by-a-namespace-user): a namespace user can neither create a secondary network nor read the allocation table for one, so secondary-network exhaustion presents as unexplained `ContainerCreating` pods with no cluster-level signal naming the cause.

---

# VM Memory Overhead Testing

A VM asking for 8Gi of guest memory does not remove 8Gi from what containers can schedule on its node. KubeVirt adds per-VMI overhead — QEMU itself, page tables for the guest's address space, the containerdisk and console containers, and a safety margin — and none of it appears anywhere in the `VirtualMachine` spec. The gap is invisible until a container that should fit does not.

`test-vm-memory-overhead.sh` measures the gap across a sweep of guest sizes and vCPU counts and reports the node-level split between VM and container memory.

```bash
cd vm-testing
./test-vm-memory-overhead.sh
```

Takes roughly 5-8 minutes for the default five-VM sweep, or about half that with `CHECK_GUEST_MEMTOTAL=0`. Needs no RBAC grant. It boots from ephemeral `containerDisk`s because nothing here depends on persistence, and holds only one VM at a time, so it can run on a busy cluster without becoming the capacity problem it is measuring.

## What it asserts

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | Each VM in the sweep reaches `Ready` | Setup |
| 2 | The virt-launcher pod requests strictly more memory than the guest size | **The core claim** — the overhead is real and is charged to the node |
| 3 | The guest's own `MemTotal` is close to its configured size | The overhead is charged to the node but is *not* given to the workload |
| 4 | Overhead at the largest guest size differs from the smallest | Confirms a term that scales, so it cannot be budgeted as a flat per-VM constant |
| 5 | Overhead at the highest vCPU count exceeds the lowest at equal memory | vCPU count is a second input most capacity planning ignores |

It also reports, without failing: the per-container request and limit breakdown for every virt-launcher pod, the pod's QoS class, `vmi.status.memory.guestAtBoot` and `guestCurrent`, the KubeVirt version, and the node-level VM-versus-container split of requested memory.

### What it deliberately does not assert

No specific overhead figure or percentage. The overhead formula is a KubeVirt-version property; hard-coding a number would turn a routine operator upgrade into a test failure while proving nothing extra. The test asserts the *shape* — overhead exists, it scales with guest size, it scales with vCPU count — and reports the numbers for whoever needs them.

### Cluster settings that change the answer

Step 1 records `higherWorkloadDensity.memoryOvercommitPercentage` and `additionalGuestMemoryOverheadRatio` from the `HyperConverged` resource. Both silently rescale the overhead formula, so a measurement reported without them is not reproducible on another cluster. An overcommit above 100% means KubeVirt deliberately requests *less* than the guest size, betting the guest will not touch all of it — that inverts the sign of what this test measures and is called out as a warning rather than left in a log line.

## Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `NAMESPACE` | `mm-test` | also honours `PROJECT` |
| `MEMORY_SWEEP` | `1Gi 4Gi 8Gi` | three sizes so the fixed and scaling terms can be separated in one run |
| `CPU_SWEEP` | `1 4` | vCPU counts compared at a fixed memory size |
| `CPU_SWEEP_MEMORY` | `4Gi` | the size the vCPU sweep holds constant |
| `CHECK_GUEST_MEMTOTAL` | `1` | `0` skips the in-guest read and roughly halves the runtime; drops check 3 |
| `KEEP_VM` | `0` | `1` leaves the last VM of the sweep in place |

Reading `nodes` and the `HyperConverged` resource are the only accesses outside the namespace, and both degrade to warnings if denied.

---

# VM Evictability Testing

`test-vm-memory-overhead.sh` measures how much node memory a VM takes. This measures how hard it is to get back.

Under pressure the platform reclaims memory by evicting pods. A container yields and is rescheduled elsewhere; a VM either refuses outright or has to be live migrated, which is slow, bandwidth-hungry, and conditional on storage that supports it. So a VM's cost to its neighbours is not just its size — it is that its share of the node is not reclaimable the way a container's is.

```bash
cd vm-testing
./test-vm-evictability.sh
```

Takes roughly 8-12 minutes for both modes. Needs no RBAC grant: `pods/eviction` with verb `create` is part of `clusterrole/edit`. Requires `oc` and `jq`; no `virtctl`, because nothing logs into a guest.

## Why it does not stress a node

The decisive experiment would drive a node into real memory pressure and watch the kubelet choose victims. On a shared cluster that evicts other tenants' workloads, so this script does not do it.

Instead it measures evictability directly, through the Eviction API and the scheduling metadata that determines eviction order, touching only objects it created itself. Memory pressure is the *trigger*; evictability is the *mechanism*, and the mechanism is what differs between a VM and a pod. The pressure-based variant is written up as [a manual procedure](#the-pressure-based-variant) below and is deliberately not scripted.

It also avoids `oc adm drain`, even with `--dry-run=server`. Drain cordons the node, which needs `patch` on `nodes` and is cluster-admin only, and a real drain would disturb every other workload on the host. A raw Eviction against one named pod touches exactly that pod.

## What it asserts

Each check runs once per mode. `rwx` is a VM on `ReadWriteMany` storage with `evictionStrategy: LiveMigrate` — the migratable case. `rwo` is a VM on `ReadWriteOnce` with no eviction strategy at all, which is what a user gets who never thought about it, and the only honest setting on unshared storage.

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | Root disk provisions in the requested access mode | Setup; warns if the StorageClass substituted a mode, since that would invalidate the run's label |
| 2 | VM reaches `Ready`, control container reaches `Ready` on the same node | Both workloads genuinely compete for one pool |
| 3 | Both request the same memory | Without this the comparison proves nothing |
| 4 | A PDB protects the VM and none protects the container (`rwx`) | KubeVirt creates `kubevirt-disruption-budget-<vmi>` for migratable VMIs; a Deployment pod has nothing equivalent |
| 5 | The control container's eviction is accepted | — |
| 6 | The control container terminates | Its memory was reclaimable |
| 7 | The Deployment replaces it | The memory came back to the *cluster*, not just to that node |
| 8 | The VM does not simply yield its memory on request | **The asymmetry** |
| 9 | The pinned VM's outcome differs from the migratable one | Storage access mode determines behaviour under disruption |

It also reports, without failing: QoS class, priority class and resolved priority, memory requests and matching PDBs for both workloads side by side, and the node's requested memory split into reclaimable and non-reclaimable.

### Three outcomes, all informative

Evicting the virt-launcher pod can go three ways, and the script branches rather than assuming one — which one happens *is* the result:

- **Refused (HTTP 429).** A PodDisruptionBudget rejects the eviction. The VM keeps its memory and the caller gets nothing.
- **Accepted, then live migrated.** Same VMI UID, guest never stopped, now on a different node. Nothing was reclaimed — the cost was *relocated*, at the price of a migration. The script reports the migration mode and end time.
- **Accepted, guest killed.** The VMI is destroyed and recreated, and anything in guest RAM is lost. Expected for the pinned case; a failure for the migratable one.

The VMI UID is what distinguishes the second from the third. A VM that crashes and restarts elsewhere also ends up "running on a different node", so node name alone cannot tell relocation from destruction — the same reasoning that makes `boot_id` the decisive check in the migration suite.

## Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `NAMESPACE` | `mm-test` | also honours `PROJECT` |
| `TEST_BOTH_MODES` | `1` | `0` runs only `DISK_MODE`. The contrast is the finding, so prefer `1` |
| `DISK_MODE` | `rwx` | used only when `TEST_BOTH_MODES=0` |
| `VM_MEMORY` | `2Gi` | the control container requests the same |
| `EVICTION_TIMEOUT` | `180` | seconds to wait for an eviction to take effect |
| `CONTROL_IMAGE` | `ubi9/ubi-minimal:latest` | the control container, which only sleeps |

Shares `SOURCE_MODE`, `IMAGE_URL`, `DISK_SIZE`, `STORAGE_CLASS`, `DV_STALL` and `KEEP_VM` with the storage suite, including the same stall detector — a broken import does not report `Failed`, it retry-loops, so the only signal is that nothing is moving.

## The pressure-based variant

Not scripted, and **not to be run on a shared cluster**. Record the result as a one-off if you run it on something disposable.

1. Cordon a node that hosts nothing outside your own namespace. Confirm with `oc get pods -A --field-selector spec.nodeName=$NODE`.
2. Place on it a VM and a Burstable container pod with equal memory requests.
3. Inflate a third pod's memory until the kubelet reports `MemoryPressure` on the node.
4. Record the eviction order from the kubelet's events, with the ranking reason for each victim.

The expectation is that the Burstable container goes first and the VM last or not at all, because eviction sorts by QoS class and then by usage over request. That is the same ordering the Tier A checks above infer from metadata; this variant observes it directly.
