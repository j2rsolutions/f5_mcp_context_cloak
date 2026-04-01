# Context Cloak

> Privacy-preserving MCP-assisted LLM workflows with F5 BIG-IP

**Status:** Lab / Proof of Concept

## Overview

Context Cloak demonstrates how to use **F5 BIG-IP TMOS v21** as a policy and tokenization control point in an LLM pipeline. An **MCP server** retrieves sensitive customer records from Postgres, while BIG-IP ensures that personally identifiable information (PII) never reaches the inference engine in cleartext.

The architecture uses:

| Component | Role | Provided By |
|---|---|---|
| **Open WebUI** | Chat UI and MCP orchestration | Pre-existing |
| **BIG-IP TMOS v21** | MCP session routing + PII anonymization | This repo (Terraform + iRules) — deploy to AWS or configure existing |
| **MCP Server** | Exposes customer data tools via JSON-RPC 2.0 | This repo (Python + Kubernetes) |
| **Postgres** | Customer and financial data backend | This repo (Kubernetes) |
| **vLLM** | LLM inference endpoint | Pre-existing |

## Architecture

```
┌──────────┐     ┌──────────────┐     ┌────────────────┐     ┌────────────┐     ┌──────────┐
│          │     │              │     │                │     │            │     │          │
│  User    ├────►│  Open WebUI  ├────►│  BIG-IP        ├────►│ MCP Server ├────►│ Postgres │
│          │     │              │     │  (MCP VS)      │     │            │     │          │
└──────────┘     │              │     └────────────────┘     └────────────┘     └──────────┘
                 │              │
                 │              │     ┌────────────────┐     ┌──────────┐
                 │              ├────►│  BIG-IP        ├────►│  vLLM    │
                 │              │     │  (Inference VS)│     │          │
                 └──────────────┘     └────────────────┘     └──────────┘
```

See [docs/architecture.md](docs/architecture.md) for detailed Mermaid diagrams.

## Data Flow

1. **User asks a question** in Open WebUI (e.g., "Generate a financial report for John Doe")
2. **Open WebUI invokes MCP tools** to retrieve customer data — routed through the BIG-IP MCP virtual server
3. **BIG-IP preserves MCP session affinity** using `Mcp-Session-Id` header enrichment and pool member pinning
4. **MCP server returns sensitive data** (SSN, account numbers, balances) to Open WebUI
5. **Open WebUI composes a prompt** containing the retrieved data and sends it toward vLLM
6. **BIG-IP Inference VS intercepts the prompt**, detects sensitive values, replaces them with deterministic placeholders (e.g., `<<SSN:sid123:001>>`), and stores the mapping in a session-keyed subtable
7. **vLLM generates a response** using placeholders — it never sees real PII
8. **BIG-IP intercepts the response**, restores original values from the mapping table
9. **User receives the final response** with real data intact

## Trust Boundaries

```
  Trusted (internal)                    Untrusted (inference)
 ┌──────────────────────┐             ┌─────────────────────┐
 │ Open WebUI           │             │                     │
 │ MCP Server           │  ◄─ BIG-IP ─►  vLLM              │
 │ Postgres             │   anonymize │                     │
 └──────────────────────┘   /restore  └─────────────────────┘
```

- **Trusted zone:** Open WebUI, MCP server, Postgres, and the BIG-IP control plane all handle cleartext PII
- **Untrusted zone:** vLLM only ever sees anonymized placeholders
- **BIG-IP is the enforcement boundary** — it tokenizes outbound and de-tokenizes inbound

## Anonymization & Reverse Substitution

### How it works

**Outbound (request to vLLM):**
- The BIG-IP iRule on the Inference VS scans JSON request bodies for patterns matching known PII formats (SSN, account numbers, etc.)
- Each detected value is replaced with a placeholder: `<<TYPE:SESSION_ID:SEQUENCE>>`
- The mapping `placeholder → original_value` is stored in a BIG-IP subtable keyed by a correlation ID

**Inbound (response from vLLM):**
- The iRule scans the response body for placeholder patterns
- Each placeholder is looked up in the subtable and replaced with the original value
- The subtable entry is cleaned up after use (TTL-based expiry as a safety net)

### Placeholder format

```
<<SSN:a1b2c3:001>>        — Social Security Number
<<ACCT:a1b2c3:002>>       — Account number
<<NAME:a1b2c3:003>>       — Person name
<<BAL:a1b2c3:004>>        — Financial balance
```

The session ID portion ensures uniqueness across concurrent requests. The sequence number ensures uniqueness within a single request.

## What This Repo Deploys vs. What You Provide

### You provide (pre-existing)
- Kubernetes cluster (RKE2) with storage and networking
- Open WebUI instance configured with MCP support
- vLLM inference endpoint
- **Either:** an existing BIG-IP TMOS v21 appliance, **or** an AWS account + F5 BYOL license key
- Network connectivity between all components

### This repo deploys
- MCP server (Python) on Kubernetes
- Postgres database on Kubernetes
- **Option A — AWS:** Full BIG-IP VE infrastructure on AWS (VPC, 3-NIC EC2, security groups, EIPs) via `terraform/aws-infra/`
- **Option B — Existing BIG-IP:** Configuration only (virtual servers, pools, profiles, iRules) via `terraform/bigip/`
- Sample customer data for testing

## Limitations & Security Caveats

> **This is a lab/POC.** Do not use in production without significant hardening.

- **Pattern-based detection is fragile.** The iRule uses regex to find PII. It will miss values that don't match expected patterns and may false-positive on non-PII data that happens to look like an SSN.
- **Payload size limits.** BIG-IP JSON and SSE profiles have configurable max sizes (default 64KB). Large MCP responses or LLM outputs may be truncated or bypass inspection.
- **Streaming responses.** SSE/streaming responses from vLLM are handled on a per-event basis. Placeholders split across SSE chunks will not be restored correctly. For this POC, non-streaming inference is recommended.
- **Subtable TTL.** Mapping entries expire after a configurable TTL. Long-running conversations may lose mappings if the TTL is too short.
- **No encryption of mapping data.** The BIG-IP subtable stores cleartext PII in memory. This is acceptable for a lab but should be evaluated for production.
- **Single BIG-IP.** This POC assumes a standalone BIG-IP. HA pairs would need subtable synchronization or an external mapping store.
- **No auth on MCP server.** The MCP server does not enforce authentication. In production, mTLS or token-based auth should be added.

## Quick Start

```bash
# 1. Clone and setup
git clone <this-repo>
cd f5_mcp_context_cloak
make setup

# 2. Start local Postgres and seed data
make db-up
make db-init

# 3. Run MCP server locally
make mcp-server

# 4. Deploy to Kubernetes
kubectl apply -k kubernetes/overlays/lab/
```

### Option A: Deploy BIG-IP on AWS (BYOL)

```bash
cd terraform/aws-infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set your BYOL license key, admin password, mgmt CIDRs
terraform init
terraform plan
terraform apply

# Note the outputs — bigip_mgmt_url, bigip_vip_public_ips, etc.
# Wait ~10 minutes for BIG-IP to finish onboarding (runtime-init + DO licensing)

# Then configure the BIG-IP with VS, pools, iRules:
cd ../bigip
cp terraform.tfvars.example terraform.tfvars
# Set bigip_mgmt_host to the mgmt EIP from aws-infra output
# Set mcp_vs_ip / vllm_vs_ip to the secondary IPs from aws-infra output
terraform init
terraform plan
terraform apply
```

### Option B: Configure an existing BIG-IP

```bash
cd terraform/bigip
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your BIG-IP management IP and pool member addresses
terraform init
terraform plan
terraform apply
```

> **AWS prerequisite:** You must accept the [F5 BIG-IP BYOL Marketplace offer](https://aws.amazon.com/marketplace/pp/prodview-73utu5c5sfyyc) before Terraform can launch the AMI.

## Repository Structure

```
├── docs/                  # Architecture diagrams and test plan
├── examples/              # Prompts and curl examples
├── irules/                # BIG-IP iRules (Tcl)
├── kubernetes/
│   ├── base/              # Base Kustomize manifests
│   └── overlays/lab/      # Lab-specific overrides
├── mcp-server/
│   ├── src/               # Python MCP server source
│   └── sql/               # Schema and seed data
├── scripts/               # Bootstrap and helper scripts
└── terraform/
    ├── aws-infra/         # AWS VPC + BIG-IP VE instance (BYOL)
    └── bigip/             # BIG-IP application config (VS, pools, iRules)
```

## References

- [Managing MCP in iRules — Part 1](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-1/344321)
- [Managing MCP in iRules — Part 2](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-2/344421)
- [Managing MCP in iRules — Part 3](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-3/344423)
- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
