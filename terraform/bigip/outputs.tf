output "mcp_virtual_server" {
  description = "MCP virtual server name and destination"
  value = {
    name        = bigip_ltm_virtual_server.mcp.name
    destination = "${var.mcp_vs_ip}:${var.mcp_vs_port}"
    pool        = bigip_ltm_pool.mcp.name
  }
}

output "vllm_virtual_server" {
  description = "vLLM inference virtual server name and destination"
  value = {
    name        = bigip_ltm_virtual_server.vllm.name
    destination = "${var.vllm_vs_ip}:${var.vllm_vs_port}"
    pool        = bigip_ltm_pool.vllm.name
  }
}

output "irules" {
  description = "iRule names deployed"
  value = {
    mcp_session_persistence = bigip_ltm_irule.mcp_session_persistence.name
    vllm_anonymization      = bigip_ltm_irule.vllm_anonymization.name
  }
}
