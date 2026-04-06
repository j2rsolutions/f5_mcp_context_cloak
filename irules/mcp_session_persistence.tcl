# =============================================================================
# iRule: mcp_session_persistence
# Virtual Server: MCP VS
# Purpose:
#   1. MCP session affinity (Mcp-Session-Id enrichment + pool pinning)
#   2. Populate cloaking table by extracting PII from MCP response body
#      Response passes through UNMODIFIED -- real data goes to client
#      The HTTP profile "rechunk" setting de-chunks SSE responses so
#      HTTP::collect works on streaming MCP responses.
# =============================================================================

when RULE_INIT {
    set static::cloak_ttl 3600
    set static::cloak_prefix "cloak_"
    set static::fake_firsts [list Alice Maria David Sarah James Emily Michael Lisa Robert Jennifer]
    set static::fake_lasts  [list Johnson Garcia Wilson Thompson Anderson Martinez Brown Davis Taylor Moore]
}


when HTTP_REQUEST {
    set is_req_to_sse_endpoint 0
    set collect_response 0
    set req_path [HTTP::path]

    if { [HTTP::header exists "X-Cloak-Session"] } {
        set cloak_session_id [HTTP::header "X-Cloak-Session"]
    } else {
        set cloak_session_id [IP::client_addr]
    }

    if { $req_path eq "/sse" } {
        set is_req_to_sse_endpoint 1
        if { [HTTP::header exists "Accept"] && [HTTP::header "Accept"] contains "text/event-stream" } {
            set sse_persistence_key "[IP::client_addr]:[HTTP::uri]"
            persist uie $sse_persistence_key
        }
        return
    }

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
                set pmbr_info [URI::decode [string range $query 10 end]]
                set pmbr_parts [split $pmbr_info ","]
                if { [llength $pmbr_parts] == 2 } {
                    set pmbr_tuple [split [lindex $pmbr_parts 1] ":"]
                    if { [llength $pmbr_tuple] == 2 } {
                        pool [lindex $pmbr_parts 0] member [lindex $pmbr_parts 1]
                        set f5_sess_found 1
                    } else {
                        HTTP::respond 404 noserver
                        return
                    }
                } else {
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
        }
        return
    }

    if { $req_path eq "/mcp" } {
        set collect_response 1
        if { [HTTP::header exists "Mcp-Session-Id"] } {
            set header_value [HTTP::header "Mcp-Session-Id"]
            set header_parts [split $header_value ","]
            if { [llength $header_parts] == 3 } {
                set pool_name [lindex $header_parts 0]
                set member_addr [lindex $header_parts 1]
                set original_session_id [lindex $header_parts 2]
                set pmbr_tuple [split $member_addr ":"]
                if { [llength $pmbr_tuple] == 2 } {
                    pool $pool_name member $member_addr
                    HTTP::header replace "Mcp-Session-Id" $original_session_id
                    log local0. "MCP-Persist: pinned to $pool_name member $member_addr"
                } else {
                    HTTP::respond 404 noserver
                    return
                }
            } elseif { [llength $header_parts] != 1 } {
                HTTP::respond 404 noserver
                return
            }
        }
    }
}


when HTTP_RESPONSE {
    if { [HTTP::header exists "Mcp-Session-Id"] } {
        set pool_name [LB::server pool]
        set member_addr "[IP::server_addr]:[LB::server port]"
        set original_session_id [HTTP::header "Mcp-Session-Id"]
        set enriched_header "${pool_name},${member_addr},${original_session_id}"
        HTTP::header replace "Mcp-Session-Id" $enriched_header
    }

    if { $is_req_to_sse_endpoint } {
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
            if { [regexp {(data:\s*/messages)(\?)(.*)} $sse_data -> prefix qmark rest] } {
                set new_payload "${prefix}${qmark}f5Session=${f5_session_value}&${rest}"
                HTTP::payload replace 0 [string length $sse_data] $new_payload
            }
        }
    }

    if { $collect_response } {
        if { [HTTP::header exists "Content-Length"] && [HTTP::header "Content-Length"] > 0 } {
            HTTP::collect [HTTP::header "Content-Length"]
        } else {
            HTTP::collect 1048576
        }
    }
}


# =============================================================================
# HTTP_RESPONSE_DATA -- Cloaking Table Builder
# Extracts PII from MCP response body, generates fakes, stores mappings.
# Response passes through UNMODIFIED.
# =============================================================================
when HTTP_RESPONSE_DATA {
    if { !$collect_response } { return }

    set payload [HTTP::payload]
    set table_name "${static::cloak_prefix}${cloak_session_id}"

    # --- NAMES ---
    set name_matches [regexp -all -inline {(?:full_name|customer_name)[^A-Za-z]*([A-Z][a-z]+ [A-Z][a-z]+)} $payload]
    for {set i 1} {$i < [llength $name_matches]} {incr i 2} {
        set real_val [lindex $name_matches $i]
        if { [table lookup -subtable $table_name "r2f_${real_val}"] ne "" } { continue }
        if { [table lookup -subtable $table_name "f2r_${real_val}"] ne "" } { continue }
        set hash 0
        foreach c [split $real_val ""] { incr hash [scan $c %c] }
        set fi [expr {$hash % 10}]
        set li [expr {($hash / 10) % 10}]
        set fake_val "[lindex $static::fake_firsts $fi] [lindex $static::fake_lasts $li]"
        if { $fake_val eq $real_val } { set fi [expr {($fi + 1) % 10}]; set fake_val "[lindex $static::fake_firsts $fi] [lindex $static::fake_lasts $li]" }
        set collision [table lookup -subtable $table_name "f2r_${fake_val}"]
        if { $collision ne "" && $collision ne $real_val } { set fi [expr {($fi + 1) % 10}]; set fake_val "[lindex $static::fake_firsts $fi] [lindex $static::fake_lasts $li]" }

        table set -subtable $table_name "r2f_${real_val}" $fake_val $static::cloak_ttl
        table set -subtable $table_name "f2r_${fake_val}" $real_val $static::cloak_ttl
        set fl [table lookup -subtable $table_name "_fake_list"]
        if { $fl eq "" } { table set -subtable $table_name "_fake_list" $fake_val $static::cloak_ttl
        } else { table set -subtable $table_name "_fake_list" "${fl}|${fake_val}" $static::cloak_ttl }
        set rl [table lookup -subtable $table_name "_real_list"]
        if { $rl eq "" } { table set -subtable $table_name "_real_list" $real_val $static::cloak_ttl
        } else { table set -subtable $table_name "_real_list" "${rl}|${real_val}" $static::cloak_ttl }
        log local0. "CloakTable: name '$real_val' -> '$fake_val' (session=$cloak_session_id)"
    }

    # --- SSN ---
    set ssn_matches [regexp -all -inline {ssn[^0-9]*([0-9]{3}-[0-9]{2}-[0-9]{4})} $payload]
    for {set i 1} {$i < [llength $ssn_matches]} {incr i 2} {
        set real_val [lindex $ssn_matches $i]
        if { [table lookup -subtable $table_name "r2f_${real_val}"] ne "" } { continue }
        set fake_val ""
        foreach c [split $real_val ""] {
            if { [string is digit $c] } { append fake_val [expr {($c + 5) % 10}] } else { append fake_val $c }
        }
        table set -subtable $table_name "r2f_${real_val}" $fake_val $static::cloak_ttl
        table set -subtable $table_name "f2r_${fake_val}" $real_val $static::cloak_ttl
        set fl [table lookup -subtable $table_name "_fake_list"]
        if { $fl eq "" } { table set -subtable $table_name "_fake_list" $fake_val $static::cloak_ttl
        } else { table set -subtable $table_name "_fake_list" "${fl}|${fake_val}" $static::cloak_ttl }
        set rl [table lookup -subtable $table_name "_real_list"]
        if { $rl eq "" } { table set -subtable $table_name "_real_list" $real_val $static::cloak_ttl
        } else { table set -subtable $table_name "_real_list" "${rl}|${real_val}" $static::cloak_ttl }
        log local0. "CloakTable: SSN [string range $real_val 0 2]*** (session=$cloak_session_id)"
    }

    # --- PHONE ---
    set phone_matches [regexp -all -inline {phone[^0-9(]*(\(?[0-9]{3}\)?[\s.\-][0-9]{3}[\s.\-][0-9]{4})} $payload]
    for {set i 1} {$i < [llength $phone_matches]} {incr i 2} {
        set real_val [lindex $phone_matches $i]
        if { [table lookup -subtable $table_name "r2f_${real_val}"] ne "" } { continue }
        set fake_val ""
        foreach c [split $real_val ""] {
            if { [string is digit $c] } { append fake_val [expr {($c + 4) % 10}] } else { append fake_val $c }
        }
        table set -subtable $table_name "r2f_${real_val}" $fake_val $static::cloak_ttl
        table set -subtable $table_name "f2r_${fake_val}" $real_val $static::cloak_ttl
        set fl [table lookup -subtable $table_name "_fake_list"]
        if { $fl eq "" } { table set -subtable $table_name "_fake_list" $fake_val $static::cloak_ttl
        } else { table set -subtable $table_name "_fake_list" "${fl}|${fake_val}" $static::cloak_ttl }
        set rl [table lookup -subtable $table_name "_real_list"]
        if { $rl eq "" } { table set -subtable $table_name "_real_list" $real_val $static::cloak_ttl
        } else { table set -subtable $table_name "_real_list" "${rl}|${real_val}" $static::cloak_ttl }
        log local0. "CloakTable: phone registered (session=$cloak_session_id)"
    }

    # --- EMAIL ---
    set email_matches [regexp -all -inline {email[^a-zA-Z0-9]*([a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})} $payload]
    for {set i 1} {$i < [llength $email_matches]} {incr i 2} {
        set real_val [lindex $email_matches $i]
        if { [table lookup -subtable $table_name "r2f_${real_val}"] ne "" } { continue }
        set hash 0
        foreach c [split $real_val ""] { incr hash [scan $c %c] }
        set fi [expr {$hash % 10}]
        set li [expr {($hash / 10) % 10}]
        set first [string tolower [lindex $static::fake_firsts $fi]]
        set last  [string tolower [lindex $static::fake_lasts $li]]
        set fake_val "${first}.${last}@example.net"
        table set -subtable $table_name "r2f_${real_val}" $fake_val $static::cloak_ttl
        table set -subtable $table_name "f2r_${fake_val}" $real_val $static::cloak_ttl
        set fl [table lookup -subtable $table_name "_fake_list"]
        if { $fl eq "" } { table set -subtable $table_name "_fake_list" $fake_val $static::cloak_ttl
        } else { table set -subtable $table_name "_fake_list" "${fl}|${fake_val}" $static::cloak_ttl }
        set rl [table lookup -subtable $table_name "_real_list"]
        if { $rl eq "" } { table set -subtable $table_name "_real_list" $real_val $static::cloak_ttl
        } else { table set -subtable $table_name "_real_list" "${rl}|${real_val}" $static::cloak_ttl }
        log local0. "CloakTable: email registered (session=$cloak_session_id)"
    }

    # --- ACCOUNT NUMBER ---
    set acct_matches [regexp -all -inline {account_number[^0-9]*([0-9]{4}-[0-9]{4}-[0-9]{4})} $payload]
    for {set i 1} {$i < [llength $acct_matches]} {incr i 2} {
        set real_val [lindex $acct_matches $i]
        if { [table lookup -subtable $table_name "r2f_${real_val}"] ne "" } { continue }
        set fake_val ""
        foreach c [split $real_val ""] {
            if { [string is digit $c] } { append fake_val [expr {($c + 3) % 10}] } else { append fake_val $c }
        }
        table set -subtable $table_name "r2f_${real_val}" $fake_val $static::cloak_ttl
        table set -subtable $table_name "f2r_${fake_val}" $real_val $static::cloak_ttl
        set fl [table lookup -subtable $table_name "_fake_list"]
        if { $fl eq "" } { table set -subtable $table_name "_fake_list" $fake_val $static::cloak_ttl
        } else { table set -subtable $table_name "_fake_list" "${fl}|${fake_val}" $static::cloak_ttl }
        set rl [table lookup -subtable $table_name "_real_list"]
        if { $rl eq "" } { table set -subtable $table_name "_real_list" $real_val $static::cloak_ttl
        } else { table set -subtable $table_name "_real_list" "${rl}|${real_val}" $static::cloak_ttl }
        log local0. "CloakTable: account [string range $real_val 0 3]*** (session=$cloak_session_id)"
    }

    log local0. "CloakTable: MCP response scanned (session=$cloak_session_id)"
}
