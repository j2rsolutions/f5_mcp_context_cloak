terraform {
  required_version = ">= 1.5.0"

  required_providers {
    bigip = {
      source  = "F5Networks/bigip"
      version = ">= 1.22.0"
    }
  }
}

provider "bigip" {
  address  = var.bigip_mgmt_host
  port     = var.bigip_mgmt_port
  username = var.bigip_username
  password = var.bigip_password

  # TODO: Set to true if using self-signed certs on BIG-IP management
  # token_auth = true
}
