#!/usr/bin/env bash
# =============================================================================
# Context Cloak — curl examples for testing MCP and inference endpoints
# =============================================================================
#
# Usage:
#   Update the VIP addresses below to match your environment, then run
#   individual sections or the whole script.
#
# Prerequisites:
#   - BIG-IP configured with MCP and Inference virtual servers
#   - MCP server deployed and healthy
#   - vLLM endpoint deployed and healthy
# =============================================================================

set -euo pipefail

# --- Configuration ---
MCP_VIP="https://10.0.10.100"        # TODO: Update to your MCP VS VIP
INFERENCE_VIP="https://10.0.10.101"  # TODO: Update to your Inference VS VIP
CURL_OPTS="-sk"                       # -s silent, -k skip TLS verification (lab only)

echo "=== 1. MCP: Initialize session ==="
INIT_RESPONSE=$(curl $CURL_OPTS -X POST "${MCP_VIP}/mcp" \
  -H "Content-Type: application/json" \
  -D /dev/stderr \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "curl-test", "version": "1.0"}
    }
  }' 2>&1)

echo "$INIT_RESPONSE"
echo ""

# Extract Mcp-Session-Id from response headers
SESSION_ID=$(echo "$INIT_RESPONSE" | grep -i "mcp-session-id" | head -1 | awk '{print $2}' | tr -d '\r')
echo "Session ID: ${SESSION_ID:-NOT FOUND}"
echo ""


echo "=== 2. MCP: List available tools ==="
curl $CURL_OPTS -X POST "${MCP_VIP}/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list"
  }' | python3 -m json.tool 2>/dev/null || true
echo ""


echo "=== 3. MCP: Get customer by name ==="
curl $CURL_OPTS -X POST "${MCP_VIP}/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "get_customer_by_name",
      "arguments": {"name": "John Doe"}
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""


echo "=== 4. MCP: Get financial summary ==="
curl $CURL_OPTS -X POST "${MCP_VIP}/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "get_customer_financial_summary",
      "arguments": {"customer_name": "John Doe"}
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""


echo "=== 5. MCP: Get customer SSN ==="
curl $CURL_OPTS -X POST "${MCP_VIP}/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": {
      "name": "get_customer_ssn",
      "arguments": {"customer_name": "John Doe"}
    }
  }' | python3 -m json.tool 2>/dev/null || true
echo ""


echo "=== 6. Inference: Chat completion (with PII — tests anonymization) ==="
echo "NOTE: The BIG-IP anonymization iRule should replace PII with placeholders"
echo "      before this reaches vLLM. Check vLLM logs to verify."
echo ""
curl $CURL_OPTS -X POST "${INFERENCE_VIP}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: test-$(date +%s)" \
  -H "X-Context-Cloak-Names: John Doe" \
  -d '{
    "model": "default",
    "messages": [
      {
        "role": "system",
        "content": "You are a financial analyst. Any value in <<>> brackets is a data token. Reproduce all tokens exactly as-is in your output. Do not modify or omit them."
      },
      {
        "role": "user",
        "content": "Generate a brief report for customer John Doe, SSN: 078-05-1120. Checking account 4532-1189-0042 balance: $45,230.18. Savings account 4532-1189-0043 balance: $128,750.00. Email: john.doe@example.com. Phone: 217-555-0142."
      }
    ],
    "temperature": 0.3,
    "max_tokens": 500
  }' | python3 -m json.tool 2>/dev/null || true
echo ""


echo "=== 7. Inference: Pre-anonymized prompt (test placeholder passthrough) ==="
echo "NOTE: This sends already-anonymized data to verify the model preserves tokens"
echo ""
curl $CURL_OPTS -X POST "${INFERENCE_VIP}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [
      {
        "role": "system",
        "content": "You are a financial analyst. CRITICAL: Any value in <<>> brackets is a data reference token. You MUST reproduce these tokens EXACTLY as-is. Never modify them."
      },
      {
        "role": "user",
        "content": "Summarize the financial position of <<NAME:test99:001>>. SSN: <<SSN:test99:002>>. Accounts: Checking <<ACCT:test99:003>> with <<BAL:test99:004>>, Savings <<ACCT:test99:005>> with <<BAL:test99:006>>."
      }
    ],
    "temperature": 0.1,
    "max_tokens": 300
  }' | python3 -m json.tool 2>/dev/null || true
echo ""

echo "=== Done ==="
