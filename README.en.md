# claude-crew

<p align="right"><a href="./README.md">中文</a> · <a href="./README.en.md">English</a></p>

Named, attachable, persistent **tmux sessions for [Claude Code](https://claude.com/claude-code)**,
with pluggable model backends.

A *crew session* is a tmux session running `claude`, pinned to a **name**, a **backend**
(base URL + model + token + env), and a **stable session-id**. That gives you:

- **Address a long-lived agent by name** — `crew api "add rate limiting"`, `crew docs "update the changelog"`.
- **Attach any time to watch** — `crew attach api` drops you into the live session.
- **Persistence** — sessions `--resume` the same conversation across tmux/host restarts.
- **Per-session backends** — run one session on Claude, another on a cheaper model, side by side.

It's a thin, dependency-light bash script (tmux + Claude Code). No daemon, no config server,
**no dependency on any particular project**.

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
crew send bob "look at X" # drop a message in another session's mailbox (see "Talking between sessions")
crew inbox                # read your own mailbox
```

Session name defaults to the current directory's basename (deduped with a number on
collision). The directory↔name map and each session's id live under
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

## Working with GKD: interactive sessions + programmatic delegation

`crew` manages **interactive, observable, long-lived** tmux sessions. [GKD](https://github.com/alvis-HaoH/gkd) is for
**programmatic one-shot delegation**: it spawns a `claude -p --model X` sub-process to do
the work and returns just the **result**. The two are complementary, and crew wires GKD in:

- **crew is the single source of backend truth; GKD borrows it.** `crew gkd-sync` projects
  crew's `backends/*.conf` into GKD's `config/models.json` (define once, use in both).
- **`crew delegate --backend B "task"`** — one-shot programmatic delegation: ensure the
  backend is up → sync backends into GKD → invoke GKD's runtime → print the result to stdout.

```bash
crew mysess "iterate on this module over time"        # interactive: an attachable tmux session
crew delegate --backend glm "rewrite these 50 files to X"   # programmatic: GKD delegation, result returned
crew gkd-sync                                          # manually sync crew backends into GKD's models.json
```

**GKD is an optional dependency**: `delegate`/`gkd-sync` need GKD — point `GKD_DIR` at your
GKD checkout ([install GKD](https://github.com/alvis-HaoH/gkd)); everything else (session
management) works without it. crew depends on **neither GKD nor any particular project**.

## Talking between sessions (async mailbox)

Sessions communicate via a **mailbox**: `crew send` drops a message (a file) into another
session's inbox, and the recipient reads it with `crew inbox` when it's ready. Since `crew`
is on PATH inside a session, an agent can `crew send other "..."` itself — that's agent-to-agent
collaboration.

```bash
crew send bob "review the rate-limit denominator"   # deliver (async, doesn't interrupt bob)
crew send --nudge bob "urgent, look now"             # deliver AND inject a one-line "you have mail" prompt
crew send --all "pausing — main is about to change"  # broadcast to all running sessions
crew inbox                                            # read + consume your mailbox (auto-detects your session)
crew inbox --peek bob                                 # look without consuming
```

Each message is tagged with a sender (`--from`, defaults to `$CREW_SESSION` or `cli`) and a
timestamp. crew injects `CREW_SESSION=<name>` into each session, so an agent knows "who am I"
and its messages are auto-signed. The mailbox is **async** — it doesn't interrupt the recipient
unless you add `--nudge`.

## Notes & gotchas

- **Session isolation.** Named sessions are persistent (`--resume`) *and* inherit their
  working directory's `CLAUDE.md`. For a clean one-off task, use a fresh session name in a
  neutral directory (or `--fresh`) — otherwise prior history or a project's `CLAUDE.md` can
  steer the agent off-task.
- **Container-friendly.** The "is the backend already up?" check uses bash's built-in
  `/dev/tcp` (falling back to `nc`/`lsof`/`ss`), so it works in minimal containers that
  ship no `lsof` — where an `lsof`-based check would silently fail and spawn duplicate backends.
- **Portable UUIDs** via `uuidgen` / `/proc` / `python3` / `node` / `openssl`.

## License

MIT — see [LICENSE](LICENSE).
