# Agent Deployment Test Case

Test case for verifying agent deployment with Rossoctl operator, covering AgentCard and AgentRuntime features.

## Overview

This test case validates that an agent is properly deployed with the required Kubernetes resources and follows the Rossoctl agent discovery and management patterns:

- **AgentCard**: Automatic discovery of deployed agents and their capabilities
- **AgentRuntime**: Runtime management with authentication/identity sidecars
- **Distributed Tracing**: OpenTelemetry integration for agent observability
- **Protocol Support**: Agent-to-agent (a2a) and HTTP protocol support

## Files

- `test-agent-deployment.sh` - Main test script that verifies agent deployment
- `sample-agent.yaml` - Example agent deployment with required labels and resources
- `deploy.sh` - Script to deploy the sample agent
- `cleanup.sh` - Script to remove all agent resources

## Prerequisites

- OpenShift cluster with Rossoctl operator installed
- `oc` CLI configured with cluster access
- Admin privileges for creating/deleting resources (AgentCard/AgentRuntime require `--as system:admin`)
- `jq` command (optional, fallback available for JSON parsing)
- `curl` in container images for health checks (test will skip if unavailable)

## Usage

### Deploy Sample Agent

```bash
cd agent-deployment/
./deploy.sh
```

This creates:
- Test agent deployment with required `protocol.rossoctl.io/a2a` label
- Service for agent endpoints
- AgentCard and AgentRuntime resources (operator adds `rossoctl.io/type: agent` label during reconciliation)

### Run Tests

```bash
./test-agent-deployment.sh
```

The test verifies:

1. **Agent Deployment**: Deployment exists and is ready
2. **Required Labels**: `rossoctl.io/type: agent` (added by operator) and `protocol.rossoctl.io/*` labels
3. **AgentCard Creation**: Discovery resource is created automatically
4. **AgentRuntime Configuration**: Runtime management is configured
5. **Pod Injection**: Sidecars (AuthBridge, SPIFFE) are injected
6. **Service Accessibility**: Agent service is reachable
7. **Distributed Tracing**: OpenTelemetry configuration is present

### Cleanup

```bash
./cleanup.sh
```

## Environment Variables

- `PROJECT` - OpenShift project name (default: `ajamias`)
- `AGENT_NAME` - Agent deployment name (default: `test-agent`)
- `TIMEOUT` - Test timeout in seconds (default: `300`)

## Expected Test Results

### Successful Deployment

```
✓ Agent deployment 'test-agent' exists
✓ Agent deployment is ready (1/1)
✓ Agent has rossoctl.io/type: agent label (added by operator)
✓ Agent has protocol label: protocol.rossoctl.io/a2a
✓ AgentCard 'test-agent' exists
✓ AgentCard has endpoints configured
✓ AgentRuntime 'test-agent' exists
✓ AgentRuntime references correct deployment
✓ Agent pod 'test-agent-xxx' found
✓ AuthBridge sidecar injected
✓ SPIFFE helper sidecar injected
✓ Agent pod is running
✓ Agent service 'test-agent' exists
✓ Agent health endpoint responsive
✓ OpenTelemetry configuration found
```

### Warnings vs Errors

- **✓ (Green)**: Critical checks that must pass
- **⚠ (Yellow)**: Optional features that may not be configured
- **✗ (Red)**: Critical failures that indicate deployment issues

## Agent Requirements

Agents deployed with Rossoctl must:

1. **Have Required Labels**:
   ```yaml
   protocol.rossoctl.io/a2a: "true"      # Protocol label (set by user)
   # rossoctl.io/type: agent             # Added by operator during reconciliation
   ```

2. **Support Discovery**: AgentCard with `targetRef` pointing to deployment

3. **Runtime Management**: AgentRuntime with `type: agent` and `targetRef` configured for:
   - Authentication/identity sidecars
   - Distributed tracing with OpenTelemetry
   - SPIFFE workload identity

4. **Protocol Support**: Implement supported protocols (HTTP, agent-to-agent)

## Integration with Existing Workflows

This test case follows the same patterns as other test cases in this repository:

- All scripts use `set -euo pipefail`
- All `oc` mutating commands use `--as system:admin`
- Environment variables for configuration
- Consistent output formatting with ✓/⚠/✗ indicators

## Troubleshooting

### AgentCard/AgentRuntime Not Found

These Custom Resource Definitions may not be available on all OpenShift clusters. The test will show warnings but continue.

### Sidecars Not Injected

Sidecar injection depends on:
- AgentRuntime resource configuration
- Platform operator availability
- Proper labels on the deployment

### Agent Not Responding

Check:
- Pod logs: `oc logs -l app=test-agent -n mm-test`
- Service endpoints: `oc get endpoints test-agent -n mm-test`
- Network policies that might block traffic

## Reference

- Rossoctl Operator: https://github.com/rossoctl/rossoctl
- AgentCard/AgentRuntime CRDs: `agent.rossoctl.dev/v1alpha1`
- Install docs: https://github.com/rossoctl/rossoctl/blob/main/docs/getting-started/install.md