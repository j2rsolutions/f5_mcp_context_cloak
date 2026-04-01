# =============================================================================
# AWS Secrets Manager — BIG-IP admin password
# The runtime-init user_data retrieves this at boot.
# =============================================================================

resource "aws_secretsmanager_secret" "bigip_admin" {
  name_prefix = "${var.name_prefix}-bigip-admin-"
  description = "BIG-IP admin password for Context Cloak lab"

  tags = {
    Name = "${var.name_prefix}-bigip-admin-secret"
  }
}

resource "aws_secretsmanager_secret_version" "bigip_admin" {
  secret_id     = aws_secretsmanager_secret.bigip_admin.id
  secret_string = var.admin_password
}
