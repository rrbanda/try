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

## End-to-End Test (Step 9)

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

## Expected Result

If working, the last curl returns:
```
event: message
data: {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"APIVERSION   KIND        NAME..."}]}}
```

If still failing with "4xx for initialize POST, likely a legacy SSE server":
- Check broker logs: `oc logs deployment/mcp-gateway -n mcp-gateway-system --tail=50`
- Verify Istio is healthy: `oc get istio -A` (must NOT show ReconcileError/IstioCNINotFound)
- The Istio control plane MUST be functional for the gateway to route tools/call traffic
