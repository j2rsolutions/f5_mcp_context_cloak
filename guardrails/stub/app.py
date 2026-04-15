"""
Context Cloak -- F5 AI Guardrails reference stub.

Minimal OpenAI-compatible proxy that enforces the policy in
/policy/policy.yaml. Exists so the Context Cloak demo is
reproducible end-to-end without a licensed F5 AI Guardrails
instance. Replace with the real product in production; the
Service contract (POST /v1/chat/completions, /healthz) is stable.

Contract:
  - POST /v1/chat/completions
      Inspects the last user message against the policy's inbound
      rules. On match -> returns an OpenAI-shaped assistant message
      with the configured block message (status 200 so the chat UI
      renders it naturally). On no match -> forwards the request
      upstream and post-processes the response with outbound rules.
  - GET  /healthz -> 200
"""

from __future__ import annotations

import os
import re
import time
from typing import Any

import httpx
import yaml
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

POLICY_PATH = os.environ.get("POLICY_PATH", "/policy/policy.yaml")
UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "http://vllm.inference.svc.cluster.local:8000")
REQUEST_TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "120"))

app = FastAPI(title="Context Cloak Guardrails Stub", version="0.3.0")


def load_policy() -> dict[str, Any]:
    with open(POLICY_PATH, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)["policy"]


POLICY = load_policy()
INBOUND = [(r["id"], re.compile(r["pattern"])) for r in POLICY.get("inbound", [])]
OUTBOUND = [
    (r["id"], re.compile(r["pattern"]), r.get("action", "redact"), r.get("replacement", "[REDACTED]"))
    for r in POLICY.get("outbound", [])
]
BLOCK_MESSAGE = POLICY.get("block_response", {}).get("message", "Request blocked by policy.")


def scan_inbound(text: str) -> str | None:
    """Return the id of the first matching inbound rule, or None."""
    for rule_id, pattern in INBOUND:
        if pattern.search(text):
            return rule_id
    return None


def apply_outbound(text: str) -> tuple[str, list[str]]:
    """Apply outbound rules; return (cleaned_text, matched_rule_ids)."""
    matched: list[str] = []
    for rule_id, pattern, action, replacement in OUTBOUND:
        if pattern.search(text):
            matched.append(rule_id)
            if action == "redact":
                text = pattern.sub(replacement, text)
    return text, matched


def block_response(model: str, rule_id: str) -> dict[str, Any]:
    return {
        "id": f"guardrails-block-{int(time.time())}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": BLOCK_MESSAGE},
                "finish_reason": "guardrails_block",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        "guardrails": {"blocked": True, "rule": rule_id},
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> JSONResponse:
    body = await request.json()
    model = body.get("model", "unknown")
    messages = body.get("messages", [])

    # Inspect only the last user message -- earlier turns are either
    # system/tool output (already cloaked by BIG-IP) or prior assistant
    # replies (already cleared on the way out).
    last_user = next(
        (m.get("content", "") for m in reversed(messages) if m.get("role") == "user"),
        "",
    )
    rule_hit = scan_inbound(last_user) if isinstance(last_user, str) else None
    if rule_hit:
        return JSONResponse(block_response(model, rule_hit))

    # Forward upstream
    url = f"{UPSTREAM_URL.rstrip('/')}/v1/chat/completions"
    # Force non-streaming so outbound rules can inspect the whole body.
    # (BIG-IP already rewrites stream:true -> false for the same reason.)
    body["stream"] = False
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        upstream = await client.post(url, json=body)
    data = upstream.json()

    # Outbound redaction on assistant content
    for choice in data.get("choices", []):
        msg = choice.get("message", {})
        content = msg.get("content", "")
        if isinstance(content, str):
            cleaned, matched = apply_outbound(content)
            if matched:
                msg["content"] = cleaned
                data.setdefault("guardrails", {})["outbound_matches"] = matched
    return JSONResponse(data, status_code=upstream.status_code)
