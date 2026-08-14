# demo.tape — VHS script that records the README GIF.
#   Render:  vhs scripts/demo.tape        (writes docs/crew-demo.gif)
# VHS drives the typing + pacing; `crew` here is a shell function that routes to
# scripts/demo.sh so the output is canned (no tmux/CCR/network). Offline & stable.

Output docs/crew-demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1180
Set Height 660
Set Padding 22
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms
Set PlaybackSpeed 1.0

Hide
Type "source scripts/demo-init.sh" Enter
Show
Sleep 800ms

Type "# claude-crew — one tool, many models, per-session key failover" Sleep 400ms Enter
Sleep 1s

# 1) many models
Type "crew models" Sleep 300ms Enter
Sleep 1800ms

# 2) per-session model switching
Type "crew web  --model GLM-5.2      # session 'web' on GLM" Sleep 300ms Enter
Sleep 900ms
Type "crew docs --model kimi-k3      # session 'docs' on kimi" Sleep 300ms Enter
Sleep 900ms
Type "crew ls                        # who's running, on what key" Sleep 300ms Enter
Sleep 2200ms

# 3) automatic multi-key failover (the headline)
Type "# when the top key starts 429ing, crew-proxy trips it and fails over —" Sleep 250ms Enter
Type "# same request, next key, claude never notices" Sleep 400ms Enter
Sleep 700ms
Type "crew failover" Sleep 300ms Enter
Sleep 2800ms

# 4) inter-session summon
Type "crew send web '接口签名改了,同步下调用方' --nudge" Sleep 300ms Enter
Sleep 1200ms
Type "crew inbox                      # the 'web' agent reads its mailbox" Sleep 300ms Enter
Sleep 2200ms

Type "# + a live dashboard at :8788/dashboard — keys, sessions, logs" Sleep 400ms Enter
Sleep 2200ms
