# Context Cloak — Project Guide

## What this is
A proof-of-concept lab demonstrating privacy-preserving MCP-assisted LLM workflows.
BIG-IP TMOS v21 acts as the policy/tokenization control point between Open WebUI and vLLM,
with an MCP server backed by Postgres running on Kubernetes (RKE2).

## Key directories
- `mcp-server/` — Python MCP server (FastMCP) with Postgres backend
- `irules/` — BIG-IP iRules for MCP session persistence and anonymization
- `terraform/aws-infra/` — Terraform for AWS VPC + BIG-IP VE instance (BYOL, 3-NIC)
- `terraform/bigip/` — Terraform for BIG-IP application config (VS, pools, profiles, iRules)
- `kubernetes/` — Kustomize manifests (base + lab overlay)
- `docs/` — Architecture diagrams and test plan
- `examples/` — Prompts and curl examples
- `scripts/` — Bootstrap and helper scripts

## Conventions
- All BIG-IP iRules use Tcl syntax targeting TMOS v21+
- `terraform/aws-infra/` uses hashicorp/aws provider; `terraform/bigip/` uses F5Networks/bigip provider
- Kubernetes manifests use Kustomize (no Helm)
- Python code targets 3.11+
- SQL migrations are numbered sequentially in `mcp-server/sql/`

## Running locally
```bash
make setup        # create venv, install deps
make db-up        # start local Postgres via Docker
make db-init      # run schema + seed SQL
make mcp-server   # run MCP server locally
```

## Common tasks
- Adding a new MCP tool: edit `mcp-server/src/tools.py`, register in `server.py`
- Modifying seed data: edit `mcp-server/sql/002_seed_data.sql`
- Updating BIG-IP config: edit terraform under `terraform/bigip/`
- Deploying BIG-IP on AWS: edit terraform under `terraform/aws-infra/`
- AWS infra uses f5-bigip-runtime-init with Declarative Onboarding for BYOL licensing
