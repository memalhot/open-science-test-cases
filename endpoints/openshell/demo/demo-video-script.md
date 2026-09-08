# Openshell demo:

Start: In this demo, we deploy an OpenShell sandbox for an agent in a single script, and
then make external requests from inside the sandbox to validate it works. This demo is especially useful if you want to explicitly allow your agent to access specific endpoints so it doesn’t make unexpected requests elsewhere.

Step 1: first it makes sure the OpenShell gateway is up and running in the cluster.

Step 2: Then it confirms the OpenShell CLI is installed, port-forwards the gateway, and registers it so we can drive everything locally.

Step 3: Now we apply the policy. The policy explicitly allows the Anthropic API and
example.com, each tied to a specific binary. Later on, we will be sending a request to github.com, which we hope will fail because it is not allowed in the policy.

Step 4: Now we spin up a sandbox called claude-agent with that policy attached, and give
it a moment to come up. (SKIP to 0:34) We see that it is ready by reading the claude code version.

Step 5: First from inside the sandbox, we curl example.com and it goes straight through with a 200, exactly like the policy says it should. After that, the same agent tries to reach github.com and the proxy denies it with a 403 before the connection is ever made.

Step 6: You can see the logs from the gateway in step 6.

END: To clean up, we delete the sandbox. So in this demo, we only see explicit allow permissions to external urls, however if any of you need more administrative endpoints to our infrastructure, for example logs, metrics, etc, just let us know and we can work with you on getting permissions for your agents.

