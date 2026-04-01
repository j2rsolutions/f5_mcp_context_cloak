# =============================================================================
# BIG-IP Profiles for MCP and Inference traffic
# =============================================================================

# JSON profile — enables JSON_REQUEST/JSON_RESPONSE iRule events
resource "bigip_ltm_profile_http" "mcp_http" {
  name          = "/${var.partition}/context_cloak_http"
  defaults_from = "/${var.partition}/http"

  # Allow large headers for Mcp-Session-Id enrichment
  # TODO: Adjust if your MCP payloads need larger header support
}

# TODO: The F5Networks/bigip Terraform provider may not have native resources
# for JSON and SSE profiles as of v1.22. If not available, create them via
# tmsh commands in a provisioner or use bigip_command / bigip_as3.
#
# The tmsh commands would be:
#   tmsh create ltm profile json context_cloak_json maximum-bytes ${var.json_profile_max_bytes}
#   tmsh create ltm profile sse context_cloak_sse max-buffered-msg-bytes ${var.sse_profile_max_bytes}
#
# For now, we reference these profiles by name and assume they exist or are
# created out-of-band.

# Uncomment and use if bigip_command is available in your provider version:
#
# resource "bigip_command" "json_profile" {
#   commands = [
#     "tmsh create ltm profile json /${var.partition}/context_cloak_json maximum-bytes ${var.json_profile_max_bytes} maximum-entries 4096 maximum-non-json-bytes 65536"
#   ]
# }
#
# resource "bigip_command" "sse_profile" {
#   commands = [
#     "tmsh create ltm profile sse /${var.partition}/context_cloak_sse max-buffered-msg-bytes ${var.sse_profile_max_bytes} max-field-name-size 2048"
#   ]
# }

locals {
  # Profile names — update these if you create custom profiles above
  json_profile_name = "/${var.partition}/json"
  sse_profile_name  = "/${var.partition}/sse"
  http_profile_name = "/${var.partition}/${var.http_profile_name}"
}
