# =============================================================================
# iRule: vllm_anonymization
# Virtual Server: Inference (vLLM) VS
# Profiles Required: HTTP, JSON
# Purpose: Anonymize PII in outbound prompts to vLLM and restore original
#          values in responses before returning to the client.
#
# Design:
#   - REQUEST phase: Scan JSON body for PII patterns, replace with
#     deterministic placeholders, store mappings in a BIG-IP subtable.
#   - RESPONSE phase: Scan JSON body for placeholders, restore original
#     values from the subtable.
#
# Placeholder format: <<TYPE:SESSION_ID:SEQUENCE>>
#   TYPE = SSN | ACCT | NAME | BAL | DOB | PHONE | EMAIL
#   SESSION_ID = correlation ID for this request
#   SEQUENCE = zero-padded counter (001, 002, ...)
#
# Limitations:
#   - Pattern matching is regex-based and may miss non-standard formats
#   - JSON profile max payload size applies (default 64KB)
#   - Streaming (SSE) responses may split placeholders across chunks;
#     for this POC, use non-streaming inference
#   - Subtable entries have a TTL; long-running requests may lose mappings
#   - Names are only detected when explicitly provided via X-Context-Cloak-Names header
#     or listed in a static table (regex for arbitrary names is impractical)
#
# TODO: Evaluate whether JSON_REQUEST / JSON_RESPONSE events (requires JSON
#       profile) provide a better hook point than HTTP_REQUEST_DATA /
#       HTTP_RESPONSE_DATA for payload manipulation. The JSON profile parses
#       the payload into a DOM, which is great for inspection but may not
#       support full payload text replacement needed for anonymization. This
#       POC uses HTTP_REQUEST_DATA for raw text substitution.
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration — adjust these for your environment
# ---------------------------------------------------------------------------
# Subtable TTL in seconds (how long mappings survive)
# Set this longer than your expected inference round-trip time
set static::anon_ttl 300

# Subtable name prefix
set static::anon_table_prefix "anon_map_"

# Known names table — pre-populated with names the iRule should recognize.
# In production, this could be populated from an external source.
# Format: subtable "known_pii_names" with entries like "John Doe" -> "1"
# TODO: Populate this table via an iCall script or external feed
set static::names_table "known_pii_names"


when HTTP_REQUEST {
    # Generate a unique correlation/session ID for this request
    # Use X-Request-ID if provided, otherwise generate one
    if { [HTTP::header exists "X-Request-ID"] } {
        set correlation_id [HTTP::header "X-Request-ID"]
    } else {
        # Generate a short unique ID from client IP + timestamp + random
        set correlation_id "[format %x [expr {int(rand()*0xFFFFFF)}]][clock clicks -milliseconds]"
    }

    # Store for use in response phase
    set do_anonymize 0
    set req_path [HTTP::path]

    # Only process inference API calls
    if { $req_path starts_with "/v1/chat/completions" ||
         $req_path starts_with "/v1/completions" } {
        set do_anonymize 1
        # Collect the request body
        if { [HTTP::header exists "Content-Length"] && [HTTP::header "Content-Length"] > 0 } {
            HTTP::collect [HTTP::header "Content-Length"]
        }
    }
}


when HTTP_REQUEST_DATA {
    if { !$do_anonymize } { return }

    set payload [HTTP::payload]
    set sequence 0
    set table_name "${static::anon_table_prefix}${correlation_id}"
    set modified 0

    # -------------------------------------------------------------------
    # Pattern: SSN (###-##-####)
    # -------------------------------------------------------------------
    while { [regexp -indices {[0-9]{3}-[0-9]{2}-[0-9]{4}} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set original [string range $payload $start $end]
        incr sequence
        set placeholder "<<SSN:${correlation_id}:[format %03d $sequence]>>"

        # Store mapping: placeholder -> original value
        table set -subtable $table_name $placeholder $original $static::anon_ttl

        # Replace in payload
        set payload "[string range $payload 0 [expr {$start - 1}]]${placeholder}[string range $payload [expr {$end + 1}] end]"
        set modified 1
        log local0. "Anon: Replaced SSN with $placeholder"
    }

    # -------------------------------------------------------------------
    # Pattern: Account numbers (####-####-#### or ####-####-####-####)
    # Matches 12-16 digit numbers with dashes in groups of 4
    # -------------------------------------------------------------------
    while { [regexp -indices {[0-9]{4}-[0-9]{4}-[0-9]{4}(-[0-9]{4})?} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set original [string range $payload $start $end]

        # Skip if this looks like it's already a placeholder
        if { [string match "<<*>>" $original] } { break }

        incr sequence
        set placeholder "<<ACCT:${correlation_id}:[format %03d $sequence]>>"

        table set -subtable $table_name $placeholder $original $static::anon_ttl

        set payload "[string range $payload 0 [expr {$start - 1}]]${placeholder}[string range $payload [expr {$end + 1}] end]"
        set modified 1
        log local0. "Anon: Replaced account with $placeholder"
    }

    # -------------------------------------------------------------------
    # Pattern: Dollar amounts ($X,XXX.XX or $X.XX or $XXX,XXX.XX)
    # -------------------------------------------------------------------
    while { [regexp -indices {\$[0-9]{1,3}(,[0-9]{3})*\.[0-9]{2}} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set original [string range $payload $start $end]

        incr sequence
        set placeholder "<<BAL:${correlation_id}:[format %03d $sequence]>>"

        table set -subtable $table_name $placeholder $original $static::anon_ttl

        set payload "[string range $payload 0 [expr {$start - 1}]]${placeholder}[string range $payload [expr {$end + 1}] end]"
        set modified 1
        log local0. "Anon: Replaced balance with $placeholder"
    }

    # -------------------------------------------------------------------
    # Pattern: Dates of birth (MM/DD/YYYY or YYYY-MM-DD)
    # -------------------------------------------------------------------
    while { [regexp -indices {(0[1-9]|1[0-2])/(0[1-9]|[12][0-9]|3[01])/[0-9]{4}} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set original [string range $payload $start $end]

        incr sequence
        set placeholder "<<DOB:${correlation_id}:[format %03d $sequence]>>"

        table set -subtable $table_name $placeholder $original $static::anon_ttl

        set payload "[string range $payload 0 [expr {$start - 1}]]${placeholder}[string range $payload [expr {$end + 1}] end]"
        set modified 1
        log local0. "Anon: Replaced DOB with $placeholder"
    }

    # ISO date format (YYYY-MM-DD)
    while { [regexp -indices {[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set original [string range $payload $start $end]

        incr sequence
        set placeholder "<<DOB:${correlation_id}:[format %03d $sequence]>>"

        table set -subtable $table_name $placeholder $original $static::anon_ttl

        set payload "[string range $payload 0 [expr {$start - 1}]]${placeholder}[string range $payload [expr {$end + 1}] end]"
        set modified 1
        log local0. "Anon: Replaced DOB (ISO) with $placeholder"
    }

    # -------------------------------------------------------------------
    # Pattern: Phone numbers (###-###-#### or (###) ###-####)
    # -------------------------------------------------------------------
    while { [regexp -indices {\(?[0-9]{3}\)?[\s.-][0-9]{3}[\s.-][0-9]{4}} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set original [string range $payload $start $end]

        incr sequence
        set placeholder "<<PHONE:${correlation_id}:[format %03d $sequence]>>"

        table set -subtable $table_name $placeholder $original $static::anon_ttl

        set payload "[string range $payload 0 [expr {$start - 1}]]${placeholder}[string range $payload [expr {$end + 1}] end]"
        set modified 1
        log local0. "Anon: Replaced phone with $placeholder"
    }

    # -------------------------------------------------------------------
    # Pattern: Email addresses
    # -------------------------------------------------------------------
    while { [regexp -indices {[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set original [string range $payload $start $end]

        incr sequence
        set placeholder "<<EMAIL:${correlation_id}:[format %03d $sequence]>>"

        table set -subtable $table_name $placeholder $original $static::anon_ttl

        set payload "[string range $payload 0 [expr {$start - 1}]]${placeholder}[string range $payload [expr {$end + 1}] end]"
        set modified 1
        log local0. "Anon: Replaced email with $placeholder"
    }

    # -------------------------------------------------------------------
    # Pattern: Known names (from X-Context-Cloak-Names header or static table)
    # The header is a comma-separated list of names to anonymize.
    # This is the safest approach — arbitrary name detection is unreliable.
    # -------------------------------------------------------------------
    if { [HTTP::header exists "X-Context-Cloak-Names"] } {
        set names_list [split [HTTP::header "X-Context-Cloak-Names"] ","]
        foreach raw_name $names_list {
            set name [string trim $raw_name]
            if { [string length $name] < 2 } { continue }

            # Replace all occurrences of this name
            while { [set idx [string first $name $payload]] >= 0 } {
                incr sequence
                set placeholder "<<NAME:${correlation_id}:[format %03d $sequence]>>"

                table set -subtable $table_name $placeholder $name $static::anon_ttl

                set end_idx [expr {$idx + [string length $name] - 1}]
                set payload "[string range $payload 0 [expr {$idx - 1}]]${placeholder}[string range $payload [expr {$end_idx + 1}] end]"
                set modified 1
                log local0. "Anon: Replaced name '$name' with $placeholder"
            }
        }
        # Strip the names header so it doesn't reach vLLM
        HTTP::header remove "X-Context-Cloak-Names"
    }

    # Apply modified payload
    if { $modified } {
        HTTP::payload replace 0 [HTTP::payload length] $payload
        # Inject correlation ID so response phase can find the subtable
        HTTP::header insert "X-Anon-Correlation-ID" $correlation_id
        log local0. "Anon: Request anonymized ($sequence replacements, correlation=$correlation_id)"
    }
}


when HTTP_RESPONSE {
    if { !$do_anonymize } { return }

    # Collect response body for de-anonymization
    if { [HTTP::header exists "Content-Length"] && [HTTP::header "Content-Length"] > 0 } {
        HTTP::collect [HTTP::header "Content-Length"]
    }
}


when HTTP_RESPONSE_DATA {
    if { !$do_anonymize } { return }

    set payload [HTTP::payload]
    set table_name "${static::anon_table_prefix}${correlation_id}"
    set restored 0

    # Find all placeholders in the response: <<TYPE:SESSION:SEQ>>
    # and replace them with original values from the subtable
    while { [regexp -indices {<<[A-Z]+:[^>]+:[0-9]{3}>>} $payload match_range] } {
        set start [lindex $match_range 0]
        set end [lindex $match_range 1]
        set placeholder [string range $payload $start $end]

        # Look up the original value
        set original [table lookup -subtable $table_name $placeholder]

        if { $original ne "" } {
            set payload "[string range $payload 0 [expr {$start - 1}]]${original}[string range $payload [expr {$end + 1}] end]"
            incr restored
            log local0. "Anon: Restored $placeholder -> [string range $original 0 3]***"
        } else {
            # Placeholder not found in subtable — leave it as-is
            # This can happen if TTL expired or if the placeholder was
            # generated by a different request
            log local0. "Anon: WARNING — no mapping found for $placeholder (TTL expired?)"
            # Move past this placeholder to avoid infinite loop
            break
        }
    }

    if { $restored > 0 } {
        HTTP::payload replace 0 [HTTP::payload length] $payload
        log local0. "Anon: Response de-anonymized ($restored restorations, correlation=$correlation_id)"
    }

    # Clean up: delete the subtable (entries will TTL out regardless, but
    # explicit cleanup is good practice)
    # TODO: Verify TMOS syntax for subtable deletion. The command below
    # deletes all entries in the subtable. If the subtable is shared
    # across requests (it's not in this design), this would be destructive.
    # table delete -subtable $table_name -all
}
