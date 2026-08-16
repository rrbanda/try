# MCP Gateway End-to-End Fix — Bippin's Cluster

## Prerequisites Check (Step 1)

Run these first to verify the foundation:

```bash
echo "=== OCP Version ===" && oc version
echo ""
echo "=== RHOAI Version ===" && oc get csv -n redhat-ods-operator | grep -i rhods
echo ""
echo "=== Service Mesh ===" && oc get csv -A | grep -i servicemesh
echo ""
echo "=== MCP Gateway Operator ===" && oc get csv -A | grep -i mcp-gateway
echo ""
echo "=== Kuadrant/RHCL ===" && oc get csv -A | grep -i kuadrant
```

## Core Components Health (Step 2)

```bash
echo "=== Gateway ===" && oc get gateway -A
echo ""
echo "=== Gateway Pods ===" && oc get pods -n gateway-system
echo ""
echo "=== MCP Gateway Pods ===" && oc get pods -n mcp-gateway-system
echo ""
echo "=== MCP Server Pods ===" && oc get pods -n ocp-mcp-server
echo ""
echo "=== Istio Health ===" && oc get istio -A
echo ""
echo "=== IstioCNI ===" && oc get istiocni -A
```

## Fix: Update MCP Server ConfigMap (Step 3)

The working sandbox uses `require_oauth = true` + `skip_jwt_verification = true`. Apply this:

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: openshift-mcp-server-config
  namespace: ocp-mcp-server
data:
  config.toml: |
    log_level = 5
    port = "8080"
    read_only = true
    toolsets = ["core", "config"]
    require_oauth = true
    skip_jwt_verification = true
    cluster_auth_mode = "passthrough"

    [[denied_resources]]
    group = ""
    version = "v1"
    kind = "Secret"

    [[denied_resources]]
    group = ""
    version = "v1"
    kind = "ConfigMap"

    [[denied_resources]]
    group = "rbac.authorization.k8s.io"
    version = "v1"
    kind = "Role"

    [[denied_resources]]
    group = "rbac.authorization.k8s.io"
    version = "v1"
    kind = "RoleBinding"

    [[denied_resources]]
    group = "rbac.authorization.k8s.io"
    version = "v1"
    kind = "ClusterRole"

    [[denied_resources]]
    group = "rbac.authorization.k8s.io"
    version = "v1"
    kind = "ClusterRoleBinding"
EOF
```

## Fix: HTTPRoute Backend (Step 4)

The HTTPRoute must point to the actual ClusterIP service (not ExternalName):

```bash
oc patch httproute openshift-mcp-server-route -n ocp-mcp-server --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"mcp-server"}]'
```

## Fix: DestinationRule for mTLS (Step 5)

Disable Istio mTLS for the MCP server service:

```bash
oc apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: mcp-server-no-mtls
  namespace: ocp-mcp-server
spec:
  host: mcp-server.ocp-mcp-server.svc.cluster.local
  trafficPolicy:
    tls:
      mode: DISABLE
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: openshift-mcp-server-no-mtls
  namespace: ocp-mcp-server
spec:
  host: openshift-mcp-server.ocp-mcp-server.svc.cluster.local
  trafficPolicy:
    tls:
      mode: DISABLE
EOF
```

## Fix: Namespace Labels for Istio Discovery (Step 6)

```bash
oc label namespace ocp-mcp-server istio-discovery=enabled --overwrite
oc label namespace gateway-system istio-discovery=enabled --overwrite
oc label namespace mcp-gateway-system istio-discovery=enabled --overwrite
```

## Restart Everything (Step 7)

```bash
oc rollout restart deployment/mcp-server -n ocp-mcp-server
oc rollout restart deployment/mcp-gateway -n mcp-gateway-system
oc rollout status deployment/mcp-server -n ocp-mcp-server --timeout=60s
oc rollout status deployment/mcp-gateway -n mcp-gateway-system --timeout=60s
```

## Verify (Step 8)

```bash
echo "=== MCPServerRegistration ==="
oc get mcpserverregistrations -n ocp-mcp-server

echo ""
echo "=== Broker logs (last 5 relevant) ==="
oc logs deployment/mcp-gateway -n mcp-gateway-system --tail=20 | grep -i "server validation\|healthy"

echo ""
echo "=== MCP Server config ==="
oc exec deployment/mcp-server -n ocp-mcp-server -- cat /etc/mcp-config/config.toml
```

## CRITICAL Diagnostic: Isolate the Broker's Session Path (Step 9)

The broker uses TWO paths:
- **Discovery** (SSE): connects directly to `url` in config → works
- **Session/tools/call** (Streamable HTTP): connects through the gateway Envoy using Host `openshift-mcp.mcp.local`

This test simulates EXACTLY what the broker does for `tools/call`:

```bash
echo "=== Test 1: Direct to MCP server (bypass gateway) ==="
oc run test-direct --rm -i --restart=Never -n mcp-gateway-system \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -- \
  curl -s -w "\nHTTP_CODE:%{http_code}\n" -X POST \
  http://openshift-mcp-server.ocp-mcp-server.svc.cluster.local:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

```bash
echo "=== Test 2: Through gateway Envoy with internal hostname (what broker does for tools/call) ==="
oc run test-via-gw --rm -i --restart=Never -n mcp-gateway-system \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -- \
  curl -s -w "\nHTTP_CODE:%{http_code}\n" -X POST \
  http://mcp-gateway-istio.gateway-system.svc.cluster.local:8080/mcp \
  -H "Host: openshift-mcp.mcp.local" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

```bash
echo "=== Test 3: Check broker's actual config (what URL and hostname it uses) ==="
oc get secret mcp-gateway-config -n mcp-gateway-system -o jsonpath='{.data.config\.yaml}' | base64 -d
```

### Interpreting Results:

| Test 1 (Direct) | Test 2 (Via Gateway) | Diagnosis |
|---|---|---|
| HTTP 200 | HTTP 200 | Both paths work — issue is broker-internal |
| HTTP 200 | HTTP 404 | **Gateway can't route internal hostname** — Envoy vhost not programmed |
| HTTP 200 | HTTP 503 | **Gateway can't reach backend** — DestinationRule or mTLS issue |
| HTTP 4xx | any | MCP server itself rejects — config/image issue |

## End-to-End Test via External Gateway (Step 10)

```bash
export MCP_GATEWAY_HOSTNAME=$(oc get route mcp-gateway -n gateway-system -o jsonpath='{.spec.host}')
echo "Gateway: $MCP_GATEWAY_HOSTNAME"

# Get token (handles older oc clients)
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
echo "=== tools/call test ==="
curl -sk -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"openshift_namespaces_list","arguments":{}}}'
```

## Expected Results

**Step 9 — Test 1 (Direct):** HTTP 200 with JSON-RPC response or SSE stream
**Step 9 — Test 2 (Via Gateway):** HTTP 200 — if NOT, this is the root cause
**Step 10 — tools/call:** SSE stream with namespace list

If Test 2 fails with 404/503:
```bash
echo "=== Check Envoy vhosts for internal hostname ==="
oc exec deployment/mcp-gateway-istio -n gateway-system -- \
  curl -s localhost:15000/config_dump?resource=dynamic_route_configs | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(vh['name']) for rc in d.get('configs',[]) for rs in rc.get('dynamic_route_configs',[]) for vh in rs.get('route_config',{}).get('virtual_hosts',[])]" 2>/dev/null || \
  echo "Try: oc exec deployment/mcp-gateway-istio -n gateway-system -- curl -s localhost:15000/config_dump | grep -c 'openshift-mcp.mcp.local'"

echo ""
echo "=== Check HTTPRoute targets mcps listener ==="
oc get httproute openshift-mcp-server-route -n ocp-mcp-server -o yaml | grep -A5 "parentRefs"

echo ""
echo "=== Check Gateway has mcps listener ==="
oc get gateway mcp-gateway -n gateway-system -o yaml | grep -A5 "mcps"
```

## If Everything Passes but tools/call STILL Fails (Step 11)

Check broker logs at the exact moment of failure:

```bash
echo "=== Trigger tools/call and immediately check logs ==="
# In one terminal, tail logs:
oc logs -f deployment/mcp-gateway -n mcp-gateway-system &
LOG_PID=$!

# Wait a moment then fire request
sleep 2
curl -sk -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"openshift_namespaces_list","arguments":{}}}'

# Kill log tail
sleep 3 && kill $LOG_PID 2>/dev/null
```

Look for these patterns in logs:
- `server=""` → prefix/routing table not built (MCPServerRegistration uses wrong field)
- `4xx for initialize POST` → broker can't create session to backend
- `connection refused` → network/service issue
- `tls handshake` → mTLS issue (need DestinationRule)
