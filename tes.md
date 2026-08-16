# MCP Gateway End-to-End Fix — Bippin's Cluster

## Status

- PREFIX is already correctly set to `openshift` ✅ (immutable, confirmed working)
- `tools/call` still fails → issue is broker-to-MCP-server connectivity during session creation

---

## Step 1: Check broker runtime config

```bash
oc get secret mcp-gateway-config -n mcp-gateway-system -o jsonpath='{.data.config\.yaml}' | base64 -d
```

Verify output shows:
- `prefix: openshift` ← must be present
- `url: http://...` ← the URL broker uses to connect to MCP server
- `credential:` ← token for authenticating to MCP server

## Step 2: Check broker logs for the actual error

```bash
oc logs deployment/mcp-gateway -n mcp-gateway-system --tail=50 | grep -i "server\|error\|initialize\|session\|4xx"
```

## Step 3: Restart the broker

## Step 3: Restart the broker

```bash
oc rollout restart deployment/mcp-gateway -n mcp-gateway-system
oc rollout status deployment/mcp-gateway -n mcp-gateway-system --timeout=60s
```

## Step 4: Verify broker picks up the prefix

```bash
oc get mcpserverregistrations -n ocp-mcp-server -o custom-columns='NAME:.metadata.name,PREFIX:.spec.prefix,STATE:.status.state'
```

PREFIX must show `openshift`. STATE must show `Enabled`.

## Step 5: Test end-to-end

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

## If Still Failing

Check broker logs immediately after the test:

```bash
oc logs deployment/mcp-gateway -n mcp-gateway-system --tail=30 | grep -i "server\|error\|initialize"
```

- If `server=""` still appears → prefix patch didn't take, check: `oc get mcpserverregistration -n ocp-mcp-server -o jsonpath='{.items[0].spec.prefix}'`
- If `server="ocp-mcp-server/openshift-mcp-server-reg"` but still 4xx → MCP server connectivity issue, run:
  ```bash
  oc get secret mcp-gateway-config -n mcp-gateway-system -o jsonpath='{.data.config\.yaml}' | base64 -d
  ```
  and verify `url` resolves and `prefix` is populated.
