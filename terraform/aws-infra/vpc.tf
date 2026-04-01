# =============================================================================
# VPC and Networking
# Single-AZ lab deployment with 3 subnets (mgmt, external, internal)
# =============================================================================

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# --- Internet Gateway ---

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# --- Subnets ---

resource "aws_subnet" "mgmt" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.mgmt_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.name_prefix}-mgmt"
  }
}

resource "aws_subnet" "external" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.external_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.name_prefix}-external"
  }
}

resource "aws_subnet" "internal" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.internal_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.name_prefix}-internal"
  }
}

# --- Route Tables ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "mgmt" {
  subnet_id      = aws_subnet.mgmt.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "external" {
  subnet_id      = aws_subnet.external.id
  route_table_id = aws_route_table.public.id
}

# Internal subnet uses the VPC default route table (no internet route).
# If internal pool members need outbound access, add a NAT gateway.
