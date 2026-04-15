# Architecture

## Design Philosophy

Context Cloak is built on three principles:

1. **The enforcement point should be the network, not the application.** MCP servers shouldn't need to know about cloaking. LLMs shouldn't need special prompts. BIG-IP sits in the data path and handles everything transparently.

2. **Extract from structure, substitute with exact matching.** PII is identified from structured MCP JSON responses (known field names), not from regex scanning arbitrary text. Substitution uses exact `[string map]` -- no pattern matching that might false-positive.

3. **The LLM should never know its data is fake.** Realistic substitution preserves the model's reasoning ability. Tokenization (`<<SSN:...>>`) is available as an option but is primarily for guardrails integration, not for natural LLM interaction.

## Why Substitution Over Masking or Tokenization

| Approach | Example | LLM sees | LLM behavior | User sees |
|---|---|---|---|---|
| **Masking** | `SSN: ****` | Nothing useful | Can't reason, generic output | Useless report |
| **Tokenization** | `SSN: <<SSN:001>>` | Placeholder | Knows it's fake, may hallucinate | Risk of leaked tokens |
| **Substitution** | `SSN: 523-50-6675` | Realistic fake | Reasons naturally, perfect output | Real data (de-cloaked) |

Substitution is a **cipher** -- structurally identical to the real data, consistently mapped within a session, and transparently reversed. The LLM's behavior is indistinguishable from processing real data because the data *looks* real.

## Data Flow

```
User asks question
    |
    v
Open WebUI ──► BIG-IP MCP VS ──► MCP Server ──► Postgres
                    |                                |
              Builds cloaking                   Returns real
              table from response               PII data
              (field-level extraction)              |
                    |                               |
              Passes response              ◄────────┘
              through UNMODIFIED
                    |
                    v
Open WebUI receives real data
Open WebUI chains tool calls (real data works)
Open WebUI composes prompt with real PII
    |
    v
Open WebUI ──► BIG-IP Inference VS ──► vLLM / Qwen
                    |                       |
              string map                Sees only
              real -> fake              fake PII
                    |                       |
              Prompt sent              Generates
              with fake PII            response with
                    |                  fake values
                    |                       |
              string map               ◄────┘
              fake -> real
                    |
                    v
              User sees real data
              in the final response
```

### Why MCP Responses Pass Through Unmodified

Earlier iterations cloaked the MCP response before it reached Open WebUI. This broke **tool chaining** -- when the LLM tried to call `get_accounts("Alice Johnson")` (the fake name), the MCP server returned "not found" because Alice Johnson doesn't exist in the database.

By passing real data through the MCP path and cloaking only at the inference boundary, tool chaining works naturally. Open WebUI has real data to work with, and BIG-IP swaps it at the last moment before the LLM sees it.

## Cloaking Table

The cloaking table is a BIG-IP **subtable** -- an in-memory key-value store scoped to a session, with configurable TTL (default 1 hour).

```
Subtable: cloak_<session_id>

  Key                          Value               Purpose
  ─────────────────────────    ──────────────────   ──────────────────────
  r2f_John Doe                 Maria Garcia         Request cloaking (real->fake)
  f2r_Maria Garcia             John Doe             Response de-cloaking (fake->real)
  r2f_078-05-1120              523-50-6675          SSN mapping
  f2r_523-50-6675              078-05-1120
  _real_list                   John Doe|078-05-1120  Index for request cloaking
  _fake_list                   Maria Garcia|523-...  Index for response de-cloaking
```

### Subtable TTL and Cache Behavior

Cloaking table entries persist for the configured TTL (default 1 hour). This means:

- **Changing a field's cloaking mode** (e.g., from tokenize to substitute) won't take effect for already-cached PII values until the old entries expire
- **The same customer** will get the same fake identity within a session — this is by design for consistency
- **To force a cache flush**, restart TMM on the BIG-IP: `bigstart restart tmm` (this drops all active connections briefly)
- **To avoid stale entries after config changes**, either wait for TTL expiry or restart TMM

A future enhancement could add a "Flush Cloaking Table" button to the iAppLX GUI.

### Session ID

Both the MCP VS and Inference VS derive the session ID the same way:
1. `X-Cloak-Session` header (if present)
2. Client IP address (fallback)

This ensures both virtual servers reference the same subtable.

### Fake Value Generation

| PII Type | Strategy | Example |
|---|---|---|
| Name | Hash-based pick from 10x10 name pool | John Doe -> Maria Garcia |
| SSN | Shift each digit by +5 mod 10 | 078-05-1120 -> 523-50-6675 |
| Phone | Shift each digit by +4 mod 10 | 217-555-0142 -> 651-999-4586 |
| Email | Hash-picked name @example.net | john@email.com -> maria.garcia@example.net |
| Account # | Shift each digit by +3 mod 10 | 4532-1189-0042 -> 7865-4412-3375 |

Dollar amounts, dates, descriptions, and other non-identifying fields are **not cloaked**.

## iRule Architecture

### MCP VS iRule (`mcp_session_persistence`)

| Event | What it does |
|---|---|
| `RULE_INIT` | Initialize config: TTL, prefix, fake name pools, data group reference |
| `HTTP_REQUEST` | MCP session persistence (Mcp-Session-Id parsing, pool pinning) |
| `HTTP_RESPONSE` | Mcp-Session-Id enrichment, SSE injection, body collection (rechunk) |
| `HTTP_RESPONSE_DATA` | **Cloaking table builder** -- iterates data group entries, matches fields in JSON, generates fakes, stores mappings. Does NOT modify the response. |

### Inference VS iRule (`vllm_anonymization`)

| Event | What it does |
|---|---|
| `RULE_INIT` | Initialize config: cloak prefix, tokenize prompt |
| `HTTP_REQUEST` | Detect inference paths, collect request body |
| `HTTP_REQUEST_DATA` | **Request cloaking** -- `[string map]` real->fake, optional tokenize prompt injection |
| `HTTP_RESPONSE` | Collect response body |
| `HTTP_RESPONSE_DATA` | **Response de-cloaking** -- `[string map]` fake->real |

### Data Group: `context_cloak_fields`

The iRules are **data-group-driven** -- no PII field names are hardcoded. The data group maps field names to cloaking modes:

```
ltm data-group internal context_cloak_fields {
    records {
        full_name     { data "substitute:name" }
        customer_name { data "substitute:name" }
        ssn           { data "tokenize:SSN" }
        account_number{ data "substitute:digit_shift:3" }
        phone         { data "substitute:phone:4" }
        email         { data "substitute:email" }
    }
}
```

Change the data group, the cloaking behavior changes instantly. The iAppLX GUI manages this automatically.

## iAppLX Architecture

```
f5-context-cloak/
├── nodejs/
│   └── restWorker.js          # REST API worker (config, deploy, undeploy)
├── lib/
│   ├── irule_generator.js     # Generates iRules from PII field config
│   └── bigip_client.js        # tmsh execution + file write via REST
├── presentation/
│   └── index.html             # Configuration web UI
└── package.json
```

### REST API

| Method | Body | Action |
|---|---|---|
| `GET /mgmt/shared/context-cloak` | -- | Return config + deployment state |
| `POST` | `{config: {...}}` | Save configuration |
| `POST` | `{action: "deploy"}` | Undeploy existing, then deploy all objects |
| `POST` | `{action: "undeploy"}` | Remove all Context Cloak objects |

### Deploy Sequence

1. Delete existing Context Cloak objects (idempotent)
2. Create data group from PII field config
3. Create HTTP profile with `rechunk`
4. Create client-ssl profile
5. Generate MCP + Inference iRules from config, write to files, merge via tmsh
6. Create MCP pool, server-ssl (with SNI), host header iRule, virtual server
7. Create LLM pool(s), server-ssl, host header iRule(s), virtual server(s)
8. Save config

## Network Topology (AWS)

```
┌─────────────────────────────────────────────────────────┐
│                    AWS VPC 10.0.0.0/16                   │
│                                                          │
│  Management Subnet 10.0.0.0/24                          │
│    eth0: 10.0.0.200 (EIP) -- SSH/HTTPS mgmt             │
│                                                          │
│  External Subnet 10.0.1.0/24                            │
│    eth1: 10.0.1.200 (EIP) -- Self IP                    │
│          10.0.1.100 (EIP) -- MCP VIP                    │
│          10.0.1.101 (EIP) -- Inference VIP              │
│                                                          │
│  Internal Subnet 10.0.2.0/24                            │
│    eth2: 10.0.2.200 -- Pool member traffic              │
│                                                          │
│  Routes: mgmt + external via IGW, internal isolated     │
└─────────────────────────────────────────────────────────┘
```

## MCP Server Architecture

```
mcp-server/
├── src/
│   ├── server.py      # FastMCP entry point, tool registration
│   ├── tools.py       # Tool implementations with smart customer lookup
│   ├── db.py          # Postgres access layer (psycopg 3)
│   └── config.py      # Environment-based configuration
└── sql/
    ├── 001_schema.sql  # customers, financial_accounts, transactions, audit_log
    └── 002_seed_data.sql  # 5 customers, 13 accounts, 51 transactions
```

### Tools

| Tool | Input | Output | PII Fields |
|---|---|---|---|
| `find_customer` | name, SSN, or account # | Customer profile (no SSN) | full_name, phone, email |
| `get_customer_ssn` | name, SSN, or account # | SSN only | customer_name, ssn |
| `get_accounts` | name, SSN, or account # | All accounts + balances | customer_name, account_number |
| `get_transactions` | account #, days | Transaction history + summary | customer_name, account_number |

All tools support **smart lookup** -- pass a name, SSN, or account number and the resolver figures out which one based on format.

## Guardrails Mode (F5 AI Guardrails Integration)

Context Cloak ships with an optional **Guardrails Mode** that inserts F5 AI Guardrails between the Inference VS and vLLM. This closes the "first prompt" gap that cloaking alone cannot cover — PII the analyst types directly before any MCP lookup has populated the cloaking table.

### Topology in Guardrails Mode

```
Open WebUI
    │ POST /v1/chat/completions
    ▼
BIG-IP Inference VS            (1) real -> token substitution
    │                              (pre-existing cloak table only)
    ▼
F5 AI Guardrails  (k8s)         (2) inspect last user message
    │                              block on raw PII patterns
    │                              redact leaked <<TYPE:ID:SEQ>>
    ▼
vLLM (Qwen)                    (3) sees only tokens
```

The BIG-IP Inference VS pool member address is the Guardrails K8s Service (`ai-guardrails.guardrails.svc.cluster.local:8000`). Guardrails forwards cleared requests to the upstream vLLM service defined in its policy.

### Why tokenize, not substitute, in Guardrails Mode

Substitution produces realistic fakes (fake SSN `523-50-6675`, fake account `7865-4412-3375`). Those values still match Guardrails' PII regex patterns — Guardrails would block the cloaked request. Tokenization emits `<<SSN:10.0.1.50:001>>`, which does not match any PII pattern and passes through cleanly.

When Guardrails Mode is enabled in the iAppLX UI:

1. The worker's `normalizeConfigForDeploy` force-rewrites every non-disabled `pii_fields[].cloak_mode` to `tokenize` before the data group is built.
2. The iRule generator's `hasTokenize` branch is forced on, so the tokenize guidance system prompt is always injected into the messages array.
3. Per-field mode selectors in the UI are locked and visually disabled; a banner explains why.

The original config on disk is not mutated — users can toggle Guardrails Mode off and their per-field modes are intact.

### What each layer protects

| Layer | Protects against | Does not protect |
|---|---|---|
| **BIG-IP Inference VS (cloaking)** | Backend-sourced PII (MCP responses): SSN, account #, phone, email, full name | User-typed PII in the first prompt (no mapping yet) |
| **F5 AI Guardrails (inbound)** | User-typed high-sensitivity PII: SSN, account #, phone, email, credit card | Names (required as lookup keys); transaction amounts; dates |
| **F5 AI Guardrails (outbound)** | Leaked `<<TYPE:ID:SEQ>>` tokens (de-cloak mismatch or LLM hallucination) | Semantic leakage of tokenized content |

See [`docs/guardrails-integration.md`](guardrails-integration.md) for the full deployment guide, threat model, and an honest list of what Context Cloak does not protect (quasi-identifiers, trajectories, time series).

### The three-layer defense

1. **Guardrails (inbound)** — the user can't accidentally paste regulated PII
2. **BIG-IP cloaking** — backend-sourced PII is tokenized before reaching the LLM
3. **Guardrails (outbound)** — any leaked token is redacted before the analyst sees it

Each layer compensates for what the others can't see.
