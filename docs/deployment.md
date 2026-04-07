# Deployment Guide

This guide covers deploying the full Context Cloak stack: BIG-IP infrastructure, Kubernetes workloads, iAppLX installation, and Open WebUI integration.

## Prerequisites

- AWS account with F5 BYOL Marketplace offer accepted
- F5 BIG-IP BYOL license key
- Kubernetes cluster (RKE2 or similar) with GPU nodes for vLLM
- Container registry (ECR, Harbor, etc.)
- Open WebUI instance
- vLLM inference endpoint (Qwen 2.5 7B Instruct recommended for tool calling)
- Terraform, kubectl, Docker CLI

## Step 1: Deploy BIG-IP on AWS

```bash
cd terraform/aws-infra
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
bigip_license_key = "YOUR-BYOL-KEY"
admin_password    = "your-strong-password"
allowed_mgmt_cidrs = ["0.0.0.0/0"]  # Restrict in production
```

```bash
terraform init
terraform plan
terraform apply
```

This creates:
- VPC with management, external, and internal subnets
- BIG-IP VE (m5.xlarge, 3-NIC) with EIPs
- Security groups for management and traffic
- Secrets Manager for admin password

**Wait ~10 minutes** for BIG-IP onboarding (runtime-init + Declarative Onboarding).

### Post-Deploy: License and Network

The DO declaration may not apply the license or admin password reliably. Verify manually:

```bash
# Get SSH key
terraform output -raw ssh_private_key > /tmp/bigip_key.pem
chmod 600 /tmp/bigip_key.pem

# SSH in and check
ssh -i /tmp/bigip_key.pem admin@$(terraform output -raw bigip_mgmt_public_ip)

# If license didn't apply:
install sys license registration-key YOUR-BYOL-KEY

# If password didn't apply:
modify auth user admin password YOUR-PASSWORD
modify auth user admin shell bash

# Configure networking (if DO didn't):
create net vlan external interfaces add { 1.1 { untagged } }
create net vlan internal interfaces add { 1.2 { untagged } }
create net self external_self address 10.0.1.200/24 vlan external allow-service add { tcp:443 tcp:80 }
create net self internal_self address 10.0.2.200/24 vlan internal allow-service default
create net route default_gw gw 10.0.1.1 network default
save sys config
```

### Key Outputs

| Output | Description |
|---|---|
| `bigip_mgmt_public_ip` | Management UI/API (HTTPS) |
| `bigip_vip_public_ips.vip_0` | MCP VIP EIP |
| `bigip_vip_public_ips.vip_1` | Inference VIP EIP |

## Step 2: Deploy MCP Server on Kubernetes

### Build and Push Container Image

```bash
cd mcp-server

# Build for linux/amd64
docker build --platform linux/amd64 -t <registry>/context-cloak-mcp-server:latest .

# Push to registry
docker push <registry>/context-cloak-mcp-server:latest
```

### Create ECR Pull Secret (if using ECR)

```bash
aws ecr get-login-password --region us-east-1 | \
  kubectl create secret docker-registry ecr-pull-secret \
    --docker-server=<account>.dkr.ecr.us-east-1.amazonaws.com \
    --docker-username=AWS \
    --docker-password-stdin \
    -n context-cloak
```

### Update Lab Overlay

Edit `kubernetes/overlays/lab/kustomization.yaml`:
```yaml
images:
  - name: context-cloak-mcp-server
    newName: <registry>/context-cloak-mcp-server
    newTag: latest
```

### Deploy

```bash
kubectl apply -k kubernetes/overlays/lab/
```

This creates:
- `context-cloak` namespace
- Postgres deployment with emptyDir storage
- MCP server deployment (1 replica)
- Database seed job (schema + sample data)
- Services, configmaps, secrets, network policies

### Verify

```bash
kubectl get pods -n context-cloak
# Should show: postgres (Running), mcp-server (Running), db-seed (Completed)

# Test MCP server
./scripts/test-mcp.sh
```

### Create Ingress for MCP Server

The BIG-IP needs a routable endpoint to reach the MCP server. Create an ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mcp-server-ingress
  namespace: context-cloak
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: mcp.your-domain.com
    http:
      paths:
      - backend:
          service:
            name: mcp-server
            port:
              number: 8080
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - mcp.your-domain.com
    secretName: mcp-tls
```

Create a DNS record pointing `mcp.your-domain.com` to your ingress controller's IP.

## Step 3: Install iAppLX on BIG-IP

### Build the RPM

On the BIG-IP, use the built-in package builder:

```bash
# SCP the iAppLX files to BIG-IP
scp -r iapplx/ admin@<bigip-mgmt>:/var/config/rest/iapps/f5-context-cloak/

# SSH in and build
ssh admin@<bigip-mgmt>

# Build RPM
curl -sk -u admin:<password> \
  -X POST http://localhost:8100/mgmt/shared/iapp/build-package \
  -H "Content-Type: application/json" \
  -d '{"appName":"f5-context-cloak","packageVersion":"0.1.0","packageRelease":"0001","srcBasePath":"/var/config/rest/iapps/f5-context-cloak/"}'
```

### Install the RPM

```bash
# Upload via REST API
FILESIZE=$(stat -c%s /var/config/rest/iapps/RPMS/f5-context-cloak-0.1.0-0001.noarch.rpm)
curl -sk -u admin:<password> \
  -X POST "https://<bigip-mgmt>/mgmt/shared/file-transfer/uploads/f5-context-cloak.rpm" \
  -H "Content-Type: application/octet-stream" \
  -H "Content-Range: 0-$((FILESIZE-1))/$FILESIZE" \
  --data-binary @/var/config/rest/iapps/RPMS/f5-context-cloak-0.1.0-0001.noarch.rpm

# Install via package management
curl -sk -u admin:<password> \
  -X POST "https://<bigip-mgmt>/mgmt/shared/iapp/package-management-tasks" \
  -H "Content-Type: application/json" \
  -d '{"operation":"INSTALL","packageFilePath":"/var/config/rest/downloads/f5-context-cloak.rpm"}'
```

### Verify Installation

```bash
# Check REST API
curl -sk -u admin:<password> https://<bigip-mgmt>/mgmt/shared/context-cloak

# Access GUI
# Navigate to: https://<bigip-mgmt>/iapps/f5-context-cloak/index.html
```

## Step 4: Configure and Deploy via GUI

1. Open `https://<bigip-mgmt>/iapps/f5-context-cloak/index.html`
2. Fill in **MCP Server** config:
   - VS IP: secondary IP on external interface (e.g., `10.0.1.100`)
   - Port: `443`
   - Pool Member: ingress controller IP
   - Pool Port: `443`
   - Host Header: `mcp.your-domain.com`
3. Fill in **LLM Endpoint**:
   - Name: descriptive name (e.g., `qwen`)
   - Hostname: vLLM ingress hostname
   - VS IP: another secondary IP (e.g., `10.0.1.101`)
   - Pool Member: ingress controller IP
   - Pool Port: `443`
4. Configure **PII Fields** -- select which fields to cloak and their mode
5. Click **Deploy**
6. Check the output log at the bottom for OK/FAIL status

## Step 5: Configure Open WebUI

### Point MCP Tool Server at BIG-IP

In Open WebUI Admin > Settings > Tool Servers, add:
- **URL:** `https://<mcp-vip-eip>/mcp`
- **Type:** `mcp`
- **Auth:** `none`

### Point Inference at BIG-IP

Update the OpenAI API base URL to route through the BIG-IP Inference VS. This can be done via environment variable or the Open WebUI database:

```bash
kubectl set env deployment/open-webui \
  OPENAI_API_BASE_URLS="https://<inference-vip-eip>/v1" \
  OPENAI_API_KEYS="<vllm-api-key>" \
  AIOHTTP_CLIENT_SESSION_SSL=False \
  AIOHTTP_CLIENT_SESSION_TOOL_SERVER_SSL=False
```

**Note:** The SSL settings disable certificate verification for the BIG-IP's self-signed certificate. In production, use proper certificates.

**Note:** Open WebUI's SQLite database may override environment variables. If the model doesn't appear, patch the database directly:

```bash
kubectl exec deploy/open-webui -- python3 -c "
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute('SELECT data FROM config WHERE id=1')
data = json.loads(cur.fetchone()[0])
data['openai']['api_base_urls'] = ['https://<inference-vip-eip>/v1']
data['openai']['api_keys'] = ['<vllm-api-key>']
cur.execute('UPDATE config SET data=? WHERE id=1', (json.dumps(data),))
conn.commit()
"
```

## Step 6: Test

1. Open WebUI, start a new chat
2. Select the LLM model (e.g., Qwen/Qwen2.5-7B-Instruct)
3. Enable MCP tools (click + or wrench icon)
4. Send: *"Get the transactions for account number 4532-1189-0042 for the last 30 days"*
5. Monitor BIG-IP logs: `tail -f /var/log/ltm | grep -iE 'Cloak|Decloak|CloakTable'`

Expected log output:
```
CloakTable: full_name (substitute) (session=...)
CloakTable: account_number (substitute) (session=...)
CloakTable: scan complete (session=...)
Cloak: request cloaked (N values, session=...)
Decloak: response de-cloaked (N values, session=...)
```

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| MCP tool calls fail | MCP VS not reachable | Check pool member health, host header, SSL profile |
| "No cloaking table" in logs | Session ID mismatch between MCP and Inference VS | Both must see same client IP; check SNAT settings |
| Cloaking table empty | Chunked response not collected | Verify HTTP profile has `response-chunking rechunk` |
| Model not appearing in Open WebUI | DB overrides env vars | Patch SQLite database directly |
| SSL errors from Open WebUI | Self-signed BIG-IP cert | Set `AIOHTTP_CLIENT_SESSION_SSL=False` |
| iAppLX worker not loading | Wrong file structure | Worker must be `nodejs/restWorker.js`, libs in `../lib/` |
