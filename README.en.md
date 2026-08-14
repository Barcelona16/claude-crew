# claude-crew

<p align="right"><a href="./README.md">中文</a> · <a href="./README.en.md">English</a></p>

Named, attachable, persistent **tmux sessions for [Claude Code](https://claude.com/claude-code)**,
with pluggable model backends.

![demo](docs/crew-demo.gif)

A *crew session* is a tmux session running `claude`, pinned to a **name**, a **backend**
(base URL + model + token + env), and a **stable session-id**. That gives you:

- **Address a long-lived agent by name** — `crew api "add rate limiting"`, `crew docs "update the changelog"`.
- **Attach any time to watch** — `crew attach api` drops you into the live session.
- **Persistence** — sessions `--resume` the same conversation across tmux/host restarts.
- **Per-session model + key switching** — two knobs (`--model` / `--key`) over CCR; run one session on Opus, another on GLM/kimi.
- **Don't want to remember flags? `--pick` pops a menu** — `crew <name> --pick` walks you through model → key → tmux (fzf if installed, else a numbered prompt); an existing session preselects its last config, just hit Enter.
- **Automatic multi-key failover** — give a model a priority-ordered list of keys; when the top one fails repeatedly (401/403/429/5xx), the local `crew-proxy` transparently switches to the next, invisibly to claude.

It's a thin, dependency-light bash script (tmux + Claude Code). No daemon, no config server,
**no dependency on any particular project**.

## Install

```bash
git clone <this repo> && cd claude-crew
bash install.sh          # symlinks `crew` into ~/.local/bin
crew --help
```

## Onboarding a teammate (one-shot `setup.sh`, macOS / Linux)

`install.sh` only installs the `crew` tool itself (session management on your existing Claude).
To get the multi-model **opus/glm/kimi** switching + key failover, run `setup.sh` — it wires up the
dependencies in one go:

```bash
git clone <repo> && cd claude-crew
GATEWAY_TOKEN=<your JD gateway token> bash setup.sh   # or just `bash setup.sh` to be prompted
```

It: installs crew + claude-code-router (`npm i -g`) → **generates/merges** the CCR provider
config with your token (leaves your existing providers untouched) → writes model presets +
`keys.conf` + `key-policy.conf` → installs `crew-proxy` → runs CCR (`:3456`) and crew-proxy
(`:8788`) as background services (**launchd on macOS / systemd --user on Linux**) → sets the
default model.

**Prerequisites (each person's own)**: Node.js, tmux, Claude Code CLI, python3 (used by
crew-proxy); **your own JD llm-gw token** (can't share someone else's — it's tied to their
account/quota). The internal CCR template routes through `llm-gw.jd.local`.

> **Want to ride your JoyCode quota?** joycode has been split out of the core into a separate
> internal plugin repo `claude-crew-joycode` (on JD coding). After the core `setup.sh`, run that
> plugin's `install.sh` — it adds the `joycode_*` presets + proxy.

Then: `crew models` · `crew up` (ensure deps up) · `crew <name> --model GLM-5.2`. **Keys stay
local** (`~/.claude-code-router/config.json`, `~/.config/claude-crew/keys.conf`) — never committed.

## Usage

```bash
crew mysess "read src/app.ts and list its exports"   # start/continue a named session + feed a task
crew                      # ensure + attach the session for the current directory
crew mysess --model GLM-5.2  # switch model (auto-attaches after); --key switches the key
crew mysess --pick           # interactive menus: model → key → tmux (no flags to remember)
crew ls                   # list sessions (name / status / model / key)
crew models               # list model presets
crew keys                 # list API key aliases (masked)
crew up                   # ensure dependency services (CCR / crew-proxy) are up
crew stats                # crew-proxy usage in the terminal (key health + token totals)
crew doctor               # read-only health check (services up, keys/key-policy resolvable)
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
switch the API key (`--key -` clears) · `--pick` (`-p`) **interactive menus for model → key → tmux**
(uses fzf if installed, else a numbered prompt; any knob you also pass on the CLI is skipped;
when the current dir already has a session, defaults preselect its last model/key/tmux) ·
`--fresh` start a new conversation (no `--resume`) ·
`--safe` drop the bypass (**bypass is ON by default**; `CREW_YOLO=0` disables globally). A
`--model`/`--key` switch on an interactive TTY restarts (keeps history via `--resume`) and **auto-attaches**.

## Model presets (over CCR)

A preset is `~/.config/claude-crew/backends/<name>.conf` (sourced as bash). `crew models`
lists them. Each defines how it routes (`BASE_URL` / `MODEL` / `TOKEN`) and its `KEY_MODE`
(how `--key` lands) — see [`backends/default.conf.example`](backends/default.conf.example):

| Key | Meaning |
|-----|---------|
| `BASE_URL` | `ANTHROPIC_BASE_URL` (defaults to crew-proxy `:8788`, which forwards to CCR `:3456`) |
| `MODEL` | `claude --model <MODEL>`; for `ccr` mode written as `provider,realmodel` |
| `TOKEN` / `TOKEN_CMD` / `TOKEN_ENV` | inbound auth token (literal / command stdout / env var name) |
| `KEY_MODE` | `token` (default) / `ccr` — see below |
| `ENV_EXTRA` | extra `K=V` injected into the session (e.g. `MAX_THINKING_TOKENS=0`) |
| `DANGEROUS` | `1` → force `--dangerously-skip-permissions` (bypass is now on by default) |

**Two knobs: `--model` (pick a preset) + `--key` (pick a key)**. How `--key` lands depends on the preset's `KEY_MODE`:

| KEY_MODE | Routing | `--key <alias>` effect |
|---|---|---|
| `token` (default) | direct to the gateway; the inbound token is the credential | replaces `ANTHROPIC_AUTH_TOKEN` with the key from `keys.conf` |
| `ccr` | via [claude-code-router](https://github.com/musistudio/claude-code-router) `:3456` (through crew-proxy by default), `MODEL=provider,realmodel` | swaps to the CCR provider serving that model with that key (resolved live from CCR's config) |

**Prefer `ccr`** — CCR's Anthropic↔OpenAI streaming translation is correct (usable for
interactive sessions), and keys live in one place (CCR config).
`--key` aliases are in `~/.config/claude-crew/keys.conf` (`alias=key`); `crew keys` lists them
masked. To make "any model × any key" switchable, give each model a provider for both keys in CCR.

Preset names **are the CCR model names** (`crew models`).

```bash
crew mysess --model Claude-Opus-4.8-joybuilder             # Opus-4.8 (via CCR)
crew mysess --model Claude-Opus-4.8-joybuilder --key k8b04 # switch key (→ the matching CCR provider)
crew mysess --model GLM-5.2 --key k19aa
crew mysess --model kimi-k3-joybuilder                     # kimi (via CCR)
crew keys                                                  # see key aliases
```

## Dependency services (CCR + crew-proxy)

`ccr` presets need two local services running:

- **CCR (claude-code-router) `:3456`** — the single entry point; translates/forwards Claude
  Code's Anthropic requests to each gateway and **picks the upstream key per provider**. Every
  `ccr` preset goes through it.
- **crew-proxy `:8788`** — a thin proxy sitting between claude and CCR, responsible for **key
  priority + automatic failover**. For a model with no priority list in `key-policy.conf` it's
  just a **transparent forwarder**, entirely invisible to single-key users.

A preset's `BASE_URL` defaults to crew-proxy; it then forwards to CCR. Run both as **launchd
agents** (background + auto-restart + start at login). crew auto-ensures deps when starting a
`ccr` session, or run `crew up` manually:

```bash
crew up   # ensure CCR :3456 + crew-proxy :8788 are up (kickstarts the launchd agents as needed)
```

### Automatic multi-key failover

Give a model a priority-ordered (high → low) list of keys and `crew-proxy` forwards through the
highest-priority healthy key. When that key fails consecutively up to the threshold (default 3,
on status 401/403/429/5xx or a connection error) it **trips** the key, cools it down for a while
(default 60s), and transparently switches to the next one **within the same request** — claude
sees nothing. When all keys are tripped it hard-forwards through the top key, surfacing the real
upstream error (never faking success).

Configure in `~/.config/claude-crew/key-policy.conf`:

```
# <model> = <alias1> <alias2> ...   (highest priority first)
Claude-Opus-4.8-joybuilder = k8b04 k8b05 k8b06
```

Prerequisite: each alias must be (a) in `keys.conf` and (b) backed by a CCR provider that serves
that model with that key. Tunable via env vars: `CREW_PROXY_FAILS` (trip threshold),
`CREW_PROXY_COOLDOWN` (cooldown seconds), `CREW_PROXY_PORT`, and `CREW_PROXY_DISABLE=1` (turn it
off entirely and connect straight to CCR).

### Control dashboard

crew-proxy ships a local control panel — open **http://127.0.0.1:8788/dashboard** in a browser
(zero deps, same process as the proxy, vanilla JS refreshing every 3s). It shows:

- **Keys** — each key's healthy/tripped state, request count, ok/fail, consecutive failures, cooldown
- **Sessions** — every crew session (name/status/model/key/dir); each row has **copy** (copies the `crew <name> --model ...` command), **kill**, and **edit** (change model/key)
- **Recent requests** — a live request feed (model · key · status · whether it failed over)
- **+ add key/provider** — fill in alias/key/model/base_url to write a new provider into your CCR
  config (**config.json is backed up first**; run `crew up` afterwards to reload CCR)

The panel binds `127.0.0.1` only. Every write op (kill / edit / add provider) validates input to
prevent injection. **Token usage** is tallied per key and per model (input/output tokens, parsed
from the upstream response's usage field **after** the body is relayed — so it never slows
forwarding; streaming supported too) and shown on the panel. This version counts tokens only, not
cost.

Install the launchd agents (macOS; plists are generated under `~/.claude-code-router/`):

```bash
cp ~/.claude-code-router/com.claudecrew.ccr.plist   ~/Library/LaunchAgents/
cp ~/.claude-code-router/com.claudecrew.proxy.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.ccr.plist
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.proxy.plist
# restart after editing CCR config (no terminal needed):
launchctl kickstart -k gui/$(id -u)/com.claudecrew.ccr
```

> **Don't run `ccr start` in the foreground** — it's a foreground process; let launchd manage it.
> Override ports/labels with `CREW_CCR_PORT` / `CREW_CCR_LABEL` / `CREW_PROXY_PORT` /
> `CREW_PROXY_LABEL` (handy for adapting to other environments like the cloud).

## Programmatic one-shot delegation

`crew delegate` spawns a `claude -p --model X` sub-process to do the work and prints just the
**result** to stdout — no tmux, no session, no `--resume`. Handy in scripts for "run a one-shot
task on some model and hand back the result":

```bash
crew delegate --model GLM-5.2 "rewrite these 50 files to X"   # one-shot delegation, result to stdout
```

It reuses crew's model presets + `--key` logic and depends on no external tool. Core session
management depends on no particular project. For heavier multi-agent orchestration, write your
own `ext/*.sh` extension (sourced at startup from `$CREW_HOME/ext/` if present).

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
