# Example backend: GLM (or any OpenAI-compatible model) via LiteLLM

This turns a non-Anthropic model into a **tool-using** Claude Code agent. Claude Code
speaks the Anthropic `/v1/messages` API; LiteLLM runs as a local proxy that translates
that (including tool-calling) to an OpenAI-compatible upstream and back.

```
crew --backend glm         Claude Code (Anthropic /v1/messages, tools)
        │                        │
        ▼                        ▼
   LiteLLM  :4000  ── OpenAI /v1/chat/completions ──►  your GLM / OpenAI-compatible gateway
```

## Setup

1. Edit `config.yaml`: set `api_base` (your OpenAI-compatible gateway, ending in `/v1`)
   and `model` (`openai/<YourModel>`).
2. Export your upstream token: `export GLM_GATEWAY_TOKEN=...`
3. Install + register the backend:
   ```bash
   bash setup.sh
   # (need a mirror? PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple bash setup.sh)
   ```
4. Use it:
   ```bash
   crew --backend glm mysess "run `uname -s` and paste the real output"
   crew attach mysess
   ```

`crew` auto-starts LiteLLM on first use (via the backend's `ENSURE_CMD`) and reuses it
if it's already listening — the port check uses bash's `/dev/tcp`, so it works in bare
containers with no `lsof`/`ss`.

## Gotchas (learned the hard way)

- **`api_base` must end at `/v1`**, not `/v1/chat/completions` — LiteLLM appends the
  suffix itself; a doubled path returns 404.
- **Pin `litellm==1.80.0`** — 1.95 conflicts with fastapi 0.141 (`get_flat_dependant`).
- **`LITELLM_LOCAL_MODEL_COST_MAP=True`** — skips a slow GitHub cost-map fetch on start
  (already set by `ensure-litellm.sh`).
- **Client must pass `--model glm-5.2`** — the default Anthropic model name isn't in the
  LiteLLM `model_list`, so it 400s. The `glm` backend sets this for you.
- **Reasoning models** put answers in `reasoning_content` and need `max_tokens` headroom
  (config sets 8192); `drop_params: true` discards upstream-unsupported params (e.g. the
  Anthropic `thinking` field) to avoid 400s. `MAX_THINKING_TOKENS=0` is set on the client.
- Some gateways have **broken streaming**; if you hit stream errors, prefer a non-streaming
  upstream. LiteLLM buffers fine for the delegation use case.

## Two tokens, don't confuse them

- **Client → LiteLLM**: the `master_key` in `config.yaml` (`sk-local-crew`). The `glm`
  backend passes this as `ANTHROPIC_AUTH_TOKEN`.
- **LiteLLM → upstream**: your real `GLM_GATEWAY_TOKEN`, read from the environment.
