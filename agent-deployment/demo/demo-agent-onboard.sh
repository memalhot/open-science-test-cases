#!/bin/bash
#
# demo-agent-onboard.sh
#
# Demonstrates onboarding an A2A agent to the Rossoctl operator ENTIRELY from
# the CLI — no Rossoctl UI involved — then exercises the agent with a live A2A
# request to prove it receives + acknowledges traffic. The UI is only a frontend
# over the same three CRDs this script applies with `oc apply`:
#
#   AgentRuntime         (agent.rossoctl.dev)  wires identity/auth/mTLS onto a workload
#   AgentCard            (agent.rossoctl.dev)  discovers + indexes + verifies agent metadata
#   AuthorizationPolicy  (agent.rossoctl.dev)  declarative authz rules
#
# Flow:
#   1. Preflight: operator + CRDs present. Detect optional deps (Keycloak/SPIRE).
#   2. Opt the demo namespace into Rossoctl (label rossoctl-enabled=true).
#   3. Deploy a tiny A2A agent: a Deployment + Service that serves an A2A agent
#      card at /.well-known/agent-card.json. Labeled protocol.rossoctl.io/a2a so
#      the operator's sync controller notices it. rossoctl.io/type is NOT set by
#      us (a ValidatingAdmissionPolicy forbids it); the operator stamps
#      rossoctl.io/type=agent itself when it reconciles the AgentRuntime (step 5).
#   4. Apply AgentRuntime + AuthorizationPolicy CRs. (The AgentCard is NOT hand-
#      authored: once the operator labels the workload, its sync controller
#      auto-creates the AgentCard, and a webhook rejects a duplicate.)
#   5. Verify the operator RECONCILED (pure CLI proof):
#        - operator stamped rossoctl.io/type=agent on the workload.
#        - auto-created AgentCard: Synced=True and status.card.name == agent name
#          (the operator fetched the card over http from the Service).
#        - AgentRuntime status.card populated.
#   6. Show the operator's reconcile in its logs.
#   6b. Exercise the agent (data plane): an outside client sends a real A2A
#      JSON-RPC message/send to the agent's Service; the agent acknowledges it.
#      Proven by the JSON-RPC ack in the response AND the agent's own log line
#      ("A2A REQUEST RECEIVED"). The agent is a tiny stdlib http server
#      (agent.py, in the card ConfigMap) that serves the card AND answers POST.
#   7. (optional, INJECT=1) recreate the pod with injection enabled and prove
#      the webhook injected the `authbridge-proxy` sidecar container.
#
# WHY DISCOVERY IS THE DEFAULT DEMO:
#   AgentCard discovery works over plain http and needs no supporting infra, so
#   it runs green on a bare operator install. Full AuthBridge sidecar enforcement
#   (mTLS/OIDC) needs SPIRE + Keycloak (installed by the umbrella chart's
#   scripts/ocp/setup-rossoctl.sh). Without them the injected sidecar will NOT
#   become Ready — INJECT=1 only asserts the container was injected, not healthy.
#
# The operator's injection webhook fires only when BOTH are true:
#   * namespace has label  rossoctl-enabled=true
#   * pod has label        rossoctl.io/type in (agent,tool)  and  rossoctl.io/inject != disabled
#
# PREREQUISITES:
#   * oc + curl on PATH; logged in as / able to --as system:admin.
#   * The Rossoctl operator installed (helm install rossoctl-operator ...).
#
# Usage:
#   ./demo-agent-onboard.sh
#   ./demo-agent-onboard.sh --no-cleanup
#   INJECT=1 ./demo-agent-onboard.sh          # also demo sidecar injection
#   KEEP=1 NAMESPACE=my-agents ./demo-agent-onboard.sh
#
# Env:
#   NAMESPACE     demo namespace                (default rossoctl-demo)
#   AGENT_NAME    Deployment + Service name     (default weather-agent)
#   AGENT_IMAGE   http server image             (default registry.access.redhat.com/ubi9/python-311:latest)
#   INJECT        1 = also demo sidecar inject  (default 0)
#   KEEP          1 = leave resources up        (default 0; --no-cleanup sets it)

set -euo pipefail

# Command tracing: `--trace` / `-x` / TRACE=1 turns on `set -x`.
TRACE="${TRACE:-0}"
for a in "$@"; do [[ "$a" == "--trace" || "$a" == "-x" ]] && TRACE=1; done
if [[ "${TRACE}" == "1" ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
fi

NAMESPACE="${NAMESPACE:-rossoctl-demo}"
AGENT_NAME="${AGENT_NAME:-weather-agent}"
AGENT_IMAGE="${AGENT_IMAGE:-registry.access.redhat.com/ubi9/python-311:latest}"
INJECT="${INJECT:-0}"
KEEP="${KEEP:-0}"
PF_PID=""
ACK_OK="no"
ADMIN=(--as system:admin)
GROUP="agent.rossoctl.dev"

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
yellow() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*"; }
log()    { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()    { red "$*"; exit 1; }

[[ "${1:-}" == "--no-cleanup" ]] && KEEP=1

cleanup() {
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
  if [[ "${KEEP}" == "1" ]]; then
    yellow "cleanup: leaving namespace '${NAMESPACE}' up (--no-cleanup / KEEP=1)"
    yellow "  inspect: oc get art,agentcards,ap -n ${NAMESPACE}"
    yellow "  remove:  oc delete ns ${NAMESPACE} ${ADMIN[*]}"
    return 0
  fi
  log "cleanup: deleting namespace '${NAMESPACE}'"
  oc delete ns "${NAMESPACE}" "${ADMIN[@]}" --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# --- 0. preflight -----------------------------------------------------------
log "0. Preflight"
command -v oc   >/dev/null || die "oc not found"
command -v curl >/dev/null || die "curl not found"
oc whoami >/dev/null 2>&1 || die "not logged in (oc login ...)"

for crd in agentruntimes.${GROUP} agentcards.${GROUP} authorizationpolicies.${GROUP}; do
  oc get crd "${crd}" >/dev/null 2>&1 || die "CRD ${crd} missing — is the rossoctl operator installed?"
done
green "operator CRDs present (AgentRuntime, AgentCard, AuthorizationPolicy)"

if oc get deploy rossoctl-controller-manager -n rossoctl-system >/dev/null 2>&1; then
  green "rossoctl-controller-manager found in rossoctl-system"
else
  yellow "rossoctl-controller-manager not found in rossoctl-system — reconcile may not happen"
fi

# Optional deps — only needed for a HEALTHY injected sidecar (mTLS/OIDC).
HAVE_KEYCLOAK=0; HAVE_SPIRE=0
oc get ns keycloak >/dev/null 2>&1 && HAVE_KEYCLOAK=1
if oc get ns spire >/dev/null 2>&1 || oc get ns spire-system >/dev/null 2>&1; then HAVE_SPIRE=1; fi
if [[ "${INJECT}" == "1" && ( "${HAVE_KEYCLOAK}" == "0" || "${HAVE_SPIRE}" == "0" ) ]]; then
  yellow "INJECT=1 but Keycloak=${HAVE_KEYCLOAK} SPIRE=${HAVE_SPIRE}: the authbridge-proxy sidecar will be"
  yellow "  injected but will NOT become Ready without those. We only assert injection, not health."
fi

# --- 1. namespace opt-in ----------------------------------------------------
log "1. Creating namespace '${NAMESPACE}' and opting it into Rossoctl"
oc create namespace "${NAMESPACE}" "${ADMIN[@]}" --dry-run=client -o yaml | oc apply "${ADMIN[@]}" -f -
# rossoctl-enabled=true is the namespaceSelector the injection webhook requires.
oc label namespace "${NAMESPACE}" rossoctl-enabled=true --overwrite "${ADMIN[@]}"
green "namespace '${NAMESPACE}' labeled rossoctl-enabled=true"

# Decide the pod injection label: disabled by default so the discovery demo
# stays green on a bare operator (a crashlooping sidecar would break the fetch).
if [[ "${INJECT}" == "1" ]]; then INJECT_LABEL="enabled"; else INJECT_LABEL="disabled"; fi

# --- 2. deploy the A2A agent (Deployment + Service) --------------------------
# NOTE: the operator derives the card URL from the SERVICE, and assumes the
# Service is named the same as the workload/targetRef. So Service name == AGENT_NAME.
log "2. Deploying test A2A agent '${AGENT_NAME}' (serves /.well-known/agent-card.json)"

SVC_URL="http://${AGENT_NAME}.${NAMESPACE}.svc.cluster.local:8080/"
oc apply "${ADMIN[@]}" -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${AGENT_NAME}-card
  namespace: ${NAMESPACE}
data:
  # A2A AgentCard document, served verbatim at the well-known path.
  agent-card.json: |
    {
      "protocolVersion": "0.3.0",
      "name": "${AGENT_NAME}",
      "description": "Demo weather agent onboarded to rossoctl via CLI",
      "url": "${SVC_URL}",
      "version": "1.0.0",
      "capabilities": { "streaming": false, "pushNotifications": false },
      "defaultInputModes": ["text"],
      "defaultOutputModes": ["text"],
      "skills": [
        {
          "id": "get-weather",
          "name": "Get weather",
          "description": "Return the current weather for a city",
          "tags": ["weather", "demo"]
        }
      ]
    }
  # A2A agent server: serves the card at the well-known path AND answers a
  # JSON-RPC message/send POST with a Task ack, printing a receipt marker to
  # stdout so the demo can prove the agent received + acknowledged the request.
  agent.py: |
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    CARD_PATH = "/opt/agent/.well-known/agent-card.json"

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in ("/.well-known/agent-card.json", "/.well-known/agent.json"):
                try:
                    with open(CARD_PATH, "rb") as f:
                        self._send(200, f.read())
                except OSError:
                    self._send(404, '{"error":"card not found"}')
            else:
                self._send(404, '{"error":"not found"}')

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                req = json.loads(raw or b"{}")
            except ValueError:
                req = {}
            rpc_id = req.get("id", 1)
            method = req.get("method", "")
            # Proof-of-receipt marker (the demo script greps this in the pod log).
            print("A2A REQUEST RECEIVED method=%s id=%s" % (method, rpc_id), flush=True)
            result = {
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "kind": "task",
                    "id": "task-%s" % rpc_id,
                    "status": {"state": "completed"},
                    "artifacts": [
                        {"parts": [{"kind": "text",
                                    "text": "ack: received %s, agent acknowledges the request" % method}]}
                    ],
                },
            }
            self._send(200, json.dumps(result))

        def log_message(self, fmt, *args):
            # Route access logs to stdout so oc logs surfaces them.
            sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
            sys.stdout.flush()

    if __name__ == "__main__":
        port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
        HTTPServer(("", port), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${AGENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${AGENT_NAME}
    # The sync controller keys off the workload's TOP-LEVEL labels, so the A2A
    # protocol marker goes here. rossoctl.io/type is intentionally NOT set — a
    # cluster ValidatingAdmissionPolicy (agent-label-protection) forbids users
    # from setting it; the operator stamps rossoctl.io/type=agent itself when the
    # AgentRuntime CR below is reconciled (verified in step 4).
    protocol.rossoctl.io/a2a: ""
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${AGENT_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${AGENT_NAME}
        rossoctl.io/inject: "${INJECT_LABEL}"   # webhook gate (see header)
    spec:
      containers:
        - name: agent
          image: ${AGENT_IMAGE}
          # A small stdlib A2A server: serves the card at the well-known path and
          # answers a JSON-RPC message/send POST with a Task ack (see agent.py).
          command: ["/bin/sh", "-c"]
          args: ["exec python3 /opt/agent/agent.py 8080"]
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            - name: card
              mountPath: /opt/agent/.well-known/agent-card.json
              subPath: agent-card.json
            - name: card
              mountPath: /opt/agent/.well-known/agent.json   # legacy path too
              subPath: agent-card.json
            - name: card
              mountPath: /opt/agent/agent.py
              subPath: agent.py
          readinessProbe:
            httpGet: { path: /.well-known/agent-card.json, port: 8080 }
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: card
          configMap:
            name: ${AGENT_NAME}-card
---
apiVersion: v1
kind: Service
metadata:
  name: ${AGENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${AGENT_NAME}
spec:
  selector:
    app.kubernetes.io/name: ${AGENT_NAME}
  ports:
    - name: http
      port: 8080
      targetPort: 8080
YAML

log "2b. Waiting for the agent to roll out"
oc rollout status deploy/"${AGENT_NAME}" -n "${NAMESPACE}" "${ADMIN[@]}" --timeout=180s \
  || die "agent deployment did not become ready"
green "agent '${AGENT_NAME}' running"

# Confirm the card is actually served (in-cluster, from the agent pod itself).
POD="$(oc get pod -n "${NAMESPACE}" -l app.kubernetes.io/name="${AGENT_NAME}" -o jsonpath='{.items[0].metadata.name}')"
# The readiness probe already GETs the card path, but confirm the served body
# actually parses as the expected AgentCard (name matches).
CARD_NAME="$(oc exec -n "${NAMESPACE}" "${POD}" -c agent "${ADMIN[@]}" -- \
  python3 -c "import json,urllib.request; print(json.load(urllib.request.urlopen('http://localhost:8080/.well-known/agent-card.json'))['name'])" 2>/dev/null || true)"
if [[ "${CARD_NAME}" == "${AGENT_NAME}" ]]; then
  green "agent serves a valid A2A card (name='${CARD_NAME}') at ${SVC_URL}.well-known/agent-card.json"
else
  yellow "could not confirm card body from inside the pod (got '${CARD_NAME}'; continuing)"
fi

# --- 3. apply the CRs (this is the whole 'CLI = the UI' point) ---------------
# NOTE: we do NOT create an AgentCard by hand. Once the operator labels the
# workload (rossoctl.io/type=agent) and sees the protocol label, its sync
# controller AUTO-creates the AgentCard; a webhook rejects a second card that
# targets the same Deployment. So we apply only AgentRuntime + AuthorizationPolicy.
log "3. Applying AgentRuntime + AuthorizationPolicy (AgentCard is auto-created by the operator)"
oc apply "${ADMIN[@]}" -f - <<YAML
apiVersion: ${GROUP}/v1alpha1
kind: AgentRuntime
metadata:
  name: ${AGENT_NAME}-runtime
  namespace: ${NAMESPACE}
spec:
  type: agent
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${AGENT_NAME}
  # Least-dep modes: no SPIRE/Keycloak required to reconcile the CR itself.
  authBridgeMode: lite
  mtlsMode: disabled
  egressEnforcement: none
  tlsBridgeMode: disabled
---
apiVersion: ${GROUP}/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: ${AGENT_NAME}-authz
  namespace: ${NAMESPACE}
spec:
  scope: namespace
  policies:
    # path is a .rego filename; content is the Rego policy body.
    - path: authz.rego
      content: |
        package rossoctl.authz
        default allow := false
        # Demo policy: allow calls exercising the get-weather skill.
        allow if input.skill == "get-weather"
YAML
# Note: reading agent.rossoctl.dev CRs typically needs elevated RBAC, so all CR
# gets below use --as system:admin.
green "CRs applied: $(oc get art,ap -n "${NAMESPACE}" "${ADMIN[@]}" -o name | tr '\n' ' ')"

# --- 4. verify the operator reconciled --------------------------------------
log "4. Waiting for the operator to auto-create + sync the AgentCard"
# Reconcile proof #1: the operator (not us) stamped rossoctl.io/type onto the
# workload — users are blocked from setting it by the agent-label-protection VAP.
OPLABEL="$(oc get deploy "${AGENT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.rossoctl\.io/type}' 2>/dev/null || true)"
if [[ "${OPLABEL}" == "agent" ]]; then
  green "operator stamped rossoctl.io/type=agent on the workload (via AgentRuntime)"
else
  yellow "operator has not yet applied rossoctl.io/type to the workload (got '${OPLABEL}')"
fi

# Reconcile proof #2: the auto-created AgentCard reaches Synced=True with the
# card fetched over http from the Service. Discover its name by targetRef.
CARD=""; SYNCED=0; DISCOVERED_NAME=""
for _ in $(seq 1 40); do
  CARD="$(oc get agentcards -n "${NAMESPACE}" "${ADMIN[@]}" \
    -o jsonpath="{range .items[?(@.status.targetRef.name=='${AGENT_NAME}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null | head -1)"
  [[ -z "${CARD}" ]] && CARD="$(oc get agentcards -n "${NAMESPACE}" "${ADMIN[@]}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${CARD}" ]]; then
    s="$(oc get agentcard "${CARD}" -n "${NAMESPACE}" "${ADMIN[@]}" -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || true)"
    DISCOVERED_NAME="$(oc get agentcard "${CARD}" -n "${NAMESPACE}" "${ADMIN[@]}" -o jsonpath='{.status.card.name}' 2>/dev/null || true)"
    if [[ "${s}" == "True" || "${DISCOVERED_NAME}" == "${AGENT_NAME}" ]]; then SYNCED=1; break; fi
  fi
  sleep 3
done

echo "--- oc get agentcards -n ${NAMESPACE} ---"
oc get agentcards -n "${NAMESPACE}" "${ADMIN[@]}" 2>/dev/null || true
echo "--- AgentRuntime discovered card ---"
oc get agentruntime "${AGENT_NAME}-runtime" -n "${NAMESPACE}" "${ADMIN[@]}" \
  -o jsonpath='{"name="}{.status.card.name}{" hash="}{.status.card.cardHash}{"\n"}' 2>/dev/null || true

if [[ "${SYNCED}" == "1" && "${DISCOVERED_NAME}" == "${AGENT_NAME}" ]]; then
  green "operator auto-created AgentCard '${CARD}', fetched + indexed it: status.card.name='${DISCOVERED_NAME}'"
else
  yellow "AgentCard not fully synced yet (card='${CARD}' status.card.name='${DISCOVERED_NAME}')"
  echo "--- AgentCard conditions ---"
  [[ -n "${CARD}" ]] && oc get agentcard "${CARD}" -n "${NAMESPACE}" "${ADMIN[@]}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}: {.message}){"\n"}{end}' 2>/dev/null || true
fi

# --- 5. operator logs: proof the controller did the work --------------------
log "5. Operator reconcile log lines mentioning '${AGENT_NAME}'"
oc logs deploy/rossoctl-controller-manager -n rossoctl-system --tail=2000 2>/dev/null \
  | grep -iE "${AGENT_NAME}|AgentCard|AgentRuntime|AuthorizationPolicy" | tail -12 \
  || yellow "no matching operator log lines (check: oc logs deploy/rossoctl-controller-manager -n rossoctl-system)"

# --- 5b. exercise the agent: send an A2A request, confirm the ack -----------
# Onboarding/discovery above is control-plane. This step is the data plane: an
# outside client sends a real A2A JSON-RPC message/send to the agent's Service
# and the agent acknowledges it. We prove it two ways: the JSON-RPC ack in the
# response, and the agent's own log line recording receipt.
log "5b. Sending an A2A request to '${AGENT_NAME}' and confirming the ack"

# Port-forward the Service so the request originates OUTSIDE the pod (a real
# client path into the ClusterIP), mirroring how the openshell demo dials in.
oc port-forward "svc/${AGENT_NAME}" 8080:8080 -n "${NAMESPACE}" "${ADMIN[@]}" \
  >/tmp/rossoctl-agent-pf.log 2>&1 &
PF_PID=$!
# Wait for the forward to accept connections.
for _ in $(seq 1 20); do
  curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:8080/.well-known/agent-card.json" 2>/dev/null && break
  kill -0 "${PF_PID}" 2>/dev/null || { yellow "port-forward exited early; see /tmp/rossoctl-agent-pf.log"; break; }
  sleep 1
done

# A2A message/send: ask the agent to exercise its advertised get-weather skill.
REQ='{"jsonrpc":"2.0","id":"demo-1","method":"message/send","params":{"message":{"role":"user","messageId":"m-1","parts":[{"kind":"text","text":"weather in Paris?"}]}}}'
echo "--- request (A2A message/send) ---"
echo "${REQ}"
echo "--- response ---"
RESP="$(curl -sS --max-time 15 -H 'Content-Type: application/json' -d "${REQ}" "http://127.0.0.1:8080/" 2>&1 || true)"
echo "${RESP}"

if echo "${RESP}" | grep -q '"result"' && echo "${RESP}" | grep -qiE 'completed|ack'; then
  ACK_OK="yes"
  green "agent RECEIVED the A2A request and returned a JSON-RPC ack (task completed)"
else
  yellow "no ack observed in the response (agent may not have handled message/send)"
fi

# Proof #2: the agent's own log recorded the receipt (analogue of openshell's
# enforcement-log proof).
log "5c. Agent log proving it received the request"
if oc logs deploy/"${AGENT_NAME}" -n "${NAMESPACE}" "${ADMIN[@]}" --tail=50 2>/dev/null \
     | grep -E 'A2A REQUEST RECEIVED' | tail -3; then
  green "agent log shows 'A2A REQUEST RECEIVED' — receipt confirmed in-workload"
  ACK_OK="yes"
else
  yellow "no 'A2A REQUEST RECEIVED' line in the agent log yet"
fi

# Stop the port-forward now that we're done with it.
[[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
PF_PID=""

# --- 6. optional: prove sidecar injection -----------------------------------
# Only the AgentRuntime path adds rossoctl.io/type to the pod template, so the
# injection webhook fires on the rolled pods. The sidecar needs SPIRE+Keycloak
# to become Ready, so we assert INJECTION (container in the pod spec), not health.
INJECT_OK="skipped"
if [[ "${INJECT}" == "1" ]]; then
  log "6. Verifying the webhook injected the AuthBridge sidecar"
  # The AgentRuntime reconcile patched rossoctl.io/type onto the pod template and
  # started its own rollout; the mutating webhook then injects the authbridge
  # sidecar at pod admission. WITHOUT SPIRE+Keycloak the injected pod can't be
  # admitted/started, so there is usually no live pod to inspect. The authoritative
  # proof of injection is the operator's own log — that's what we assert here.
  # (If SPIRE+Keycloak are present, the injected pod also shows up: it carries
  #  rossoctl.io/type=agent and an 'authbridge-*' container.)
  if oc get rs -n "${NAMESPACE}" \
       -o jsonpath="{range .items[?(@.spec.template.metadata.labels.rossoctl\.io/type=='agent')]}{.metadata.name}{'\n'}{end}" 2>/dev/null | grep -q .; then
    green "operator created a ReplicaSet whose pod template carries rossoctl.io/type=agent"
  fi
  INJLOG=""
  for _ in $(seq 1 20); do
    INJLOG="$(oc logs deploy/rossoctl-controller-manager -n rossoctl-system --since=10m --tail=6000 2>/dev/null \
      | grep -iE 'injection complete|Successfully mutated Pod' \
      | grep -i "${NAMESPACE}" | grep -i "${AGENT_NAME}" | tail -2 || true)"
    [[ -n "${INJLOG}" ]] && break
    sleep 3
  done
  if [[ -n "${INJLOG}" ]]; then
    echo "${INJLOG}"
    green "operator webhook injected the AuthBridge sidecar (see log lines above)"
    INJECT_OK="yes"
    # Best-effort: if deps exist, an injected pod will also be present.
    IPOD="$(oc get pods -n "${NAMESPACE}" -l rossoctl.io/type=agent -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${IPOD}" ]]; then
      echo "injected pod ${IPOD} containers: $(oc get pod "${IPOD}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)"
    else
      yellow "no live injected pod (expected without SPIRE/Keycloak — the sidecar can't start)"
    fi
  else
    yellow "no injection log line found — check featureGates.globalEnabled and namespace/pod labels"
    INJECT_OK="no"
  fi
fi

# --- 7. summary -------------------------------------------------------------
log "7. Result"
if [[ "${SYNCED}" == "1" && "${DISCOVERED_NAME}" == "${AGENT_NAME}" && "${ACK_OK}" == "yes" ]]; then
  green "DEMO PASSED: agent onboarded to rossoctl via CLI only — operator discovered and indexed"
  green "  the A2A card and reconciled AgentRuntime/AgentCard/AuthorizationPolicy."
  green "  The agent then RECEIVED a live A2A message/send and acknowledged it. Sidecar inject: ${INJECT_OK}."
  exit 0
else
  red "DEMO INCONCLUSIVE: discovery synced=${SYNCED} (card='${DISCOVERED_NAME}'), request ack=${ACK_OK}. Inspect:"
  red "  oc describe agentcard ${CARD:-<name>} -n ${NAMESPACE} --as system:admin"
  red "  oc logs deploy/rossoctl-controller-manager -n rossoctl-system"
  red "  oc logs deploy/${AGENT_NAME} -n ${NAMESPACE} --as system:admin   # agent request log"
  exit 1
fi
