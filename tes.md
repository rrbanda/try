# MCP Gateway End-to-End Fix — Bippin's Cluster

## Root Cause (CONFIRMED WORKING)

The HTTPRoute's `parentRef` was NOT targeting `sectionName: mcps`. This caused the broker config to use the wrong hostname, so the gateway Envoy returned 404 on every `tools/call`.

**Fix:** Patch the HTTPRoute parentRef to target the `mcps` listener.

---

## Step 1: Patch HTTPRoute to target `mcps` listener

```bash
oc patch httproute openshift-mcp-server-route -n ocp-mcp-server --type=merge \
  -p '{"spec":{"parentRefs":[{"name":"mcp-gateway","namespace":"gateway-system","sectionName":"mcps"}]}}'
```

## Step 2: Restart broker to pick up new config

```bash
oc rollout restart deployment/mcp-gateway -n mcp-gateway-system
oc rollout status deployment/mcp-gateway -n mcp-gateway-system --timeout=60s
```

## Step 3: Verify broker config updated

```bash
oc get secret mcp-gateway-config -n mcp-gateway-system -o jsonpath='{.data.config\.yaml}' | base64 -d | grep hostname
```

Must show: `hostname: openshift-mcp.mcp.local`

## Step 4: Grant RBAC for MCP server ServiceAccount

```bash
oc adm policy add-cluster-role-to-user cluster-reader system:serviceaccount:ocp-mcp-server:default
```

## Step 5: Test end-to-end

```bash
export MCP_GATEWAY_HOSTNAME=$(oc get route mcp-gateway -n gateway-system -o jsonpath='{.spec.host}')
echo "Gateway: $MCP_GATEWAY_HOSTNAME"

# Get token
TOKEN=$(oc create token default -n ocp-mcp-server 2>/dev/null)
if [ -z "$TOKEN" ]; then
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
data: {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"APIVERSION   KIND        NAME\nv1           Namespace   default\nv1           Namespace   kube-system\n..."}]}}
```

## Summary

| What was wrong | Fix |
|---|---|
| HTTPRoute parentRef missing `sectionName: mcps` | `oc patch httproute ... sectionName: mcps` |
| Broker config had wrong hostname | Restart broker after HTTPRoute fix |
| ServiceAccount lacks cluster-reader | `oc adm policy add-cluster-role-to-user cluster-reader` |
