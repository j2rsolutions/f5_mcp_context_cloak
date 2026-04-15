# Context Cloak Part 2 — DevCentral Article Outline

> **Working title:** *Context Cloak Part 2: Closing the First-Prompt Gap with F5 AI Guardrails*
>
> **Audience:** DevCentral readers who followed Part 1 (F5 BIG-IP, MCP, PII cloaking). Assumes familiarity with iRules, iAppLX, and the Open WebUI → BIG-IP → MCP/vLLM flow.
>
> **Length target:** ~2,500 words + diagrams, code snippets, and demo GIFs. Matches Part 1 tone: honest, technical, opinionated.

---

## 1. Recap: Where Part 1 Left Off (≈250 words)

- One-paragraph recap of the cloaking model: BIG-IP as MCP enforcement point, session subtable, real↔fake substitution at the inference boundary.
- The scene-setter: Part 1 closed with the honest admission that cloaking is **reactive** — it can only protect PII it has already seen come back through an MCP tool. If the analyst types raw PII *in the first prompt*, cloaking cannot help.
- Tease: Part 2 is about that gap, and about why the obvious answer (just substitute everything) doesn't work once a real PII-detection system is in the mix.

## 2. The First-Prompt Problem (≈300 words)

- Reproduce the failure scenario in plain language: *"Please look up 078-05-1120"* — raw SSN, no MCP call yet, cloak table empty. Part 1's BIG-IP iRule sees nothing to swap.
- Why this matters in practice: audit and compliance don't care that "usually" the analyst types a name. One leak is a breach.
- Why the obvious fix (regex in the inference iRule to reject raw PII) is a tar pit: false positives, expanding pattern catalog, iRule spaghetti.
- The cleaner answer: put a **PII detection product** in the data path. Enter F5 AI Guardrails.

## 3. Topology: Where Guardrails Sits (≈300 words + diagram)

- Diagram: Open WebUI → BIG-IP Inference VS → **F5 AI Guardrails (k8s)** → vLLM.
- Explain the pool-member wiring: the Inference VS pool member is now the Guardrails K8s Service, not vLLM directly. Guardrails forwards cleared traffic to vLLM per its own policy.
- Clarify trust boundaries: BIG-IP owns the cloak table; Guardrails owns inbound PII detection and outbound leaked-token detection. vLLM remains untrusted and sees only tokens.
- Call out the MCP path is unchanged — Guardrails only sits on the inference path.

## 4. The Substitution/Guardrails Conflict (≈350 words) — *the key insight*

- Frame the problem: Part 1 used realistic substitution (fake SSN `523-50-6675`, fake account `7865-4412-3375`) because the LLM reasons naturally on realistic data.
- But Guardrails' inbound PII detection is **regex-based** — it can't tell a fake SSN from a real one. From its perspective, a cloaked request still contains PII. Guardrails would block cloaked requests.
- This is the article's intellectual pivot: *Substitution and PII-detection-based Guardrails are fundamentally incompatible.*
- The resolution: **tokenization**. `<<SSN:10.0.1.50:001>>` is structurally unambiguous and doesn't match any PII pattern. Guardrails passes it through; BIG-IP decloaks it on the way back.
- The trade-off: tokens are harder for small LLMs to preserve (they may summarize or hallucinate over them). Mitigated by (a) larger models — we use Qwen 2.5 14B — and (b) a guidance system prompt that tells the model to treat tokens as opaque values and reproduce them verbatim.
- Conclusion: **Guardrails Mode = tokenize-only**. Substitution is off, guidance prompt is on.

## 5. What We Built in the iAppLX (≈250 words + screenshots)

- New **Operating Mode** card with a **Guardrails Mode** toggle.
- When on:
  - UI visually locks all per-field cloak-mode selectors to Tokenize, shows a banner explaining why.
  - Worker's `normalizeConfigForDeploy` rewrites every non-disabled field's mode to `tokenize` before deploying. Original config on disk is preserved — toggle off restores per-field modes.
  - iRule generator emits a banner comment and forces tokenize-prompt injection unconditionally.
- Guardrails endpoint URL, policy name, and block message are first-class fields.
- Screenshot: the new UI with the banner and locked selectors.

## 6. Deploying the Guardrails Policy (≈400 words + code)

- Walk through the policy YAML (inbound rules block high-sensitivity PII patterns, outbound rules redact leaked tokens, block response in OpenAI shape).
- Explain the rule choices: names and customer IDs are intentionally allowed (required as lookup keys); credit cards and SSNs are blocked; transaction amounts are not inspected.
- Reference-stub deployment: `guardrails/stub/` — a small FastAPI service that enforces the policy. Exists so the demo reproduces without a licensed Guardrails instance. In production, replace with the real product, keep the Service name/port and policy ConfigMap.
- `kubectl apply -k kubernetes/base/guardrails`.
- Point the BIG-IP Inference VS pool member at `ai-guardrails.guardrails.svc.cluster.local:8000`.

## 7. The Three Demos (≈400 words)

### Demo 1: Raw SSN blocked
- Analyst pastes `078-05-1120` into first prompt; Guardrails returns the guidance message; vLLM never sees the request.
- Show: Open WebUI rendering, vLLM logs empty, Guardrails logs showing `rule=ssn action=block`.

### Demo 2: Name lookup succeeds end-to-end
- Analyst queries by name. Full flow: MCP retrieves, BIG-IP tokenizes, Guardrails passes tokens through, vLLM preserves them, BIG-IP decloaks. Analyst sees real values.
- Show split-view GIF: Open WebUI (real) vs. vLLM logs (tokens).

### Demo 3: Leaked-token safety net
- Force a decloak mismatch (stale token from prior session, or LLM hallucination). Outbound rule redacts to `[REDACTED]` before it reaches the analyst.
- Show Guardrails log event — useful for audit.

## 8. What This Does Not Fix (≈300 words) — *honesty section*

- Names still pass through — they have to. The trade-off is deliberate; names are lower-sensitivity than SSN/account/credit-card.
- **Transaction amounts are not PII by regex**. `$1,247.83 at Whole Foods` is a quasi-identifier, not a regulated pattern. Guardrails won't catch it; cloaking won't swap it. We leave it in cleartext to preserve the analyst's analytical use case.
- Brief paragraph on quasi-identifier theory: Sweeney (2000) — zip + DOB + sex re-identifies 87% of US population. Not a solvable problem with atomic-value substitution.
- **Coordinates over time** — de Montjoye et al. (2013), four spatio-temporal points identify 95% of people. Per-point substitution doesn't help (pattern is the identifier). Needs structural transformation — a Part 3 topic.
- Point to `docs/guardrails-integration.md` for the full "what we don't protect" section.

## 9. The Roadmap / What's Next (≈150 words)

- Part 3 preview: **structural transformation for high-dimensional PII** — data classes (Atomic, Quasi-Identifier, Sequence, Time-Series, Free-Text), bucketing and generalization primitives, spatial/temporal cloaking, POI semantic substitution, optional differential-privacy noise.
- Frame the series arc: each part admits what the previous part didn't solve, which is what builds credibility in a field full of hand-wavy "privacy-preserving AI" claims.

## 10. Wrap (≈100 words)

- One-paragraph summary: Guardrails Mode closes the first-prompt gap, pivots cloaking from substitution to tokenization to play nicely with PII detection, and introduces an outbound safety net for leaked tokens.
- Repo link, branch link (`feature/ai-guardrails-integration`), Part 1 link.
- CTA: try it, file issues, share what you'd cloak in your own environment.

---

## Assets checklist

- [ ] Updated architecture diagram (PNG export from draw.io or Mermaid)
- [ ] Screenshot: iAppLX UI in Guardrails Mode
- [ ] GIF: Demo 1 (raw SSN blocked)
- [ ] GIF: Demo 2 (name lookup end-to-end)
- [ ] GIF: Demo 3 (leaked-token redaction)
- [ ] Inline code snippets: policy YAML excerpt, iRule comment banner, worker `normalizeConfigForDeploy`
- [ ] Word doc draft for F5 DevCentral editorial

## Draft voice / tone notes

- First person; match Part 1's "conversational-but-technical" voice.
- Name the limits explicitly; don't hand-wave around quasi-identifiers.
- Use the James Veitch comparison again only briefly — the payoff was Part 1's setup. Part 2's analogy is different: *Guardrails is the bouncer, Cloaking is the witness protection program.* The bouncer stops known troublemakers at the door; witness protection lives inside and swaps identities for everyone who got past.
- Keep the "three-layer defense" framing from the README — it's the cleanest conceptual hook.
