# VM Testing

Two test suites for OpenShift Virtualization:

- **Networking** (`test-vm.sh`, `net-test-vm.yaml`) — a CirrOS VM on an ephemeral `containerDisk`, checking egress and inbound reachability.
- **Persistent storage** (`test-vm-storage.sh`) — a Fedora VM on a CDI-provisioned PVC, checking that guest data survives a stop/start.

## Prerequisites

Both require `oc` and `virtctl`, authenticated to the target cluster, with OpenShift Virtualization installed (see `component-checks/oc-virt-checks.sh`). `virtctl` is not bundled with `oc`; get its download URL with:

```bash
oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o jsonpath='{.spec.links[*].href}'
```

The scripts run entirely as the logged-in user — no `--as system:admin` anywhere — so what they prove is what a real project user can actually do.

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

`SOURCE_MODE=registry` is the default because `SOURCE_MODE=datasource` does not work on this cluster, and the failure is silent — the DataVolume never reports `Failed`, it retry-loops indefinitely. Both clone strategies fail:

- **`csi-clone`** — the PVC event reads `rpc error: code = Unimplemented desc = volume cloning is not supported for FlashBlade`. The StorageProfile nonetheless advertises `cloneStrategy: csi-clone`, so CDI keeps choosing a strategy the driver cannot serve.
- **host-assisted `copy`** (forced with the `cdi.kubevirt.io/cloneType: copy` annotation) — gets further, standing up a source pod and an upload server, then the upload server dies untarring onto the target: `error unarchiving to /data: exit status 2`, and the clone restarts from the beginning.

This affects more than this test. Cloning a golden image is the path the console's **Create VirtualMachine → from template** button takes, so provisioning a VM through the UI on the default StorageClass hangs with no error surfaced to the user. Worth raising with whoever owns the Pure/Portworx CSI configuration.

The `DV_STALL` detector exists because of this: it fails the test in about four minutes with the CDI worker pod logs attached, rather than spinning for the full `DV_TIMEOUT`.

