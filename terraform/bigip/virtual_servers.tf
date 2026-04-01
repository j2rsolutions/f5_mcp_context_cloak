# =============================================================================
# Virtual Server: MCP
# Routes MCP JSON-RPC 2.0 traffic to the MCP server pool.
# Profiles: HTTP + JSON + SSE for iRule event support.
# iRule: mcp_session_persistence for Mcp-Session-Id-based affinity.
# =============================================================================

resource "bigip_ltm_virtual_server" "mcp" {
  name        = "/${var.partition}/${var.mcp_vs_name}"
  destination = "${var.mcp_vs_ip}"
  port        = var.mcp_vs_port
  pool        = bigip_ltm_pool.mcp.name
  ip_protocol = "tcp"

  source_address_translation = var.mcp_vs_snat

  profiles = compact([
    local.http_profile_name,
    local.json_profile_name,
    local.sse_profile_name,
    # TODO: Add client SSL profile if terminating TLS on BIG-IP
    var.ssl_client_profile != "" ? "/${var.partition}/${var.ssl_client_profile}" : "",
  ])

  irules = [
    bigip_ltm_irule.mcp_session_persistence.name,
  ]

  # TODO: Uncomment and set if restricting to a specific VLAN
  # vlans         = ["/${var.partition}/${var.mcp_vs_vlan}"]
  # vlans_enabled = true
}

# =============================================================================
# Virtual Server: vLLM Inference
# Front-ends the vLLM endpoint. The anonymization iRule strips PII from
# outbound requests and restores values in responses.
# =============================================================================

resource "bigip_ltm_virtual_server" "vllm" {
  name        = "/${var.partition}/${var.vllm_vs_name}"
  destination = "${var.vllm_vs_ip}"
  port        = var.vllm_vs_port
  pool        = bigip_ltm_pool.vllm.name
  ip_protocol = "tcp"

  source_address_translation = var.vllm_vs_snat

  profiles = compact([
    local.http_profile_name,
    local.json_profile_name,
    # SSE profile not needed here — inference uses standard HTTP request/response
    # TODO: Add if you enable streaming inference later
    var.ssl_client_profile != "" ? "/${var.partition}/${var.ssl_client_profile}" : "",
  ])

  irules = [
    bigip_ltm_irule.vllm_anonymization.name,
  ]

  # TODO: Uncomment and set if restricting to a specific VLAN
  # vlans         = ["/${var.partition}/${var.vllm_vs_vlan}"]
  # vlans_enabled = true
}
