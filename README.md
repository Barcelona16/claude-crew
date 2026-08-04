# claude-crew

Named, attachable, persistent **tmux sessions for [Claude Code](https://claude.com/claude-code)**,
with pluggable model backends.

A *crew session* is a tmux session running `claude`, pinned to a **name**, a **backend**
(base URL + model + token + env), and a **stable session-id**. That gives you:

- **Address agents by name** — `crew api "add rate limiting"`, `crew docs "update the changelog"`.
- **Attach any time to watch** — `crew attach api` drops you into the live session.
- **Persistence** — sessions `--resume` the same conversation across tmux/host restarts.
- **Per-session backends** — run one session on Claude, another on a cheaper model, side by side.

It's a thin, dependency-light bash script (tmux + Claude Code). No daemon, no config server.

## Install

```bash
git clone <this repo> && cd claude-crew
bash install.sh          # symlinks `crew` into ~/.local/bin
crew --help
```

## Usage

```bash
crew mysess "read src/app.ts and list its exports"   # start/continue a named session + feed a task
crew                      # ensure + attach the session for the current directory
crew ls                   # list running sessions
crew attach mysess        # attach to observe
crew kill mysess          # stop a session
crew backends             # list backend presets
```

Session name defaults to the current directory's basename (deduped with a number on
collision). The directory↔name map and each session's id are stored under
`~/.local/share/claude-crew/`, so re-running `crew` from the same directory reattaches
the same conversation.

**Flags:** `--backend <name>` pick a backend · `--fresh` start a new conversation (no
`--resume`) · `--yolo` add `--dangerously-skip-permissions`.

## Backends

A backend is a preset in `~/.config/claude-crew/backends/<name>.conf` (sourced as bash).
The built-in `default` backend is just plain Claude with your ambient config. Any of the
keys are optional — see [`backends/default.conf.example`](backends/default.conf.example):

| Key | Meaning |
|-----|---------|
| `BASE_URL` | `ANTHROPIC_BASE_URL` override (point at a proxy/gateway) |
| `MODEL` | `claude --model <MODEL>` |
| `TOKEN` / `TOKEN_CMD` | auth token, literal or from a command's stdout |
| `ENSURE_CMD` | idempotent command run before the session (e.g. start a proxy) |
| `ENV_EXTRA` | extra `K=V` env injected into the session |
| `DANGEROUS` | `1` → add `--dangerously-skip-permissions` |
| `CLAUDE_FLAGS` | override the flags passed to `claude` |

### Example: drive a non-Anthropic model as a tool-using agent

[`examples/glm-litellm/`](examples/glm-litellm/) sets up a `glm` backend that uses
[LiteLLM](https://github.com/BerriAI/litellm) to translate Anthropic `/v1/messages`
(with tool-calling) to an OpenAI-compatible upstream — so a cheaper model runs as a real
tool-using Claude Code agent, and `crew` starts the proxy on demand.

```bash
bash examples/glm-litellm/setup.sh
export GLM_GATEWAY_TOKEN=...            # your upstream token
crew --backend glm worker "run a quick smoke test and report"
```

## Notes & gotchas

- **Session isolation.** Named sessions are persistent (`--resume`) *and* inherit their
  working directory's `CLAUDE.md`. For a clean one-off task, use a fresh session name in a
  neutral directory (or `--fresh`) — otherwise prior history or a project's `CLAUDE.md` can
  steer the agent off-task.
- **Container-friendly.** The "is the backend already up?" check uses bash's built-in
  `/dev/tcp` (falling back to `nc`/`lsof`/`ss`), so it works in minimal containers that
  ship no `lsof` — where an `lsof`-based check would silently fail and spawn duplicate
  backends.
- **Portable UUIDs** via `uuidgen` / `/proc` / `python3` / `node` / `openssl`.

## Relationship to GKD

`crew` is for **interactive, observable, long-lived** worker sessions you watch in tmux.
If you instead want to **programmatically delegate** a task to another model and get the
result back into your main session, use a delegation tool like GKD — it spawns
`claude -p --model X` sub-agents and returns their output. The two compose well: the same
LiteLLM backend from `examples/glm-litellm/` can serve a delegation tool's `baseUrl` too.

## License

MIT — see [LICENSE](LICENSE).
