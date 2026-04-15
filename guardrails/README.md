# Guardrails (Context Cloak Part 2)

Assets for integrating **F5 AI Guardrails** in front of the Inference VS.

## Contents

- `policies/context-cloak-policy.yaml` — reference policy (high-sensitivity PII blocks + leaked-token outbound redaction). Canonical source. Also embedded into `kubernetes/base/guardrails/configmap-policy.yaml`.
- `stub/` — minimal OpenAI-compatible reference stub so the demo runs end-to-end without a licensed Guardrails instance. Replace with the real product in production.

## Topology

```
Open WebUI
    │ POST /v1/chat/completions
    ▼
BIG-IP Inference VS     (cloaks real → tokens)
    │
    ▼
F5 AI Guardrails        (blocks raw PII in prompt; redacts leaked tokens in reply)
    │
    ▼
vLLM                     (sees only tokens)
```

The BIG-IP Inference VS pool member is set to the Guardrails Service (`ai-guardrails.guardrails.svc.cluster.local:8000`). Guardrails forwards cleared requests to the vLLM service defined in its policy `upstream.url`.

## Build the reference stub

```bash
cd guardrails/stub
docker build -t ghcr.io/j2rsolutions/context-cloak-guardrails-stub:0.3.0 .
# push to your registry of choice, then deploy:
kubectl apply -k ../../kubernetes/base/guardrails
```

## Replace the stub with F5 AI Guardrails

Delete `kubernetes/base/guardrails/stub-deployment.yaml` (or replace its container spec), keep the `Service` and `ConfigMap`. Adapt the policy to the product's schema if keys differ.

See [`docs/guardrails-integration.md`](../docs/guardrails-integration.md) for the full deployment, threat model, and what the system does not protect.
