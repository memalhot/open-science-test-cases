# NVIDIA OpenShell Deployment Test Case

Test case for deploying NVIDIA OpenShell on OpenShift - a policy-enforced sandbox runtime for autonomous AI agents.

## Overview

This test case validates deployment of NVIDIA OpenShell, which provides:

- **Sandboxed Agent Execution**: Policy-enforced runtime for AI agents with isolation
- **Multi-domain Policies**: Filesystem, network, process, and inference controls
- **LLM Privacy**: Sensitive context stays on sandbox compute
- **Hot-reloadable Policies**: Network rules update without restart
- **Multi-agent Support**: Compatible with Claude Code, OpenCode, GitHub Copilot CLI

## Architecture

OpenShell consists of:
- **Gateway**: Control-plane API (gRPC/HTTP on port 8080)
- **Sandboxes**: Kubernetes-native execution environments via agent-sandbox CRDs
- **Policy Engine**: Declarative YAML-based access controls

## Files

- `deploy.sh` - Installs agent-sandbox CRDs and OpenShell via Helm
- `test-openshell.sh` - Validates gateway, sandboxes, and API endpoints
- `cleanup.sh` - Removes OpenShell and associated resources
- `values-openshift.yaml` - OpenShift-specific Helm values

## Prerequisites

- OpenShift cluster with admin access
- `oc` CLI configured
- `helm` >= 3.18.0
- Admin privileges for SCC configuration
- Internet access for pulling images from ghcr.io

## Usage

### Deploy OpenShell

```bash
cd endpoints/openshell/
./deploy.sh
```

This:
1. Installs kubernetes-sigs agent-sandbox CRDs
2. Creates `openshell` namespace
3. Configures privileged SCC for sandbox service account
4. Deploys OpenShell via Helm with OpenShift-specific settings

### Run Tests

```bash
./test-openshell.sh
```

Tests verify:

1. **Agent Sandbox CRDs**: Custom resources registered
2. **Gateway Deployment**: StatefulSet/Deployment ready
3. **Gateway Service**: gRPC/HTTP API accessible
4. **Health Endpoints**: Health (8081) and metrics (9090) responding
5. **Database**: SQLite or PostgreSQL backend operational
6. **RBAC**: Service accounts and roles configured
7. **Sandbox Namespace**: Workspace isolation enabled

### Cleanup

```bash
./cleanup.sh
```

Removes Helm release, namespace, and optionally agent-sandbox CRDs.

## Environment Variables

- `OPENSHELL_NAMESPACE` - Namespace (default: `openshell`)
- `OPENSHELL_VERSION` - Helm chart version (default: `latest`)
- `SANDBOX_NAMESPACE` - Sandbox workspace namespace (default: `openshell-sandboxes`)
- `TIMEOUT` - Test timeout in seconds (default: `300`)
- `KEEP_CRDS` - Preserve agent-sandbox CRDs on cleanup (default: `true`)

## Expected Test Results

### Successful Deployment

```
✓ Agent sandbox CRDs installed
✓ OpenShell namespace 'openshell' exists
✓ Gateway StatefulSet/Deployment ready
✓ Gateway service 'openshell-gateway' exists
✓ Health endpoint responding (8081)
✓ Metrics endpoint responding (9090)
✓ gRPC API accessible (8080)
✓ Database initialized
✓ Sandbox namespace configured
✓ Service account has privileged SCC
✓ RBAC roles created
```

### Status Indicators

- **✓ (Green)**: Critical checks passed
- **⚠ (Yellow)**: Optional features unavailable
- **✗ (Red)**: Critical failures

## Configuration

### OpenShift-Specific Settings

`values-openshift.yaml` includes:

```yaml
server:
  disableTls: true           # Route handles TLS
podSecurityContext:
  fsGroup: null              # OpenShift auto-assigns
securityContext:
  runAsUser: null            # OpenShift auto-assigns
workload:
  kind: statefulset          # SQLite default
server:
  drivers:
    kubernetes:
      workspaceMode: managed  # Auto-create sandbox namespaces
```

### Authentication

Default: mTLS with auto-generated certificates

Optional OIDC (Keycloak example):
```yaml
server:
  oidc:
    issuer: "https://keycloak.example.com/realms/openshell"
    audience: "openshell-cli"
    adminRole: "admin"
```

### Database Backend

**Default**: SQLite with StatefulSet + PVC

**PostgreSQL** (HA deployments):
```bash
kubectl create secret generic pg-creds -n openshell \
  --from-literal=uri="postgresql://user:pass@host:5432/openshell"

helm upgrade openshell ... \
  --set workload.kind=deployment \
  --set server.externalDbSecret=pg-creds \
  --set replicaCount=3
```

### Credential Storage

**Options**:
- Database (default, encrypted)
- Kubernetes Secrets
- HashiCorp Vault

```yaml
server:
  credentialDrivers:
    kubernetesSecrets:
      enabled: true
      namespace: "openshell-credentials"
```

## Access Methods

### Internal (gRPC API)

```bash
# Port-forward gateway
oc port-forward svc/openshell-gateway 8080:8080 -n openshell

# Test with grpcurl (if available)
grpcurl -plaintext localhost:8080 list
```

### Route (External)

```bash
# Create route for external access
oc create route edge openshell-gateway \
  --service=openshell-gateway \
  --port=8080 \
  -n openshell

# Get URL
oc get route openshell-gateway -n openshell -o jsonpath='{.spec.host}'
```

## Security Features

### Sandbox Policies

Four policy domains enforced per sandbox:

1. **Filesystem**: Read/write controls, prevents unauthorized access
2. **Network**: L7 enforcement, blocks unauthorized outbound connections
3. **Process**: Syscall filtering, privilege escalation prevention
4. **Inference**: Model API routing, keeps sensitive context local

Example policy:
```yaml
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: my-agent-sandbox
spec:
  policy:
    filesystem:
      allowedPaths: ["/workspace", "/tmp"]
    network:
      allowedHosts: ["api.openai.com"]
    inference:
      sensitiveModels: ["gpt-4"]
```

### OpenShift SCC

Requires privileged SCC for sandbox service account:

```bash
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n openshell
```

## Troubleshooting

### Gateway Not Starting

```bash
# Check StatefulSet/Deployment status
oc describe statefulset openshell-gateway -n openshell

# View logs
oc logs -l app.kubernetes.io/name=openshell -n openshell
```

### Sandbox Creation Fails

```bash
# Verify CRDs
oc get crd sandboxes.agents.x-k8s.io

# Check SCC
oc describe scc privileged | grep openshell-sandbox

# View sandbox namespace
oc get pods -n openshell-sandboxes
```

### Database Connection Issues

```bash
# SQLite: check PVC
oc get pvc -n openshell

# PostgreSQL: verify secret
oc get secret pg-creds -n openshell
```

## Integration with Development Workflows

Follows repository conventions:
- `set -euo pipefail` in all scripts
- `--as system:admin` for mutating commands
- Environment variables for configuration
- Status indicators (✓/⚠/✗)

## Use Cases

- **AI Agent Development**: Sandboxed execution for LangChain, CrewAI agents
- **Code Generation Safety**: Isolate code-generating LLMs
- **Multi-tenant Workspaces**: Per-team sandbox isolation
- **Compliance**: Policy-enforced data access controls

## Limitations

- **Alpha status**: Expect API changes
- **OpenShift support**: Experimental, documented in upstream
- **GPU passthrough**: Requires NVIDIA Container Toolkit
- **Performance**: Sandbox overhead vs direct execution

## Reference

- **Upstream**: https://github.com/NVIDIA/openshell
- **Docs**: https://docs.nvidia.com/openshell/latest/
- **Agent Sandbox**: https://github.com/kubernetes-sigs/agent-sandbox
- **License**: Apache 2.0
