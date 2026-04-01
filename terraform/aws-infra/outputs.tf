# =============================================================================
# Outputs
# =============================================================================

output "bigip_mgmt_public_ip" {
  description = "Public IP for BIG-IP management (SSH + HTTPS GUI)"
  value       = aws_eip.mgmt.public_ip
}

output "bigip_mgmt_private_ip" {
  description = "Private IP for BIG-IP management"
  value       = var.bigip_mgmt_private_ip
}

output "bigip_mgmt_url" {
  description = "URL for BIG-IP Configuration Utility"
  value       = "https://${aws_eip.mgmt.public_ip}"
}

output "bigip_external_public_ip" {
  description = "Public IP for BIG-IP external interface (self IP)"
  value       = aws_eip.external.public_ip
}

output "bigip_vip_public_ips" {
  description = "Public IPs mapped to BIG-IP VIP secondary addresses"
  value = {
    for idx, eip in aws_eip.vip : "vip_${idx}" => {
      public_ip  = eip.public_ip
      private_ip = var.bigip_external_secondary_ips[idx]
    }
  }
}

output "bigip_internal_private_ip" {
  description = "Private IP for BIG-IP internal interface"
  value       = var.bigip_internal_private_ip
}

output "bigip_ami_id" {
  description = "AMI ID used for BIG-IP"
  value       = data.aws_ami.bigip.id
}

output "bigip_ami_name" {
  description = "AMI name used for BIG-IP"
  value       = data.aws_ami.bigip.name
}

output "bigip_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.bigip.id
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "subnet_ids" {
  description = "Subnet IDs by role"
  value = {
    mgmt     = aws_subnet.mgmt.id
    external = aws_subnet.external.id
    internal = aws_subnet.internal.id
  }
}

output "ssh_private_key" {
  description = "Generated SSH private key (only if ssh_public_key was empty)"
  value       = var.ssh_public_key == "" ? tls_private_key.bigip[0].private_key_pem : null
  sensitive   = true
}

# --- Values to feed into terraform/bigip/ ---
output "bigip_provider_config" {
  description = "Values to use for the F5Networks/bigip provider in terraform/bigip/"
  value = {
    bigip_mgmt_host = aws_eip.mgmt.public_ip
    bigip_mgmt_port = 443
    mcp_vs_ip       = var.bigip_external_secondary_ips[0]
    vllm_vs_ip      = length(var.bigip_external_secondary_ips) > 1 ? var.bigip_external_secondary_ips[1] : ""
  }
}
