# =============================================================================
# BIG-IP Connection
# =============================================================================

variable "bigip_mgmt_host" {
  description = "BIG-IP management IP or hostname"
  type        = string
}

variable "bigip_mgmt_port" {
  description = "BIG-IP management port"
  type        = number
  default     = 443
}

variable "bigip_username" {
  description = "BIG-IP admin username"
  type        = string
  default     = "admin"
}

variable "bigip_password" {
  description = "BIG-IP admin password"
  type        = string
  sensitive   = true
}

variable "partition" {
  description = "BIG-IP partition for all resources"
  type        = string
  default     = "Common"
}

# =============================================================================
# MCP Virtual Server
# =============================================================================

variable "mcp_vs_name" {
  description = "Name of the MCP virtual server"
  type        = string
  default     = "mcp_vs"
}

variable "mcp_vs_ip" {
  description = "Virtual IP for the MCP virtual server"
  type        = string
}

variable "mcp_vs_port" {
  description = "Port for the MCP virtual server"
  type        = number
  default     = 443
}

variable "mcp_vs_vlan" {
  description = "VLAN name for the MCP virtual server (client-side)"
  type        = string
  default     = ""
}

variable "mcp_vs_snat" {
  description = "SNAT setting for MCP VS (automap, none, or snat pool name)"
  type        = string
  default     = "automap"
}

# =============================================================================
# MCP Pool Members
# =============================================================================

variable "mcp_pool_name" {
  description = "Name of the MCP server pool"
  type        = string
  default     = "mcp_server_pool"
}

variable "mcp_pool_members" {
  description = "List of MCP server pool members"
  type = list(object({
    address = string
    port    = number
  }))
}

variable "mcp_monitor_send" {
  description = "HTTP monitor send string for MCP health check"
  type        = string
  default     = "POST /mcp HTTP/1.1\\r\\nHost: mcp-server\\r\\nContent-Type: application/json\\r\\nContent-Length: 2\\r\\n\\r\\n{}"
}

variable "mcp_monitor_receive" {
  description = "HTTP monitor expected receive string"
  type        = string
  default     = "HTTP/1"
}

# =============================================================================
# Inference (vLLM) Virtual Server
# =============================================================================

variable "vllm_vs_name" {
  description = "Name of the vLLM inference virtual server"
  type        = string
  default     = "vllm_inference_vs"
}

variable "vllm_vs_ip" {
  description = "Virtual IP for the vLLM inference virtual server"
  type        = string
}

variable "vllm_vs_port" {
  description = "Port for the vLLM inference virtual server"
  type        = number
  default     = 443
}

variable "vllm_vs_vlan" {
  description = "VLAN name for the inference virtual server (client-side)"
  type        = string
  default     = ""
}

variable "vllm_vs_snat" {
  description = "SNAT setting for vLLM VS (automap, none, or snat pool name)"
  type        = string
  default     = "automap"
}

# =============================================================================
# vLLM Pool Members
# =============================================================================

variable "vllm_pool_name" {
  description = "Name of the vLLM server pool"
  type        = string
  default     = "vllm_pool"
}

variable "vllm_pool_members" {
  description = "List of vLLM pool members"
  type = list(object({
    address = string
    port    = number
  }))
}

# =============================================================================
# Profiles
# =============================================================================

variable "http_profile_name" {
  description = "Name of the HTTP profile to use or create"
  type        = string
  default     = "http"
}

variable "ssl_client_profile" {
  description = "Client SSL profile name (set to empty string to disable TLS)"
  type        = string
  default     = ""
}

variable "json_profile_max_bytes" {
  description = "Maximum JSON payload size in bytes for the JSON profile"
  type        = number
  default     = 131072
}

variable "sse_profile_max_bytes" {
  description = "Maximum SSE buffered message size in bytes"
  type        = number
  default     = 131072
}

# =============================================================================
# iRule content paths
# =============================================================================

variable "mcp_irule_path" {
  description = "Path to the MCP session persistence iRule file"
  type        = string
  default     = "../../irules/mcp_session_persistence.tcl"
}

variable "vllm_irule_path" {
  description = "Path to the vLLM anonymization iRule file"
  type        = string
  default     = "../../irules/vllm_anonymization.tcl"
}
