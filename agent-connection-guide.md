# Connecting an External AI Agent to OpenShift MCP Server

## Overview

Your organization has deployed a secure MCP (Model Context Protocol) server on OpenShift, accessible through an MCP Gateway. This guide shows how to configure your AI agent to connect and use OpenShift tools (list namespaces, get pods, describe resources, etc.) securely.

---

## Prerequisites

- Your admin has shared the **MCP Gateway URL** (e.g., `https://mcp-gateway.apps.example.com`)
- You have a valid **ServiceAccount token** or OIDC JWT issued by the cluster's identity provider
- Your agent supports MCP protocol version `2025-03-26` (Streamable HTTP transport)

---

## Step 1: Obtain a Bearer Token

Ask your cluster admin for a ServiceAccount token scoped to the MCP server namespace:

```bash
# Admin runs this and shares the token with you
oc create token <your-service-account> -n ocp-mcp-server --duration=3600s
```

Or, if your organization uses OIDC (e.g., Keycloak, Azure AD), obtain a JWT from your identity provider that the cluster's AuthPolicy trusts.

---

## Step 2: Initialize an MCP Session

Send an `initialize` request to the gateway's `/mcp` endpoint:

```bash
curl -sk -D - -X POST "https://<MCP_GATEWAY_URL>/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <YOUR_TOKEN>" \
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

**Save the `Mcp-Session-Id` header from the response.** You need it for all subsequent requests.

---

## Step 3: Discover Available Tools

```bash
curl -sk -X POST "https://<MCP_GATEWAY_URL>/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <YOUR_TOKEN>" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
    "params": {}
  }'
```

This returns all available tools with their names, descriptions, and input schemas.

---

## Step 4: Call a Tool

Example — list all namespaces:

```bash
curl -sk -X POST "https://<MCP_GATEWAY_URL>/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <YOUR_TOKEN>" \
  -H "Mcp-Session-Id: <SESSION_ID>" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "openshift_namespaces_list",
      "arguments": {}
    }
  }'
```

---

## Agent SDK Integration

### Python (using `mcp` SDK)

```python
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def connect():
    url = "https://<MCP_GATEWAY_URL>/mcp"
    headers = {"Authorization": "Bearer <YOUR_TOKEN>"}

    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # List tools
            tools = await session.list_tools()
            print(f"Available tools: {[t.name for t in tools.tools]}")

            # Call a tool
            result = await session.call_tool("openshift_namespaces_list", arguments={})
            print(result.content[0].text)
```

### TypeScript/JavaScript

```typescript
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const transport = new StreamableHTTPClientTransport(
  new URL("https://<MCP_GATEWAY_URL>/mcp"),
  { requestInit: { headers: { "Authorization": "Bearer <YOUR_TOKEN>" } } }
);

const client = new Client({ name: "my-agent", version: "1.0" });
await client.connect(transport);

const tools = await client.listTools();
console.log("Tools:", tools.tools.map(t => t.name));

const result = await client.callTool({ name: "openshift_namespaces_list", arguments: {} });
console.log(result.content[0].text);
```

---

## Available Tools (Examples)

| Tool Name | Description |
|-----------|-------------|
| `openshift_namespaces_list` | List all namespaces |
| `openshift_pods_list` | List pods in a namespace |
| `openshift_pods_get` | Get details of a specific pod |
| `openshift_deployments_list` | List deployments |
| `openshift_services_list` | List services |
| `openshift_routes_list` | List routes |
| `openshift_events_list` | List events |
| `openshift_nodes_list` | List cluster nodes |

Use `tools/list` (Step 3) to get the complete, current list with full input schemas.

---

## Security Notes

- All traffic is encrypted via TLS (HTTPS)
- The gateway enforces JWT authentication — invalid/expired tokens are rejected
- The MCP server operates in **read-only mode** — no write operations are possible
- Access to sensitive resources (Secrets, ConfigMaps, RBAC objects) is explicitly denied
- Token expiry is enforced — obtain fresh tokens before expiry

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| HTTP 401 | Invalid or expired token | Get a new token from your admin |
| HTTP 403 | Token valid but not authorized | Admin needs to update AuthPolicy to trust your issuer |
| `"isError": true` with RBAC message | Tool tried an operation the SA can't do | Expected for restricted resources — use allowed tools |
| Connection timeout | Network/firewall blocking | Ensure your agent can reach the gateway URL on port 443 |
| No `Mcp-Session-Id` in response | Initialize failed | Check token validity and gateway health |

---

## Quick Test (Copy-Paste)

Replace `MCP_URL` and `TOKEN`, then run all three:

```bash
MCP_URL="https://<MCP_GATEWAY_URL>/mcp"
TOKEN="<YOUR_TOKEN>"

# 1. Initialize
SESSION_ID=$(curl -sk -D - -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')
echo "Session: $SESSION_ID"

# 2. List tools
curl -sk -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# 3. Call a tool
echo ""
curl -sk -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openshift_namespaces_list","arguments":{}}}'
```
