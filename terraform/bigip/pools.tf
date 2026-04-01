# =============================================================================
# Pool: MCP Server
# =============================================================================

resource "bigip_ltm_monitor" "mcp_http" {
  name          = "/${var.partition}/mcp_http_monitor"
  parent        = "/${var.partition}/http"
  send          = var.mcp_monitor_send
  receive       = var.mcp_monitor_receive
  interval      = 10
  timeout       = 31
  adaptive_limit = 0
}

resource "bigip_ltm_pool" "mcp" {
  name                = "/${var.partition}/${var.mcp_pool_name}"
  load_balancing_mode = "round-robin"
  monitors            = [bigip_ltm_monitor.mcp_http.name]

  # Minimum active members before marking pool down
  minimum_active_member = 1
}

resource "bigip_ltm_pool_attachment" "mcp_members" {
  for_each = { for idx, m in var.mcp_pool_members : idx => m }

  pool = bigip_ltm_pool.mcp.name
  node = "/${var.partition}/${each.value.address}:${each.value.port}"
}

# =============================================================================
# Pool: vLLM Inference
# =============================================================================

resource "bigip_ltm_monitor" "vllm_http" {
  name          = "/${var.partition}/vllm_http_monitor"
  parent        = "/${var.partition}/http"
  send          = "GET /health HTTP/1.1\\r\\nHost: vllm\\r\\n\\r\\n"
  receive       = "HTTP/1"
  interval      = 10
  timeout       = 31
  adaptive_limit = 0
}

resource "bigip_ltm_pool" "vllm" {
  name                = "/${var.partition}/${var.vllm_pool_name}"
  load_balancing_mode = "round-robin"
  monitors            = [bigip_ltm_monitor.vllm_http.name]

  minimum_active_member = 1
}

resource "bigip_ltm_pool_attachment" "vllm_members" {
  for_each = { for idx, m in var.vllm_pool_members : idx => m }

  pool = bigip_ltm_pool.vllm.name
  node = "/${var.partition}/${each.value.address}:${each.value.port}"
}
