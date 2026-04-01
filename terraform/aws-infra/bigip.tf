# =============================================================================
# BIG-IP VE Instance — 3-NIC BYOL Deployment
#
# NIC layout:
#   eth0 = Management   (public EIP for SSH/GUI access)
#   eth1 = External     (public EIP, VIP secondary IPs)
#   eth2 = Internal     (server-side, no public IP)
# =============================================================================

# --- AMI Lookup ---

data "aws_ami" "bigip" {
  most_recent = true
  owners      = ["679593333241"] # F5 Networks

  filter {
    name   = "name"
    values = [var.bigip_ami_name_filter]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- SSH Key Pair ---

resource "tls_private_key" "bigip" {
  count     = var.ssh_public_key == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bigip" {
  key_name_prefix = "${var.name_prefix}-bigip-"
  public_key      = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.bigip[0].public_key_openssh

  tags = {
    Name = "${var.name_prefix}-bigip-key"
  }
}

# --- Network Interfaces ---

resource "aws_network_interface" "mgmt" {
  subnet_id       = aws_subnet.mgmt.id
  security_groups = [aws_security_group.mgmt.id]
  private_ips     = [var.bigip_mgmt_private_ip]

  tags = {
    Name = "${var.name_prefix}-bigip-mgmt-eni"
  }
}

resource "aws_network_interface" "external" {
  subnet_id         = aws_subnet.external.id
  security_groups   = [aws_security_group.external.id]
  private_ips       = concat([var.bigip_external_private_ip], var.bigip_external_secondary_ips)
  source_dest_check = false # Required for BIG-IP forwarding

  tags = {
    Name = "${var.name_prefix}-bigip-external-eni"
  }
}

resource "aws_network_interface" "internal" {
  subnet_id         = aws_subnet.internal.id
  security_groups   = [aws_security_group.internal.id]
  private_ips       = [var.bigip_internal_private_ip]
  source_dest_check = false # Required for BIG-IP forwarding

  tags = {
    Name = "${var.name_prefix}-bigip-internal-eni"
  }
}

# --- Elastic IPs ---

resource "aws_eip" "mgmt" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-bigip-mgmt-eip"
  }
}

resource "aws_eip_association" "mgmt" {
  allocation_id        = aws_eip.mgmt.id
  network_interface_id = aws_network_interface.mgmt.id
  private_ip_address   = var.bigip_mgmt_private_ip
}

resource "aws_eip" "external" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-bigip-external-eip"
  }
}

resource "aws_eip_association" "external" {
  allocation_id        = aws_eip.external.id
  network_interface_id = aws_network_interface.external.id
  private_ip_address   = var.bigip_external_private_ip
}

# VIP EIPs — one per secondary IP on the external interface
resource "aws_eip" "vip" {
  count  = length(var.bigip_external_secondary_ips)
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-bigip-vip-${count.index}-eip"
  }
}

resource "aws_eip_association" "vip" {
  count                = length(var.bigip_external_secondary_ips)
  allocation_id        = aws_eip.vip[count.index].id
  network_interface_id = aws_network_interface.external.id
  private_ip_address   = var.bigip_external_secondary_ips[count.index]
}

# --- IAM Role (for Secrets Manager access) ---

resource "aws_iam_role" "bigip" {
  name_prefix = "${var.name_prefix}-bigip-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.name_prefix}-bigip-role"
  }
}

resource "aws_iam_role_policy" "bigip_secrets" {
  name_prefix = "${var.name_prefix}-secrets-"
  role        = aws_iam_role.bigip.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = [
        aws_secretsmanager_secret.bigip_admin.arn
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "bigip" {
  name_prefix = "${var.name_prefix}-bigip-"
  role        = aws_iam_role.bigip.name
}

# --- BIG-IP EC2 Instance ---

resource "aws_instance" "bigip" {
  ami           = data.aws_ami.bigip.id
  instance_type = var.bigip_instance_type
  key_name      = aws_key_pair.bigip.key_name

  iam_instance_profile = aws_iam_instance_profile.bigip.name

  # eth0 = management (primary interface must be attached at launch)
  network_interface {
    network_interface_id = aws_network_interface.mgmt.id
    device_index         = 0
  }

  user_data = templatefile("${path.module}/templates/user_data.tpl", {
    secret_id             = aws_secretsmanager_secret.bigip_admin.id
    aws_region            = var.aws_region
    hostname              = var.bigip_hostname
    license_key           = var.bigip_license_key
    runtime_init_version  = var.f5_runtime_init_version
    do_version            = var.do_version
    as3_version           = var.as3_version
    external_self_ip      = var.bigip_external_private_ip
    internal_self_ip      = var.bigip_internal_private_ip
    external_subnet_cidr  = var.external_subnet_cidr
    internal_subnet_cidr  = var.internal_subnet_cidr
    mgmt_gateway          = cidrhost(var.mgmt_subnet_cidr, 1)
    external_gateway      = cidrhost(var.external_subnet_cidr, 1)
    internal_gateway      = cidrhost(var.internal_subnet_cidr, 1)
    external_mask         = cidrnetmask(var.external_subnet_cidr)
    internal_mask         = cidrnetmask(var.internal_subnet_cidr)
  })

  tags = {
    Name = "${var.name_prefix}-bigip"
  }

  # BIG-IP takes a while to boot and onboard
  timeouts {
    create = "30m"
  }
}

# Attach additional NICs after launch
resource "aws_network_interface_attachment" "external" {
  instance_id          = aws_instance.bigip.id
  network_interface_id = aws_network_interface.external.id
  device_index         = 1
}

resource "aws_network_interface_attachment" "internal" {
  instance_id          = aws_instance.bigip.id
  network_interface_id = aws_network_interface.internal.id
  device_index         = 2
}
