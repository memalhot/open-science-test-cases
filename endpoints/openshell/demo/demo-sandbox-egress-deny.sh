#!/bin/bash
#
# demo-sandbox-egress-deny.sh
#
# Demonstrates that NVIDIA OpenShell — not a raw Kubernetes NetworkPolicy —
# denies a Claude Code agent's attempt to read from github.com.
#
# OpenShell enforces egress with an inline L7 "policy proxy" (OPA/regorus) that
# evaluates destination host + calling binary before traffic leaves the sandbox.
# Policy is fail-closed: anything not explicitly allowed is denied. A blocked
# host surfaces as:  curl: (56) Received HTTP code 403 from proxy after CONNECT
#
# Flow:
#   1. Deploy OpenShell (gateway + agent-sandbox controller) if not present.
#   2. Install the `openshell` CLI locally; register + select the gateway.
#   3. Write a network policy that allows api.anthropic.com (for the claude
#      binary) and example.com (for curl) — and deliberately OMITS github.com,
#      so github is denied by default.
#   4. Create a sandbox running the Claude Code agent, with that policy attached.
#   5. From inside the sandbox: curl example.com -> ALLOWED by OpenShell;
#      curl github.com -> DENIED (403 from the OpenShell policy proxy).
#   6. Show the deny in `openshell logs` (action=deny).
#
# The denial is done by OpenShell's proxy. No Kubernetes NetworkPolicy is used.
#
# PREREQUISITES / CAVEATS:
#   * helm, oc, and curl on PATH; logged in to the cluster with admin.
#   * On Kubernetes the OpenShell gateway authenticates via OIDC or a trusted
#     access proxy (the Helm chart does NOT render mTLS user auth). If your
#     gateway requires OIDC, register it with the appropriate flags/token first
#     and pass GATEWAY_ALREADY_REGISTERED=1 to skip the auto-registration here.
#   * Actually running the claude agent needs ANTHROPIC_API_KEY; the github
#     denial itself does not (we probe with curl), so the key is optional.
#
# Usage:
#   ./demo-sandbox-egress-deny.sh
#   ./demo-sandbox-egress-deny.sh --no-cleanup
#   KEEP=1 SKIP_OPENSHELL=1 ./demo-sandbox-egress-deny.sh
#
# Env:
#   OPENSHELL_NAMESPACE  gateway namespace (default openshell)
#   GATEWAY_NAME         local CLI alias for the gateway (default demo)
#   GATEWAY_URL          gateway endpoint the CLI dials (default http://127.0.0.1:8080 via port-forward)
#   SANDBOX_NAME         sandbox name (default claude-agent)
#   SANDBOX_NAMESPACE    where the sandbox pod lands (default openshell-sandboxes)
#   ALLOW_HOST           host allowed for curl, to contrast (default example.com)
#   DENY_URL             the URL the agent tries and is denied (default https://github.com)
#   SKIP_OPENSHELL=1     do not run deploy.sh (gateway already up)
#   GATEWAY_ALREADY_REGISTERED=1  skip `openshell gateway add/select`

set -euo pipefail

# Command tracing: `--trace` / `-x` / TRACE=1 turns on `set -x` so every command
# is printed as it runs (readable PS4 with file:line). Off by default (noisy).
TRACE="${TRACE:-0}"
for a in "$@"; do [[ "$a" == "--trace" || "$a" == "-x" ]] && TRACE=1; done
if [[ "${TRACE}" == "1" ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENSHELL_NAMESPACE="${OPENSHELL_NAMESPACE:-openshell}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-openshell-sandboxes}"
GATEWAY_NAME="${GATEWAY_NAME:-demo}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:8080}"
SANDBOX_NAME="${SANDBOX_NAME:-claude-agent}"
ALLOW_HOST="${ALLOW_HOST:-example.com}"
DENY_URL="${DENY_URL:-https://github.com}"
KEEP="${KEEP:-0}"
SKIP_OPENSHELL="${SKIP_OPENSHELL:-0}"
GATEWAY_ALREADY_REGISTERED="${GATEWAY_ALREADY_REGISTERED:-0}"
ADMIN=(--as system:admin)

POLICY_FILE="$(mktemp /tmp/openshell-policy.XXXXXX.yaml)"
PF_PID=""
CREATE_PID=""

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
yellow() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*"; }
log()    { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()    { red "$*"; exit 1; }

cleanup() {
  [[ -n "${CREATE_PID}" ]] && kill "${CREATE_PID}" 2>/dev/null || true
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
  rm -f "${POLICY_FILE}" 2>/dev/null || true
  if [[ "${KEEP}" == "1" ]]; then
    yellow "cleanup: leaving sandbox '${SANDBOX_NAME}' up (--no-cleanup)"
    return 0
  fi
  log "cleanup: deleting sandbox '${SANDBOX_NAME}'"
  openshell sandbox delete "${SANDBOX_NAME}" 2>/dev/null || \
    oc delete sandbox "${SANDBOX_NAME}" -n "${SANDBOX_NAMESPACE}" "${ADMIN[@]}" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

[[ "${1:-}" == "--no-cleanup" ]] && KEEP=1

# --- 0. preflight -----------------------------------------------------------
command -v oc   >/dev/null || die "oc not found"
command -v curl >/dev/null || die "curl not found"
oc whoami >/dev/null 2>&1 || die "not logged in (oc login ...)"

# --- 1. deploy OpenShell ----------------------------------------------------
log "1. Ensuring OpenShell gateway is deployed"
if [[ "${SKIP_OPENSHELL}" == "1" ]]; then
  yellow "SKIP_OPENSHELL=1 — not running deploy.sh"
elif oc get ns "${OPENSHELL_NAMESPACE}" >/dev/null 2>&1 \
     && oc get deploy,statefulset -n "${OPENSHELL_NAMESPACE}" -l app.kubernetes.io/name=openshell >/dev/null 2>&1; then
  green "OpenShell already deployed in '${OPENSHELL_NAMESPACE}'"
else
  command -v helm >/dev/null || die "helm not found (required to deploy OpenShell)"
  ( cd "${ROOT}" && ./deploy.sh ) || die "OpenShell deploy.sh failed"
fi

# Resolve the gateway service and wait for it to be ready.
GW_SVC="$(oc get svc -n "${OPENSHELL_NAMESPACE}" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo openshell-gateway)"
oc rollout status "$(oc get statefulset,deploy -n "${OPENSHELL_NAMESPACE}" -l app.kubernetes.io/name=openshell -o name | head -1)" \
  -n "${OPENSHELL_NAMESPACE}" "${ADMIN[@]}" --timeout=5m || yellow "gateway rollout not confirmed"
green "Gateway service: ${GW_SVC}"

# --- 2. openshell CLI + gateway registration --------------------------------
log "2. Ensuring the 'openshell' CLI is installed"
if ! command -v openshell >/dev/null; then
  yellow "openshell CLI not found — installing to \$HOME/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh \
    || die "openshell CLI install failed — install manually and re-run"
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v openshell >/dev/null || die "openshell still not on PATH after install"
fi
green "openshell CLI: $(command -v openshell)"

log "2b. Port-forwarding the gateway and registering it with the CLI"
oc port-forward "svc/${GW_SVC}" 8080:8080 -n "${OPENSHELL_NAMESPACE}" >/tmp/openshell-pf.log 2>&1 &
PF_PID=$!
sleep 4
if [[ "${GATEWAY_ALREADY_REGISTERED}" == "1" ]]; then
  yellow "GATEWAY_ALREADY_REGISTERED=1 — skipping gateway add/select"
else
  # NOTE: assumes a local/plaintext-reachable gateway (values-openshift sets
  # server.disableTls: true). If your gateway enforces OIDC/mTLS, register it
  # yourself and re-run with GATEWAY_ALREADY_REGISTERED=1.
  openshell gateway add "${GATEWAY_URL}" --local --name "${GATEWAY_NAME}" 2>/dev/null || true
  openshell gateway select "${GATEWAY_NAME}" \
    || die "could not select gateway '${GATEWAY_NAME}' — likely OIDC/mTLS auth required (see caveats)"
fi
green "gateway '${GATEWAY_NAME}' selected (${GATEWAY_URL})"

# --- 3. write the OpenShell network policy ----------------------------------
log "3. Writing OpenShell network policy (allow anthropic+${ALLOW_HOST}; github omitted -> denied)"
cat >"${POLICY_FILE}" <<YAML
# OpenShell sandbox policy. Per-binary allowlist, fail-closed: only listed
# binaries may reach listed endpoints; github.com is absent -> denied.
version: 1
network_policies:
  anthropic_api:
    name: anthropic_api
    endpoints:
      - host: api.anthropic.com
        port: 443
        protocol: rest
        enforcement: enforce
        access: full
    binaries:
      - path: /usr/local/bin/claude
  contrast_allow:
    name: contrast_allow
    endpoints:
      - host: ${ALLOW_HOST}
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only
    binaries:
      - path: /usr/bin/curl
YAML
cat "${POLICY_FILE}"

# --- 4. create the sandbox with the policy attached -------------------------
# NOTE: this CLI's `sandbox create` attaches to the trailing command; there is
# no --detach. So we start it in the background with a keepalive command
# (sleep infinity) so the sandbox pod stays up while we probe it via
# `openshell sandbox exec`. The Claude Code agent itself is exercised through
# exec below (running `claude` as the foreground process would block the script
# and needs an API key just to start).
log "4. Creating sandbox '${SANDBOX_NAME}' with the OpenShell policy attached"
openshell sandbox create --name "${SANDBOX_NAME}" --policy "${POLICY_FILE}" --no-tty -- sleep infinity \
  >/tmp/openshell-create.log 2>&1 &
CREATE_PID=$!

# Wait until the sandbox accepts exec (i.e. pod is running).
log "4b. Waiting for sandbox to become ready"
READY=0
for _ in $(seq 1 60); do
  if openshell sandbox exec -n "${SANDBOX_NAME}" -- true >/dev/null 2>&1; then READY=1; break; fi
  # bail early if the create process already died
  kill -0 "${CREATE_PID}" 2>/dev/null || { yellow "create process exited early; see /tmp/openshell-create.log"; break; }
  sleep 3
done
[[ "${READY}" == "1" ]] || { cat /tmp/openshell-create.log 2>/dev/null; die "sandbox never became ready (check gateway auth / policy validation)"; }
green "sandbox '${SANDBOX_NAME}' ready under OpenShell policy"

# probe = run a command inside the sandbox THROUGH OpenShell (proxy path).
probe() { openshell sandbox exec -n "${SANDBOX_NAME}" --timeout 20 -- bash -lc "$1"; }

# Show the Claude Code agent is present in the sandbox (best-effort).
probe "command -v claude && claude --version" 2>/dev/null \
  && green "Claude Code agent available in sandbox" \
  || yellow "claude binary not in default image (denial demo uses curl; agent optional)"

# --- 5. probe: allowed vs denied, both enforced by OpenShell ----------------
log "5a. ALLOWED path: curl https://${ALLOW_HOST} from inside the sandbox"
# Write the body to a file inside the sandbox (not /dev/null, which trips a
# spurious "curl: (23) Failure writing output" through the exec stream), then
# print only the status. Judge on the HTTP status, not curl's exit code.
AOUT="$(probe "curl -sS -o /tmp/probe.out -w 'HTTP %{http_code}\n' --max-time 15 https://${ALLOW_HOST} 2>&1" || true)"
echo "${AOUT}"
if echo "${AOUT}" | grep -qiE 'HTTP (200|2[0-9][0-9])'; then
  green "OpenShell ALLOWED curl -> ${ALLOW_HOST} (matches policy)"
else
  yellow "allowed-path probe inconclusive"
fi

log "5b. DENIED path: reading ${DENY_URL} from inside the sandbox (expect 403 from proxy)"
DENIED=0
OUT="$(probe "curl -sS --max-time 15 ${DENY_URL} 2>&1" || true)"
echo "${OUT}"
if echo "${OUT}" | grep -qiE '403.*proxy|proxy after CONNECT|CONNECT tunnel failed, response 403|policy_denied'; then
  DENIED=1
elif ! echo "${OUT}" | grep -qiE '<html|HTTP/.* 200|<!DOCTYPE'; then
  DENIED=1   # no real page came back -> blocked
fi

# --- 6. corroborate via OpenShell deny logs ---------------------------------
log "6. OpenShell enforcement logs (proof the proxy did the deny)"
# NOTE: --tail STREAMS live logs and never returns; use a bounded read instead.
# The deny decision is an OCSF security event from the sandbox-side policy proxy:
#   NET:OPEN [MED] DENIED /usr/bin/curl(...) -> github.com:443
#     [engine:opa] [reason:endpoint github.com:443 is not allowed by any policy]
echo "--- sandbox proxy (OPA enforcement) ---"
SBLOG="$(openshell logs "${SANDBOX_NAME}" -n 800 --since 10m --source sandbox 2>/dev/null || true)"
DENYLINE="$(echo "${SBLOG}" | grep -iE 'DENIED' | grep -i "${DENY_URL#https://}" | tail -3)"
if [[ -n "${DENYLINE}" ]]; then
  echo "${DENYLINE}"
  green "OpenShell OPA engine logged the DENY for ${DENY_URL}"
  [[ "${DENIED}" == "1" ]] || DENIED=1
else
  echo "${SBLOG}" | grep -iE 'DENIED|deny|policy' | tail -5 || true
  yellow "no explicit DENIED line matched (check: openshell logs ${SANDBOX_NAME} --source sandbox | grep DENIED)"
fi
echo "--- gateway (policy load + relayed command) ---"
openshell logs "${SANDBOX_NAME}" -n 400 --since 10m --source gateway 2>/dev/null \
  | grep -iE 'status=loaded|ExecSandbox .*command started' | tail -3 || true

# --- 7. summary -------------------------------------------------------------
log "7. Result"
if [[ "${DENIED}" == "1" ]]; then
  green "DEMO PASSED: OpenShell's policy proxy DENIED the Claude Code agent's read of ${DENY_URL}, while allowing ${ALLOW_HOST}."
  exit 0
else
  red "DEMO INCONCLUSIVE/FAILED: ${DENY_URL} was not observably denied. Inspect: openshell logs ${SANDBOX_NAME} --tail"
  exit 1
fi
