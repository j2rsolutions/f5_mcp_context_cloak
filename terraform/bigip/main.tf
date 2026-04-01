# =============================================================================
# Context Cloak — BIG-IP Terraform Configuration
# =============================================================================
#
# This Terraform configuration deploys:
#   1. MCP virtual server with session persistence iRule
#   2. vLLM inference virtual server with anonymization iRule
#   3. Pools, monitors, and profiles for both
#
# Prerequisites:
#   - BIG-IP TMOS v21+ with JSON and SSE profile support
#   - Network connectivity from BIG-IP to MCP server nodes and vLLM nodes
#   - JSON and SSE profiles created on BIG-IP (see profiles.tf for details)
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars
#   # Edit terraform.tfvars with your environment details
#   terraform init
#   terraform plan
#   terraform apply
#
# =============================================================================

# All resources are defined in:
#   - providers.tf    — provider configuration
#   - variables.tf    — input variables
#   - profiles.tf     — HTTP/JSON/SSE profiles
#   - pools.tf        — pools, monitors, and members
#   - irules.tf       — iRule resources
#   - virtual_servers.tf — virtual server definitions
#   - outputs.tf      — outputs
