#!/usr/bin/env python3
"""Check yaml/raycluster.yaml against the CodeFlare mutating webhook.

On RHOAI 2.x the CodeFlare operator rewrites every RayCluster on admission:
it appends an oauth-proxy sidecar, overwrites the head service account, and
injects mTLS env, cert volumes and a create-cert init container — but only
into container index 0. Our vLLM driver is a sidecar at index 1, so the
variant compensates by hand, and if that ever drifts the only symptom is a
driver that cannot reach the Ray GCS.

That interaction is impossible to regression-test without a 2.x cluster. This
reimplements Default() from codeflare-operator
pkg/controllers/raycluster_webhook.go, applies it to the rendered manifest,
and asserts the invariants the variant depends on.

    VARIANT_DIR="$PWD" . ../common/lib.sh && load_config \
      && render raycluster.yaml > /tmp/rc.yaml
    python3 check-codeflare-mutation.py /tmp/rc.yaml

Requires PyYAML. This is a static check of the manifest — it proves the two
halves agree, not that the cluster behaves as documented.
"""
import sys

try:
    import yaml
except ImportError:
    sys.exit("this check needs PyYAML: pip install pyyaml")

CLUSTER = "beam"


def upsert(items, new, key="name"):
    for i, it in enumerate(items):
        if it.get(key) == new.get(key):
            items[i] = new
            return items
    items.append(new)
    return items


def cert_volume_mounts():
    return [
        {"name": "ca-vol", "mountPath": "/home/ray/workspace/ca", "readOnly": True},
        {"name": "server-cert", "mountPath": "/home/ray/workspace/tls", "readOnly": False},
    ]


def env_var_list():
    return [
        {"name": "MY_POD_IP", "valueFrom": {"fieldRef": {"fieldPath": "status.podIP"}}},
        {"name": "RAY_USE_TLS", "value": "1"},
        {"name": "RAY_TLS_SERVER_CERT", "value": "/home/ray/workspace/tls/server.crt"},
        {"name": "RAY_TLS_SERVER_KEY", "value": "/home/ray/workspace/tls/server.key"},
        {"name": "RAY_TLS_CA_CERT", "value": "/home/ray/workspace/tls/ca.crt"},
    ]


def ca_volumes():
    return [
        {"name": "ca-vol", "secret": {"secretName": f"ca-secret-{CLUSTER}"}},
        {"name": "server-cert", "emptyDir": {}},
    ]


def default(rc, oauth=True, mtls=True):
    """Mirror of rayClusterWebhook.Default()."""
    head = rc["spec"]["headGroupSpec"]["template"]["spec"]

    if oauth:
        head.setdefault("containers", [])
        upsert(head["containers"], {
            "name": "oauth-proxy",
            "image": "registry.redhat.io/openshift4/ose-oauth-proxy",
            "ports": [{"containerPort": 8443, "name": "oauth-proxy"}],
            "volumeMounts": [{"name": "proxy-tls-secret", "mountPath": "/etc/tls/private", "readOnly": True}],
        })
        head.setdefault("volumes", [])
        upsert(head["volumes"], {
            "name": "proxy-tls-secret",
            "secret": {"secretName": f"{CLUSTER}-proxy-tls-secret"},
        })
        head["serviceAccountName"] = f"{CLUSTER}-oauth-proxy"

    if mtls:
        # NOTE the index: the webhook only ever touches Containers[0].
        c0 = head["containers"][0]
        c0.setdefault("env", [])
        for ev in env_var_list():
            upsert(c0["env"], ev)
        head.setdefault("initContainers", [])
        upsert(head["initContainers"], {"name": "create-cert", "image": "quay.io/project-codeflare/ray:latest"})
        head.setdefault("volumes", [])
        for v in ca_volumes():
            upsert(head["volumes"], v)
        c0.setdefault("volumeMounts", [])
        for m in cert_volume_mounts():
            upsert(c0["volumeMounts"], m)

        for wg in rc["spec"].get("workerGroupSpecs", []):
            ws = wg["template"]["spec"]
            w0 = ws["containers"][0]
            w0.setdefault("env", [])
            for ev in env_var_list():
                upsert(w0["env"], ev)
            ws.setdefault("volumes", [])
            for v in ca_volumes():
                upsert(ws["volumes"], v)
            w0.setdefault("volumeMounts", [])
            for m in cert_volume_mounts():
                upsert(w0["volumeMounts"], m)
            ws.setdefault("initContainers", [])
            upsert(ws["initContainers"], {"name": "create-cert", "image": "quay.io/project-codeflare/ray:latest"})
    return rc


passed = failed = 0


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {msg}")
    else:
        failed += 1
        print(f"  FAIL  {msg}")


rc = yaml.safe_load(open(sys.argv[1]))
pre_head = rc["spec"]["headGroupSpec"]["template"]["spec"]

print("=== before mutation ===")
check([c["name"] for c in pre_head["containers"]] == ["ray-head", "vllm"],
      f"head containers: {[c['name'] for c in pre_head['containers']]}")
pre_vols = {v["name"] for v in pre_head.get("volumes", [])}
check("ca-vol" not in pre_vols and "server-cert" not in pre_vols,
      "manifest does not pre-declare ca-vol/server-cert (webhook owns them)")
check("serviceAccountName" not in pre_head,
      "manifest does not set serviceAccountName (webhook overwrites it)")

rc = default(rc)
head = rc["spec"]["headGroupSpec"]["template"]["spec"]
names = [c["name"] for c in head["containers"]]
by_name = {c["name"]: c for c in head["containers"]}

print("\n=== after CodeFlare mutation ===")
check(names[0] == "ray-head", f"ray-head still at index 0 (order: {names})")
check("oauth-proxy" in names, "oauth-proxy sidecar appended")
check(head.get("serviceAccountName") == "beam-oauth-proxy",
      f"serviceAccountName -> {head.get('serviceAccountName')}")
check(any(c["name"] == "create-cert" for c in head.get("initContainers", [])),
      "create-cert init container added to head")

want_tls = {"RAY_USE_TLS", "RAY_TLS_SERVER_CERT", "RAY_TLS_SERVER_KEY", "RAY_TLS_CA_CERT"}
ray_env = {e["name"] for e in by_name["ray-head"].get("env", [])}
check(want_tls <= ray_env, "ray-head got the TLS env from the webhook")

# The whole point of the rhoai2 variant.
vllm_env = {e["name"] for e in by_name["vllm"].get("env", [])}
check(want_tls <= vllm_env,
      "vllm sidecar has the TLS env (webhook does NOT inject it — we must)")

vol_names = [v["name"] for v in head["volumes"]]
check(len(vol_names) == len(set(vol_names)), f"no duplicate pod volumes: {vol_names}")
check({"ca-vol", "server-cert", "proxy-tls-secret"} <= set(vol_names),
      "webhook added ca-vol, server-cert and proxy-tls-secret")

# Our sidecar mounts volumes the webhook creates; confirm they now resolve.
vllm_mounts = {m["name"]: m["mountPath"] for m in by_name["vllm"].get("volumeMounts", [])}
check("ca-vol" in vllm_mounts and "server-cert" in vllm_mounts,
      "vllm mounts ca-vol and server-cert")
check(all(n in vol_names for n in vllm_mounts),
      f"every vllm volumeMount resolves to a pod volume: {sorted(vllm_mounts)}")

# Env paths must match where the volumes actually land, or the driver reads
# nothing and Ray fails the TLS handshake with an unhelpful error.
vllm_envv = {e["name"]: e.get("value") for e in by_name["vllm"].get("env", [])}
check(vllm_envv.get("RAY_TLS_SERVER_CERT", "").startswith(vllm_mounts.get("server-cert", "\0")),
      f"RAY_TLS_SERVER_CERT ({vllm_envv.get('RAY_TLS_SERVER_CERT')}) lies under the server-cert mount")
check(vllm_envv.get("RAY_TLS_CA_CERT", "").startswith(vllm_mounts.get("server-cert", "\0")),
      f"RAY_TLS_CA_CERT ({vllm_envv.get('RAY_TLS_CA_CERT')}) lies under the server-cert mount")

for cname in ("ray-head", "vllm"):
    paths = [m["mountPath"] for m in by_name[cname].get("volumeMounts", [])]
    check(len(paths) == len(set(paths)), f"{cname}: no duplicate mountPaths ({paths})")
    # ray-home at /home/ray and the certs at /home/ray/workspace/* are nested;
    # kubelet mounts shortest-first, so the deeper ones survive.
    check("/home/ray" in paths and any(p.startswith("/home/ray/workspace/") for p in paths)
          if cname == "vllm" else True,
          f"{cname}: cert mounts nest under the /home/ray emptyDir")

for wg in rc["spec"]["workerGroupSpecs"]:
    ws = wg["template"]["spec"]
    w0 = ws["containers"][0]
    check(w0["name"] == "ray-worker", "worker container 0 is ray-worker")
    check(want_tls <= {e["name"] for e in w0["env"]}, "worker got TLS env from the webhook")
    wvn = [v["name"] for v in ws["volumes"]]
    check(len(wvn) == len(set(wvn)), f"worker: no duplicate volumes ({wvn})")

print(f"\n=== {passed} passed, {failed} failed ===")
sys.exit(1 if failed else 0)
