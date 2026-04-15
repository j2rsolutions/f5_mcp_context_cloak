# Context Cloak Part 2 — Guardrails Mode Demo Evidence

> Companion to [`docs/demo-evidence.md`](demo-evidence.md) (Part 1). All artifacts below demonstrate F5 AI Guardrails sitting between the BIG-IP Inference VS and vLLM, with Context Cloak in **Guardrails Mode** (tokenize-only, guidance prompt always injected).

**Placeholders**: GIFs and screenshots referenced on this page are captured during live demos. Placeholders are tracked in `docs/gifs/guardrails/` — replace with recorded artifacts during the demo run.

---

## Setup

| Component | Version / Detail |
|---|---|
| F5 BIG-IP VE | v21.0.0.1 on AWS (m5.xlarge) |
| Context Cloak iAppLX | v0.3.0 (Guardrails Mode enabled) |
| F5 AI Guardrails | Reference stub (`guardrails/stub/`) — swap for real product in prod |
| vLLM model | Qwen 2.5 14B Instruct AWQ on NVIDIA L4 (24GB) |
| MCP Server | FastMCP + PostgreSQL on Kubernetes (RKE2) |
| Open WebUI | Chat interface |

---

## Step 1: Enabling Guardrails Mode in the iAppLX UI

Toggle **Operating Mode → Guardrails Mode** on. Observe that the PII Field Configuration table visually locks every per-field Cloak Mode dropdown to **Tokenize**, and a banner appears explaining why.

![Context Cloak GUI in Guardrails Mode — mode selectors locked to Tokenize](gifs/guardrails/guardrails_mode_toggle.gif)

*The Guardrails endpoint URL and block message become editable when the toggle is on. Click Deploy to regenerate the data group (tokenize-only) and iRules (guidance prompt always injected).*

---

## Demo 1: Raw SSN blocked by Guardrails

**Prompt:** *"Please look up 078-05-1120 and give me the full profile."*

Context Cloak has no entry for `078-05-1120` in its subtable yet (no MCP call has happened in this session). Under the old architecture this SSN would reach the LLM in cleartext. With Guardrails Mode, the inbound `ssn` rule fires before the request reaches vLLM.

![Guardrails blocking raw SSN in the first prompt](gifs/guardrails/guardrails_raw_ssn_blocked.gif)

*Left: Open WebUI — Guardrails block message rendered as an assistant reply. Right: vLLM logs — no request received. Center: Guardrails logs showing `rule=ssn action=block`.*

### What Guardrails returned

```json
{
  "id": "guardrails-block-1712345678",
  "model": "qwen2.5-14b-instruct-awq",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "It looks like your request includes sensitive information (e.g. SSN, account number, or phone number). Please rephrase using a customer name or ID instead. The system will securely retrieve protected fields on your behalf."
    },
    "finish_reason": "guardrails_block"
  }],
  "guardrails": {"blocked": true, "rule": "ssn"}
}
```

### What the analyst does next

Rephrases: *"Please look up John Doe and give me the full profile."* — this succeeds (see Demo 2).

---

## Demo 2: Name lookup succeeds end-to-end

**Prompt:** *"Please look up John Doe, pull his accounts, and summarize his last 30 days of activity."*

Names pass Guardrails' inbound rules. Open WebUI calls MCP tools, BIG-IP MCP VS extracts PII from the response and builds the tokenize-only cloaking table, Open WebUI composes the next prompt with real data, BIG-IP Inference VS tokenizes, Guardrails sees only tokens and passes them through, vLLM generates with tokens preserved, BIG-IP decloaks on the way back.

![Name-keyed query flowing end-to-end through Guardrails Mode](gifs/guardrails/guardrails_name_lookup_succeeds.gif)

*Four-panel capture: (1) Open WebUI with real values in the final response, (2) BIG-IP iRule logs showing tokenize + guidance prompt injected, (3) Guardrails logs showing inbound=clear, (4) vLLM logs showing only tokens in the prompt.*

### What the LLM saw (vLLM logs)

```json
{
  "messages": [
    {"role": "system", "content": "You may encounter placeholders in the format <<TYPE:ID:SEQ>>..."},
    {"role": "user", "content": "Summarize <<NAME:10.0.1.50:001>>'s activity across <<NUM:10.0.1.50:001>> and <<NUM:10.0.1.50:002>>."}
  ]
}
```

### What the analyst saw (Open WebUI)

> John Doe's checking account (4532-1189-0042) shows $6,400 in deposits and $3,034 in spending over the last 30 days...

---

## Demo 3: Leaked-token safety net

To demonstrate the outbound layer, force a decloak mismatch: query a customer, capture the token sequence, then send a prompt that references a token that was *never* in the mapping (e.g., `<<SSN:10.0.1.50:999>>`). The LLM echoes the unknown token in its response. BIG-IP has no `f2r_` entry for it, so the token survives de-cloaking and arrives at Guardrails' outbound layer.

![Leaked cloak token redacted by Guardrails outbound rule](gifs/guardrails/guardrails_token_leak_detected.gif)

*Left: Open WebUI showing `[REDACTED]` where the stray token would have appeared. Right: Guardrails logs showing `rule=leaked-cloak-token action=redact`. The analyst is protected from ever seeing a raw token, and the event is surfaced for investigation (likely indicates TTL expiry or a cloaking-table cold-start bug).*

---

## Summary

| Demo | Where PII comes from | What Guardrails does | What the analyst sees |
|---|---|---|---|
| 1 | User types raw SSN | Inbound rule blocks | Guidance message ("rephrase using a name or ID") |
| 2 | MCP response, tokenized by BIG-IP | Inbound: pass; outbound: pass | Real values (decloaked by BIG-IP) |
| 3 | LLM echoes stale token | Outbound: redact `<<...>>` | `[REDACTED]` instead of a raw token |

## Artifact checklist (placeholders to replace during live demo)

```
docs/gifs/guardrails/
├── guardrails_mode_toggle.gif           (iAppLX UI toggle + deploy)
├── guardrails_raw_ssn_blocked.gif       (Demo 1)
├── guardrails_name_lookup_succeeds.gif  (Demo 2)
└── guardrails_token_leak_detected.gif   (Demo 3)
```

Recommended capture tool: `ffmpeg -f x11grab` or Kap (macOS). Compress with `gifsicle -O3` for README embedding; archive originals under `docs/gifs/guardrails/original/`.
