/**
 * iRule Generator for Context Cloak
 *
 * Dynamically generates BIG-IP iRules from the PII field configuration.
 * Two iRules are produced:
 *
 * 1. MCP iRule (mcp_session_persistence):
 *    - Handles MCP session affinity (Mcp-Session-Id enrichment)
 *    - Collects MCP response bodies (with rechunk for SSE streams)
 *    - Iterates the data group to find PII fields in the response JSON
 *    - Generates fake values (substitute mode) or tokens (tokenize mode)
 *    - Stores bidirectional mappings in a session-keyed subtable
 *    - Passes the response through UNMODIFIED (enables tool chaining)
 *
 * 2. Inference iRule (vllm_anonymization):
 *    - Cloaks inference requests: string map real -> fake
 *    - De-cloaks inference responses: string map fake -> real
 *    - Optionally injects a system prompt for tokenize guidance
 *
 * Key design decisions:
 * - Tcl double-quote strings use q() helper for consistent quoting
 * - Regex patterns use set+append with braces to avoid Tcl bracket interpretation
 * - Base64 file writes (via bigip_client.js) avoid heredoc escaping issues
 * - Data group iteration (class names/class match) makes fields configurable
 *   without modifying iRule code
 */

'use strict';

// Helper: wrap a string in Tcl double quotes
function q(s) { return '"' + s + '"'; }
// Helper: wrap in Tcl braces (prevents substitution -- used for regex patterns)
function b(s) { return '{' + s + '}'; }

/**
 * Generate the MCP Virtual Server iRule.
 * This iRule builds the cloaking table by extracting PII from MCP responses.
 * The response passes through unmodified so tool chaining works.
 */
function generateMcpIrule(config) {
    var ttl = config.session.ttl || 3600;
    var prefix = 'cloak_';
    var p = config.partition || 'Common';
    var dgName = '/' + p + '/context_cloak_fields';
    var firsts = config.fake_names.first.join(' ');
    var lasts = config.fake_names.last.join(' ');
    var lines = [];

    lines.push('when RULE_INIT {');
    lines.push('    set static::cloak_ttl ' + ttl);
    lines.push('    set static::cloak_prefix ' + q(prefix));
    lines.push('    set static::cloak_dg ' + q(dgName));
    lines.push('    set static::fake_firsts [list ' + firsts + ']');
    lines.push('    set static::fake_lasts  [list ' + lasts + ']');
    lines.push('}');
    lines.push('');

    // HTTP_REQUEST
    lines.push('when HTTP_REQUEST {');
    lines.push('    set collect_response 0');
    lines.push('    set req_path [HTTP::path]');
    if (config.session.id_source === 'header') {
        lines.push('    if { [HTTP::header exists ' + q(config.session.id_header) + '] } {');
        lines.push('        set cloak_session_id [HTTP::header ' + q(config.session.id_header) + ']');
        lines.push('    } else {');
        lines.push('        set cloak_session_id [IP::client_addr]');
        lines.push('    }');
    } else {
        lines.push('    set cloak_session_id [IP::client_addr]');
    }
    lines.push('    if { $req_path eq ' + q('/mcp') + ' } {');
    lines.push('        set collect_response 1');
    lines.push('        if { [HTTP::header exists ' + q('Mcp-Session-Id') + '] } {');
    lines.push('            set header_value [HTTP::header ' + q('Mcp-Session-Id') + ']');
    lines.push('            set header_parts [split $header_value ' + q(',') + ']');
    lines.push('            if { [llength $header_parts] == 3 } {');
    lines.push('                pool [lindex $header_parts 0] member [lindex $header_parts 1]');
    lines.push('                HTTP::header replace ' + q('Mcp-Session-Id') + ' [lindex $header_parts 2]');
    lines.push('            }');
    lines.push('        }');
    lines.push('    }');
    lines.push('}');
    lines.push('');

    // HTTP_RESPONSE
    lines.push('when HTTP_RESPONSE {');
    lines.push('    if { [HTTP::header exists ' + q('Mcp-Session-Id') + '] } {');
    lines.push('        set enriched ' + q('[LB::server pool],[IP::server_addr]:[LB::server port],[HTTP::header Mcp-Session-Id]'));
    lines.push('        HTTP::header replace ' + q('Mcp-Session-Id') + ' $enriched');
    lines.push('    }');
    lines.push('    if { $collect_response } {');
    lines.push('        if { [HTTP::header exists ' + q('Content-Length') + '] && [HTTP::header ' + q('Content-Length') + '] > 0 } {');
    lines.push('            HTTP::collect [HTTP::header ' + q('Content-Length') + ']');
    lines.push('        } else {');
    lines.push('            HTTP::collect 1048576');
    lines.push('        }');
    lines.push('    }');
    lines.push('}');
    lines.push('');

    // HTTP_RESPONSE_DATA -- data-group-driven PII extraction
    lines.push('when HTTP_RESPONSE_DATA {');
    lines.push('    if { !$collect_response } { return }');
    lines.push('    set payload [HTTP::payload]');
    lines.push('    set table_name ' + q('${static::cloak_prefix}${cloak_session_id}'));
    lines.push('');
    lines.push('    foreach field_name [class names $static::cloak_dg] {');
    lines.push('        set cloak_config [class match -value $field_name equals $static::cloak_dg]');
    lines.push('        set config_parts [split $cloak_config ' + q(':') + ']');
    lines.push('        set cloak_mode [lindex $config_parts 0]');
    lines.push('        set cloak_type [lindex $config_parts 1]');
    lines.push('        set cloak_param [lindex $config_parts 2]');
    lines.push('');

    // Build regex based on type
    // Build regex patterns using string concatenation to avoid Tcl bracket issues
    // The regex part is in braces (no substitution), field_name is a variable
    lines.push('        set pattern ""');
    lines.push('        switch $cloak_type {');
    lines.push('            "name" { set pattern "${field_name}"; append pattern {[^A-Za-z]*([A-Z][a-z]+ [A-Z][a-z]+)} }');
    lines.push('            "SSN" { set pattern "${field_name}"; append pattern {[^0-9]*([0-9]{3}-[0-9]{2}-[0-9]{4})} }');
    lines.push('            "digit_shift" { set pattern "${field_name}"; append pattern {[^0-9]*([0-9]{4}-[0-9]{4}-[0-9]{4})} }');
    lines.push('            "email" { set pattern "${field_name}"; append pattern {[^a-zA-Z0-9]*([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+[.][a-zA-Z]{2,})} }');
    lines.push('            "phone" { set pattern "${field_name}"; append pattern {[^0-9(-]*([0-9() ./-]{7,})} }');
    lines.push('            default { set pattern "${field_name}"; append pattern {[^A-Za-z0-9]*([A-Za-z0-9 .@_-]+)} }');
    lines.push('        }');
    lines.push('');
    lines.push('        if { $pattern eq ' + q('') + ' } { continue }');
    lines.push('        set matches [regexp -all -inline $pattern $payload]');
    lines.push('        for {set i 1} {$i < [llength $matches]} {incr i 2} {');
    lines.push('            set real_val [lindex $matches $i]');
    lines.push('            if { [table lookup -subtable $table_name ' + q('r2f_${real_val}') + '] ne ' + q('') + ' } { continue }');
    lines.push('            if { [table lookup -subtable $table_name ' + q('f2r_${real_val}') + '] ne ' + q('') + ' } { continue }');
    lines.push('');
    lines.push('            set fake_val ' + q(''));
    lines.push('            if { $cloak_mode eq ' + q('tokenize') + ' } {');
    lines.push('                set seq_key ' + q('_seq_${cloak_type}'));
    lines.push('                set seq [table lookup -subtable $table_name $seq_key]');
    lines.push('                if { $seq eq ' + q('') + ' } { set seq 0 }');
    lines.push('                incr seq');
    lines.push('                table set -subtable $table_name $seq_key $seq $static::cloak_ttl');
    lines.push('                set fake_val ' + q('<<${cloak_type}:${cloak_session_id}:[format %03d $seq]>>'));
    lines.push('            } elseif { $cloak_mode eq ' + q('substitute') + ' } {');
    lines.push('                switch $cloak_type {');
    lines.push('                    ' + q('name') + ' {');
    lines.push('                        set hash 0');
    lines.push('                        foreach c [split $real_val ' + q('') + '] { incr hash [scan $c %c] }');
    lines.push('                        set fi [expr {$hash % [llength $static::fake_firsts]}]');
    lines.push('                        set li [expr {($hash / 10) % [llength $static::fake_lasts]}]');
    lines.push('                        set fake_val ' + q('[lindex $static::fake_firsts $fi] [lindex $static::fake_lasts $li]'));
    lines.push('                        if { $fake_val eq $real_val } {');
    lines.push('                            set fi [expr {($fi + 1) % [llength $static::fake_firsts]}]');
    lines.push('                            set fake_val ' + q('[lindex $static::fake_firsts $fi] [lindex $static::fake_lasts $li]'));
    lines.push('                        }');
    lines.push('                    }');
    lines.push('                    ' + q('email') + ' {');
    lines.push('                        set hash 0');
    lines.push('                        foreach c [split $real_val ' + q('') + '] { incr hash [scan $c %c] }');
    lines.push('                        set fi [expr {$hash % [llength $static::fake_firsts]}]');
    lines.push('                        set li [expr {($hash / 10) % [llength $static::fake_lasts]}]');
    lines.push('                        set fake_val ' + q('[string tolower [lindex $static::fake_firsts $fi]].[string tolower [lindex $static::fake_lasts $li]]@example.net'));
    lines.push('                    }');
    lines.push('                    default {');
    lines.push('                        set shift 5');
    lines.push('                        if { $cloak_param ne ' + q('') + ' } { set shift $cloak_param }');
    lines.push('                        foreach c [split $real_val ' + q('') + '] {');
    lines.push('                            if { [string is digit $c] } {');
    lines.push('                                append fake_val [expr {($c + $shift) % 10}]');
    lines.push('                            } else {');
    lines.push('                                append fake_val $c');
    lines.push('                            }');
    lines.push('                        }');
    lines.push('                    }');
    lines.push('                }');
    lines.push('            }');
    lines.push('');
    lines.push('            if { $fake_val eq ' + q('') + ' } { continue }');
    lines.push('            table set -subtable $table_name ' + q('r2f_${real_val}') + ' $fake_val $static::cloak_ttl');
    lines.push('            table set -subtable $table_name ' + q('f2r_${fake_val}') + ' $real_val $static::cloak_ttl');
    lines.push('            set fl [table lookup -subtable $table_name ' + q('_fake_list') + ']');
    lines.push('            if { $fl eq ' + q('') + ' } { table set -subtable $table_name ' + q('_fake_list') + ' $fake_val $static::cloak_ttl');
    lines.push('            } else { table set -subtable $table_name ' + q('_fake_list') + ' ' + q('${fl}|${fake_val}') + ' $static::cloak_ttl }');
    lines.push('            set rl [table lookup -subtable $table_name ' + q('_real_list') + ']');
    lines.push('            if { $rl eq ' + q('') + ' } { table set -subtable $table_name ' + q('_real_list') + ' $real_val $static::cloak_ttl');
    lines.push('            } else { table set -subtable $table_name ' + q('_real_list') + ' ' + q('${rl}|${real_val}') + ' $static::cloak_ttl }');
    lines.push('            log local0. ' + q('CloakTable: ${field_name} (${cloak_mode}) (session=$cloak_session_id)'));
    lines.push('        }');
    lines.push('    }');
    lines.push('    log local0. ' + q('CloakTable: scan complete (session=$cloak_session_id)'));
    lines.push('}');

    return lines.join('\n');
}

function generateInferenceIrule(config) {
    var prefix = 'cloak_';
    var hasTokenize = config.pii_fields.some(function(f) { return f.cloak_mode === 'tokenize'; });
    var tokenizePrompt = config.tokenize_prompt || 'You may encounter placeholders in the format <<TYPE:ID:SEQ>> in the data you receive. These are privacy tokens representing sensitive information that has been secured. Treat these placeholders as if they were real values. Reference them naturally in your response exactly as they appear. They will be automatically replaced with the actual values before the user sees your response. Do not mention that the data is tokenized or masked.';
    var lines = [];

    lines.push('when RULE_INIT {');
    lines.push('    set static::cloak_prefix ' + q(prefix));
    if (hasTokenize) {
        // Use Tcl braces to avoid escaping issues with << >> and quotes
        lines.push('    set static::tokenize_prompt {' + tokenizePrompt + '}');
    }
    lines.push('}');
    lines.push('');

    lines.push('when HTTP_REQUEST {');
    lines.push('    set do_cloak 0');
    lines.push('    set req_path [HTTP::path]');
    if (config.session.id_source === 'header') {
        lines.push('    if { [HTTP::header exists ' + q(config.session.id_header) + '] } {');
        lines.push('        set cloak_session_id [HTTP::header ' + q(config.session.id_header) + ']');
        lines.push('    } else {');
        lines.push('        set cloak_session_id [IP::client_addr]');
        lines.push('    }');
    } else {
        lines.push('    set cloak_session_id [IP::client_addr]');
    }

    var paths = ['/v1/chat/completions', '/v1/completions'];
    (config.llm_endpoints || []).forEach(function (ep) {
        if (ep.api_path && paths.indexOf(ep.api_path) === -1) paths.push(ep.api_path);
    });
    lines.push('    if { ' + paths.map(function (p) { return '$req_path starts_with ' + q(p); }).join(' || ') + ' } {');
    lines.push('        set do_cloak 1');
    lines.push('        if { [HTTP::header exists ' + q('Content-Length') + '] && [HTTP::header ' + q('Content-Length') + '] > 0 } {');
    lines.push('            HTTP::collect [HTTP::header ' + q('Content-Length') + ']');
    lines.push('        }');
    lines.push('    }');
    lines.push('}');
    lines.push('');

    // Request cloaking with optional tokenize prompt injection
    lines.push('when HTTP_REQUEST_DATA {');
    lines.push('    if { !$do_cloak } { return }');
    lines.push('    set payload [HTTP::payload]');
    lines.push('    set table_name ' + q('${static::cloak_prefix}${cloak_session_id}'));
    lines.push('    set list_raw [table lookup -subtable $table_name ' + q('_real_list') + ']');
    lines.push('    if { $list_raw eq ' + q('') + ' } {');
    lines.push('        log local0. ' + q('Cloak: no cloaking table (session=$cloak_session_id)'));
    lines.push('        HTTP::release');
    lines.push('        return');
    lines.push('    }');
    lines.push('    set entries [split $list_raw ' + q('|') + ']');
    lines.push('    set sorted [list]');
    lines.push('    foreach entry $entries {');
    lines.push('        if { $entry eq ' + q('') + ' } { continue }');
    lines.push('        set len [string length $entry]');
    lines.push('        set inserted 0');
    lines.push('        for {set j 0} {$j < [llength $sorted]} {incr j} {');
    lines.push('            if { $len > [string length [lindex $sorted $j]] } {');
    lines.push('                set sorted [linsert $sorted $j $entry]');
    lines.push('                set inserted 1');
    lines.push('                break');
    lines.push('            }');
    lines.push('        }');
    lines.push('        if { !$inserted } { lappend sorted $entry }');
    lines.push('    }');
    lines.push('    set map_pairs [list]');
    lines.push('    set count 0');
    lines.push('    foreach val $sorted {');
    lines.push('        set mapped [table lookup -subtable $table_name ' + q('r2f_${val}') + ']');
    lines.push('        if { $mapped ne ' + q('') + ' } {');
    lines.push('            lappend map_pairs $val $mapped');
    lines.push('            incr count');
    lines.push('        }');
    lines.push('    }');
    lines.push('    if { $count > 0 } {');
    lines.push('        set payload [string map $map_pairs $payload]');
    if (hasTokenize) {
        // Inject tokenize guidance: prepend system message into the messages array
        // Look for "messages":[ and insert a system message right after the [
        lines.push('        if { [regexp {<<[A-Z]+:} $payload] } {');
        lines.push('            set marker {\\\"messages\\\":\\[}');
        lines.push('            set mpos [string first $marker $payload]');
        lines.push('            if { $mpos >= 0 } {');
        lines.push('                set insert_pos [expr {$mpos + [string length $marker]}]');
        lines.push('                set sys_msg "{\\\"role\\\":\\\"system\\\",\\\"content\\\":\\\"$static::tokenize_prompt\\\"},"');
        lines.push('                set payload [string replace $payload $insert_pos [expr {$insert_pos - 1}] $sys_msg]');
        lines.push('                log local0. ' + q('Cloak: tokenize guidance prompt injected'));
        lines.push('            }');
        lines.push('        }');
    }
    lines.push('        HTTP::payload replace 0 [HTTP::payload length] $payload');
    lines.push('        log local0. ' + q('Cloak: request cloaked ($count values, session=$cloak_session_id)'));
    lines.push('    }');
    lines.push('    HTTP::release');
    lines.push('}');
    lines.push('');

    // Response collection
    lines.push('when HTTP_RESPONSE {');
    lines.push('    if { !$do_cloak } { return }');
    lines.push('    if { [HTTP::header exists ' + q('Content-Length') + '] && [HTTP::header ' + q('Content-Length') + '] > 0 } {');
    lines.push('        HTTP::collect [HTTP::header ' + q('Content-Length') + ']');
    lines.push('    }');
    lines.push('}');
    lines.push('');

    // Response de-cloaking
    lines.push(makeStringMapHandler('HTTP_RESPONSE_DATA', '_fake_list', 'f2r_',
        'Decloak: response de-cloaked', 'Decloak: no cloaking table'));

    return lines.join('\n');
}

function makeStringMapHandler(event, listKey, lookupPrefix, successMsg, noTableMsg) {
    var lines = [];
    lines.push('when ' + event + ' {');
    lines.push('    if { !$do_cloak } { return }');
    lines.push('    set payload [HTTP::payload]');
    lines.push('    set table_name ' + q('${static::cloak_prefix}${cloak_session_id}'));
    lines.push('    set list_raw [table lookup -subtable $table_name ' + q(listKey) + ']');
    lines.push('    if { $list_raw eq ' + q('') + ' } {');
    lines.push('        log local0. ' + q(noTableMsg + ' (session=$cloak_session_id)'));
    lines.push('        HTTP::release');
    lines.push('        return');
    lines.push('    }');
    lines.push('    set entries [split $list_raw ' + q('|') + ']');
    lines.push('    set sorted [list]');
    lines.push('    foreach entry $entries {');
    lines.push('        if { $entry eq ' + q('') + ' } { continue }');
    lines.push('        set len [string length $entry]');
    lines.push('        set inserted 0');
    lines.push('        for {set j 0} {$j < [llength $sorted]} {incr j} {');
    lines.push('            if { $len > [string length [lindex $sorted $j]] } {');
    lines.push('                set sorted [linsert $sorted $j $entry]');
    lines.push('                set inserted 1');
    lines.push('                break');
    lines.push('            }');
    lines.push('        }');
    lines.push('        if { !$inserted } { lappend sorted $entry }');
    lines.push('    }');
    lines.push('    set map_pairs [list]');
    lines.push('    set count 0');
    lines.push('    foreach val $sorted {');
    lines.push('        set mapped [table lookup -subtable $table_name ' + q(lookupPrefix + '${val}') + ']');
    lines.push('        if { $mapped ne ' + q('') + ' } {');
    lines.push('            lappend map_pairs $val $mapped');
    lines.push('            incr count');
    lines.push('        }');
    lines.push('    }');
    lines.push('    if { $count > 0 } {');
    lines.push('        set payload [string map $map_pairs $payload]');
    lines.push('        HTTP::payload replace 0 [HTTP::payload length] $payload');
    lines.push('        log local0. ' + q(successMsg + ' ($count values, session=$cloak_session_id)'));
    lines.push('    }');
    lines.push('    HTTP::release');
    lines.push('}');
    return lines.join('\n');
}

module.exports = {
    generateMcpIrule: generateMcpIrule,
    generateInferenceIrule: generateInferenceIrule
};
