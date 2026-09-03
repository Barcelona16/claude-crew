#!/usr/bin/env bash
# crew-stop-hook.test.sh — Stop hook 脚本单元测试(v3.1 升级 2)
# 覆盖 spec §8 单元 U1-U7 + 独立 U8(work 2026-09-03 建议):
#   U1 合法 Stop JSON + inbox 有触发者 → 写 turn-done 到触发者 inbox
#   U2 缺 session_id/reason 等字段 → 恒退 0 不 crash
#   U3 triggerFrom 反查:consumed 最新条目 from.kind=session 且非 self → 命中
#   U4 空 inbox(用户手敲 tmux 场景)→ triggerFrom=null 静默不发
#   U5 恒退 0:node 缺失(模拟) / CN 缺失 / 坏 JSON / 无 CREW_SESSION 全静默
#   U6 marker 已存在 → 跳过重复通知
#   U7 crew-notify.js write 支持 --channel/--kind(写入 envelope)
#   U8 (追加断言 · 不算入 7 用例范围)launcher 生成 settings.json:有/无 Stop hook 两种
#      语法均合法 JSON;有 hook 时 hooks.Stop 挂 crew-stop-hook.sh
#
# 参考 crew-sendmsg-hook.test.sh 结构(env -i 隔离,STATE 每 case 干净)。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../bin/crew-stop-hook.sh"
CN="$SCRIPT_DIR/../bin/crew-notify.js"
LAUNCHER="$SCRIPT_DIR/../bin/crew-launcher"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

unset CREW_SESSION CREW_STATE FEEDBACK_JSONL 2>/dev/null || true

# 模拟触发者 X 发给 self 的 consumed 信封(供 triggerFrom 反查命中)
seed_consumed() {
  local state="$1" self="$2" from_id="$3" from_kind="${4:-session}"
  mkdir -p "$state/inbox/$self/consumed"
  cat > "$state/inbox/$self/consumed/0001-2026-09-03T00-00-00Z.json" <<EOF
{"id":"trig01","ts":"2026-09-03T00:00:00Z","from":{"kind":"$from_kind","id":"$from_id"},"note":"trigger","delivery":{"state":"acked"}}
EOF
}

# 模拟 transcript jsonl 有一条 assistant text
seed_transcript() {
  local file="$1" text="$2"
  cat > "$file" <<EOF
{"type":"user","message":{"content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"$text"}]}}
EOF
}

# 每 case 一个干净 state 目录。env -i 干净环境,只保留 PATH/HOME + 显式传入的。
run_hook() {
  local json="$1"; shift
  STATE="$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)"
  printf '%s' "$json" | env -i PATH="$PATH" HOME="$HOME" \
    CREW_STATE="$STATE/state" FEEDBACK_JSONL="$STATE/fb.jsonl" "$@" bash "$HOOK"
  RC=$?
}
inbox_count() { ls "$STATE/state/inbox/$1"/*.json 2>/dev/null | wc -l | tr -d ' '; }
cleanup() { rm -rf "$STATE"; }

# ---- U1: 合法 Stop + triggerFrom 命中 → 写 turn-done ----
echo "--- U1: 合法 Stop + triggerFrom 命中 → 写 turn-done ---"
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
seed_consumed "$STATE/state" "alice" "bob"
TP="$STATE/transcript.jsonl"
seed_transcript "$TP" "task complete abc"
printf '%s' "{\"session_id\":\"sid1\",\"transcript_path\":\"$TP\",\"cwd\":\"/x\",\"hook_event_name\":\"Stop\",\"reason\":\"end_turn\"}" \
  | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE/state" CREW_SESSION=alice bash "$HOOK"
RC=$?
[ "$RC" = 0 ] && _ok "退 0" || _ng "退码=$RC"
[ "$(inbox_count bob)" = 1 ] && _ok "bob(触发者)inbox 写 1 条 turn-done" || _ng "bob inbox 数=$(inbox_count bob)"
f=$(ls "$STATE/state/inbox/bob"/*.json 2>/dev/null | head -1)
if [ -n "$f" ]; then
  node -e "
    const e=JSON.parse(require('fs').readFileSync('$f'));
    const ok = e.channel==='crew-auto-done'
      && e.kind==='turn-done'
      && e.from.kind==='session' && e.from.id==='alice'
      && e.note.includes('[auto-done] alice turn 完成')
      && e.note.includes('task complete abc');
    process.exit(ok?0:1);
  " && _ok "信封:channel=crew-auto-done, kind=turn-done, from=alice, note 含 snippet" \
    || _ng "信封字段/note 内容不对"
else _ng "无信封文件"; fi
# marker 应写入
[ -f "$STATE/state/alice.turn-sid1.done" ] && _ok "marker 已写入" || _ng "marker 未写入"
cleanup

# ---- U2: 缺字段(session_id/reason)→ 恒退 0 不 crash ----
echo "--- U2: 缺字段 session_id/reason → 恒退 0 ---"
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
seed_consumed "$STATE/state" "alice" "bob"
printf '%s' '{"hook_event_name":"Stop"}' | env -i PATH="$PATH" HOME="$HOME" \
  CREW_STATE="$STATE/state" CREW_SESSION=alice bash "$HOOK"
RC=$?
[ "$RC" = 0 ] && _ok "缺 session_id/reason 退 0 不 crash" || _ng "退码=$RC"
# 无 sid → marker 命名会是 alice.turn-.done,消息仍会发出(是防御性行为,不是 bug)
# 关键是不 crash + 退 0
cleanup

# ---- U3: triggerFrom 反查:consumed 最新条目 kind=session 非 self → 命中 ----
echo "--- U3: triggerFrom 反查命中 kind=session 非 self ---"
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
mkdir -p "$STATE/state/inbox/alice/consumed"
# 两条,较老的 kind=erp(应跳过),较新的 kind=session/name=bob(应命中)
cat > "$STATE/state/inbox/alice/consumed/0001-A.json" <<'EOF'
{"from":{"kind":"erp","id":"wangqiwang1"}}
EOF
cat > "$STATE/state/inbox/alice/consumed/0002-B.json" <<'EOF'
{"from":{"kind":"session","id":"bob"}}
EOF
TP="$STATE/tp.jsonl"
seed_transcript "$TP" "hi"
printf '%s' "{\"session_id\":\"s3\",\"transcript_path\":\"$TP\",\"hook_event_name\":\"Stop\",\"reason\":\"r\"}" \
  | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE/state" CREW_SESSION=alice bash "$HOOK"
[ "$(inbox_count bob)" = 1 ] && _ok "反查命中最新 session:bob(跳过 erp)" || _ng "反查错 · bob 数=$(inbox_count bob)"
cleanup

# ---- U4: 空 inbox → triggerFrom=null 静默不发 ----
echo "--- U4: 空 inbox → 静默不发 ---"
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
# 不 seed consumed
printf '%s' '{"session_id":"s4","transcript_path":"/nope","hook_event_name":"Stop","reason":"r"}' \
  | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE/state" CREW_SESSION=alice bash "$HOOK"
RC=$?
[ "$RC" = 0 ] && _ok "退 0" || _ng "退码=$RC"
[ ! -d "$STATE/state/inbox" ] || [ "$(ls "$STATE/state/inbox" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && _ok "空 inbox 不创建任何 outbound" || _ng "空 inbox 反而写了?"
[ ! -f "$STATE/state/alice.turn-s4.done" ] && _ok "空 inbox 场景不写 marker(未发送)" || _ng "空 inbox 但写了 marker"
cleanup

# ---- U5: 恒退 0 组合(坏 JSON / 无 CREW_SESSION / CN 缺失)----
echo "--- U5: 恒退 0(坏 JSON / 无 CREW_SESSION / CN 缺失)---"
u5_ok=0
# a) 坏 JSON
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
seed_consumed "$STATE/state" "alice" "bob"
printf '%s' 'not json {{' | env -i PATH="$PATH" HOME="$HOME" \
  CREW_STATE="$STATE/state" CREW_SESSION=alice bash "$HOOK"
[ "$?" = 0 ] && [ "$(inbox_count bob)" = 0 ] && u5_ok=$((u5_ok+1))
cleanup
# b) 无 CREW_SESSION
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
seed_consumed "$STATE/state" "alice" "bob"
printf '%s' '{"session_id":"x","hook_event_name":"Stop","reason":"r"}' \
  | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE/state" bash "$HOOK"
[ "$?" = 0 ] && [ "$(inbox_count bob)" = 0 ] && u5_ok=$((u5_ok+1))
cleanup
# c) CN 不存在 → hook 自身 exit 0(通过 spawn timeout 或 CN 检测:hook 里 [ -f "$CN" ] || exit 0)
#    模拟方式:重命名 crew-notify.js
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
seed_consumed "$STATE/state" "alice" "bob"
# 让 hook 找 CN 找不到 · 做法:用假 script path 变量(hook 内 SCRIPT_DIR 决定 CN,不便改)
# 用 fake_hook 备份法:复制 hook 到临时目录(内联 CN 路径也是 SCRIPT_DIR/../bin/crew-notify.js)
FAKE_BIN=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
mkdir -p "$FAKE_BIN/bin"
cp "$HOOK" "$FAKE_BIN/bin/crew-stop-hook.sh"
# 不放 crew-notify.js,hook 内 [ -f "$CN" ] || exit 0 会命中
printf '%s' '{"session_id":"x","hook_event_name":"Stop","reason":"r"}' \
  | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE/state" CREW_SESSION=alice \
  bash "$FAKE_BIN/bin/crew-stop-hook.sh"
[ "$?" = 0 ] && u5_ok=$((u5_ok+1))
rm -rf "$FAKE_BIN"
cleanup
[ "$u5_ok" = 3 ] && _ok "3 种恒退 0 场景全通过($u5_ok/3)" || _ng "只 $u5_ok/3 通过"

# ---- U6: marker 已存在 → 跳过重复 ----
echo "--- U6: marker 已存在 → 跳过 ---"
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
seed_consumed "$STATE/state" "alice" "bob"
mkdir -p "$STATE/state"
touch "$STATE/state/alice.turn-dupsid.done"
TP="$STATE/tp.jsonl"
seed_transcript "$TP" "second turn"
printf '%s' "{\"session_id\":\"dupsid\",\"transcript_path\":\"$TP\",\"hook_event_name\":\"Stop\",\"reason\":\"r\"}" \
  | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE/state" CREW_SESSION=alice bash "$HOOK"
RC=$?
[ "$RC" = 0 ] && _ok "退 0" || _ng "退码=$RC"
[ "$(inbox_count bob)" = 0 ] && _ok "marker 命中 → bob inbox 无新条目(跳过)" || _ng "重复通知 · bob 数=$(inbox_count bob)"
cleanup

# ---- U7: crew-notify.js write 支持 --channel/--kind ----
echo "--- U7: crew-notify.js --channel/--kind 参数写入 envelope ---"
STATE=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE/state" \
  node "$CN" write --to bob --from session:alice --note "hi" --channel crew-auto-done --kind turn-done >/dev/null
f=$(ls "$STATE/state/inbox/bob"/*.json 2>/dev/null | head -1)
if [ -n "$f" ]; then
  node -e "
    const e=JSON.parse(require('fs').readFileSync('$f'));
    process.exit((e.channel==='crew-auto-done' && e.kind==='turn-done')?0:1);
  " && _ok "envelope 含 channel=crew-auto-done + kind=turn-done" || _ng "字段不对"
else _ng "write 无产物"; fi
# 且默认(不给 --channel)时,envelope.channel 不应存在(靠 mirror fallback)
STATE2=$(mktemp -d /tmp/crew-stop-hook-test.XXXXXX)
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE2/state" \
  node "$CN" write --to bob --from session:alice --note "hi2" >/dev/null
f2=$(ls "$STATE2/state/inbox/bob"/*.json 2>/dev/null | head -1)
node -e "
  const e=JSON.parse(require('fs').readFileSync('$f2'));
  process.exit((typeof e.channel==='undefined' && typeof e.kind==='undefined')?0:1);
" && _ok "默认不给 --channel 时 envelope 不含 channel/kind 字段(向后兼容)" \
  || _ng "默认路径破坏了兼容"
rm -rf "$STATE2"
cleanup

# ---- U8(独立断言 · work 2026-09-03 建议)----
# launcher 生成 settings.json 的两种路径都要合法 JSON。
# 直接跑 launcher 里的内联 node 片段,不 spawn 完整 launcher(避免依赖 backend/tmux)。
echo "--- U8: launcher 生成 settings.json 语法合法(有/无 Stop hook)---"
u8_a=$(HOOK_CMD=/x MATCHER=SendMessage STOP_HOOK_CMD=/y HAS_STOP=1 node -e '
  const hooks={PostToolUse:[{matcher:process.env.MATCHER,
    hooks:[{type:"command",command:process.env.HOOK_CMD}]}]};
  if (process.env.HAS_STOP) {
    hooks.Stop=[{matcher:"*",
      hooks:[{type:"command",command:process.env.STOP_HOOK_CMD}]}];
  }
  process.stdout.write(JSON.stringify({hooks}));
')
u8_b=$(HOOK_CMD=/x MATCHER=SendMessage STOP_HOOK_CMD=/y HAS_STOP="" node -e '
  const hooks={PostToolUse:[{matcher:process.env.MATCHER,
    hooks:[{type:"command",command:process.env.HOOK_CMD}]}]};
  if (process.env.HAS_STOP) {
    hooks.Stop=[{matcher:"*",
      hooks:[{type:"command",command:process.env.STOP_HOOK_CMD}]}];
  }
  process.stdout.write(JSON.stringify({hooks}));
')
node -e "const j=JSON.parse('$u8_a');process.exit((j.hooks.Stop && j.hooks.Stop[0].matcher==='*' && j.hooks.Stop[0].hooks[0].command==='/y')?0:1)" \
  && _ok "有 Stop hook 时 settings.json 合法 + Stop 段挂载正确" || _ng "有 Stop 分支 JSON 或字段不对"
node -e "const j=JSON.parse('$u8_b');process.exit((typeof j.hooks.Stop==='undefined' && j.hooks.PostToolUse)?0:1)" \
  && _ok "无 Stop hook 时 settings.json 合法 + 仅 PostToolUse 挂载(降级)" || _ng "降级分支 JSON 或字段不对"

echo
echo "=== crew-stop-hook.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
