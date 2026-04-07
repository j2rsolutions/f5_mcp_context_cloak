# Context Cloak

> Privacy-preserving PII cloaking for MCP-assisted LLM workflows, powered by F5 BIG-IP

**Status:** Lab / Proof of Concept

---

## The Story

As I dove deeper into the world of AI -- MCP servers, LLM orchestration, tool-calling models, agentic workflows -- one question kept nagging me: **how do you use the power of LLMs to process sensitive data without actually exposing that data to the model?**

Banks, healthcare providers, government agencies -- they all want to leverage AI for report generation, customer analysis, and workflow automation. But the data they need to process is full of PII: Social Security Numbers, account numbers, names, phone numbers. Sending that to an LLM (whether cloud-hosted or self-hosted) creates a security and compliance risk that most organizations can't accept.

I've spent years working with F5 technology, and when I learned that **BIG-IP TMOS v21 added native support for the MCP protocol**, the lightbulb went on. BIG-IP already sits in the data path between clients and servers. It already inspects, transforms, and enforces policy on HTTP traffic. What if it could **transparently cloak PII before it reaches the LLM, and de-cloak it on the way back?**

That's Context Cloak.

## The Problem

An analyst asks an LLM: *"Generate a financial report for John Doe, SSN 078-05-1120, account 4532-1189-0042."*

The LLM now has real PII. Whether it's logged, cached, fine-tuned on, or exfiltrated -- that data is exposed. Traditional approaches fail here:

| Approach | What happens | Why it fails |
|---|---|---|
| **Masking** (`****`) | LLM can't see the data | Can't reason about what it can't see |
| **Tokenization** (`<<SSN:001>>`) | LLM sees placeholders | Works with larger models (14B+); smaller models may hallucinate |
| **Do nothing** | LLM sees real PII | Security and compliance violation |

## The Solution: Value Substitution

Context Cloak takes a different approach -- **substitute real PII with realistic fake values**:

- `John Doe` becomes `Maria Garcia`
- `078-05-1120` becomes `523-50-6675`
- `4532-1189-0042` becomes `7865-4412-3375`

The LLM sees what looks like real data and reasons about it naturally. It generates a perfect financial report for "Maria Garcia." On the way back, BIG-IP swaps the fakes back to the real values. The user sees a report about John Doe. **The LLM never knew John Doe existed.**

This is conceptually a **substitution cipher** -- every real value maps to a consistent fake within the session, and the mapping is reversed transparently. When I was thinking about this concept, my mind kept coming back to [James Veitch's TED talk about messing with email scammers](https://www.ted.com/talks/james_veitch_this_is_what_happens_when_you_reply_to_spam_email?t=280). Veitch tells the scammer they need to use a code for security: "Lawyer" becomes "Gummy Bear," "Bank" becomes "Cream Egg," "Documents" becomes "Jelly Beans," and "Western Union" becomes "A Giant Gummy Lizard." The scammer actually uses the code. He writes back: *"I am trying to raise the balance for the Gummy Bear so he can submit all the needed Fizzy Cola Bottle Jelly Beans to the Creme Egg... Send 1,500 pounds via a Giant Gummy Lizard."* The real transaction details -- the amounts, the urgency, the process -- all stayed intact. Only the sensitive terms were swapped. The scammer didn't even question it. That idea stuck with me -- what if we could do the same thing to protect PII from LLMs? But rotate the candy -- so it's not a static code book, but a fresh set of substitutions every session.

## Example Scenario

**Use case:** A financial analyst at a bank needs to review a customer's recent spending patterns.

1. The analyst opens a chat UI (Open WebUI) and asks: *"Look up customer John Doe, get his accounts, and summarize his last 30 days of transactions."*

2. The LLM calls MCP tools to fetch data from the bank's customer database through BIG-IP. The MCP server returns real customer data -- name, SSN, account numbers, transaction history.

3. **BIG-IP intercepts the MCP response**, reads the structured JSON fields, and builds a cloaking table: `John Doe -> Maria Garcia`, `078-05-1120 -> 523-50-6675`, etc. The real data passes through to Open WebUI so the LLM can chain tool calls.

4. When Open WebUI sends the prompt to the LLM, **BIG-IP intercepts the inference request** and swaps every real PII value with its fake counterpart using exact string matching.

5. The LLM generates: *"Maria Garcia's checking account (7865-4412-3375) shows $6,400 in deposits and $3,034 in spending over the last 30 days..."*

6. **BIG-IP intercepts the response** and swaps fakes back to reals. The analyst sees: *"John Doe's checking account (4532-1189-0042) shows $6,400 in deposits and $3,034 in spending..."*

The LLM produced a perfect report. It never saw John Doe's real SSN. The analyst got exactly what they needed.

## Why BIG-IP?

F5 BIG-IP was the natural candidate for this:

- **Already in the data path** -- BIG-IP is a reverse proxy/ADC that organizations already deploy between clients and servers
- **MCP protocol support** -- TMOS v21 added native MCP awareness via iRules
- **iRules** -- Tcl-based traffic manipulation that can inspect, transform, and rewrite HTTP payloads in real-time
- **Subtables** -- In-memory key-value storage perfect for session-scoped cloaking maps
- **iAppLX** -- Deployable application packages with REST APIs and web UIs
- **Trust boundary** -- BIG-IP is already the enforcement point for SSL termination, WAF, and access control

## Architecture

```
                        ┌─────────────────────────────┐
                        │      F5 BIG-IP TMOS v21     │
                        │                             │
   ┌──────────┐        │  ┌─────────┐  ┌──────────┐  │        ┌──────────┐
   │          │        │  │ MCP VS  │  │Cloaking  │  │        │          │
   │  Open    │───────►│  │ Builds  │  │ Table    │  │◄───────│   MCP    │
   │  WebUI   │        │  │ table   │  │ (subtable│  │        │  Server  │
   │          │        │  │         │  │  per     │  │        │          │
   │ (sees    │        │  └─────────┘  │  session)│  │        │ (Postgres│
   │  real    │        │               │          │  │        │  backend)│
   │  data)   │        │  ┌─────────┐  │ real↔fake│  │        └──────────┘
   │          │───────►│  │Inference│  │ mappings │  │
   │          │        │  │  VS     │  │          │  │        ┌──────────┐
   │          │◄───────│  │ Cloaks  │  └──────────┘  │───────►│  vLLM    │
   │          │        │  │ request │                 │        │ (Qwen)   │
   └──────────┘        │  │ Decloaks│                 │        │          │
                        │  │ response│                 │◄───────│ sees only│
                        │  └─────────┘                 │        │ fake PII │
                        └─────────────────────────────┘        └──────────┘
```

### Data Flow

1. **User asks a question** in Open WebUI
2. **Open WebUI calls MCP tools** through BIG-IP MCP Virtual Server
3. **BIG-IP MCP VS** forwards to MCP server, receives response with real PII
4. **BIG-IP scans the response** -- extracts PII from known JSON fields, generates deterministic fakes, stores bidirectional mappings in a session-keyed subtable. **Response passes through unmodified** so tool chaining works.
5. **Open WebUI** receives real data, chains tool calls, composes a prompt
6. **Open WebUI sends prompt** to vLLM through BIG-IP Inference VS
7. **BIG-IP Inference VS cloaks the request** -- `[string map]` swaps all real PII with fakes
8. **vLLM generates** a response using fake data -- it has no idea it's fake
9. **BIG-IP Inference VS de-cloaks the response** -- swaps fakes back to reals
10. **User sees** the final report with real data restored

### Trust Boundaries

| Zone | Components | Sees Real PII? |
|---|---|---|
| MCP Server + Postgres | Source of truth | Yes |
| BIG-IP (Enforcement) | MCP VS + Inference VS + Cloaking Table | Yes -- performs the swap |
| Open WebUI | Chat UI, MCP orchestration | Yes -- receives real data from MCP |
| vLLM / Qwen (Untrusted) | LLM inference | **No -- only sees fake data** |

## iAppLX: Context Cloak Application

Context Cloak is packaged as an **iAppLX extension** -- a deployable application on BIG-IP with a REST API and web-based configuration UI.

### What the iAppLX Does

When deployed, it creates all required BIG-IP objects:

- **Data Group** (`context_cloak_fields`) -- maps PII field names to cloaking modes
- **iRules** -- dynamically generated from your PII field configuration
- **HTTP Profile** -- with `rechunk` to handle SSE/chunked MCP responses
- **SSL Profiles** -- client-ssl for frontend, server-ssl with SNI for backends
- **Pools + Monitors** -- for MCP server and LLM endpoints
- **Virtual Servers** -- MCP VS and Inference VS with all profiles and iRules attached

### Configuration UI

Access at `https://<bigip>/iapps/f5-context-cloak/index.html` after installation.

The UI provides:

- **MCP Server** -- Virtual server IP, pool member, host header for backend routing
- **LLM Endpoints** -- Multiple LLM backends with hostname-based routing
- **PII Field Configuration** -- The core of Context Cloak:

| Field | Aliases | Mode | Type / Label |
|---|---|---|---|
| `full_name` | `customer_name` | Substitute | Name Pool |
| `ssn` | | Tokenize | SSN |
| `account_number` | | Substitute | Digit Shift |
| `phone` | | Substitute | Phone |
| `email` | | Substitute | Email |

- **Tokenize Guidance Prompt** -- System message injected when tokenize mode is active
- **Session Configuration** -- TTL, session ID source (client IP or header)

### Cloaking Modes

**Substitute** -- Replace PII with realistic fake values:
- Names: picked deterministically from a 10x10 fake name pool
- SSN/Phone/Account: each digit shifted by a fixed offset mod 10
- Email: derived from fake name pool + @example.net

Best for: fields the LLM needs to reason about naturally (names in reports, account numbers in summaries).

**Tokenize** -- Replace PII with structured placeholders:
- Format: `<<TYPE:SESSION_ID:SEQUENCE>>` (e.g., `<<SSN:10.0.1.50:001>>`)
- When enabled, a guidance prompt is injected telling the LLM to treat tokens as real values

Best for: defense-in-depth with F5 AI Gateway, or fields where guardrails need to catch leaks. A guidance prompt is automatically injected to instruct the LLM to reproduce tokens verbatim. Larger models (14B+ parameters) handle this reliably; smaller models (7B) may struggle. Both modes can be mixed per-field in the same request.

### PII Field Configuration

The admin tells BIG-IP which JSON fields in MCP responses contain PII. The iRule anchors on these field names when scanning responses -- no arbitrary regex scanning of free text. Because MCP responses are structured JSON with known schemas, extraction is deterministic and reliable.

Fields can be added, removed, or have their mode changed at any time. Click **Deploy** and the iRules regenerate from the new configuration.

## What's Next: F5 AI Gateway Integration

Context Cloak's tokenize mode is designed to complement **F5 AI Gateway** and guardrails solutions. The `<<SSN:session:001>>` format is intentionally distinctive -- if any token leaks through de-cloaking (because the LLM rephrased or reformatted it), a guardrails policy can catch it as a pattern match violation.

The vision: **Context Cloak as the first layer of defense (PII never reaches the LLM), AI Gateway as the safety net (catches anything that slips through).** Defense in depth for AI data protection.

Future integration points:
- AI Gateway policy rules that flag `<<TYPE:...>>` patterns in LLM responses
- Centralized cloaking policy management across multiple BIG-IP instances
- Telemetry and audit logging for compliance reporting
- Auto-discovery of MCP tool schemas for PII field detection

## Deployment

See [docs/deployment.md](docs/deployment.md) for full deployment instructions.

### Quick Start (Local Development)

```bash
git clone <this-repo>
cd f5_mcp_context_cloak
make setup        # Python venv + dependencies
make db-up        # Start local Postgres
make db-init      # Load schema + seed data
make mcp-server   # Run MCP server on localhost:8080
./scripts/test-mcp.sh  # Test MCP tools
```

### Production Deployment

1. **Deploy BIG-IP on AWS** -- `terraform/aws-infra/`
2. **Deploy MCP Server + Postgres on Kubernetes** -- `kubernetes/overlays/lab/`
3. **Install iAppLX** -- Upload RPM via BIG-IP Package Management LX
4. **Configure via GUI** -- Set MCP/LLM endpoints, PII fields, deploy

## Repository Structure

```
├── docs/                  # Architecture, deployment guide, design rationale
├── examples/              # Prompts and curl examples
├── iapplx/                # BIG-IP iAppLX package
│   ├── nodejs/            # REST worker + iRule generator + BIG-IP client
│   ├── presentation/      # Configuration web UI
│   └── scripts/           # RPM build script
├── irules/                # BIG-IP iRules (standalone versions)
│   ├── mcp_session_persistence.tcl   # MCP session + cloaking table builder
│   └── vllm_anonymization.tcl        # Inference cloak/decloak
├── kubernetes/            # Kustomize manifests
│   ├── base/              # MCP server, Postgres, seed job, network policies
│   └── overlays/lab/      # Lab patches (ECR, emptyDir, probes)
├── mcp-server/            # Python MCP server (FastMCP + psycopg)
│   ├── src/               # Server, tools, DB layer, config
│   └── sql/               # Schema and seed data
├── scripts/               # Bootstrap and test scripts
└── terraform/             # Infrastructure as code
    ├── aws-infra/         # AWS VPC + BIG-IP VE (BYOL, 3-NIC)
    └── bigip/             # BIG-IP application config
```

## References

- [Managing MCP in iRules -- Part 1](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-1/344321)
- [Managing MCP in iRules -- Part 2](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-2/344421)
- [Managing MCP in iRules -- Part 3](https://community.f5.com/kb/technicalarticles/managing-model-context-protocol-in-irules---part-3/344423)
- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
- [James Veitch: This is what happens when you reply to spam email (TED, skip to 4:40)](https://www.ted.com/talks/james_veitch_this_is_what_happens_when_you_reply_to_spam_email?t=280)
