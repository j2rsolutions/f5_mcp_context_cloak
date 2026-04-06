# =============================================================================
# iRule: vllm_anonymization (cloak + de-cloak)
# Virtual Server: Inference (vLLM) VS
# Profiles Required: HTTP
# Purpose:
#   REQUEST:  Cloak PII in the prompt (real -> fake) using the cloaking table
#             populated by the MCP VS iRule.
#   RESPONSE: De-cloak PII in the LLM response (fake -> real) so the user
#             sees the original values.
#
# The cloaking table is a BIG-IP subtable keyed by session ID, containing:
#   r2f_<real> -> <fake>   (used on request: real->fake)
#   f2r_<fake> -> <real>   (used on response: fake->real)
#   _real_list -> pipe-delimited list of all real values (for request cloaking)
#   _fake_list -> pipe-delimited list of all fake values (for response de-cloaking)
# =============================================================================

when RULE_INIT {
    set static::cloak_prefix "cloak_"
}


when HTTP_REQUEST {
    set do_cloak 0
    set req_path [HTTP::path]

    if { [HTTP::header exists "X-Cloak-Session"] } {
        set cloak_session_id [HTTP::header "X-Cloak-Session"]
    } else {
        set cloak_session_id [IP::client_addr]
    }

    if { $req_path starts_with "/v1/chat/completions" ||
         $req_path starts_with "/v1/completions" } {
        set do_cloak 1
        if { [HTTP::header exists "Content-Length"] && [HTTP::header "Content-Length"] > 0 } {
            HTTP::collect [HTTP::header "Content-Length"]
        }
    }
}


# =============================================================================
# REQUEST CLOAKING -- replace real PII with fakes in the prompt to vLLM
# =============================================================================
when HTTP_REQUEST_DATA {
    if { !$do_cloak } { return }

    set payload [HTTP::payload]
    set table_name "${static::cloak_prefix}${cloak_session_id}"

    set real_list_raw [table lookup -subtable $table_name "_real_list"]

    if { $real_list_raw eq "" } {
        # Build the real_list from r2f_ entries by scanning the fake_list
        set fake_list_raw [table lookup -subtable $table_name "_fake_list"]
        if { $fake_list_raw eq "" } {
            log local0. "Cloak: no cloaking table for session=$cloak_session_id, passing through"
            HTTP::release
            return
        }
        # Build real_list from fake_list lookups
        set fake_entries [split $fake_list_raw "|"]
        set real_list ""
        foreach fake_val $fake_entries {
            set real_val [table lookup -subtable $table_name "f2r_${fake_val}"]
            if { $real_val ne "" } {
                if { $real_list eq "" } {
                    set real_list $real_val
                } else {
                    append real_list "|${real_val}"
                }
            }
        }
        if { $real_list ne "" } {
            table set -subtable $table_name "_real_list" $real_list $static::cloak_ttl
        }
        set real_list_raw $real_list
    }

    if { $real_list_raw eq "" } {
        HTTP::release
        return
    }

    set real_entries [split $real_list_raw "|"]

    # Sort by length descending (longest first to avoid partial matches)
    set sorted_reals [list]
    foreach entry $real_entries {
        if { $entry eq "" } { continue }
        set len [string length $entry]
        set inserted 0
        for {set j 0} {$j < [llength $sorted_reals]} {incr j} {
            if { $len > [string length [lindex $sorted_reals $j]] } {
                set sorted_reals [linsert $sorted_reals $j $entry]
                set inserted 1
                break
            }
        }
        if { !$inserted } {
            lappend sorted_reals $entry
        }
    }

    # Build string map: real -> fake
    set map_pairs [list]
    set pair_count 0
    foreach real_val $sorted_reals {
        set fake_val [table lookup -subtable $table_name "r2f_${real_val}"]
        if { $fake_val ne "" } {
            lappend map_pairs $real_val $fake_val
            incr pair_count
        }
    }

    if { $pair_count > 0 } {
        set payload [string map $map_pairs $payload]
        HTTP::payload replace 0 [HTTP::payload length] $payload
        log local0. "Cloak: request cloaked ($pair_count PII values replaced, session=$cloak_session_id)"
    }

    HTTP::release
}


when HTTP_RESPONSE {
    if { !$do_cloak } { return }

    if { [HTTP::header exists "Content-Length"] && [HTTP::header "Content-Length"] > 0 } {
        HTTP::collect [HTTP::header "Content-Length"]
    }
}


# =============================================================================
# RESPONSE DE-CLOAKING -- replace fake PII with reals in the LLM response
# =============================================================================
when HTTP_RESPONSE_DATA {
    if { !$do_cloak } { return }

    set payload [HTTP::payload]
    set table_name "${static::cloak_prefix}${cloak_session_id}"

    set fake_list_raw [table lookup -subtable $table_name "_fake_list"]
    if { $fake_list_raw eq "" } {
        return
    }

    set fake_entries [split $fake_list_raw "|"]

    # Sort by length descending
    set sorted_fakes [list]
    foreach entry $fake_entries {
        if { $entry eq "" } { continue }
        set len [string length $entry]
        set inserted 0
        for {set j 0} {$j < [llength $sorted_fakes]} {incr j} {
            if { $len > [string length [lindex $sorted_fakes $j]] } {
                set sorted_fakes [linsert $sorted_fakes $j $entry]
                set inserted 1
                break
            }
        }
        if { !$inserted } {
            lappend sorted_fakes $entry
        }
    }

    # Build string map: fake -> real
    set map_pairs [list]
    set pair_count 0
    foreach fake_val $sorted_fakes {
        set real_val [table lookup -subtable $table_name "f2r_${fake_val}"]
        if { $real_val ne "" } {
            lappend map_pairs $fake_val $real_val
            incr pair_count
        }
    }

    if { $pair_count > 0 } {
        set payload [string map $map_pairs $payload]
        HTTP::payload replace 0 [HTTP::payload length] $payload
        log local0. "Decloak: response de-cloaked ($pair_count mappings applied, session=$cloak_session_id)"
    }
}
