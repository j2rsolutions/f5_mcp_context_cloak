# Test Plan

## 1. Deployment Validation

### 1.1 Kubernetes Resources
- [ ] Namespace `context-cloak` exists
- [ ] Postgres pod is Running and Ready
- [ ] MCP server pod(s) are Running and Ready
- [ ] Postgres service resolves from MCP server pod
- [ ] Seed data is loaded (check with `psql` exec into Postgres pod)

```bash
kubectl get pods -n context-cloak
kubectl exec -n context-cloak deploy/postgres -- psql -U mcpuser -d context_cloak -c "SELECT count(*) FROM customers;"
```

### 1.2 BIG-IP Configuration
- [ ] MCP virtual server is active (green) in TMOS
- [ ] Inference virtual server is active (green) in TMOS
- [ ] MCP pool has healthy members
- [ ] vLLM pool has healthy members
- [ ] iRules are attached to correct virtual servers
- [ ] HTTP, JSON, and SSE profiles are attached to MCP VS
- [ ] HTTP and JSON profiles are attached to Inference VS

```bash
tmsh show ltm virtual mcp_vs
tmsh show ltm virtual vllm_inference_vs
tmsh show ltm pool mcp_server_pool members
tmsh show ltm pool vllm_pool members
```

## 2. MCP Routing Validation

### 2.1 MCP Initialize
Send an MCP initialize request through BIG-IP and verify a response with `Mcp-Session-Id` is returned.

```bash
curl -sk -X POST https://10.0.10.100/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "test-client", "version": "1.0"}
    }
  }' \
  -D - 2>&1 | grep -i mcp-session-id
```

**Expected:** Response includes `Mcp-Session-Id` header with format `poolname,ip:port,original_session_id`.

### 2.2 MCP Tool Listing
```bash
SESSION_ID="<value from 2.1>"

curl -sk -X POST https://10.0.10.100/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list"
  }'
```

**Expected:** JSON response listing `get_customer_by_name`, `get_customer_financial_summary`, `get_customer_ssn`.

### 2.3 MCP Tool Call
```bash
curl -sk -X POST https://10.0.10.100/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "get_customer_by_name",
      "arguments": {"name": "John Doe"}
    }
  }'
```

**Expected:** JSON response containing customer record with name, SSN, DOB, address, etc.

## 3. Session Persistence Validation

### 3.1 Sticky Routing
1. Send an initialize request and note the `Mcp-Session-Id` (which encodes pool member)
2. Send 10 subsequent requests using the same `Mcp-Session-Id`
3. On the MCP server side, verify all requests were handled by the same pod

```bash
# Run from MCP server pod — check access logs
kubectl logs -n context-cloak deploy/mcp-server --tail=20
```

**Expected:** All requests from the same session land on the same pod.

### 3.2 Multiple Concurrent Sessions
1. Open two terminals, each establishing a separate MCP session
2. Verify each session is independently pinned (may be same or different pool members)
3. Verify no cross-contamination of session state

## 4. Anonymization Validation

### 4.1 Outbound PII Removal
Send a chat completion request through the Inference VS that contains known PII values:

```bash
curl -sk -X POST https://10.0.10.101/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: test-anon-001" \
  -d '{
    "model": "default",
    "messages": [
      {"role": "system", "content": "You are a financial analyst."},
      {"role": "user", "content": "Customer: John Doe, SSN: 078-05-1120, Account: 4532-1189-0042, Balance: $45,230.18. Generate a summary."}
    ]
  }'
```

**Verification:** Capture the request as seen by vLLM (e.g., via vLLM request logs or a tcpdump on the server VLAN). Confirm that:
- [ ] `078-05-1120` is replaced with `<<SSN:...:...>>`
- [ ] `4532-1189-0042` is replaced with `<<ACCT:...:...>>`
- [ ] `John Doe` is replaced with `<<NAME:...:...>>`
- [ ] `$45,230.18` is replaced with `<<BAL:...:...>>`

### 4.2 Subtable Verification
While a request is in-flight (or within TTL), verify the BIG-IP subtable contains mappings:

```bash
# On BIG-IP CLI
tmsh run util bash -c "tmsh show ltm data-group internal"
# Or use iRule logging to confirm table writes
```

## 5. Reverse Substitution Validation

### 5.1 Placeholder Restoration
Using the same request from 4.1, verify the response returned to the client contains:
- [ ] Original SSN `078-05-1120` (not the placeholder)
- [ ] Original account number `4532-1189-0042`
- [ ] Original name `John Doe`
- [ ] Original balance `$45,230.18`

### 5.2 Prompt Engineering Verification
Send a prompt via the Inference VS that explicitly instructs the model to preserve placeholders:

```bash
curl -sk -X POST https://10.0.10.101/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [
      {"role": "system", "content": "IMPORTANT: Any value enclosed in << >> is a data reference token. You MUST reproduce these tokens exactly as-is in your output. Do not modify, decode, or omit them."},
      {"role": "user", "content": "Write a report for <<NAME:test:001>> with SSN <<SSN:test:002>>. Their checking account <<ACCT:test:003>> has balance <<BAL:test:004>>."}
    ]
  }'
```

**Expected:** Model output includes placeholders verbatim, which BIG-IP then restores.

## 6. Failure Scenarios

### 6.1 MCP Server Unavailable
- Take down MCP server pods
- Send MCP request through BIG-IP
- **Expected:** BIG-IP returns 503 (pool has no available members)

### 6.2 Stale Session ID
- Send a request with an `Mcp-Session-Id` that references a pool member that no longer exists
- **Expected:** BIG-IP returns 404 or resets to load-balanced selection

### 6.3 Subtable TTL Expiry
- Send a request through the Inference VS
- Wait for subtable TTL to expire
- Verify the response still arrives (graceful degradation — placeholders may not be restored)

### 6.4 Oversized Payload
- Send a request with a JSON body exceeding the JSON profile's `maximum-bytes`
- **Expected:** The JSON profile may not parse the payload. Verify behavior (passthrough vs. reject) and document.

### 6.5 vLLM Unavailable
- Take down vLLM pool members
- Send inference request
- **Expected:** BIG-IP returns 503; no subtable entries are orphaned

## 7. End-to-End Integration

### 7.1 Full Workflow via Open WebUI
1. Configure Open WebUI to use the MCP server (via BIG-IP MCP VIP)
2. Configure Open WebUI to use vLLM (via BIG-IP Inference VIP)
3. Ask: "Generate a financial report for John Doe"
4. Verify:
   - [ ] MCP tools were called (check MCP server logs)
   - [ ] BIG-IP anonymized the prompt (check iRule logs)
   - [ ] vLLM never saw real PII (check vLLM logs)
   - [ ] Response to user contains real data (check Open WebUI)

### 7.2 Audit Trail
- Verify MCP server audit log entries exist for tool calls
- Verify BIG-IP iRule logs show anonymization/restoration events
