#!/usr/bin/env bash
# crew-status.test.sh — crew heartbeat + crew status 单元测试
# 覆盖(方案 §8.1):
#   [heartbeat]
#   ① sampleAll 生成心跳文件(fake tmux idle 会话 → tmuxStatus=live, paneIdle=true)
#   ② 会话有 crew state 但 tmux 无 → tmuxStatus=dead
#   ③ ctxPct 从 "100% context used" 提取
#   ④ --once 采一次即退,不驻留
#   ⑤ 单例保护:第二次启动 exit 6(见活 PID)
#   ⑥ listCrewSessions 从 CREW_STATE 里 *.<key> 反推会话名
#   [status]
#   ⑦ 未注册 exit 4
#   ⑧ 心跳新鲜 fresh / 过期 stale
#   ⑨ inbox 计数 pending/delivered/legacy 分类
#   ⑩ pendingNudges 计数
#   ⑪ crew status 命令入口透传 exit
#   ⑫ --json 结构化输出

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
CH="$SCRIPT_DIR/../bin/crew-heartbeat.js"
CST="$SCRIPT_DIR/../bin/crew-status.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-status-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

export CREW_STATE="$T/state"
mkdir -p "$CREW_STATE"

# ---- fake tmux ----
FAKE_BIN="$T/fakebin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tmux" <<'FAKE'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  list-sessions)
    [ -n "${FAKE_TMUX_SESSIONS:-}" ] && printf '%s\n' "$FAKE_TMUX_SESSIONS" | tr ',' '\n' && exit 0
    echo "no server" >&2; exit 1 ;;
  capture-pane)
    # 支持按 target 返回不同 pane
    for i in "$@"; do case "$i" in -t) shift; target="$1";; esac; done
    var="FAKE_TMUX_PANE_${target//-/_}"
    file="${!var:-${FAKE_TMUX_PANE:-}}"
    [ -n "$file" ] && [ -f "$file" ] && cat "$file"; exit 0 ;;
  send-keys) [ -n "${FAKE_TMUX_SENT:-}" ] && echo "$*" >> "$FAKE_TMUX_SENT"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/tmux"

IDLE_PANE="$T/idle.pane"; printf '\n\n❯ \n' > "$IDLE_PANE"
CTX_PANE="$T/ctx.pane"; printf '  ⬡ session · model                                          75%% context used\n❯ \n' > "$CTX_PANE"

# 创建两个"crew 会话"的 state 标记(*.tmux/*.backend 文件让 listCrewSessions 认到)
touch "$CREW_STATE/alice.tmux"
touch "$CREW_STATE/bob.tmux"

# --- Case 1: sampleAll 生成心跳文件(idle + tmux 存在)---
echo "--- Case 1: sampleAll idle 会话 ---"
PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="alice,bob" FAKE_TMUX_PANE="$IDLE_PANE" \
  node "$CH" --once
[ -f "$CREW_STATE/heartbeat/alice.json" ] && _ok "alice 心跳文件生成" || _ng "alice 心跳文件缺失"
node -e "const j=JSON.parse(require('fs').readFileSync('$CREW_STATE/heartbeat/alice.json'));process.exit(j.tmuxStatus==='live'&&j.paneIdle===true?0:1)" \
  && _ok "alice tmuxStatus=live paneIdle=true" || _ng "alice 采样字段不对"

# --- Case 2: tmux 无该会话 → tmuxStatus=dead ---
echo "--- Case 2: tmux 无对应 → dead ---"
touch "$CREW_STATE/carol.tmux"
PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="alice,bob" FAKE_TMUX_PANE="$IDLE_PANE" \
  node "$CH" --once
node -e "const j=JSON.parse(require('fs').readFileSync('$CREW_STATE/heartbeat/carol.json'));process.exit(j.tmuxStatus==='dead'&&j.paneIdle===null?0:1)" \
  && _ok "carol tmuxStatus=dead(tmux 无)" || _ng "carol 应 dead"

# --- Case 3: ctxPct 提取 ---
echo "--- Case 3: ctxPct 提取 ---"
touch "$CREW_STATE/dave.tmux"
PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="dave" FAKE_TMUX_PANE_dave="$CTX_PANE" \
  FAKE_TMUX_PANE="$CTX_PANE" node "$CH" --once
node -e "const j=JSON.parse(require('fs').readFileSync('$CREW_STATE/heartbeat/dave.json'));process.exit(j.ctxPct===75?0:1)" \
  && _ok "dave ctxPct=75(从 '75% context used' 提取)" || _ng "ctxPct 提取失败:$(cat $CREW_STATE/heartbeat/dave.json)"

# --- Case 4: --once 采一次即退(退出 0)---
echo "--- Case 4: --once 退出 0 ---"
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="alice" FAKE_TMUX_PANE="$IDLE_PANE" \
  node "$CH" --once >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && _ok "--once exit 0" || _ng "--once exit=$rc"

# --- Case 5: 单例保护 ---
echo "--- Case 5: 单例保护 ---"
# 写一个"当前进程 PID"到 pid 文件模拟活单例(自己 pid 一定存活)
mkdir -p "$CREW_STATE/heartbeat"
echo $$ > "$CREW_STATE/heartbeat/heartbeat.pid"
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="alice" FAKE_TMUX_PANE="$IDLE_PANE" \
  timeout 3 node "$CH" >/dev/null 2>&1; echo $?)
rm -f "$CREW_STATE/heartbeat/heartbeat.pid"
[ "$rc" = 6 ] && _ok "第二次启动见活 PID exit 6" || _ng "单例保护 exit=$rc(期望 6)"

# --- Case 6: listCrewSessions 反推 ---
echo "--- Case 6: listCrewSessions 反推 ---"
# 存在 alice.tmux / bob.tmux / carol.tmux / dave.tmux 4 个会话
n=$(node -e "console.log(require('$CH').listCrewSessions().length)")
[ "$n" = "4" ] && _ok "listCrewSessions 反推 4 个(state 文件推断)" || _ng "反推数=$n(期望 4)"

# --- Case 7: crew status 未注册 → exit 4 ---
echo "--- Case 7: 未注册 exit 4 ---"
rc=$(node "$CST" ghostuser >/dev/null 2>&1; echo $?)
[ "$rc" = 4 ] && _ok "未注册 exit 4" || _ng "未注册 exit=$rc(期望 4)"

# --- Case 8: 心跳新鲜 fresh / stale ---
echo "--- Case 8: freshness ---"
# alice 的心跳刚采(几秒前)→ fresh
freshness_now=$(node "$CST" alice --json | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).heartbeat.freshness))")
[ "$freshness_now" = "fresh" ] && _ok "刚采样 → fresh" || _ng "freshness=$freshness_now(期望 fresh)"
# 手动改 alice 心跳 ts 到 300s 前 → stale
node -e "const fs=require('fs');const f='$CREW_STATE/heartbeat/alice.json';const j=JSON.parse(fs.readFileSync(f));j.ts=new Date(Date.now()-300000).toISOString();fs.writeFileSync(f,JSON.stringify(j))"
freshness_old=$(node "$CST" alice --json | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).heartbeat.freshness))")
[ "$freshness_old" = "stale" ] && _ok "300s 前 → stale" || _ng "freshness=$freshness_old(期望 stale)"

# --- Case 9: inbox 计数 pending/delivered/legacy ---
echo "--- Case 9: inbox 计数 ---"
mkdir -p "$CREW_STATE/inbox/eve"
# 一条 pending
node -e "const e={id:'a',ts:new Date().toISOString(),from:{kind:'session',id:'x'},note:'p',delivery:{state:'pending',wokeAt:null,consumedAt:null}};require('fs').writeFileSync('$CREW_STATE/inbox/eve/0001-p.json',JSON.stringify(e))"
# 一条 delivered
node -e "const e={id:'b',ts:new Date().toISOString(),from:{kind:'session',id:'x'},note:'d',delivery:{state:'delivered',wokeAt:new Date().toISOString(),consumedAt:null}};require('fs').writeFileSync('$CREW_STATE/inbox/eve/0002-d.json',JSON.stringify(e))"
# 一条老 .msg
echo "old" > "$CREW_STATE/inbox/eve/0003-l.msg"
touch "$CREW_STATE/eve.tmux"
out=$(node "$CST" eve --json)
echo "$out" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const s=JSON.parse(d);process.exit(s.inbox.pending===1&&s.inbox.delivered===1&&s.inbox.legacy===1&&s.inbox.total===3?0:1)})" \
  && _ok "inbox 计数 pending=1 delivered=1 legacy=1 total=3" || _ng "inbox 计数不对: $out"

# --- Case 10: pendingNudges 计数 ---
echo "--- Case 10: pendingNudges ---"
node -e "require('fs').writeFileSync('$CREW_STATE/pending-nudges.jsonl',JSON.stringify([{ts:'x',session:'eve',note:'n1'},{ts:'x',session:'eve',note:'n2'},{ts:'x',session:'alice',note:'m'}]))"
pn=$(node "$CST" eve --json | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).pendingNudges))")
[ "$pn" = "2" ] && _ok "eve 的 pendingNudges=2(过滤 alice 的一条)" || _ng "pendingNudges=$pn(期望 2)"

# --- Case 11: crew status 命令入口 ---
echo "--- Case 11: crew status 入口 ---"
rc=$("$CREW" status alice --json >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && _ok "crew status alice --json exit 0" || _ng "exit=$rc"
rc=$("$CREW" status nobody >/dev/null 2>&1; echo $?)
[ "$rc" = 4 ] && _ok "crew status nobody exit 4" || _ng "exit=$rc(期望 4)"

# --- Case 12: 人类可读输出关键字段 ---
echo "--- Case 12: 人类可读 ---"
out=$("$CREW" status eve 2>/dev/null)
echo "$out" | grep -q "inbox" && echo "$out" | grep -q "心跳" && _ok "人类可读含 inbox/心跳字段" || _ng "输出缺字段: $out"

# --- Case 13: 心跳采样顺带 flush pending nudge(阶段 2 §E 尾巴)---
# 场景:pending 队列有一条 nudge 指向 idle 会话 → 心跳采样 → 该条应被 flush 掉(queue 空)
echo "--- Case 13: 心跳带 pending flush ---"
IDLE="$T/idle13.pane"; printf '\n\n❯ \n' > "$IDLE"
# 造一条 pending nudge 指向 alice(alice 心跳有,fake tmux 里也 idle)
PEND="$CREW_STATE/pending-nudges.jsonl"
node -e "require('fs').writeFileSync('$PEND',JSON.stringify([{ts:'x',session:'alice',note:'补发我'}]))"
export WAKE_PENDING_FILE="$PEND"
SENT13="$T/sent13.log"; touch "$SENT13"
PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="alice" FAKE_TMUX_PANE="$IDLE" \
  FAKE_TMUX_SENT="$SENT13" node "$CH" --once
# 检查队列是否清空
n=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$PEND')).length)" 2>/dev/null || echo ERR)
[ "$n" = "0" ] && _ok "心跳采样后 pending 队列被清空(flushed 1 条)" || _ng "pending 队列剩 $n 条(期望 0)"
grep -q "补发我" "$SENT13" && _ok "flush 触发 send-keys 补发原 note" || _ng "flush 未 send-keys: $(cat $SENT13 2>&1)"

# --- Case 14: pending 里的会话 tmux 已 dead → 条目应作废丢弃 ---
echo "--- Case 14: pending 死会话作废 ---"
node -e "require('fs').writeFileSync('$PEND',JSON.stringify([{ts:'x',session:'ghost',note:'ghost'},{ts:'y',session:'alice',note:'留'}]))"
PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="alice" FAKE_TMUX_PANE="$IDLE" node "$CH" --once
n=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$PEND')).length)" 2>/dev/null || echo ERR)
# alice 那条 flush 成功也走(有心跳文件+tmux idle),ghost 那条 tmux dead 作废,队列应为 0
[ "$n" = "0" ] && _ok "ghost 死会话条目作废 + alice 补发成功,队列清空" || _ng "队列剩 $n 条"

echo
echo "=== crew-status.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
