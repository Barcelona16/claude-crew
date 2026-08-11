# claude-crew

<p align="right"><a href="./README.md">中文</a> · <a href="./README.en.md">English</a></p>

Named, attachable, persistent **tmux sessions for [Claude Code](https://claude.com/claude-code)**,
with pluggable model backends.

A *crew session* is a tmux session running `claude`, pinned to a **name**, a **backend**
(base URL + model + token + env), and a **stable session-id**. That gives you:

- **Address a long-lived agent by name** — `crew api "add rate limiting"`, `crew docs "update the changelog"`.
- **Attach any time to watch** — `crew attach api` drops you into the live session.
- **Persistence** — sessions `--resume` the same conversation across tmux/host restarts.
- **Per-session model + key switching** — two knobs (`--model` / `--key`) over CCR; run one session on Opus, another on GLM/kimi.

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
crew mysess --model GLM-5.2  # switch model (auto-attaches after); --key switches the key
crew ls                   # list sessions (name / status / model / key)
crew models               # list model presets
crew keys                 # list API key aliases (masked)
crew up                   # ensure dependency services are up (CCR / joycode proxy)
crew attach mysess        # attach to observe
crew kill mysess          # stop a session
crew send bob "look at X" # drop a message in another session's mailbox (see "Talking between sessions")
crew inbox                # read your own mailbox
```

Session name defaults to the current directory's basename (deduped with a number on
collision). The directory↔name map and each session's id live under
`~/.local/share/claude-crew/`, so re-running `crew` from the same directory reattaches
the same conversation.

**Flags:** `--model <name>` pick a model preset (`--backend` is a hidden alias) · `--key <alias>`
switch the API key (`--key -` clears) · `--fresh` start a new conversation (no `--resume`) ·
`--safe` drop the bypass (**bypass is ON by default**; `CREW_YOLO=0` disables globally). A
`--model`/`--key` switch on an interactive TTY restarts (keeps history via `--resume`) and **auto-attaches**.

## Model presets (over CCR)

A preset is `~/.config/claude-crew/backends/<name>.conf` (sourced as bash). `crew models`
lists them. Each defines how it routes (`BASE_URL` / `MODEL` / `TOKEN`) and its `KEY_MODE`
(how `--key` lands) — see [`backends/default.conf.example`](backends/default.conf.example):

| Key | Meaning |
|-----|---------|
| `BASE_URL` | `ANTHROPIC_BASE_URL` (usually CCR `:3456`) |
| `MODEL` | `claude --model <MODEL>`; for `ccr` mode written as `provider,realmodel` |
| `TOKEN` / `TOKEN_CMD` / `TOKEN_ENV` | inbound auth token (literal / command stdout / env var name) |
| `KEY_MODE` | `token` (default) / `ccr` / `litellm` — see below |
| `ENV_EXTRA` | extra `K=V` injected into the session (e.g. `MAX_THINKING_TOKENS=0`) |
| `DANGEROUS` | `1` → force `--dangerously-skip-permissions` (bypass is now on by default) |

**Two knobs: `--model` (pick a preset) + `--key` (pick a key)**. How `--key` lands depends on the preset's `KEY_MODE`:

| KEY_MODE | Routing | `--key <alias>` effect |
|---|---|---|
| `token` (default) | direct to the gateway; the inbound token is the credential | replaces `ANTHROPIC_AUTH_TOKEN` with the key from `keys.conf` |
| `ccr` | via [claude-code-router](https://github.com/musistudio/claude-code-router) `:3456`, `MODEL=provider,realmodel` | swaps to the CCR provider serving that model with that key (resolved live from CCR's config) |
| `litellm` | via a local LiteLLM | starts a per-key upstream port (mainly for `claude -p` delegation) |

**Prefer `ccr`** — CCR's Anthropic↔OpenAI streaming translation is correct (usable for
interactive sessions; LiteLLM's emits empty deltas), and keys live in one place (CCR config).
`--key` aliases are in `~/.config/claude-crew/keys.conf` (`alias=key`); `crew keys` lists them
masked. To make "any model × any key" switchable, give each model a provider for both keys in CCR.

Preset names **are the CCR model names** (`crew models`); joycode-served models are prefixed
`joycode_<model>`. joycode has **two routes**: Claude-family models go via `joycode,` (CCR
Anthropic transformer → the proxy's anthropic endpoint), while non-Claude ones (kimi / glm /
JoyAI-Code / MiniMax / DeepSeek …) go via `joycode-oai,` (CCR OpenAI transformer → the proxy's
OpenAI endpoint) — the presets are set up, so you just `crew --model joycode_<name>`.

```bash
crew mysess --model Claude-Opus-4.8-joybuilder             # Opus-4.8 (via CCR)
crew mysess --model Claude-Opus-4.8-joybuilder --key k8b04 # switch key (→ the matching CCR provider)
crew mysess --model GLM-5.2 --key k19aa
crew mysess --model kimi-k3-joybuilder                     # kimi (via CCR)
crew mysess --model joycode_Claude-Opus-4.7-hq            # joycode Claude family (via the :8765 proxy)
crew mysess --model joycode_Kimi-K2.6                     # joycode non-Claude (kimi/glm/etc, same proxy)
crew keys                                                  # see key aliases
```

## Dependency services (CCR + joycode proxy)

`ccr` presets need local proxies running:

- **CCR (claude-code-router) `:3456`** — the single entry point; translates/forwards Claude
  Code's Anthropic requests to each gateway and **picks the upstream key per provider**.
- **joycode proxy `:8765`** (only for `joycode_*` models) — reads the VS Code JoyCode login,
  HMAC-signs, and forwards to JoyCode's SaaS gateway. That auth is custom, so CCR can't replace
  it — it must run separately.

Run both as **launchd agents** (background + auto-restart + start at login). crew auto-ensures
deps when starting a `ccr` session, and `crew up` checks/starts them on demand:

```bash
crew up   # ensure CCR :3456 + joycode :8765 (kickstarts the launchd agents as needed)
```

Install the launchd agents (macOS; plists are generated under `~/.claude-code-router/`):

```bash
cp ~/.claude-code-router/com.claudecrew.ccr.plist     ~/Library/LaunchAgents/
cp ~/.claude-code-router/com.claudecrew.joycode.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.ccr.plist
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.joycode.plist
# restart after editing CCR config (no terminal needed):
launchctl kickstart -k gui/$(id -u)/com.claudecrew.ccr
```

> **Don't run `ccr start` in the foreground** — it's a foreground process; let launchd manage it.
> Override ports/labels with `CREW_CCR_PORT` / `CREW_CCR_LABEL` / `CREW_JOYCODE_PORT` /
> `CREW_JOYCODE_LABEL` (handy for other environments like the cloud). Keep the joycode proxy
> script outside TCC-protected dirs (e.g. `~/.config/claude-crew/`), else launchd reading
> `~/Desktop` is denied by macOS.

## Optional extension: GKD programmatic delegation

Core crew = tmux + CCR model/key switching. Optional add-ons live as `ext/*.sh`, sourced at
startup from `$CREW_HOME/ext/` (loaded if present; pure core otherwise).
[GKD](https://github.com/alvis-HaoH/gkd) does **programmatic one-shot delegation**: spawn a
`claude -p --model X` sub-process and return just the **result**. Enable it:

```bash
cp ext/gkd.sh ~/.config/claude-crew/ext/       # install the extension
export GKD_DIR=/path/to/gkd                      # point at your GKD checkout
crew delegate --model GLM-5.2 "rewrite these 50 files to X"  # programmatic delegation, result returned
crew gkd-sync                                    # sync crew presets into GKD's models.json
```

Without the extension, `delegate`/`gkd-sync` print how to install it. Core session management
depends on neither GKD nor any particular project.

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

## tmux: scrollback with the wheel + select-to-copy

When you `crew attach`, if tmux's mouse is off the scroll wheel flips through shell history instead of
Claude's output, and selecting text won't reach the system clipboard. `crew` already turns `mouse on`
for the sessions it creates (scoped to crew sessions, not your global config), so the wheel just works.
But "select → copy to system clipboard" is a tmux key-table binding that belongs in your own
`~/.tmux.conf`:

```tmux
set -g mouse on
set -g history-limit 50000
# Wheel in a normal pane enters copy-mode to scroll history
bind-key -T root WheelUpPane if-shell -F "#{alternate_on}" "send-keys -M" "copy-mode -e"
# Select-to-clipboard (macOS: pbcopy; Linux: "xclip -selection clipboard")
setw -g mode-keys vi
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "pbcopy"
bind-key -T copy-mode-vi Enter            send-keys -X copy-pipe-and-cancel "pbcopy"
bind-key -T copy-mode-vi y                send-keys -X copy-pipe-and-cancel "pbcopy"
```

> Terminal.app does not support holding `Option` to bypass the tmux mouse (that's an iTerm2 feature),
> so the copy-mode path is the reliable one: drag to select → release → it's in the clipboard → `Cmd+V`
> to paste. iTerm2/Ghostty support both ways.

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
