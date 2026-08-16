# 1. Update the ConfigMap to match the working sandbox
oc get configmap -n ocp-mcp-server -o name | head -1
# Then patch that ConfigMap to add these two lines:
# require_oauth = true
# skip_jwt_verification = true

# 2. Restart the MCP server to pick up the config
oc rollout restart deployment/mcp-server -n ocp-mcp-server

# 3. Restart the broker (to clear any cached state)
oc rollout restart deployment/mcp-gateway -n mcp-gateway-system

# 4. Wait for both to be ready
oc rollout status deployment/mcp-server -n ocp-mcp-server --timeout=60s
oc rollout status deployment/mcp-gateway -n mcp-gateway-system --timeout=60s
