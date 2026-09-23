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
