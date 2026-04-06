# Context Cloak

> Privacy-preserving MCP-assisted LLM workflows with F5 BIG-IP

**Status:** Lab / Proof of Concept

## Overview

Context Cloak demonstrates how to use **F5 BIG-IP TMOS v21** as a privacy enforcement point in an LLM pipeline. An **MCP server** retrieves sensitive customer records from Postgres. BIG-IP sits in the middle — it learns what PII exists by reading the structured MCP responses, then **substitutes real values with realistic fakes** before the prompt reaches the LLM. On the way back, it restores the originals. The LLM never knows it's working with fake data.

Think of it like [James Veitch messing with email scammers](https://www.ted.com/talks/james_veitch_this_is_what_happens_when_you_reply_to_spam_email) — swap "bank account" for "candy" and the conversation works perfectly, but the scammer never gets the real information. Same principle: swap "John Doe" for "Maria Garcia" and the LLM generates a perfect financial report, but it never sees the real customer.

| Component | Role | Provided By |
|---|---|---|
| **Open WebUI** | Chat UI and MCP orchestration | Pre-existing |
| **BIG-IP TMOS v21** | MCP session routing + PII substitution | This repo (Terraform + iRules) |
| **MCP Server** | Financial data tools via JSON-RPC 2.0 | This repo (Python + Kubernetes) |
| **Postgres** | Customer, account, and transaction data | This repo (Kubernetes) |
| **vLLM** | LLM inference (Qwen 2.5 7B Instruct) | Pre-existing |

## Why Substitution, Not Masking

There are three ways to hide PII from an LLM. We use the third:

| Approach | Example | Problem |
|---|---|---|
| **Masking** | `Report for **** with SSN ***-**-****` | LLM can't reason about data it can't see |
| **Tokenization** | `Report for <<NAME:001>> with SSN <<SSN:002>>` | LLM knows it's fake, hallucinates or refuses |
| **Substitution** | `Report for Maria Garcia with SSN 523-50-6675` | LLM thinks it's real, behaves naturally |

Substitution is a **cipher** — every real value maps to a consistent fake within the session, and the mapping is reversed transparently. The LLM's behavior is identical to processing real data because the data *looks* real.

See [docs/architecture.md](docs/architecture.md) for the full design rationale.

## Architecture

```
User → Open WebUI → BIG-IP MCP VS → MCP Server → Postgres
                         |
                    Builds cloaking table
                    (real ↔ fake mappings)
                    Passes real data through
                         |
       Open WebUI → BIG-IP Inference VS → vLLM
                         |                    |
                    Cloaks request         Sees only
                    (real → fake)          fake PII
                         |                    |
                    Decloaks response      Generates
                    (fake → real)          with fakes
                         |
                    User sees real data
```

## Data Flow

1. **User asks** "Look up John Doe and show his transactions" in Open WebUI
2. **Open WebUI** calls MCP tools through the BIG-IP MCP virtual server
3. **BIG-IP MCP VS** forwards to the MCP server and receives the response
4. **BIG-IP scans the response** — extracts PII from known JSON fields (`full_name`, `ssn`, `account_number`, etc.), generates deterministic fakes, stores bidirectional mappings in a session-keyed subtable. **Response passes through unmodified** so tool chaining works.
5. **Open WebUI** receives real data, chains tool calls, composes a prompt
6. **Open WebUI** sends the prompt to vLLM through the BIG-IP Inference VS
7. **BIG-IP Inference VS** cloaks the request — `[string map]` swaps all real PII with fakes. vLLM sees "Maria Garcia" and "523-50-6675" instead of "John Doe" and "078-05-1120"
8. **vLLM generates** a response using fake data
9. **BIG-IP Inference VS** de-cloaks the response — swaps fakes back to reals
10. **User sees** the final report with real data restored

## MCP Tools

The MCP server exposes four tools for financial data access:

| Tool | Description | Lookup |
|---|---|---|
| `find_customer(query)` | Customer profile (no SSN) | By name, SSN, or account number |
| `get_customer_ssn(query)` | SSN only (sensitive) | By name, SSN, or account number |
| `get_accounts(query)` | All accounts + balances | By name, SSN, or account number |
| `get_transactions(account_number, days)` | Transaction history with summary | By account number |

All tools support smart lookup — pass a name ("John Doe"), SSN ("078-05-1120"), or account number ("4532-1189-0042") and it figures out which one.

## Cloaking Details

### What gets cloaked

| PII Type | Fake Generation | Example |
|---|---|---|
| Name | Pick from 10x10 fake name pool | John Doe → Maria Garcia |
| SSN | Shift digits by +5 mod 10 | 078-05-1120 → 523-50-6675 |
| Phone | Shift digits by +4 mod 10 | 217-555-0142 → 651-999-4586 |
| Email | Hash-picked name @example.net | john@email.com → maria.garcia@example.net |
| Account # | Shift digits by +3 mod 10 | 4532-1189-0042 → 7865-4412-3375 |

### What doesn't get cloaked

Dollar amounts, transaction descriptions, dates, merchant names, and other non-identifying fields pass through unchanged — they don't identify a person.

### Session consistency

The cloaking table is keyed by session ID. Within a session, "John Doe" always maps to "Maria Garcia". Across tool calls, account lookups, and transaction queries — the same fake identity is used consistently.

## Trust Boundaries

```
  Trusted (sees real PII)              Untrusted (sees only fakes)
 ┌──────────────────────┐             ┌─────────────────────┐
 │ MCP Server + Postgres│             │                     │
 │ Open WebUI           │  ◄─ BIG-IP ─►  vLLM / Qwen       │
 │ BIG-IP control plane │   cloak /   │  sees Maria Garcia  │
 └──────────────────────┘   decloak   │  not John Doe       │
                                      └─────────────────────┘
```

## Limitations & Security Caveats

> **This is a lab/POC.** Do not use in production without significant hardening.

- **LLM-derived values** — If the LLM computes values from cloaked inputs (e.g., mentions "Mr. Garcia" when only "Maria Garcia" was in the cloaking table), the partial reference won't be de-cloaked.
- **Streaming responses** — The inference VS requires `Content-Length` for de-cloaking. Chunked/streaming vLLM responses pass through un-modified.
- **Subtable TTL** — Cloaking entries expire after 1 hour. Long sessions may lose mappings.
- **Single BIG-IP** — HA pairs would need subtable synchronization.
- **Name pool size** — 10x10 = 100 unique name combinations. Sufficient for lab; extend for broader use.
- **No auth on MCP server** — In production, add mTLS or token-based auth.

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

# 4. Test MCP tools
./scripts/test-mcp.sh

# 5. Deploy to Kubernetes
kubectl apply -k kubernetes/overlays/lab/
```

### Deploy BIG-IP on AWS (BYOL)

```bash
cd terraform/aws-infra
cp terraform.tfvars.example terraform.tfvars
# Edit: BYOL license key, admin password
terraform init && terraform apply
# Wait ~10 min for onboarding, then license via GUI or tmsh

cd ../bigip
cp terraform.tfvars.example terraform.tfvars
# Edit: mgmt IP from aws-infra output, pool member IPs
terraform init && terraform apply
```

## Repository Structure

```
├── docs/                  # Architecture, design rationale, test plan
├── examples/              # Prompts and curl examples
├── irules/                # BIG-IP iRules (Tcl)
│   ├── mcp_session_persistence.tcl   # Session affinity + cloaking table builder
│   └── vllm_anonymization.tcl        # Request cloaking + response de-cloaking
├── kubernetes/
│   ├── base/              # Base Kustomize manifests
│   └── overlays/lab/      # Lab-specific overrides (ECR image, emptyDir, probes)
├── mcp-server/
│   ├── src/               # Python MCP server (FastMCP + psycopg)
│   └── sql/               # Schema and seed data (customers, accounts, transactions)
├── scripts/
│   ├── bootstrap.sh       # All-in-one local setup
│   └── test-mcp.sh        # MCP tool test suite
└── terraform/
    ├── aws-infra/         # AWS VPC + BIG-IP VE instance (BYOL, 3-NIC)
    └── bigip/             # BIG-IP application config (VS, pools, iRules)
```

## References

- [Managing MCP in iRules — Part 1](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-1/344321)
- [Managing MCP in iRules — Part 2](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-2/344421)
- [Managing MCP in iRules — Part 3](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-3/344423)
- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
- [James Veitch: This is what happens when you reply to spam email (TED)](https://www.ted.com/talks/james_veitch_this_is_what_happens_when_you_reply_to_spam_email)
