# F5 AI Guardrails Integration (Context Cloak Part 2)

> Companion doc to the DevCentral article series. Covers deployment, the threat model, and an honest account of what the system does not protect.

## Why Guardrails Mode exists

Context Cloak's original design protects PII that comes **out of backend systems** — MCP tool responses that carry SSNs, account numbers, phone numbers. The iRule extracts these from structured JSON, stores a real↔fake mapping in a BIG-IP subtable, and swaps them at the inference boundary. The LLM never sees the real values.

That leaves one gap: **what the analyst types directly in the first prompt**.

> "I need the SSN for account 4532-1189-0042 — also check customer 078-05-1120."

Cloaking can't help here. There is no mapping for those values yet; they haven't come through the MCP tool path. The raw PII goes straight to the LLM on the first round-trip.

**F5 AI Guardrails** sits upstream of vLLM and inspects prompts for PII patterns. If the analyst pastes a raw SSN, Guardrails blocks the request before it reaches the LLM and returns a guidance message: *rephrase using a customer name or ID, and the system will retrieve the protected fields for you.*

## Why you can't use substitution with Guardrails

Substitution produces realistic-looking fakes:

| Real | Fake (substitute mode) |
|---|---|
| `078-05-1120` | `523-50-6675` |
| `4532-1189-0042` | `7865-4412-3375` |
| `john@email.com` | `maria.garcia@example.net` |

From Guardrails' perspective, the fake SSN still **matches the SSN regex**. Guardrails is doing its job correctly — it blocks anything that looks like an SSN, fake or real. Without Guardrails, substitution is the right choice (LLM reasons naturally on realistic values). With Guardrails, substitution and PII detection fight each other.

**Tokenization resolves the conflict.** `<<SSN:10.0.1.50:001>>` doesn't match SSN regex, doesn't match any other PII pattern, and can be decloaked deterministically on the response. The trade-off is that the LLM now sees placeholders — smaller models (7B) sometimes hallucinate or summarize them away, so the tokenize guidance system prompt is always injected to instruct the model to preserve tokens verbatim. Larger models (14B+) handle this reliably.

## Topology

```
Open WebUI
    │ POST /v1/chat/completions
    ▼
BIG-IP Inference VS           (1) cloak: real -> <<TYPE:ID:SEQ>> token
    │                             (uses cloak table built by MCP VS)
    ▼
F5 AI Guardrails (k8s)        (2) inbound: block raw PII patterns
    │                             outbound: redact leaked tokens
    ▼
vLLM (Qwen)                   (3) sees only tokens
```

The Inference VS pool member points at Guardrails, not at vLLM. Guardrails forwards cleared requests to vLLM per its own policy.

## What each layer protects

| Layer | Protects | Does not protect |
|---|---|---|
| **BIG-IP cloaking** | Backend-sourced PII from MCP responses | User-typed PII in first prompt; data not yet retrieved |
| **Guardrails (inbound)** | User-typed SSN, account #, phone, email, credit card | Names; customer IDs; transaction amounts; dates |
| **Guardrails (outbound)** | Leaked `<<TYPE:ID:SEQ>>` tokens | Semantic leakage of tokenized content |

Each layer compensates for the others' blind spots. None of them covers quasi-identifiers — see the honest section below.

## Deployment

### 1. Build the reference stub (or deploy the real product)

The stub is a minimal OpenAI-compatible proxy that enforces the reference policy. It exists so the demo is reproducible without a licensed Guardrails instance.

```bash
cd guardrails/stub
docker build -t <your-registry>/context-cloak-guardrails-stub:0.3.0 .
docker push <your-registry>/context-cloak-guardrails-stub:0.3.0
```

Update the image reference in `kubernetes/base/guardrails/stub-deployment.yaml`, then:

```bash
kubectl apply -k kubernetes/base/guardrails
kubectl -n guardrails get pods,svc
```

In production, replace `stub-deployment.yaml` with the real F5 AI Guardrails Deployment. Keep the `Service` name (`ai-guardrails`) and port (`8000`) and mount the same policy ConfigMap — adapt policy keys to the product schema if they differ.

### 2. Wire BIG-IP to Guardrails

In the iAppLX UI, update the **Inference** LLM Endpoint's pool member to point at the Guardrails K8s Service (via NodePort, LoadBalancer, or an Ingress, depending on how your cluster exposes services). The path stays `/v1/chat/completions`. Guardrails forwards to vLLM per its own policy.

### 3. Enable Guardrails Mode in the UI

Toggle **Operating Mode → Guardrails Mode** on. Observe that:

- All per-field cloak-mode selectors lock to **Tokenize** and are visually disabled
- A banner appears in the PII Field Configuration card explaining why
- The Tokenize Guidance Prompt section remains editable (it's now always injected)

Click **Deploy**. Behind the scenes:

- `normalizeConfigForDeploy` rewrites every non-disabled field's `cloak_mode` to `tokenize`
- The data group reflects the normalized config
- The Inference iRule emits a banner comment and forces tokenize-prompt injection
- Your on-disk config retains the per-field modes, so toggling Guardrails Mode off restores them

### 4. Verify

From Open WebUI or a curl probe, send a prompt containing a raw SSN. Guardrails should return the block message (rendered as an assistant reply) without the request ever reaching vLLM. Then query by customer name — Guardrails passes, MCP retrieves real data, cloaking tokenizes it, vLLM responds with tokens preserved, and the final response shows real values decloaked for the analyst.

## Threat model

**In scope**

- A trusted analyst running legitimate queries that may incidentally include raw PII
- Logging/caching/fine-tuning on the vLLM side that must never see regulated PII
- LLM output that might rephrase or fabricate tokens
- Decloak misses where a mapping has been evicted or never existed

**Out of scope**

- A hostile analyst deliberately trying to exfiltrate PII (they have authorized access to MCP data already — this is an authorization problem, not a cloaking problem)
- Network-level attacks on the BIG-IP itself (covered by standard hardening)
- Side-channel inference attacks across sessions (subtable TTL limits exposure)

## What we do not protect

Honesty matters here. The system is a strong control for regulated, atomic PII. It is not a universal privacy solution.

### Customer names

Names must be allowed through Guardrails — they are the lookup key for every legitimate query. "Bob Smith" will appear in the analyst's prompt, will reach the LLM on the first round, and will only get tokenized on subsequent turns once the MCP response populates the cloaking table. Names are categorically lower-sensitivity than regulated identifiers (SSN, account #) and this trade-off is deliberate. If you don't allow names, the analyst cannot query.

### Transaction amounts, dates, merchants (quasi-identifiers)

These are not PII by regex, and Guardrails does not (and should not) block them — they carry the analytical value the analyst is asking about. In aggregate, though, they are a **quasi-identifier**. `$1,247.83 at Whole Foods on 4/3` is highly re-identifiable when joined with external data. Every mitigation hurts analytical precision:

| Option | Cost |
|---|---|
| Tokenize amounts | LLM can't sum, average, compare, or rank |
| Substitute with fake amounts | LLM math on fakes can't be reversed (derived values aren't in the table) |
| Bucket / perturb amounts | Loses precision for reconciliation, keeps trends |
| Generalize dates (month vs day) | Breaks fine-grained pattern detection |

Context Cloak leaves these fields in cleartext to preserve utility. Organizations with stricter requirements should add a second transformation layer (bucketing, noise, date generalization) and accept the precision trade-off.

### Trajectories and time-series data

Coordinates over time are the textbook hard case. de Montjoye et al. (Nature, 2013) showed that **four spatio-temporal points uniquely identify 95% of individuals** in a mobile dataset. The pattern *is* the identifier. Per-point substitution yields a translated trajectory with the same shape — still unique. Per-point tokenization destroys the sequence — LLM can't reason about geography. Real solutions (spatial/temporal generalization, POI substitution, suppression, differential privacy on trajectories) are structural, not atomic, and require schema-aware transformation beyond the current data-group / `[string map]` model.

This is a planned Part 3 topic. See the "Roadmap" below.

### Free-text fields

Free-text notes or descriptions can contain unstructured PII the iRule cannot extract (no anchor field name to key on). If your MCP tools return free-text columns, treat them as high-risk and either suppress them from responses, run them through a dedicated PII-detection step before returning to Open WebUI, or accept the residual risk.

### Aggregate inference attacks

Sweeney (2000) showed that **zip code + date of birth + sex uniquely identifies 87% of the US population**. Cloaking one field at a time doesn't help if the combination survives. The best defense is to avoid returning unnecessary demographic fields in MCP responses at all.

## Roadmap (Part 3)

Structural transformation for high-dimensional PII:

- Data-class abstraction in the iAppLX schema: `Atomic` | `Quasi-Identifier` | `Sequence` | `Time-Series` | `Free-Text`
- Schema-aware MCP response extraction (parse, walk, transform, re-serialize) rather than regex / `[string map]`
- Bucketing and generalization primitives for quasi-identifiers
- Spatial and temporal generalization for trajectories
- POI semantic substitution via external geocoding
- Differential-privacy noise primitives (with explicit budget tracking)

## References

- de Montjoye, Y.-A., Hidalgo, C. A., Verleysen, M., & Blondel, V. D. (2013). *Unique in the Crowd: The privacy bounds of human mobility*. Scientific Reports 3, 1376.
- Sweeney, L. (2000). *Simple Demographics Often Identify People Uniquely*. Carnegie Mellon University Working Paper.
- [F5 AI Guardrails](https://www.f5.com/) (product page)
- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
