# Demo GIF

`docs/crew-demo.gif` (embedded at the top of the READMEs) is generated with
[VHS](https://github.com/charmbracelet/vhs) — a declarative terminal recorder.
The recording is **offline and canned**: `crew` is aliased to `demo.sh`, which
just prints representative output. Nothing touches tmux, CCR, or any gateway, so
the GIF is stable and reproducible.

It shows crew's four headline features: many models · per-session model/key
switching · automatic multi-key failover (crew-proxy) · inter-session summon.

## Regenerate

```bash
brew install vhs          # needs ffmpeg (a VHS dependency)
vhs scripts/demo.tape     # writes docs/crew-demo.gif
```

## Files

- `demo.tape` — the VHS script: typing, pacing, theme, and which commands to show.
- `demo.sh` — canned output per crew subcommand (models / a session / ls / failover / send / inbox).
- `demo-init.sh` — sourced at the start so the tape never types shell metacharacters;
  defines `crew() { bash scripts/demo.sh "$@"; }`.

To change the demo, edit `demo.tape` (pacing/commands) and `demo.sh` (output),
then re-run `vhs scripts/demo.tape`. Keep the GIF small (< ~3 MB) so it loads fast.
