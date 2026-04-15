# Guardrails demo GIFs

Artifacts for Context Cloak Part 2 (Guardrails Mode). Placeholders until the live demo is recorded.

## Expected files

| File | Demo | What to capture |
|---|---|---|
| `guardrails_mode_toggle.gif` | Setup | iAppLX UI: toggle Guardrails Mode on, observe locked selectors + banner, click Deploy, see redeploy success. |
| `guardrails_raw_ssn_blocked.gif` | Demo 1 | Analyst pastes raw SSN in Open WebUI; Guardrails returns the block message; vLLM logs show no request. |
| `guardrails_name_lookup_succeeds.gif` | Demo 2 | Name-keyed query flows end-to-end; split view of Open WebUI (real values) and vLLM logs (tokens). |
| `guardrails_token_leak_detected.gif` | Demo 3 | Stale token echoed by LLM is caught by outbound rule; analyst sees `[REDACTED]`. |

## Capture tips

- Use a 1280x720 viewport; crop tight to the relevant panels.
- Record at 10-15 fps for GIF; 30+ fps if exporting MP4.
- Put Open WebUI on the left, BIG-IP iRule log tail center, vLLM pod log tail right when showing flow.
- For Demo 1, show the Guardrails pod logs briefly to surface `rule=ssn action=block`.
- Compress with `gifsicle -O3 --colors 128` before embedding. Archive originals in `original/`.
