# =============================================================================
# Security Groups — one per BIG-IP interface
# =============================================================================

# --- Management ---
resource "aws_security_group" "mgmt" {
  name_prefix = "${var.name_prefix}-mgmt-"
  description = "BIG-IP management interface"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-mgmt-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_ssh" {
  for_each = toset(var.allowed_mgmt_cidrs)

  security_group_id = aws_security_group.mgmt.id
  description       = "SSH from admin CIDR"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_https" {
  for_each = toset(var.allowed_mgmt_cidrs)

  security_group_id = aws_security_group.mgmt.id
  description       = "HTTPS GUI/API from admin CIDR"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_https_alt" {
  for_each = toset(var.allowed_mgmt_cidrs)

  security_group_id = aws_security_group.mgmt.id
  description       = "Alternative mgmt port"
  ip_protocol       = "tcp"
  from_port         = 8443
  to_port           = 8443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "mgmt_all" {
  security_group_id = aws_security_group.mgmt.id
  description       = "All outbound (licensing, downloads)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- External (client-facing) ---
resource "aws_security_group" "external" {
  name_prefix = "${var.name_prefix}-external-"
  description = "BIG-IP external interface — virtual server traffic"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-external-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "external_https" {
  security_group_id = aws_security_group.external.id
  description       = "HTTPS for virtual servers"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "external_http" {
  security_group_id = aws_security_group.external.id
  description       = "HTTP for virtual servers"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "external_all" {
  security_group_id = aws_security_group.external.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Internal (server-facing) ---
resource "aws_security_group" "internal" {
  name_prefix = "${var.name_prefix}-internal-"
  description = "BIG-IP internal interface — pool member traffic"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-internal-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "internal_vpc" {
  security_group_id = aws_security_group.internal.id
  description       = "All traffic from VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "internal_all" {
  security_group_id = aws_security_group.internal.id
  description       = "All outbound to pool members"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
