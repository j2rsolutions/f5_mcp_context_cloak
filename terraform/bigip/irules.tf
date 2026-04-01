# =============================================================================
# iRules
# =============================================================================

resource "bigip_ltm_irule" "mcp_session_persistence" {
  name  = "/${var.partition}/mcp_session_persistence"
  irule = file(var.mcp_irule_path)
}

resource "bigip_ltm_irule" "vllm_anonymization" {
  name  = "/${var.partition}/vllm_anonymization"
  irule = file(var.vllm_irule_path)
}
