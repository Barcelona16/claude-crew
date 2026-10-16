#!/usr/bin/env bash
# crew-integration.test.sh — 阶段 1 集成 + 混沌 + 迁移端到端测试
# 覆盖(方案 §8.2/8.3/8.4):
#   [集成 6]
#   I1 hello 回环:A notify B → B inbox 消费 → B notify A → A inbox 消费
#   I2 连发不漏:A 连发 100 条 → B inbox 全消费,0 掉
#   I3 饱和补发:B busy → notify 落 pending 队列;B idle 后 flushOne 补发成功
#   I4 kill 后拒发:tmux 无该会话 → notify wake exit 1(信封仍写,不丢消息)
#   I5 crew register 10 并发只写一次(此项在 register 测已覆盖,这里补 30 并发压)
#   I6 心跳丢失:心跳 ts >180s → status 标 stale
#   [混沌 4]
#   C1 tmux 挂:list-sessions 失败 → wake exit 3 不 crash
#   C2 心跳采样时 tmux 挂 → 心跳文件 tmuxStatus=unknown
#   C3 project.json 30 并发写 → 无损坏 + 恰 1 条(register 自愈)
#   C4 mock claude OOM(模拟 tmux 无对应 crew 会话)→ 心跳标 dead
#   [迁移 2]
#   M1 老 crew send(内部走 crew-notify.js write)行为等价新 crew notify --no-wake
#   M2 老 .msg 纯文本文件与新 JSON 信封混合消费不 crash

set -uo pipefail

# 2026-09-03 v8:清 CREW_SESSION 避免继承污染 cmd_inbox 身份校验(测试跑本身不代表任何会话)
unset CREW_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
CN="$SCRIPT_DIR/../bin/crew-notify.js"
CW="$SCRIPT_DIR/../bin/crew-wake.js"
CH="$SCRIPT_DIR/../bin/crew-heartbeat.js"
CST="$SCRIPT_DIR/../bin/crew-status.js"
CR="$SCRIPT_DIR/../bin/crew-register.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-integ.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export CREW_STATE="$T/state"
export FEEDBACK_JSONL="$T/feedback.jsonl"
mkdir -p "$CREW_STATE"

# ---- fake tmux(全测试通用)----
FAKE_BIN="$T/fakebin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tmux" <<'FAKE'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  list-sessions)
    if [ "${FAKE_TMUX_DEAD:-0}" = "1" ]; then echo "no server" >&2; exit 1; fi
    [ -n "${FAKE_TMUX_SESSIONS:-}" ] && printf '%s\n' "$FAKE_TMUX_SESSIONS" | tr ',' '\n' && exit 0
    echo "no server" >&2; exit 1 ;;
  capture-pane)
    for a in "$@"; do case "$a" in -t) shift; target="$1";; esac; done
    var="FAKE_TMUX_PANE_${target//-/_}"
    file="${!var:-${FAKE_TMUX_PANE:-}}"
    [ -n "$file" ] && [ -f "$file" ] && cat "$file"; exit 0 ;;
  send-keys) [ -n "${FAKE_TMUX_SENT:-}" ] && echo "$*" >> "$FAKE_TMUX_SENT"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/tmux"
export PATH="$FAKE_BIN:$PATH"

IDLE_PANE="$T/idle.pane"; printf 'x\n❯ \n' > "$IDLE_PANE"
BUSY_PANE="$T/busy.pane"; printf 'Running...\n✳ Thinking\n' > "$BUSY_PANE"

# ================ 集成 ================
echo "=== 集成 6 场景 ==="

# --- I1 hello 回环 ---
echo "--- I1 hello 回环 ---"
export FAKE_TMUX_SESSIONS="A,B" FAKE_TMUX_PANE="$IDLE_PANE"
FAKE_TMUX_SENT="$T/sent.log" CREW_SESSION_NAME=A "$CREW" notify B "hi B" >/dev/null 2>&1
out=$("$CREW" inbox B 2>&1)
echo "$out" | grep -q "hi B" && _ok "A→B notify + B inbox 收到 hi B" || _ng "hi B 未到 B: $out"
FAKE_TMUX_SENT="$T/sent.log" CREW_SESSION_NAME=B "$CREW" notify A "hi A back" >/dev/null 2>&1
out=$("$CREW" inbox A 2>&1)
echo "$out" | grep -q "hi A back" && _ok "B→A 回复 hi A back → A 消费到" || _ng "hi A back 未到 A: $out"

# --- I2 连发 100 条 ---
echo "--- I2 连发 100 条不漏 ---"
export FAKE_TMUX_SESSIONS="X"
for i in $(seq 1 100); do
  CREW_SESSION_NAME=A node "$CN" write --to X --from "session:A" --note "msg-$i" >/dev/null
done
# 消费全部
out=$("$CREW" inbox X 2>&1)
consumed=$(echo "$out" | grep -oE "consumed [0-9]+ message" | grep -oE "[0-9]+" | tr -d ' ')
[ "$consumed" = "100" ] && _ok "100 条全消费(consumed=$consumed)" || _ng "消费=$consumed(期望 100)"
# 归档目录也应有 100 条
archived=$(ls "$CREW_STATE/inbox/X/consumed"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$archived" = "100" ] && _ok "归档 consumed/ 100 条" || _ng "归档=$archived"

# --- I3 饱和补发 ---
echo "--- I3 饱和补发(busy → pending → flushOne)---"
export FAKE_TMUX_SESSIONS="Y" FAKE_TMUX_PANE="$BUSY_PANE" WAKE_PENDING_FILE="$T/pending.jsonl"
CREW_SESSION_NAME=A "$CREW" notify Y "busy test" >/dev/null 2>&1
rc=$?
# busy → notify exit 2 + pending 有 1 条
[ "$rc" = 2 ] && _ok "busy notify exit 2" || _ng "notify exit=$rc(期望 2)"
[ -f "$WAKE_PENDING_FILE" ] && cnt=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$WAKE_PENDING_FILE')).length)") && [ "$cnt" = "1" ] \
  && _ok "pending 队列 1 条" || _ng "pending 数不对"
# 切 idle → flushOne 应发出
export FAKE_TMUX_PANE="$IDLE_PANE" FAKE_TMUX_SENT="$T/sent-flush.log"
: > "$FAKE_TMUX_SENT"
node -e "
const w=require('$CW');
const items=w.takePendingNudges();
const results=items.map(i=>w.flushOne(i));
process.exit(results.every(r=>r===true)?0:1)
" && _ok "idle 后 flushOne 补发成功" || _ng "flushOne 未补发成功"
grep -q "Enter" "$FAKE_TMUX_SENT" && _ok "补发触发 send-keys Enter" || _ng "补发未 send-keys"

# --- I4 kill 后拒发 ---
echo "--- I4 kill 后 wake 拒发(消息仍写)---"
export FAKE_TMUX_SESSIONS="Y" FAKE_TMUX_PANE="$IDLE_PANE"
CREW_SESSION_NAME=A "$CREW" notify Z "should not deliver" >/dev/null 2>&1
rc=$?
[ "$rc" = 1 ] && _ok "Z 不在 tmux → notify exit 1" || _ng "exit=$rc(期望 1)"
[ -d "$CREW_STATE/inbox/Z" ] && _ok "信封仍写到 inbox/Z(不丢消息)" || _ng "信封丢了"

# --- I5 register 30 并发压 ---
echo "--- I5 register 30 并发只写一次 ---"
mkdir -p "$T/proj30/.chaos-bridge"
cat > "$T/proj30/.chaos-bridge/project.json" <<EOF
{"name":"p30","displayName":"p30","workDir":"$T/proj30","main":"m","sessions":[{"name":"m","role":"main","kind":"crew","description":"m"}]}
EOF
pids=()
for i in $(seq 1 30); do
  node "$CR" --name concurrent30 --dir "$T/proj30" --scan-root "$T" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
node -e "JSON.parse(require('fs').readFileSync('$T/proj30/.chaos-bridge/project.json'))" 2>/dev/null && _ok "30 并发后 project.json 无损坏" || _ng "并发写坏 JSON"
cnt=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$T/proj30/.chaos-bridge/project.json')).sessions.filter(s=>s.name==='concurrent30').length)")
[ "$cnt" = "1" ] && _ok "concurrent30 恰 1 条(flock 生效)" || _ng "并发写 $cnt 条(期望 1)"

# --- I6 心跳丢失 → status 标 stale ---
echo "--- I6 心跳丢失 → stale ---"
touch "$CREW_STATE/hbtest.tmux"
mkdir -p "$CREW_STATE/heartbeat"
node -e "
const fs=require('fs');
fs.writeFileSync('$CREW_STATE/heartbeat/hbtest.json',JSON.stringify({
  name:'hbtest',ts:new Date(Date.now()-200000).toISOString(),tmux:'x',tmuxStatus:'live',paneIdle:true,ctxPct:null
}));"
freshness=$(node "$CST" hbtest --json | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).heartbeat.freshness))")
[ "$freshness" = "stale" ] && _ok "心跳 200s 前 → stale" || _ng "freshness=$freshness(期望 stale)"

# ================ 混沌 ================
echo ""
echo "=== 混沌 4 类 ==="

# --- C1a tmux server 未起(list-sessions exit 1)---
# wake exit 契约:tmux server 未起 = 会话不存在(exit 1),不是 tmux 二进制挂(exit 3)。
# 因为语义上"server 未起"和"目标会话不在其中"用户角度是同一件事。
echo "--- C1a tmux server 未起 ---"
rc=$(FAKE_TMUX_DEAD=1 node "$CW" X >/dev/null 2>&1; echo $?)
[ "$rc" = 1 ] && _ok "tmux server 未起 wake exit 1(=会话不存在)" || _ng "exit=$rc(期望 1)"

# --- C1b tmux 二进制不可执行 → exit 3 ---
# NODE_BIN:优先 env,其次 PATH 里的 node,最后 box 的 /work/node20(Linux box 兼容兜底)。
NODE_BIN="${NODE_BIN:-$(command -v node 2>/dev/null || true)}"
[ -z "$NODE_BIN" ] && [ -x /work/node20/bin/node ] && NODE_BIN=/work/node20/bin/node
echo "--- C1b tmux 二进制不可执行 → exit 3 ---"
EMPTY_BIN="$T/nobin"; mkdir -p "$EMPTY_BIN"
rc=$(PATH="$EMPTY_BIN" "$NODE_BIN" "$CW" X >/dev/null 2>&1; echo $?)
[ "$rc" = 3 ] && _ok "tmux 二进制不可执行 wake exit 3" || _ng "exit=$rc(期望 3)"

# --- C2 心跳时 tmux server 未起 → tmuxStatus=unknown ---
# heartbeat 逻辑:listTmux() 返 dead=true(error/status===null)时 → 全部会话记 unknown。
# 但 exit 1(list-sessions 有 status 但非 0)= 会话集空,该会话个个 dead。
# 这里我们测真"tmux 二进制不可执行"的场景 → dead=true(spawn error)→ unknown。
echo "--- C2 心跳采样时 tmux 二进制不可执行 → unknown ---"
touch "$CREW_STATE/hbdead.tmux"
# 关键:只保留 EMPTY_BIN,不带 fake tmux 的 PATH,让 tmux 二进制真找不到 → spawnSync error
PATH="$EMPTY_BIN" "$NODE_BIN" "$CH" --once 2>/dev/null || true
node -e "
try{const j=JSON.parse(require('fs').readFileSync('$CREW_STATE/heartbeat/hbdead.json'));process.exit(j.tmuxStatus==='unknown'?0:1)}catch(e){process.exit(2)}" \
  && _ok "tmux 二进制不可执行时 tmuxStatus=unknown" || _ng "tmuxStatus 不对(或文件缺)"

# --- C3 project.json 60 并发压(比 I5 更狠)---
echo "--- C3 60 并发写 project.json ---"
mkdir -p "$T/proj60/.chaos-bridge"
cat > "$T/proj60/.chaos-bridge/project.json" <<EOF
{"name":"p60","displayName":"p60","workDir":"$T/proj60","main":"m","sessions":[{"name":"m","role":"main","kind":"crew","description":"m"}]}
EOF
pids=()
for i in $(seq 1 60); do
  node "$CR" --name c60 --dir "$T/proj60" --scan-root "$T" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
node -e "JSON.parse(require('fs').readFileSync('$T/proj60/.chaos-bridge/project.json'))" 2>/dev/null && _ok "60 并发无 JSON 损坏" || _ng "60 并发写坏"
cnt=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$T/proj60/.chaos-bridge/project.json')).sessions.filter(s=>s.name==='c60').length)")
[ "$cnt" = "1" ] && _ok "60 并发去重恰 1 条" || _ng "重复=$cnt"

# --- C4 mock claude OOM(tmux 里无对应 session)→ 心跳 dead ---
echo "--- C4 claude OOM 模拟 → 心跳 dead ---"
touch "$CREW_STATE/deadsess.tmux"
export FAKE_TMUX_SESSIONS="A,B,X,Y"    # deadsess 不在里面
node "$CH" --once
node -e "const j=JSON.parse(require('fs').readFileSync('$CREW_STATE/heartbeat/deadsess.json'));process.exit(j.tmuxStatus==='dead'?0:1)" \
  && _ok "deadsess tmuxStatus=dead(tmux 无)" || _ng "tmuxStatus 不对"

# ================ 迁移/回归 ================
echo ""
echo "=== 迁移/回归 2 项 ==="

# --- M1 老 crew send == 新 crew notify --no-wake ---
echo "--- M1 老 crew send 与 crew notify --no-wake 行为等价 ---"
rm -rf "$CREW_STATE/inbox/mtest"
CREW_SESSION_NAME=oldA "$CREW" send mtest "old-style" >/dev/null 2>&1
CREW_SESSION_NAME=newA "$CREW" notify mtest "new-style" --no-wake >/dev/null 2>&1
n=$(ls "$CREW_STATE/inbox/mtest"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "2" ] && _ok "两种入口都落 JSON 信封(2 条)" || _ng "信封数=$n"
# 两条都应有 from.kind=session
ok=$(node -e "
const fs=require('fs');
const files=fs.readdirSync('$CREW_STATE/inbox/mtest').filter(f=>f.endsWith('.json'));
const envs=files.map(f=>JSON.parse(fs.readFileSync('$CREW_STATE/inbox/mtest/'+f)));
process.exit(envs.every(e=>e.from.kind==='session'&&e.delivery.state==='pending')?0:1)
"; echo $?)
[ "$ok" = "0" ] && _ok "两条信封结构一致(from.kind=session, state=pending)" || _ng "信封结构不一致"

# --- M2 老 .msg + 新 JSON 混合消费 ---
echo "--- M2 老 .msg + 新 JSON 混合消费不 crash ---"
rm -rf "$CREW_STATE/inbox/mix"
mkdir -p "$CREW_STATE/inbox/mix"
echo "legacy plain text" > "$CREW_STATE/inbox/mix/0001-old.msg"
CREW_SESSION_NAME=srcA "$CREW" send mix "json envelope" >/dev/null 2>&1
out=$("$CREW" inbox mix 2>&1)
echo "$out" | grep -q "legacy plain text" && _ok "老 .msg 内容消费到" || _ng ".msg 未消费"
echo "$out" | grep -q "json envelope" && _ok "新 JSON 内容消费到" || _ng "JSON 信封未消费"
consumed=$(echo "$out" | grep -oE "consumed [0-9]+ message" | grep -oE "[0-9]+" | tr -d ' ')
[ "$consumed" = "2" ] && _ok "混合消费共 2 条" || _ng "混合消费=$consumed"

echo
echo "=== crew-integration.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
