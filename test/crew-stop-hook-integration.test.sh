#!/usr/bin/env bash
# crew-stop-hook-integration.test.sh — Stop hook 集成 + 混沌(spec §8 I1-I5 + C1-C3)
#
# 集成 5 场景:
#   I1 A crew send B("do X") → B turn 完 hook 自动回 A 一条 turn-done
#   I2 A 派 5 条给 B → B 每 turn 完各回 1 条 → A 拿到 5 条 turn-done
#   I3 用户 attach tmux 手敲 B(inbox 无触发者)→ hook 触发但 triggerFrom=null 不发
#   I4 B 会话手动 crew send A "完事汇报"(marker 已存在,Stop hook 后触发)→ 检测 marker 跳过
#   I5 A 已 kill(tmux 无)· crew-notify.js write 仍成功(inbox 权威副本)· hook 恒不 crash
#
# 混沌 3 类:
#   C1 hook stdin 是坏 JSON / 空 / 非预期结构 → 恒退 0
#   C2 crew-notify.js 缺失/不可执行 → 恒退 0(hook 内 [ -f "$CN" ] || exit 0)
#   C3 inbox tail 反查时 consumed 目录中有坏 JSON 混杂 → 跳过坏行读到好条目
#
# 说明:不起真 tmux,直接调 crew-notify.js write + bash crew-stop-hook.sh 组合,
#      因为 Stop hook 触发时机是 turn 结束,单测能覆盖机制层完整性。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../bin/crew-stop-hook.sh"
CN="$SCRIPT_DIR/../bin/crew-notify.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

unset CREW_SESSION CREW_STATE FEEDBACK_JSONL 2>/dev/null || true

# helper:模拟 A crew send B(直接调 crew-notify.js write),然后 B ack 消费(挪到 consumed/)
# 这样 B 的 consumed 目录里就有 from.name=A 的信封,supra 触发 Stop hook 时可反查命中
# P0-1 修(self-review · work 判决):FEEDBACK_JSONL 隔离到 $state 目录,避免污染
# 生产 /work/agent-bridge/logs/feedback.jsonl(域宪法 69df9bc 红线)。
mock_A_send_B() {
  local from="$1" to="$2" note="${3:-msg}"
  # state 通过 $STATE(全局)传入,避免 helper 签名膨胀
  env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE" FEEDBACK_JSONL="$STATE/fb.jsonl" \
    node "$CN" write --to "$to" --from "session:$from" --note "$note" >/dev/null
  # ack 消费到 consumed(模拟 B drain --ack)
  env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE" FEEDBACK_JSONL="$STATE/fb.jsonl" \
    node "$CN" ack --to "$to" >/dev/null 2>&1
}

# 触发一次 B 的 Stop hook(session_id 传入,transcript 用临时 jsonl)
# P0-1 修:注入 FEEDBACK_JSONL 隔离。
trigger_B_stop() {
  local self="$1" sid="$2" tp="$3"
  printf '%s' "{\"session_id\":\"$sid\",\"transcript_path\":\"$tp\",\"cwd\":\"/x\",\"hook_event_name\":\"Stop\",\"reason\":\"end_turn\"}" \
    | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE" FEEDBACK_JSONL="$STATE/fb.jsonl" \
    CREW_SESSION="$self" bash "$HOOK"
}

seed_transcript() {
  local file="$1" text="$2"
  cat > "$file" <<EOF
{"type":"user","message":{"content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"$text"}]}}
EOF
}

inbox_count() { ls "$1"/*.json 2>/dev/null | wc -l | tr -d ' '; }

echo "=== 集成 5 场景 ==="

# ---- I1: A→B → B turn 完 → A 收到 1 条 turn-done ----
echo "--- I1: A→B, B turn 完自动回 A ---"
STATE=$(mktemp -d /tmp/crew-i1.XXXXXX)
mock_A_send_B "alice" "bob" "please do X"
TP="$STATE/t1.jsonl"; seed_transcript "$TP" "X done"
trigger_B_stop "bob" "sid-i1" "$TP"
c=$(inbox_count "$STATE/inbox/alice")
[ "$c" = 1 ] && _ok "A 收到 1 条 turn-done" || _ng "A inbox 数=$c"
# 校验回执内容
f=$(ls "$STATE/inbox/alice"/*.json 2>/dev/null | head -1)
node -e "
  const e=JSON.parse(require('fs').readFileSync('$f'));
  const ok=e.channel==='crew-auto-done' && e.kind==='turn-done' && e.from.id==='bob'
    && e.note.includes('X done');
  process.exit(ok?0:1);
" && _ok "回执 channel/kind/from/snippet 都对" || _ng "回执字段不对"
rm -rf "$STATE"

# ---- I2: A 派 5 条给 B → B 5 turn 各回 1 条 → A 收到 5 条 turn-done ----
echo "--- I2: A 派 5 条,B 每 turn 完回 1 条,A 累计 5 条 ---"
STATE=$(mktemp -d /tmp/crew-i2.XXXXXX)
# 派 5 条(每条各 mock 一次 send + ack,让 B 的 consumed 累计 5 个 A 信封)
for i in 1 2 3 4 5; do
  mock_A_send_B "alice" "bob" "task $i"
done
# B 起 5 个 turn,每 turn 一个不同 sid → 5 个 marker,应 5 次触发都不去重
for i in 1 2 3 4 5; do
  TP="$STATE/t2-$i.jsonl"; seed_transcript "$TP" "done $i"
  trigger_B_stop "bob" "sid-i2-$i" "$TP"
done
c=$(inbox_count "$STATE/inbox/alice")
[ "$c" = 5 ] && _ok "A 收到 5 条 turn-done" || _ng "A inbox 数=$c(期望 5)"
rm -rf "$STATE"

# ---- I3: 用户手敲 B(consumed 空)→ hook triggerFrom=null 不发 ----
echo "--- I3: 无触发者(用户手敲)→ 静默不发 ---"
STATE=$(mktemp -d /tmp/crew-i3.XXXXXX)
# 不 mock_A_send_B · B consumed 目录不存在或为空
TP="$STATE/t3.jsonl"; seed_transcript "$TP" "manual work"
trigger_B_stop "bob" "sid-i3" "$TP"
[ ! -d "$STATE/inbox" ] || [ "$(ls "$STATE/inbox" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && _ok "无触发者:未创建任何 outbound inbox" || _ng "空 consumed 反而写了 outbound"
[ ! -f "$STATE/bob.turn-sid-i3.done" ] && _ok "未发送时不写 marker" || _ng "误写 marker"
rm -rf "$STATE"

# ---- I4: marker 预置(模拟会话手动完事汇报已跑)→ hook 后触发跳过 ----
echo "--- I4: marker 预置 → hook 跳过重复 ---"
STATE=$(mktemp -d /tmp/crew-i4.XXXXXX)
mock_A_send_B "alice" "bob" "trigger"
# 会话手动 crew send A 完事汇报 → 假设它自己写 marker(spec §5 conservative:未来可选,当前 hook 冷启动为主)
# 我们直接预置 marker 模拟"手动汇报早于 hook"的时序
mkdir -p "$STATE"
touch "$STATE/bob.turn-sid-i4.done"
TP="$STATE/t4.jsonl"; seed_transcript "$TP" "post-manual"
trigger_B_stop "bob" "sid-i4" "$TP"
c=$(inbox_count "$STATE/inbox/alice")
# 已存 marker,hook 应跳过(A 无新 outbound)
[ "$c" = 0 ] && _ok "marker 存在:hook 跳过,A 无重复 turn-done" || _ng "重复通知 · A 数=$c"
rm -rf "$STATE"

# ---- I5: A 已 kill(tmux 无)· crew-notify.js write 仍成功(inbox 权威副本)· hook 恒不 crash ----
echo "--- I5: A 已 kill · inbox 权威仍写 · hook 恒不 crash ---"
STATE=$(mktemp -d /tmp/crew-i5.XXXXXX)
mock_A_send_B "alice" "bob" "before-kill"
# 不模拟 tmux · crew-notify.js write 不检测 tmux(权威副本先落,wake 才管 tmux)
TP="$STATE/t5.jsonl"; seed_transcript "$TP" "reply to killed A"
trigger_B_stop "bob" "sid-i5" "$TP"
RC=$?
c=$(inbox_count "$STATE/inbox/alice")
[ "$RC" = 0 ] && _ok "hook 退 0 不 crash(A 挂了对 hook 透明)" || _ng "退码=$RC"
[ "$c" = 1 ] && _ok "A inbox 仍写 1 条(消息不丢)" || _ng "A inbox 数=$c"
rm -rf "$STATE"

# ---- I6(self-review P1-2 修):陈旧 consumed 信封 · 超 2h 窗口 → hook 静默不发 ----
echo "--- I6: 3h 前 consumed 信封 · 超 2h 窗口 → 静默不发 ---"
STATE=$(mktemp -d /tmp/crew-i6.XXXXXX)
# 手工构造陈旧 consumed(ts 是 3h 前 · 手动构造非用 mock_A_send_B 因为后者产生 now ts)
mkdir -p "$STATE/inbox/bob/consumed"
OLD_TS=$(node -e 'console.log(new Date(Date.now()-3*60*60*1000).toISOString())')
cat > "$STATE/inbox/bob/consumed/0001-old.json" <<EOF
{"id":"trig-old-1","ts":"$OLD_TS","from":{"kind":"session","id":"alice"},"note":"stale"}
EOF
TP="$STATE/t6.jsonl"; seed_transcript "$TP" "current turn"
trigger_B_stop "bob" "sid-i6" "$TP"
c=$(inbox_count "$STATE/inbox/alice" 2>/dev/null)
[ -z "$c" ] || [ "$c" = "0" ]
if [ $? -eq 0 ]; then _ok "3h 前信封超窗口 → 不误路由回 alice"; else _ng "陈旧信封误路由 · alice 数=$c"; fi
[ ! -f "$STATE/bob.turn-sid-i6.done" ] && _ok "超窗口不写 marker(未发送)" || _ng "写了 marker"
rm -rf "$STATE"

echo
echo "=== 混沌 3 类 ==="

# ---- C1: 坏 JSON / 空 / 非预期结构 → 恒退 0 ----
echo "--- C1: 坏 JSON / 空 / 缺 hook_event_name → 恒退 0 ---"
c1_ok=0
STATE=$(mktemp -d /tmp/crew-c1.XXXXXX)
mock_A_send_B "alice" "bob" "seed"
# a) 坏 JSON
printf '%s' 'not-json {{{' | env -i PATH="$PATH" HOME="$HOME" \
  CREW_STATE="$STATE" FEEDBACK_JSONL="$STATE/fb.jsonl" CREW_SESSION=bob bash "$HOOK"
[ "$?" = 0 ] && c1_ok=$((c1_ok+1))
# b) 空 stdin
printf '' | env -i PATH="$PATH" HOME="$HOME" \
  CREW_STATE="$STATE" FEEDBACK_JSONL="$STATE/fb.jsonl" CREW_SESSION=bob bash "$HOOK"
[ "$?" = 0 ] && c1_ok=$((c1_ok+1))
# c) 缺 hook_event_name(JSON 合法但字段少)· hook 应容忍
printf '%s' '{"random":"data"}' | env -i PATH="$PATH" HOME="$HOME" \
  CREW_STATE="$STATE" FEEDBACK_JSONL="$STATE/fb.jsonl" CREW_SESSION=bob bash "$HOOK"
[ "$?" = 0 ] && c1_ok=$((c1_ok+1))
[ "$c1_ok" = 3 ] && _ok "3 种坏输入全恒退 0" || _ng "只 $c1_ok/3 通过"
rm -rf "$STATE"

# ---- C2: crew-notify.js 缺失(不可执行)→ 恒退 0 ----
echo "--- C2: crew-notify.js 缺失 → hook 恒退 0 ---"
STATE=$(mktemp -d /tmp/crew-c2.XXXXXX)
mock_A_send_B "alice" "bob" "seed"
# 建 fake bin 目录,只放 hook 副本,不放 crew-notify.js
FAKE=$(mktemp -d /tmp/crew-c2-fake.XXXXXX)
mkdir -p "$FAKE/bin"
cp "$HOOK" "$FAKE/bin/crew-stop-hook.sh"
TP="$STATE/t.jsonl"; seed_transcript "$TP" "x"
printf '%s' "{\"session_id\":\"sc2\",\"transcript_path\":\"$TP\",\"hook_event_name\":\"Stop\",\"reason\":\"r\"}" \
  | env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$STATE" FEEDBACK_JSONL="$STATE/fb.jsonl" CREW_SESSION=bob \
  bash "$FAKE/bin/crew-stop-hook.sh"
RC=$?
[ "$RC" = 0 ] && _ok "CN 缺失 hook 恒退 0" || _ng "退码=$RC"
[ "$(inbox_count "$STATE/inbox/alice" 2>/dev/null)" = 0 ] && _ok "CN 缺失时不产生 outbound" || _ng "无 CN 反而写了"
rm -rf "$FAKE" "$STATE"

# ---- C3: consumed 有坏 JSON 混杂 → 跳过读到好条目 ----
echo "--- C3: consumed 坏 JSON 混杂 · 跳过坏行读好条目 ---"
STATE=$(mktemp -d /tmp/crew-c3.XXXXXX)
mkdir -p "$STATE/inbox/bob/consumed"
# 老条目 · 坏 JSON(最新在前 · sort 逆序读所以文件名要覆盖排序)
cat > "$STATE/inbox/bob/consumed/0003-latest-BAD.json" <<'EOF'
not valid json {{{
EOF
cat > "$STATE/inbox/bob/consumed/0002-mid-A.json" <<'EOF'
{"from":{"kind":"session","id":"alice"}}
EOF
cat > "$STATE/inbox/bob/consumed/0001-oldest-E.json" <<'EOF'
{"from":{"kind":"erp","id":"user"}}
EOF
TP="$STATE/tc3.jsonl"; seed_transcript "$TP" "resilient"
trigger_B_stop "bob" "sid-c3" "$TP"
c=$(inbox_count "$STATE/inbox/alice")
[ "$c" = 1 ] && _ok "跳过坏 JSON(0003) → 读到 alice(0002)" || _ng "alice 数=$c(期望 1)"
rm -rf "$STATE"

echo
echo "=== crew-stop-hook-integration.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
