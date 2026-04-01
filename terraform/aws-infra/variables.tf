# =============================================================================
# AWS / General
# =============================================================================

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "context-cloak"
}

variable "availability_zone" {
  description = "AZ for all subnets (single-AZ lab deployment)"
  type        = string
  default     = "us-east-1a"
}

# =============================================================================
# VPC / Networking
# =============================================================================

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "mgmt_subnet_cidr" {
  description = "CIDR for the management subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "external_subnet_cidr" {
  description = "CIDR for the external (client-facing) subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "internal_subnet_cidr" {
  description = "CIDR for the internal (server-facing) subnet"
  type        = string
  default     = "10.0.2.0/24"
}

# =============================================================================
# BIG-IP Instance
# =============================================================================

variable "bigip_instance_type" {
  description = "EC2 instance type for BIG-IP (minimum m5.xlarge for 3-NIC)"
  type        = string
  default     = "m5.xlarge"
}

variable "bigip_ami_name_filter" {
  description = "AMI name filter for BIG-IP BYOL image"
  type        = string
  default     = "F5 BIGIP-21*BYOL-All Modules 2Boot*"
}

variable "bigip_mgmt_private_ip" {
  description = "Private IP for BIG-IP management interface"
  type        = string
  default     = "10.0.0.200"
}

variable "bigip_external_private_ip" {
  description = "Primary private IP for BIG-IP external interface"
  type        = string
  default     = "10.0.1.200"
}

variable "bigip_external_secondary_ips" {
  description = "Secondary private IPs on external interface (used as VIPs)"
  type        = list(string)
  default     = ["10.0.1.100", "10.0.1.101"]
}

variable "bigip_internal_private_ip" {
  description = "Private IP for BIG-IP internal interface"
  type        = string
  default     = "10.0.2.200"
}

variable "bigip_hostname" {
  description = "Hostname for the BIG-IP instance"
  type        = string
  default     = "bigip-lab.context-cloak.local"
}

# =============================================================================
# BYOL License
# =============================================================================

variable "bigip_license_key" {
  description = "F5 BYOL registration key (XXXXX-XXXXX-XXXXX-XXXXX-XXXXXXX)"
  type        = string
  sensitive   = true
}

# =============================================================================
# Access Control
# =============================================================================

variable "admin_password" {
  description = "Admin password for BIG-IP (stored in Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "allowed_mgmt_cidrs" {
  description = "CIDR blocks allowed to access BIG-IP management (SSH + HTTPS)"
  type        = list(string)
  # TODO: Restrict to your IP range
  default = ["0.0.0.0/0"]
}

variable "ssh_public_key" {
  description = "SSH public key for BIG-IP access. If empty, a key pair is generated."
  type        = string
  default     = ""
}

# =============================================================================
# Runtime Init
# =============================================================================

variable "f5_runtime_init_version" {
  description = "Version of f5-bigip-runtime-init to install"
  type        = string
  default     = "2.0.3"
}

variable "do_version" {
  description = "Declarative Onboarding extension version"
  type        = string
  default     = "1.44.0"
}

variable "as3_version" {
  description = "AS3 extension version"
  type        = string
  default     = "3.53.0"
}
