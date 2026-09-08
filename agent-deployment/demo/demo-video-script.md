# Rossoctl demo

Start: In this demo, we onboard an AI agent to Rossoctl in a single script, and
then call it to prove it's live. This demo is particularly useful if you have a multi-agent system that speaks A2A since we’ll see that Rossoctl handles the discovery, identity, and policies so your agents can automatically find each other.

Step 0: First it checks that the operator's controller is running and its three resources are installed: AgentRuntime, AgentCard, and AuthorizationPolicy.

Step 1: Next we spin up a fresh namespace and opt it into Rossoctl with the
`rossoctl-enabled` label. That label is the switch that tells the operator's webhook to
start paying attention to the resources in the namespace.

Step 2: Now we deploy the agent. For demo purposes, it’s a tiny server that serves its A2A card at the well-known path and answers agent-to-agent requests. Think of it as a stand-in for whatever real agent you'd bring to deploy. (WAIT FOR FINISH) The script confirms it's serving a valid A2A card at its service address inside the cluster.

Step 3: Now we apply two objects: an AgentRuntime that points at the deployment, and an AuthorizationPolicy that governs it.

Step 4: The AgentCard gets created automatically by the operator. From the AgentRuntime and the deployment.

Step 5: Step 5 are some logs from the operator that confirm that the agent was discovered

Step 5b/c: To confirm the agent is reachable, we send it an A2A message-send request, asking about the weather. And it answers with a JSON-RPC ack, task completed. The agent received the call and acknowledged it.

END: To clean up, we delete the namespace along with the deployment and agent custom resources. If your agent uses A2A communication, this video demonstrates how to deploy your agent using rossoctl. If you’d like to sandbox your agent, then we can move on to the OpenShell demo.

