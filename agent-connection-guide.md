# Connecting Your AI Agent to OpenShift MCP Server

## Endpoint

```
https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp
```

All requests go to this single URL. The protocol is JSON-RPC over HTTP (Streamable HTTP transport).

---

## Step 1: Get Your Token

Ask your cluster admin to create a token for your agent:

```bash
oc create token <your-service-account> -n ocp-mcp-server --duration=3600s
```

Or use the pre-existing test token:

```bash
oc get secret test-token -n ocp-mcp-server -o jsonpath='{.data.token}' | base64 -d
```

---

## Step 2: Initialize a Session

```bash
curl -sk -D - -X POST "https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <TOKEN>" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-03-26",
      "capabilities": {},
      "clientInfo": {"name": "my-agent", "version": "1.0"}
    }
  }'
```

**Save the `Mcp-Session-Id` response header.** Required for all subsequent calls.

---

## Step 3: List Available Tools

```bash
curl -sk -X POST "https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

---

## Step 4: Call a Tool

Example — list namespaces:

```bash
curl -sk -X POST "https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openshift_namespaces_list","arguments":{}}}'
```

Example — list pods in a namespace:

```bash
curl -sk -X POST "https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"openshift_pods_list","arguments":{"namespace":"default"}}}'
```

---

## Quick Copy-Paste Test (All-in-One)

Replace `TOKEN` with your actual token:

```bash
TOKEN="<paste-your-token-here>"
URL="https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp"

# Initialize
SESSION_ID=$(curl -sk -D - -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')
echo "Session: $SESSION_ID"

# List tools
echo "=== Available Tools ==="
curl -sk -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call a tool
echo ""
echo "=== Namespaces ==="
curl -sk -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openshift_namespaces_list","arguments":{}}}'
```

---

## SDK Integration

### Python

```python
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def connect():
    url = "https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp"
    headers = {"Authorization": "Bearer <TOKEN>"}

    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print(f"Tools: {[t.name for t in tools.tools]}")

            result = await session.call_tool("openshift_namespaces_list", arguments={})
            print(result.content[0].text)
```

### TypeScript

```typescript
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const transport = new StreamableHTTPClientTransport(
  new URL("https://mcp-gateway.apps.elab-ctigtdc07d.ecs.dyn.nsroot.net/mcp"),
  { requestInit: { headers: { "Authorization": "Bearer <TOKEN>" } } }
);

const client = new Client({ name: "my-agent", version: "1.0" });
await client.connect(transport);

const tools = await client.listTools();
const result = await client.callTool({ name: "openshift_namespaces_list", arguments: {} });
console.log(result.content[0].text);
```

---

## Security

- **HTTPS only** — all traffic is TLS encrypted
- **JWT required** — every request must include `Authorization: Bearer <token>`
- **Read-only** — no write operations are possible
- **Restricted resources** — Secrets, ConfigMaps, and RBAC objects are blocked
- **Session-based** — must initialize before calling tools

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| HTTP 401 | Token invalid/expired | Get a fresh token |
| HTTP 403 | Token not authorized | Ask admin to grant access |
| `no session ID found` | Missing `Mcp-Session-Id` header | Run initialize first, save the header |
| `isError: true` + RBAC msg | Tool lacks permission for that resource | Expected — use allowed tools |
| Connection refused | Network can't reach gateway | Check firewall/proxy for port 443 |
