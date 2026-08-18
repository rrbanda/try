# Troubleshooting: MCP Gateway HTTP 500 — Broker Cannot Reach MCP Server

> **Confirmed:** August 18, 2026 — Step 3 (remove `require_oauth`) resolved 500→200 on live cluster.  
> Next: AuthPolicy enforcement (Step 9) to make unauthenticated return 401.

> **Symptom:** External `curl` to `https://<GATEWAY>/mcp` returns HTTP 500  
> **MCP Server logs show:** `"Authentication failed - missing or invalid bearer token"`  
> **Meaning:** The broker is reaching the MCP server, but the MCP server is rejecting its request.  
> **Root cause:** `require_oauth = true` in MCP server config blocks the broker's internal connection.

---

## Step 0: Set variables

```bash
# Set your gateway hostname
export MCP_GATEWAY_HOSTNAME=$(oc get route mcp-gateway -n gateway-system -o jsonpath='{.spec.host}' 2>/dev/null || oc get route -n gateway-system -o jsonpath='{.items[0].spec.host}')
echo "Gateway: ${MCP_GATEWAY_HOSTNAME}"
```

---

## Step 1: Confirm the 500

```bash
curl -sk -w "\nHTTP_CODE: %{http_code}\n" \
  -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

- **HTTP 500** = broker can't create session with MCP server → continue below
- **HTTP 401** = AuthPolicy is working, needs token → skip to Step 7
- **HTTP 200** = working already (check response body for session ID)
- **HTTP 503** = Route/Envoy issue → check Route target port (Step 6)

---

## Step 2: Check broker config (GOLDEN DIAGNOSTIC)

This tells you exactly what the broker knows about the MCP server:

```bash
oc extract secret/mcp-gateway-config -n mcp-gateway-system --to=-
```

**Look for these fields:**

| Field | Expected Value | If Wrong |
|-------|---------------|----------|
| `hostname` | `openshift-mcp.mcp.local` | Fix HTTPRoute parentRef (Step 4) |
| `url` | `http://mcp-server.ocp-mcp-server.svc.cluster.local:8080/mcp` | Fix MCPServerRegistration |
| `credential` / token | A long JWT string (not empty) | Fix credentialRef (Step 5) |
| `prefix` | `openshift` | Fix MCPServerRegistration |

---

## Step 3: Check MCP server config for `require_oauth`

```bash
# Find the ConfigMap name
oc get configmap -n ocp-mcp-server -o name

# Check if require_oauth is set
oc get configmap -n ocp-mcp-server -o yaml | grep -i "require_oauth"
```

**If `require_oauth = true` is present, this is your problem.**

The broker connects internally to the MCP server. If `require_oauth` is enabled, the MCP server demands a valid OAuth token from the broker. The broker's `credentialRef` token may not pass the MCP server's validation.

**Fix: Remove `require_oauth` from the MCP server config.**  
External security is handled by the Gateway AuthPolicy — the MCP server trusts internal cluster traffic.

```bash
# Get the ConfigMap name
CM_NAME=$(oc get configmap -n ocp-mcp-server -o custom-columns=NAME:.metadata.name --no-headers | grep -i mcp | head -1)
echo "ConfigMap: ${CM_NAME}"

# View current config
oc get configmap ${CM_NAME} -n ocp-mcp-server -o jsonpath='{.data}' 

# Patch out require_oauth (replace config.toml with cleaned version)
oc get configmap ${CM_NAME} -n ocp-mcp-server -o jsonpath='{.data.config\.toml}' > /tmp/mcp-config.toml

# Remove the problematic lines
grep -v "require_oauth" /tmp/mcp-config.toml | grep -v "skip_jwt_verification" > /tmp/mcp-config-clean.toml

# Apply cleaned config
oc create configmap ${CM_NAME} -n ocp-mcp-server \
  --from-file=config.toml=/tmp/mcp-config-clean.toml \
  --dry-run=client -o yaml | oc apply -f -

# Restart MCP server
oc rollout restart deployment/mcp-server -n ocp-mcp-server
oc rollout status deployment/mcp-server -n ocp-mcp-server --timeout=60s
```

**Re-test:**
```bash
curl -sk -w "\nHTTP_CODE: %{http_code}\n" \
  -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

If now **HTTP 200** → jump to Step 7 for full E2E test.  
If still **HTTP 500** → continue to Step 4.

---

## Step 4: Fix HTTPRoute parentRef (hostname mismatch)

If the broker config shows `hostname: mcp-server.ocp-mcp-server.svc.cluster.local` instead of `openshift-mcp.mcp.local`, the HTTPRoute is not targeting the `mcps` listener:

```bash
# Check current HTTPRoute
oc get httproute -n ocp-mcp-server -o yaml | grep -A5 "parentRefs"

# Fix: patch to target mcps listener
ROUTE_NAME=$(oc get httproute -n ocp-mcp-server -o custom-columns=NAME:.metadata.name --no-headers | head -1)

oc patch httproute ${ROUTE_NAME} -n ocp-mcp-server --type=merge \
  -p '{"spec":{"parentRefs":[{"name":"mcp-gateway","namespace":"gateway-system","sectionName":"mcps"}]}}'

# Restart broker to pick up new config
oc rollout restart deployment/mcp-gateway -n mcp-gateway-system
oc rollout status deployment/mcp-gateway -n mcp-gateway-system --timeout=60s

# Verify broker config updated
oc extract secret/mcp-gateway-config -n mcp-gateway-system --to=- | grep hostname
# Must show: hostname: openshift-mcp.mcp.local
```

---

## Step 5: Fix broker credentials (credentialRef)

If the broker config has no `credential` field or an empty token:

```bash
# 5a. Ensure broker ServiceAccount exists
oc get sa mcp-gateway-broker -n ocp-mcp-server 2>/dev/null || \
  oc create sa mcp-gateway-broker -n ocp-mcp-server

# 5b. Create a token secret for it
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mcp-gateway-broker-token
  namespace: ocp-mcp-server
  annotations:
    kubernetes.io/service-account.name: mcp-gateway-broker
type: kubernetes.io/service-account-token
EOF

# 5c. Ensure controller can read it
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mcp-gateway-secret-reader
  namespace: ocp-mcp-server
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mcp-gateway-secret-reader
  namespace: ocp-mcp-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: mcp-gateway-secret-reader
subjects:
- kind: ServiceAccount
  name: mcp-gateway-controller
  namespace: mcp-gateway-system
EOF

# 5d. Patch MCPServerRegistration to use credentialRef
REG_NAME=$(oc get mcpserverregistration -n ocp-mcp-server -o custom-columns=NAME:.metadata.name --no-headers | head -1)

oc patch mcpserverregistration ${REG_NAME} -n ocp-mcp-server --type=merge \
  -p '{"spec":{"credentialRef":{"name":"mcp-gateway-broker-token","namespace":"ocp-mcp-server"}}}'

# 5e. Restart broker
oc rollout restart deployment/mcp-gateway -n mcp-gateway-system
oc rollout status deployment/mcp-gateway -n mcp-gateway-system --timeout=60s
```

---

## Step 6: Route target port (HTTP 503)

If you're getting HTTP 503, the OpenShift Route is pointing at the wrong port:

```bash
# Check current route
oc get route -n gateway-system -o jsonpath='{.items[0].spec.port.targetPort}'

# Fix: should be 8080 for Istio gateway
ROUTE_NAME=$(oc get route -n gateway-system -o custom-columns=NAME:.metadata.name --no-headers | head -1)
oc patch route ${ROUTE_NAME} -n gateway-system --type=json \
  -p '[{"op":"replace","path":"/spec/port","value":{"targetPort":"8080"}}]'
```

---

## Step 7: Full end-to-end test (after fix)

```bash
# Get a valid token
TOKEN=$(oc create token mcp-viewer -n ocp-mcp-server 2>/dev/null || \
  oc get secret mcp-viewer-token -n ocp-mcp-server -o jsonpath='{.data.token}' | base64 -d)

echo "Token: ${TOKEN:0:20}..."

# 7a: Initialize session
echo "=== INITIALIZE ==="
RESPONSE=$(curl -sk -D /tmp/mcp-headers.txt \
  -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}')
echo "${RESPONSE}"

SESSION=$(grep -i "mcp-session-id" /tmp/mcp-headers.txt | tr -d '\r' | awk '{print $2}')
echo "Session: ${SESSION}"

# 7b: List tools
echo ""
echo "=== TOOLS/LIST ==="
curl -sk "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# 7c: Call a tool
echo ""
echo "=== TOOLS/CALL ==="
curl -sk "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openshift_namespaces_list","arguments":{}}}'
```

---

## Step 8: Verify unauthenticated is blocked

```bash
echo "=== WITHOUT TOKEN (should be 401) ==="
curl -sk -w "\nHTTP_CODE: %{http_code}\n" \
  -X POST "https://${MCP_GATEWAY_HOSTNAME}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

- **401** = AuthPolicy working correctly ✓
- **200** = AuthPolicy not enforcing (see Step 9)
- **500** = Still broken (re-check Steps 2-5)

---

## Step 9: Fix AuthPolicy (if unauthenticated gets 200)

If unauthenticated requests pass through, the AuthPolicy isn't enforcing:

```bash
# Check AuthPolicy status
oc get authpolicy -n gateway-system
oc get authpolicy -n gateway-system -o yaml | grep -A3 "conditions"

# Check Authorino is running
oc get pods -n kuadrant-system | grep authorino

# Check Authorino logs for errors
oc logs -n kuadrant-system deployment/authorino -c authorino --tail=30

# Common fix: grant OIDC discovery access
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-jwks-anonymous-access
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:service-account-issuer-discovery
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:unauthenticated
EOF

# Restart Authorino
oc rollout restart deployment/authorino -n kuadrant-system
```

---

## Quick Reference: Expected state when working

| Component | Status |
|-----------|--------|
| MCP Server pod | Running, no `require_oauth` in config |
| Broker config hostname | `openshift-mcp.mcp.local` |
| Broker config credential | Non-empty JWT token |
| HTTPRoute parentRef | `sectionName: mcps` |
| Route targetPort | `8080` |
| AuthPolicy | `Accepted: True` |
| Authorino | Running, no TLS errors |
| Unauthenticated curl | HTTP 401 |
| Authenticated curl | HTTP 200 + session ID |
| tools/call | Returns tool result |
