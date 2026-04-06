# Context Cloak -- Project Guide

## What this is
A proof-of-concept lab demonstrating privacy-preserving MCP-assisted LLM workflows.
BIG-IP TMOS v21 acts as the PII substitution enforcement point between Open WebUI and vLLM (Qwen 2.5 7B),
with an MCP server backed by Postgres running on Kubernetes (RKE2).

The approach uses **value substitution** (not masking or tokenization) -- real PII is swapped with
realistic fakes so the LLM reasons naturally, then the fakes are swapped back in the response.

## Architecture (current state)
- **MCP VS** (18.210.135.91:443): Session persistence + cloaking table builder. Scans MCP responses
  for PII fields, generates fakes, stores mappings in BIG-IP subtable. Response passes through unmodified.
- **Inference VS** (52.3.24.169:443): Cloaks inference requests (real->fake) and decloaks responses
  (fake->real) using the cloaking table built by the MCP VS.
- **MCP Server**: FastMCP 1.26, streamable HTTP, 4 tools (find_customer, get_customer_ssn, get_accounts,
  get_transactions). Smart lookup by name, SSN, or account number.
- **Open WebUI**: Connects to MCP via BIG-IP MCP VS, sends inference via BIG-IP Inference VS.
- **HTTP profile**: Uses `response-chunking rechunk` to de-chunk SSE responses for body collection.

## Key directories
- `mcp-server/` -- Python MCP server (FastMCP) with Postgres backend
- `irules/` -- BIG-IP iRules: `mcp_session_persistence.tcl` (table builder) + `vllm_anonymization.tcl` (cloak/decloak)
- `terraform/aws-infra/` -- Terraform for AWS VPC + BIG-IP VE instance (BYOL, 3-NIC)
- `terraform/bigip/` -- Terraform for BIG-IP application config (VS, pools, profiles, iRules)
- `kubernetes/` -- Kustomize manifests (base + lab overlay)
- `docs/` -- Architecture diagrams, design rationale, test plan
- `scripts/` -- Bootstrap, helper scripts, test-mcp.sh

## Conventions
- All BIG-IP iRules use Tcl syntax targeting TMOS v21+
- iRule comments must be ASCII only (no em-dashes) -- Tcl verifier rejects UTF-8
- iRule static variables must be in `when RULE_INIT {}` block, not top-level `set`
- `terraform/aws-infra/` uses hashicorp/aws provider; `terraform/bigip/` uses F5Networks/bigip provider
- Kubernetes manifests use Kustomize (no Helm)
- Python code targets 3.11+
- SQL migrations are numbered sequentially in `mcp-server/sql/`
- Management security groups use 0.0.0.0/0 for lab (user preference)
- MCP server image is on ECR: 081006927100.dkr.ecr.us-east-1.amazonaws.com/context-cloak-mcp-server

## Running locally
```bash
make setup        # create venv, install deps
make db-up        # start local Postgres via Docker
make db-init      # run schema + seed SQL
make mcp-server   # run MCP server locally
```

## Testing
```bash
./scripts/test-mcp.sh                      # auto port-forward to k8s
./scripts/test-mcp.sh http://localhost:8080 # direct URL
```

## Common tasks
- Adding a new MCP tool: edit `mcp-server/src/tools.py`, register in `server.py`
- Adding a PII type to cloak: add extraction block in `irules/mcp_session_persistence.tcl` HTTP_RESPONSE_DATA
- Modifying seed data: edit `mcp-server/sql/002_seed_data.sql` AND `kubernetes/base/seed-job.yaml` (embedded SQL)
- Updating BIG-IP iRules: edit irules/, strip comments, SCP to BIG-IP, load via `tmsh load sys config merge`
- Rebuilding MCP server image: `docker build --platform linux/amd64 -t <ecr-uri>:<tag>` from mcp-server/
- Deploying BIG-IP on AWS: edit terraform under `terraform/aws-infra/`
- AWS infra uses f5-bigip-runtime-init with Declarative Onboarding for BYOL licensing

## Known issues
- BIG-IP DO (Declarative Onboarding) does not reliably set the admin password from Secrets Manager -- set manually via tmsh
- FastMCP 1.26 changed API: `host`/`port` are constructor args, not `run()` args; `description` kwarg removed
- Open WebUI stores config in SQLite DB that overrides env vars -- patch DB directly for OpenAI API config changes
- iRule `HTTP::collect` on chunked SSE responses requires `response-chunking rechunk` on the HTTP profile
