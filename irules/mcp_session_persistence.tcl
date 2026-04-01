# =============================================================================
# iRule: mcp_session_persistence
# Virtual Server: MCP VS
# Profiles Required: HTTP, JSON (optional), SSE (optional)
# Purpose: Maintain MCP session affinity by encoding pool member info
#          into the Mcp-Session-Id header (Streamable HTTP transport)
#          and f5Session query parameter (legacy SSE transport).
#
# Based on patterns from:
#   https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-2/344421
#
# Supports:
#   - Streamable HTTP (/mcp endpoint) — Mcp-Session-Id header enrichment
#   - Legacy SSE (/sse + /messages endpoints) — f5Session query injection
#   - UIE persistence for long-lived SSE connections
# =============================================================================

when HTTP_REQUEST {
    # Track whether this is an SSE endpoint request (used in HTTP_RESPONSE)
    set is_req_to_sse_endpoint 0

    set req_path [HTTP::path]

    # -------------------------------------------------------------------------
    # Legacy SSE transport: GET /sse
    # The client opens an SSE stream; we'll inject persistence info in the
    # response payload so subsequent /messages requests route to the same member.
    # -------------------------------------------------------------------------
    if { $req_path eq "/sse" } {
        set is_req_to_sse_endpoint 1

        # UIE persistence for long-lived SSE connections
        if { [HTTP::header exists "Accept"] && [HTTP::header "Accept"] contains "text/event-stream" } {
            set sse_persistence_key "[IP::client_addr]:[HTTP::uri]"
            persist uie $sse_persistence_key
        }
        return
    }

    # -------------------------------------------------------------------------
    # Legacy SSE transport: POST /messages?f5Session=pool,ip:port&sessionId=...
    # Extract f5Session, pin to that pool member, strip f5Session from query.
    # -------------------------------------------------------------------------
    if { $req_path eq "/messages" } {
        set query_string [HTTP::query]
        set f5_sess_found 0
        set new_query_string ""
        set query_separator ""

        set queries [split $query_string "&"]
        foreach query $queries {
            if { $f5_sess_found } {
                append new_query_string "${query_separator}${query}"
                set query_separator "&"
            } elseif { [string match "f5Session=*" $query] } {
                # Extract pool member info: pool_name,ip:port
                set pmbr_info [URI::decode [string range $query 10 end]]
                set pmbr_parts [split $pmbr_info ","]
                if { [llength $pmbr_parts] == 2 } {
                    set pmbr_tuple [split [lindex $pmbr_parts 1] ":"]
                    if { [llength $pmbr_tuple] == 2 } {
                        pool [lindex $pmbr_parts 0] member [lindex $pmbr_parts 1]
                        set f5_sess_found 1
                        log local0. "MCP-Persist: /messages pinned to [lindex $pmbr_parts 0] member [lindex $pmbr_parts 1]"
                    } else {
                        log local0. "MCP-Persist: /messages bad member tuple in f5Session"
                        HTTP::respond 404 noserver
                        return
                    }
                } else {
                    log local0. "MCP-Persist: /messages bad f5Session format"
                    HTTP::respond 404 noserver
                    return
                }
            } else {
                append new_query_string "${query_separator}${query}"
                set query_separator "&"
            }
        }

        if { $f5_sess_found } {
            HTTP::query $new_query_string
        } else {
            # No f5Session found — this is a request without persistence context.
            # Allow load balancing to proceed normally (first request scenario).
            log local0. "MCP-Persist: /messages without f5Session, using default LB"
        }
        return
    }

    # -------------------------------------------------------------------------
    # Streamable HTTP transport: POST /mcp
    # Mcp-Session-Id header format from client: pool_name,ip:port,original_id
    # We parse it, pin to the encoded member, and restore the original header.
    # -------------------------------------------------------------------------
    if { $req_path eq "/mcp" } {
        if { [HTTP::header exists "Mcp-Session-Id"] } {
            set header_value [HTTP::header "Mcp-Session-Id"]
            set header_parts [split $header_value ","]

            if { [llength $header_parts] == 3 } {
                # This is an enriched header from a prior response
                set pool_name [lindex $header_parts 0]
                set member_addr [lindex $header_parts 1]
                set original_session_id [lindex $header_parts 2]

                set pmbr_tuple [split $member_addr ":"]
                if { [llength $pmbr_tuple] == 2 } {
                    pool $pool_name member $member_addr
                    HTTP::header replace "Mcp-Session-Id" $original_session_id
                    log local0. "MCP-Persist: /mcp pinned to $pool_name member $member_addr (session: $original_session_id)"
                } else {
                    log local0. "MCP-Persist: /mcp bad member address in Mcp-Session-Id"
                    HTTP::respond 404 noserver
                    return
                }
            } elseif { [llength $header_parts] == 1 } {
                # First request after initialize — header is just the raw session ID.
                # Let load balancing proceed; we'll enrich the response header.
                log local0. "MCP-Persist: /mcp raw session ID, using default LB"
            } else {
                log local0. "MCP-Persist: /mcp unexpected Mcp-Session-Id format: $header_value"
                HTTP::respond 404 noserver
                return
            }
        }
        # No Mcp-Session-Id header = initialize request; let default LB handle it
    }
}

when HTTP_RESPONSE {
    # -------------------------------------------------------------------------
    # Streamable HTTP: Enrich Mcp-Session-Id with pool member info on response
    # Format: pool_name,ip:port,original_session_id
    # -------------------------------------------------------------------------
    if { [HTTP::header exists "Mcp-Session-Id"] } {
        set pool_name [LB::server pool]
        set member_addr "[IP::server_addr]:[LB::server port]"
        set original_session_id [HTTP::header "Mcp-Session-Id"]
        set enriched_header "${pool_name},${member_addr},${original_session_id}"
        HTTP::header replace "Mcp-Session-Id" $enriched_header
        log local0. "MCP-Persist: Response enriched Mcp-Session-Id: $enriched_header"
    }

    # -------------------------------------------------------------------------
    # Legacy SSE: Inject f5Session into the SSE endpoint event payload
    # The server sends: event: endpoint\ndata: /messages?sessionId=xxx
    # We rewrite to:    event: endpoint\ndata: /messages?f5Session=pool,ip:port&sessionId=xxx
    # -------------------------------------------------------------------------
    if { $is_req_to_sse_endpoint } {
        # Reinforce UIE persistence on SSE response
        if { [HTTP::header exists "Content-Type"] && [HTTP::header "Content-Type"] eq "text/event-stream" } {
            if { [info exists sse_persistence_key] } {
                persist add uie $sse_persistence_key
            }
        }

        set sse_data [HTTP::payload]
        if { [string length $sse_data] > 0 } {
            set pool_name [LB::server pool]
            set member_addr "[IP::server_addr]:[LB::server port]"
            set f5_session_value [URI::encode "${pool_name},${member_addr}"]

            # Find the data: line containing the endpoint URL and inject f5Session
            # Expected format: "data: /messages?sessionId=..."
            if { [regexp {(data:\s*/messages)(\?)(.*)} $sse_data -> prefix qmark rest] } {
                set new_payload "${prefix}${qmark}f5Session=${f5_session_value}&${rest}"
                HTTP::payload replace 0 [string length $sse_data] $new_payload
                log local0. "MCP-Persist: SSE endpoint enriched with f5Session"
            }
        }
    }
}
