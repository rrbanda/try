# MCP Gateway End-to-End Fix — Bippin's Cluster

## Root Cause (Confirmed)

The broker config has `hostname: mcp-server.ocp-mcp-server.svc.cluster.local` but the gateway has NO virtual host for that. The gateway's `mcps` listener only accepts `*.mcp.local` hostnames. So when the broker routes `tools/call` through the gateway Envoy, it gets **404** → "4xx for initialize POST, likely a legacy SSE server".

Working sandbox has: `hostname: openshift-mcp.mcp.local`

---

## Step 1: Fix the HTTPRoute hostname

```bash
oc patch httproute openshift-mcp-server-route -n ocp-mcp-server --type=merge \
  -p '{"spec":{"hostnames":["openshift-mcp.mcp.local"]}}'
```

## Step 2: Ensure Gateway has `mcps` listener

```bash
oc get gateway mcp-gateway -n gateway-system -o jsonpath='{.spec.listeners[*].name}'
```

If `mcps` is NOT listed, add it:

```bash
oc patch gateway mcp-gateway -n gateway-system --type=json \
  -p '[{"op":"add","path":"/spec/listeners/-","value":{"name":"mcps","hostname":"*.mcp.local","port":8080,"protocol":"HTTP","allowedRoutes":{"namespaces":{"from":"All"}}}}]'
```

## Step 3: Ensure HTTPRoute targets the mcps listener

```bash
oc patch httproute openshift-mcp-server-route -n ocp-mcp-server --type=merge \
  -p '{"spec":{"parentRefs":[{"name":"mcp-gateway","namespace":"gateway-system","sectionName":"mcps"}]}}'
```

## Step 4: Restart broker to pick up new config

```bash
oc rollout restart deployment/mcp-gateway -n mcp-gateway-system
oc rollout status deployment/mcp-gateway -n mcp-gateway-system --timeout=60s
```

## Step 5: Verify broker config updated

```bash
oc get secret mcp-gateway-config -n mcp-gateway-system -o jsonpath='{.data.config\.yaml}' | base64 -d | grep hostname
```

Must show: `hostname: openshift-mcp.mcp.local`

If it still shows the old hostname, wait 30s and check again (controller needs to reconcile).

## Step 6: Test end-to-end

```bash
export MCP_GATEWAY_HOSTNAME=$(oc get route mcp-gateway -n gateway-system -o jsonpath='{.spec.host}')
echo "Gateway: $MCP_GATEWAY_HOSTNAME"

# Get token
TOKEN=$(oc create token default -n ocp-mcp-server 2>/dev/null)
if [ -z "$TOKEN" ]; then
  oc apply -f - <<'TOKEOF'
apiVersion: v1
kind: Secret
metadata:
  name: test-token
  namespace: ocp-mcp-server
  annotations:
    kubernetes.io/service-account.name: default
type: kubernetes.io/service-account-token
TOKEOF
  sleep 3
  TOKEN=$(oc get secret test-token -n ocp-mcp-server -o jsonpath='{.data.token}' | base64 -d)
fi
echo "Token length: ${#TOKEN}"

# Initialize
SESSION_ID=$(curl -sk -D - -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')
echo "Session: $SESSION_ID"

# tools/call
echo ""
echo "=== tools/call ==="
curl -sk -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"openshift_namespaces_list","arguments":{}}}'
```

## Expected Result

```
event: message
data: {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"APIVERSION   KIND   NAME..."}]}}
```
