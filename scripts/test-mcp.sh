#!/usr/bin/env bash
# ============================================================================
# test-mcp.sh — Exercise the MCP server and display results
#
# Usage:
#   ./scripts/test-mcp.sh                      # auto port-forward to k8s
#   ./scripts/test-mcp.sh http://localhost:8080 # direct URL
#
# Requires: curl, jq
# ============================================================================

BLUE='\033[1;34m'
GREEN='\033[1;32m'
CYAN='\033[0;36m'
NC='\033[0m'

MCP_URL="${1:-}"
PF_PID=""
KUBECONFIG="${KUBECONFIG:-kubernetes/config/genai.yaml}"
T=$(mktemp)
SID=""

cleanup() {
    [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
    rm -f "$T"
}
trap cleanup EXIT

# --- Connect ------------------------------------------------------------------
if [ -z "$MCP_URL" ]; then
    pkill -f "port-forward.*9080" 2>/dev/null || true
    sleep 1
    echo -e "${BLUE}Port-forwarding to mcp-server...${NC}"
    kubectl --kubeconfig="$KUBECONFIG" port-forward -n context-cloak svc/mcp-server 9080:8080 &>/dev/null &
    PF_PID=$!
    sleep 3
    MCP_URL="http://localhost:9080"
fi

# --- Helper -------------------------------------------------------------------
call_mcp() {
    if [ -n "$SID" ]; then
        curl -si --max-time 8 -X POST "$MCP_URL/mcp" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" \
            -H "Mcp-Session-Id: $SID" \
            -d "$1" > "$T" 2>/dev/null || true
    else
        curl -si --max-time 8 -X POST "$MCP_URL/mcp" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/event-stream" \
            -d "$1" > "$T" 2>/dev/null || true
    fi

    # Capture session ID
    local new_sid
    new_sid=$(grep -i "mcp-session-id" "$T" 2>/dev/null | tr -d '\r' | awk -F': *' '{print $2}' | head -1)
    [ -n "$new_sid" ] && SID="$new_sid"
}

# Get JSON-RPC data payload
get_data()  { grep "^data: " "$T" | sed 's/^data: //'; }
# Get tool result text as parsed JSON
get_tool()  { get_data | jq -r '.result.content[0].text // empty' 2>/dev/null | jq '.' 2>/dev/null; }

# ==============================================================================
echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Context Cloak MCP Server — Test Suite${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}\n"

# 1. Initialize
echo -e "${GREEN}1. Initialize session${NC}"
call_mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-script","version":"1.0"}}}'
get_data | jq '.result.serverInfo' 2>/dev/null
echo -e "${CYAN}   Session: $SID${NC}\n"

# 2. List tools
echo -e "${GREEN}2. Available tools${NC}"
call_mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
get_data | jq -r '.result.tools[] | "   \(.name) — \(.description[0:80])"' 2>/dev/null
echo ""

# 3. find_customer by name
echo -e "${GREEN}3. find_customer(\"John Doe\")${NC}"
call_mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find_customer","arguments":{"query":"John Doe"}}}'
get_tool
echo ""

# 4. find_customer by SSN
echo -e "${GREEN}4. find_customer(\"323-45-6789\") — SSN lookup${NC}"
call_mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"find_customer","arguments":{"query":"323-45-6789"}}}'
get_tool
echo ""

# 5. find_customer by account number
echo -e "${GREEN}5. find_customer(\"5678-2234-0011\") — account number lookup${NC}"
call_mcp '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"find_customer","arguments":{"query":"5678-2234-0011"}}}'
get_tool
echo ""

# 6. get_customer_ssn
echo -e "${GREEN}6. get_customer_ssn(\"John Doe\")${NC}"
call_mcp '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_customer_ssn","arguments":{"query":"John Doe"}}}'
get_tool
echo ""

# 7. get_accounts
echo -e "${GREEN}7. get_accounts(\"Carlos Rivera\")${NC}"
call_mcp '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_accounts","arguments":{"query":"Carlos Rivera"}}}'
get_tool
echo ""

# 8. get_transactions — the big analyst use case
echo -e "${GREEN}8. get_transactions(\"4532-1189-0042\", 30) — John Doe checking${NC}"
call_mcp '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_transactions","arguments":{"account_number":"4532-1189-0042","days":30}}}'
get_tool
echo ""

# 9. Full analyst workflow: SSN → accounts → transactions
echo -e "${GREEN}9. Analyst workflow: SSN → accounts → transactions${NC}"
echo -e "${CYAN}   a) get_accounts by SSN 219-09-9999${NC}"
call_mcp '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_accounts","arguments":{"query":"219-09-9999"}}}'
get_tool
echo ""
echo -e "${CYAN}   b) get_transactions for her checking 5678-2234-0011${NC}"
call_mcp '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_transactions","arguments":{"account_number":"5678-2234-0011","days":30}}}'
get_tool
echo ""

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Done.${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
