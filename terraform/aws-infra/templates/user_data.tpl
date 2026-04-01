#!/bin/bash

# =============================================================================
# BIG-IP Runtime Init — BYOL Onboarding
# This script runs on first boot to:
#   1. Install f5-bigip-runtime-init
#   2. Apply Declarative Onboarding (license, network, provisioning)
# =============================================================================

mkdir -p /config/cloud /var/log/cloud

cat << 'RUNTIME_CONFIG' > /config/cloud/runtime-init-conf.yaml
---
controls:
  logLevel: info
  logFilename: /var/log/cloud/bigIpRuntimeInit.log

runtime_parameters:
  - name: ADMIN_PASS
    type: secret
    secretProvider:
      environment: aws
      type: SecretsManager
      secretId: ${secret_id}
      version: AWSCURRENT

pre_onboard_enabled: []

extension_packages:
  install_operations:
    - extensionType: do
      extensionVersion: ${do_version}
    - extensionType: as3
      extensionVersion: ${as3_version}

extension_services:
  service_operations:
    - extensionType: do
      type: inline
      value:
        schemaVersion: 1.0.0
        class: Device
        async: true
        label: "Context Cloak BIG-IP Onboarding"
        Common:
          class: Tenant

          hostname: ${hostname}

          myLicense:
            class: License
            licenseType: regKey
            regKey: ${license_key}

          myProvisioning:
            class: Provision
            ltm: nominal

          admin:
            class: User
            userType: regular
            password: "{{{ADMIN_PASS}}}"
            shell: bash

          # Management route uses the default from DHCP.
          # Self IPs and VLANs for external/internal are configured
          # after the additional NICs are attached and recognized.

          external_vlan:
            class: VLAN
            interfaces:
              - name: "1.1"
                tagged: false
            mtu: 1500

          internal_vlan:
            class: VLAN
            interfaces:
              - name: "1.2"
                tagged: false
            mtu: 1500

          external_self:
            class: SelfIp
            address: "${external_self_ip}/24"
            vlan: external_vlan
            allowService:
              - tcp:443
              - tcp:80
            trafficGroup: traffic-group-local-only

          internal_self:
            class: SelfIp
            address: "${internal_self_ip}/24"
            vlan: internal_vlan
            allowService: default
            trafficGroup: traffic-group-local-only

          default_gw:
            class: Route
            gw: "${external_gateway}"
            network: default
            mtu: 1500

          myDbVariables:
            class: DbVariables
            ui.advisory.enabled: true
            ui.advisory.color: blue
            ui.advisory.text: "Context Cloak Lab — BIG-IP VE (AWS)"

post_onboard_enabled: []
RUNTIME_CONFIG

# --- Install f5-bigip-runtime-init ---
for i in $(seq 1 30); do
  curl -fvo /tmp/f5-bigip-runtime-init-${runtime_init_version}-1.gz.run \
    --retry 1 --retry-connrefused --retry-delay 5 \
    "https://cdn.f5.com/product/cloudsolutions/f5-bigip-runtime-init/v${runtime_init_version}/dist/f5-bigip-runtime-init-${runtime_init_version}-1.gz.run" && break
  sleep 10
done

bash /tmp/f5-bigip-runtime-init-${runtime_init_version}-1.gz.run -- '--cloud aws'

# --- Run onboarding ---
f5-bigip-runtime-init --config-file /config/cloud/runtime-init-conf.yaml
