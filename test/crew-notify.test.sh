#!/usr/bin/env bash
# crew-notify.test.sh — crew notify(send+wake 合一)+ inbox JSON 信封 + delivery ack 单元测试
# 覆盖(方案 §8.1):
#   ① write 落 JSON 信封 + mirror feedback.jsonl
#   ② ack 消费:回写 acked + 移 consumed/ + 镜像 ack 记录
#   ③ --peek 只看不消费,状态不变
#   ④ 老 .msg 兼容(消费 rm 无 ack)
#   ⑤ mark-woke 回写 delivered
#   ⑥ crew send 命令入口
#   ⑦ crew notify(fake tmux idle → send+wake+mark-woke 全链路)
#   ⑧ crew notify --no-wake 只 send 不 wake
#   ⑨ crew notify 目标不存在 → wake exit 1(信封仍写)
#   ⑩ crew inbox 二次消费空

set -uo pipefail

# 2026-09-03 v8:清 CREW_SESSION 避免继承污染 cmd_inbox 身份校验(测试跑本身不代表任何会话)
unset CREW_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
CN="$SCRIPT_DIR/../bin/crew-notify.js"
CW="$SCRIPT_DIR/../bin/crew-wake.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-notify-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

export CREW_STATE="$T/state"
export FEEDBACK_JSONL="$T/feedback.jsonl"
mkdir -p "$CREW_STATE"

# ---- fake tmux(照抄 crew-wake.test.sh 结构)----
FAKE_BIN="$T/fakebin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tmux" <<'FAKE'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  list-sessions)
    if [ -n "${FAKE_TMUX_SESSIONS:-}" ]; then printf '%s\n' "$FAKE_TMUX_SESSIONS" | tr ',' '\n'; exit 0
    else echo "no server" >&2; exit 1; fi ;;
  capture-pane)
    [ -n "${FAKE_TMUX_PANE:-}" ] && [ -f "${FAKE_TMUX_PANE}" ] && cat "${FAKE_TMUX_PANE}"; exit 0 ;;
  send-keys) [ -n "${FAKE_TMUX_SENT:-}" ] && echo "$*" >> "$FAKE_TMUX_SENT"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/tmux"
IDLE_PANE="$T/idle.pane"; printf 'x\n❯ \n' > "$IDLE_PANE"

# ---- Case 1: write 落 JSON 信封 + mirror ----
echo "--- Case 1: write 信封 + mirror ---"
fpath=$(node "$CN" write --to alice --from "session:bob" --note "hi alice")
[ -f "$fpath" ] && _ok "信封文件生成: $(basename $fpath)" || _ng "信封文件未生成"
node -e "const e=JSON.parse(require('fs').readFileSync('$fpath'));process.exit(e.from.kind==='session'&&e.from.id==='bob'&&e.note==='hi alice'&&e.delivery.state==='pending'?0:1)" \
  && _ok "信封字段正确(from=session:bob, state=pending)" || _ng "信封字段不对"
# feedback.jsonl 镜像
[ -f "$FEEDBACK_JSONL" ] && rec=$(tail -1 "$FEEDBACK_JSONL") && \
  echo "$rec" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const r=JSON.parse(d);process.exit(r.session==='alice'&&r.source==='session'&&r.sender==='bob'&&r.replyOut===false?0:1)})" \
  && _ok "feedback.jsonl 镜像 session=alice source=session sender=bob" || _ng "镜像不对: $rec"
# 2026-09-02 [coding PR · comm-redesign]:镜像加 channel='crew-native' 标签
echo "$rec" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const r=JSON.parse(d);process.exit(r.channel==='crew-native'?0:1)})" \
  && _ok "镜像含 channel='crew-native'(drain 侧据此去重)" || _ng "channel 字段缺: $rec"

# ---- Case 2: ack 消费 → acked + 归档 + ack 镜像 ----
echo "--- Case 2: ack 消费 ---"
out=$(node "$CN" ack --to alice)
echo "$out" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const e=JSON.parse(d.trim());process.exit(e.delivery.state==='acked'&&e.delivery.consumedAt?0:1)})" \
  && _ok "ack 返回 state=acked+consumedAt" || _ng "ack 输出不对: $out"
[ -f "$CREW_STATE/inbox/alice/consumed/$(basename $fpath)" ] && _ok "归档到 consumed/" || _ng "未归档"
[ ! -f "$fpath" ] && _ok "原信封已移走" || _ng "原信封还在"
# feedback.jsonl 追加 ack 记录
tail -1 "$FEEDBACK_JSONL" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const r=JSON.parse(d);process.exit(r.ackOf&&r.delivery.state==='acked'?0:1)})" \
  && _ok "feedback.jsonl 追加 ack 记录(ackOf/state=acked)" || _ng "ack 镜像不对"

# ---- Case 3: --peek 只看不消费 ----
echo "--- Case 3: --peek 只看 ---"
node "$CN" write --to bob --from "session:alice" --note "peek me" >/dev/null
before=$(ls "$CREW_STATE/inbox/bob"/*.json 2>/dev/null | wc -l | tr -d ' ')
"$CREW" inbox bob --peek >/dev/null
after=$(ls "$CREW_STATE/inbox/bob"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$before" = "$after" ] && [ "$before" = "1" ] && _ok "--peek 后信封仍在(before=after=1)" || _ng "peek 消费了: before=$before after=$after"

# ---- Case 4: 老 .msg 兼容 ----
echo "--- Case 4: 老 .msg 兼容 ---"
mkdir -p "$CREW_STATE/inbox/legacy"
echo "old plain text" > "$CREW_STATE/inbox/legacy/0001-x.msg"
out=$(node "$CN" ack --to legacy)
echo "$out" | grep -q "old plain text" && _ok ".msg 内容被 ack 打印" || _ng ".msg 未打印"
[ ! -f "$CREW_STATE/inbox/legacy/0001-x.msg" ] && _ok ".msg 消费后已删" || _ng ".msg 未删"

# ---- Case 5: mark-woke ----
echo "--- Case 5: mark-woke ---"
fpath=$(node "$CN" write --to carol --from "session:dave" --note "wake me")
env_id=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$fpath')).id)")
node "$CN" mark-woke --to carol --id "$env_id"
node -e "const e=JSON.parse(require('fs').readFileSync('$fpath'));process.exit(e.delivery.state==='delivered'&&e.delivery.wokeAt?0:1)" \
  && _ok "mark-woke 后 state=delivered+wokeAt" || _ng "mark-woke 未生效"

# ---- Case 6: crew send 命令入口 —— 2026-09-02 根治:默认 send+wake(与 notify 一致)---
echo "--- Case 6: crew send 默认 send+wake ---"
sent6="$T/sent6.log"; : > "$sent6"
CREW_SESSION_NAME=eve PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="frank" \
  FAKE_TMUX_PANE="$IDLE_PANE" FAKE_TMUX_SENT="$sent6" \
  "$CREW" send frank "hello from eve" >/dev/null 2>&1
latest=$(ls -t "$CREW_STATE/inbox/frank"/*.json | head -1)
node -e "const e=JSON.parse(require('fs').readFileSync('$latest'));process.exit(e.from.id==='eve'&&e.note==='hello from eve'?0:1)" \
  && _ok "crew send 写信封 from=eve" || _ng "crew send 信封不对"
# 关键:默认应该也 wake(fake tmux 里 frank 存在 + idle → 应发 Enter)
grep -q "Enter" "$sent6" && _ok "crew send 默认 wake(发 Enter)—— 根治漏 wake 坑" || _ng "crew send 未默认 wake"
# 修 A:wake nudge 应该嵌信封 note 的 preview(不只是"跑 crew inbox")
grep -q "hello from eve" "$sent6" && _ok "wake nudge 嵌信封 preview('hello from eve')—— 消费瞬间见任务" || _ng "wake nudge 未嵌 preview"
grep -q "必读\|完事汇报" "$sent6" && _ok "wake nudge 含必读/汇报义务提示" || _ng "wake nudge 缺义务提示"
# state 应升为 delivered(与 notify 一致)
node -e "const e=JSON.parse(require('fs').readFileSync('$latest'));process.exit(e.delivery.state==='delivered'?0:1)" \
  && _ok "crew send 后 state=delivered" || _ng "state 未升 delivered"

# ---- Case 6b: crew send --no-wake 保留旧行为(批量广播场景)----
echo "--- Case 6b: crew send --no-wake 兼容 ---"
sent6b="$T/sent6b.log"; : > "$sent6b"
before=$(ls "$CREW_STATE/inbox/gio"/*.json 2>/dev/null | wc -l | tr -d ' ')
CREW_SESSION_NAME=eve PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="gio" \
  FAKE_TMUX_PANE="$IDLE_PANE" FAKE_TMUX_SENT="$sent6b" \
  "$CREW" send gio "silent broadcast" --no-wake >/dev/null 2>&1
after=$(ls "$CREW_STATE/inbox/gio"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$after" = "1" ] && _ok "--no-wake 仍写信封" || _ng "信封未写"
[ ! -s "$sent6b" ] && _ok "--no-wake 未 send-keys(旧行为兼容)" || _ng "--no-wake 却 wake 了"
# state 应保持 pending(未 wake)
latest=$(ls -t "$CREW_STATE/inbox/gio"/*.json | head -1)
node -e "const e=JSON.parse(require('fs').readFileSync('$latest'));process.exit(e.delivery.state==='pending'?0:1)" \
  && _ok "--no-wake state=pending(未升 delivered)" || _ng "state 不对"

# ---- Case 7: crew notify 全链路(idle → send+wake+mark-woke) ----
echo "--- Case 7: crew notify 全链路 idle ---"
sent="$T/sent.log"; : > "$sent"
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="grace" FAKE_TMUX_PANE="$IDLE_PANE" \
  FAKE_TMUX_SENT="$sent" WAKE_PENDING_FILE="$T/pend.jsonl" \
  CREW_SESSION_NAME=henry "$CREW" notify grace "notify test" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && _ok "crew notify idle exit 0" || _ng "notify exit=$rc(期望 0)"
grep -q "Enter" "$sent" && _ok "wake 发了 Enter(双 Enter)" || _ng "wake 未 send-keys"
# 信封 state 应变 delivered
latest=$(ls -t "$CREW_STATE/inbox/grace"/*.json 2>/dev/null | head -1)
[ -n "$latest" ] && node -e "const e=JSON.parse(require('fs').readFileSync('$latest'));process.exit(e.delivery.state==='delivered'?0:1)" \
  && _ok "mark-woke 生效:state=delivered" || _ng "state 未变 delivered"

# ---- Case 8: --no-wake 只 send ----
echo "--- Case 8: --no-wake ---"
sent="$T/sent2.log"; : > "$sent"
before=$(ls "$CREW_STATE/inbox/ivy"/*.json 2>/dev/null | wc -l | tr -d ' ')
PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="ivy" FAKE_TMUX_PANE="$IDLE_PANE" \
  FAKE_TMUX_SENT="$sent" CREW_SESSION_NAME=jack \
  "$CREW" notify ivy "no wake test" --no-wake >/dev/null 2>&1
after=$(ls "$CREW_STATE/inbox/ivy"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$after" = "1" ] && _ok "--no-wake 写了信封" || _ng "信封未写"
[ ! -s "$sent" ] && _ok "--no-wake 未 send-keys" || _ng "--no-wake 却 send 了: $(cat $sent)"

# ---- Case 9: notify 目标不存在 → wake exit 1(信封仍写) ----
echo "--- Case 9: 目标不存在 wake exit 1 ---"
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="other" FAKE_TMUX_PANE="$IDLE_PANE" \
  FAKE_TMUX_SENT="$T/sent9.log" CREW_SESSION_NAME=self \
  "$CREW" notify ghost "no target" >/dev/null 2>&1; echo $?)
[ "$rc" = 1 ] && _ok "wake 不存在会话 exit 1" || _ng "exit=$rc(期望 1)"
[ -d "$CREW_STATE/inbox/ghost" ] && _ok "信封仍写入 inbox(不丢消息)" || _ng "信封丢了"

# ---- Case 10: crew inbox 消费 → 二次消费空 ----
echo "--- Case 10: 二次消费空 ---"
out=$("$CREW" inbox grace 2>&1)
echo "$out" | grep -q "consumed" && _ok "首次 inbox consumed" || _ng "首次未 consumed: $out"
out2=$("$CREW" inbox grace 2>&1)
echo "$out2" | grep -q "no messages" && _ok "二次 inbox no messages" || _ng "二次输出异常: $out2"

# ---- Case 11: v8 --dedup-key · 同 key 24h 内跳过 · 不同 key 独立 · 无 key 兼容(2026-09-03) ----
echo "--- Case 11: --dedup-key(v8 · Agent-A3 复审补测试) ---"
D_STATE=$(mktemp -d /tmp/crew-notify-dedup.XXX)
D_FB=$D_STATE/fb.jsonl
# 首次写入 · dedup-key=sid-1 · 应写
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$D_STATE" FEEDBACK_JSONL="$D_FB" \
  node "$SCRIPT_DIR/../bin/crew-notify.js" write --to hank --from session:alice --note "task 1" --dedup-key sid-1 >/dev/null 2>&1
n1=$(ls "$D_STATE/inbox/hank"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n1" = "1" ] && _ok "①首次 --dedup-key=sid-1 · 写入 1 条" || _ng "①首次未写 · 数=$n1"

# 同 key 二次 · 应跳过
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$D_STATE" FEEDBACK_JSONL="$D_FB" \
  node "$SCRIPT_DIR/../bin/crew-notify.js" write --to hank --from session:alice --note "task 1 again" --dedup-key sid-1 >/dev/null 2>&1
n2=$(ls "$D_STATE/inbox/hank"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n2" = "1" ] && _ok "②同 dedup-key=sid-1 二次 · 跳过 · 仍 1 条" || _ng "②未 dedup · 数=$n2"

# 不同 key · 应独立写
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$D_STATE" FEEDBACK_JSONL="$D_FB" \
  node "$SCRIPT_DIR/../bin/crew-notify.js" write --to hank --from session:alice --note "task 2" --dedup-key sid-2 >/dev/null 2>&1
n3=$(ls "$D_STATE/inbox/hank"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n3" = "2" ] && _ok "③不同 dedup-key=sid-2 · 独立写 · 2 条" || _ng "③未独立 · 数=$n3"

# 无 --dedup-key · 应每次都写
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$D_STATE" FEEDBACK_JSONL="$D_FB" \
  node "$SCRIPT_DIR/../bin/crew-notify.js" write --to hank --from session:alice --note "no dedup" >/dev/null 2>&1
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$D_STATE" FEEDBACK_JSONL="$D_FB" \
  node "$SCRIPT_DIR/../bin/crew-notify.js" write --to hank --from session:alice --note "no dedup 2" >/dev/null 2>&1
n4=$(ls "$D_STATE/inbox/hank"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n4" = "4" ] && _ok "④无 dedup-key · 兼容每次写 · 4 条" || _ng "④兼容破坏 · 数=$n4"

# marker 目录存在 · sid-1 sid-2 各一个 stamp
n5=$(ls "$D_STATE/.dedup"/*.stamp 2>/dev/null | wc -l | tr -d ' ')
[ "$n5" = "2" ] && _ok "⑤dedup marker 目录 · 2 个 stamp(sid-1/sid-2)" || _ng "⑤marker 数不对=$n5"

# ⑥ 25h 过期 · sid-1 stamp touch -d "25 hours ago" 后同 key 应重新写入(Agent-C 复审补)
sid1_stamp=$(ls "$D_STATE/.dedup"/*.stamp | head -1)   # sid-1 的 stamp
# backdate 25h:GNU touch -d(Linux)> macOS touch -t + date -v(两者都不行则跳过该 case 不误报)
if ! touch -d "25 hours ago" "$sid1_stamp" 2>/dev/null; then
  if touch -t "$(date -v-25H +%Y%m%d%H%M.%S)" "$sid1_stamp" 2>/dev/null; then :
  else echo "  (skip: 本机无法 backdate,⑥ 跳过)" ; fi
fi
env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$D_STATE" FEEDBACK_JSONL="$D_FB" \
  node "$SCRIPT_DIR/../bin/crew-notify.js" write --to hank --from session:alice --note "sid-1 25h later" --dedup-key sid-1 >/dev/null 2>&1
n6=$(ls "$D_STATE/inbox/hank"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n6" = "5" ] && _ok "⑥sid-1 marker 25h 过期 · 允许重发 · 5 条" || _ng "⑥过期未生效 · 数=$n6"
rm -rf "$D_STATE"

# ---- Case 12: v8 crew inbox --as 身份校验 · 有 CREW_SESSION 时 --as 无效(2026-09-03 Agent-A1 加固) ----
echo "--- Case 12: crew inbox --as 身份校验(v8 · P0 加固) ---"
G_STATE=$(mktemp -d /tmp/crew-inbox-guard.XXX)
mkdir -p "$G_STATE/inbox/karen"

# 场景1:无 CREW_SESSION · 允许(本地跑兼容)
out_a=$(env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$G_STATE" "$CREW" inbox karen --peek 2>&1)
echo "$out_a" | grep -q "no messages" && _ok "①无 CREW_SESSION · 允许查任意 inbox(兼容)" || _ng "①无 CREW_SESSION 反被拒 · $out_a"

# 场景2:CREW_SESSION=karen · drain karen · 允许
out_b=$(env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$G_STATE" CREW_SESSION=karen "$CREW" inbox karen --peek 2>&1)
echo "$out_b" | grep -q "no messages" && _ok "②CREW_SESSION=karen · drain karen · 允许" || _ng "②同名反被拒 · $out_b"

# 场景3:CREW_SESSION=lisa · drain karen · 拒绝
out_c=$(env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$G_STATE" CREW_SESSION=lisa "$CREW" inbox karen --peek 2>&1)
rc_c=$?
echo "$out_c" | grep -q "denied: caller='lisa'" && [ "$rc_c" != "0" ] && _ok "③CREW_SESSION=lisa · drain karen · 拒绝 exit≠0" || _ng "③越权未拒 · out=$out_c rc=$rc_c"

# 场景4:CREW_SESSION=lisa · --as karen · 也应拒绝(v8 P0 加固 · --as 被忽略)
out_d=$(env -i PATH="$PATH" HOME="$HOME" CREW_STATE="$G_STATE" CREW_SESSION=lisa "$CREW" inbox karen --peek --as karen 2>&1)
echo "$out_d" | grep -q "denied: caller='lisa'" && _ok "④CREW_SESSION=lisa · --as karen · bypass 无效(仍 lisa)" || _ng "④bypass 仍生效 · $out_d"

# 场景4b:stderr 不 hint bypass 命令(Agent-C 复审 · 防教攻击者)
echo "$out_d" | grep -qE "CREW_SESSION=|--as $|hint:.*pass --as" && _ng "④b stderr 泄露 bypass hint · out=$out_d" "" || _ok "④b stderr 无 bypass 关键词(不教攻击者)"

# 场景5:audit log 存在 · 字段级校验(target=karen, caller=lisa 匹配)—— Agent-C 收紧
if [ -f "$G_STATE/audit.log" ]; then
  # 场景3的 audit 记录应含 target=karen + caller=lisa(denied 不显式记 result · 靠 stderr 已验)
  grep -q "target=karen" "$G_STATE/audit.log" && grep -q "caller=lisa" "$G_STATE/audit.log" \
    && _ok "⑤audit.log 字段级 · target=karen ∧ caller=lisa 记录存在" \
    || _ng "⑤audit 字段缺失 · $(cat $G_STATE/audit.log)"
else
  _ng "⑤audit log 缺失" ""
fi
rm -rf "$G_STATE"

echo
echo "=== crew-notify.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
