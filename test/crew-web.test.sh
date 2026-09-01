#!/usr/bin/env bash
# crew-web.test.sh — crew web 前端 API 单元测试
# 覆盖:
#   ① sessionCard 结构完整
#   ② inbound/outbound 归属正确(feedback.jsonl 假数据)
#   ③ handleState 返回 sessions + keys + models
#   ④ handleSwitch 白名单拒绝未知 name / key / model
#   ⑤ handleAttach 返回 tmux 命令行
#   ⑥ handleAttach 未知会话拒绝
#   ⑦ buildFrontend 注入占位符
#   ⑧ inbox 计数分类
#   ⑨ 启动真服务器 + curl /healthz 200 + /api/state 结构

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
CWEB="$SCRIPT_DIR/../bin/crew-web.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-web-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

export CREW_STATE="$T/state"
export FEEDBACK_JSONL="$T/feedback.jsonl"
mkdir -p "$CREW_STATE/heartbeat" "$CREW_STATE/inbox/alice"

# fake tmux(全测试通用):list-sessions 返空,避免真 tmux 里的会话污染 listCrewSessions
FAKE_BIN="$T/fakebin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tmux" <<'FAKE'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  list-sessions) echo ""; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/tmux"
export PATH="$FAKE_BIN:$PATH"

# 假 CCR config(白名单来源)
mkdir -p "$T/.claude-code-router"
cat > "$T/.claude-code-router/config.json" <<'JSON'
{ "Providers": [
  { "name": "prov1", "api_key": "key-abc", "models": ["Claude-Opus-4.7", "Claude-Sonnet-4"] },
  { "name": "prov2", "api_key": "key-xyz", "models": ["GLM-5.3"] }
]}
JSON
export HOME="$T"

# 假会话:alice 有全套 state,bob 只有心跳
touch "$CREW_STATE/alice.tmux"
echo "prov1,Claude-Opus-4.7" > "$CREW_STATE/alice.backend"
echo "key-abc" > "$CREW_STATE/alice.key"
echo "/work/alice" > "$CREW_STATE/alice.dir"
cat > "$CREW_STATE/heartbeat/alice.json" <<'JSON'
{ "name": "alice", "ts": "2026-09-01T18:00:00.000Z", "tmux": "crew-alice",
  "tmuxStatus": "live", "paneIdle": true, "ctxPct": 42 }
JSON

touch "$CREW_STATE/bob.tmux"
cat > "$CREW_STATE/heartbeat/bob.json" <<'JSON'
{ "name": "bob", "ts": "2026-09-01T18:00:00.000Z", "tmux": null,
  "tmuxStatus": "dead", "paneIdle": null, "ctxPct": null }
JSON

# alice inbox:1 pending JSON 信封
cat > "$CREW_STATE/inbox/alice/0001-x.json" <<'JSON'
{ "id": "e1", "ts": "2026-09-01T18:00:01.000Z", "from": {"kind":"session","id":"bob"},
  "note": "hi alice", "delivery": {"state":"pending","wokeAt":null,"consumedAt":null} }
JSON

# feedback.jsonl 假数据:
#  - bob 发给 alice(inbound to alice)
#  - alice 回复 wangqiwang1(outbound from alice)
#  - 咚咚(erp)发给 alice(inbound to alice, source=private)
cat > "$FEEDBACK_JSONL" <<'JSON'
{"ts":"2026-09-01T18:00:01.000Z","project":"crew","pin":"bob","sender":"bob","note":"hi from bob","session":"alice","source":"session","replyOut":false,"delivery":{"state":"pending"}}
{"ts":"2026-09-01T18:00:02.000Z","project":"crew","pin":"wangqiwang1","sender":"alice","note":"reply to wq","session":"wangqiwang1","source":"private","replyOut":true,"delivery":{"state":"acked"}}
{"ts":"2026-09-01T18:00:03.000Z","project":"crew","pin":"wangqiwang1","sender":"send.js","note":"erp ping","session":"alice","source":"private","replyOut":false}
JSON

# ---- Case 1: sessionCard 结构完整 ----
echo "--- Case 1: sessionCard alice ---"
node -e "
const w=require('$CWEB');
const s=w.sessionCard('alice');
process.exit(s.name==='alice'&&s.status==='live'&&s.ctxPct===42&&s.model==='prov1,Claude-Opus-4.7'&&s.inboxCount===1?0:1)
" && _ok "sessionCard 字段完整(name/status/ctxPct/model/inboxCount)" || _ng "sessionCard 字段不对"

# ---- Case 2: inbound/outbound 归属 ----
echo "--- Case 2: 消息归属 ---"
node -e "
const w=require('$CWEB');
const s=w.sessionCard('alice',20);
// alice 的 inbound 应有 2 条(bob→alice, erp→alice),outbound 1 条(alice→wangqiwang1)
if(s.inbound.length!==2||s.outbound.length!==1){console.error('inbound='+s.inbound.length+' outbound='+s.outbound.length);process.exit(1)}
// 检查 from.kind: bob=session, erp=erp
const kinds=s.inbound.map(m=>m.from.kind).sort();
if(kinds[0]!=='erp'||kinds[1]!=='session'){console.error('kinds='+kinds);process.exit(1)}
process.exit(0)
" && _ok "inbound=2(session+erp) outbound=1;来源 kind 正确" || _ng "归属错"

# ---- Case 3: handleState ----
echo "--- Case 3: handleState ---"
diag=$(node -e "
const w=require('$CWEB');
let body='',code=0;
const res={ writeHead:(c)=>{code=c}, end:(b)=>{body=b} };
w.handleState({},res,{query:{}});
const j=JSON.parse(body);
console.log('code='+code+' sessions='+j.sessions.length+' names='+j.sessions.map(s=>s.name).join(',')+' keys='+j.keys.length);
process.exit(code===200&&Array.isArray(j.sessions)&&j.sessions.length===2&&Array.isArray(j.keys)&&j.keys.length===2?0:1)
" 2>&1)
[ $? = 0 ] && _ok "handleState 200,sessions=2,keys=2" || _ng "handleState 输出不对: $diag"

# ---- Case 4: handleSwitch 白名单 ----
echo "--- Case 4: switch 白名单 ---"
node -e "
const w=require('$CWEB');
async function run() {
  // 未知 name → 400
  const r1=await callSwitch(w,{name:'ghost',key:'key-abc',model:'Claude-Opus-4.7'});
  if(r1.code!==400||r1.body.err.indexOf('unknown session')<0){console.error('r1',r1);process.exit(1)}
  // 未知 key → 400
  const r2=await callSwitch(w,{name:'alice',key:'evil-key',model:'Claude-Opus-4.7'});
  if(r2.code!==400||r2.body.err.indexOf('unknown key')<0){console.error('r2',r2);process.exit(2)}
  // 未知 model → 400
  const r3=await callSwitch(w,{name:'alice',key:'key-abc',model:'evil-model'});
  if(r3.code!==400||r3.body.err.indexOf('unknown model')<0){console.error('r3',r3);process.exit(3)}
  // key/model 都缺 → 400
  const r4=await callSwitch(w,{name:'alice'});
  if(r4.code!==400){console.error('r4',r4);process.exit(4)}
  process.exit(0)
}
function callSwitch(w,payload) {
  return new Promise(resolve=>{
    const {EventEmitter}=require('events');
    const req=new EventEmitter(); req.method='POST';
    let code=0,body=null;
    const res={writeHead:(c)=>{code=c},end:(b)=>{body=JSON.parse(b);resolve({code,body})}};
    w.handleSwitch(req,res).catch(e=>resolve({code:500,body:{err:e.message}}));
    // 模拟 body 流
    process.nextTick(()=>{req.emit('data',JSON.stringify(payload));req.emit('end')});
  })
}
run();
" && _ok "switch 白名单:未知 name/key/model + 缺参 全 400" || _ng "白名单未生效"

# ---- Case 5: handleAttach 返命令 ----
echo "--- Case 5: attach 返命令行 ---"
node -e "
const w=require('$CWEB');
async function run() {
  const r=await callAttach(w,{name:'alice'});
  if(r.code!==200||!r.body.command||r.body.command.indexOf('tmux attach -t')<0){console.error(r);process.exit(1)}
  process.exit(0)
}
function callAttach(w,payload) {
  return new Promise(resolve=>{
    const {EventEmitter}=require('events');
    const req=new EventEmitter(); req.method='POST';
    let code=0,body=null;
    const res={writeHead:(c)=>{code=c},end:(b)=>{body=JSON.parse(b);resolve({code,body})}};
    w.handleAttach(req,res).catch(e=>resolve({code:500,body:{err:e.message}}));
    process.nextTick(()=>{req.emit('data',JSON.stringify(payload));req.emit('end')});
  })
}
run();
" && _ok "attach 返 tmux attach -t 命令行" || _ng "attach 输出不对"

# ---- Case 6: handleAttach 未知会话 ----
echo "--- Case 6: attach 未知会话 400 ---"
node -e "
const w=require('$CWEB');
async function run() {
  const r=await callAttach(w,{name:'ghost'});
  if(r.code!==400){console.error(r);process.exit(1)}
  process.exit(0)
}
function callAttach(w,payload) {
  return new Promise(resolve=>{
    const {EventEmitter}=require('events');
    const req=new EventEmitter(); req.method='POST';
    let code=0,body=null;
    const res={writeHead:(c)=>{code=c},end:(b)=>{body=JSON.parse(b);resolve({code,body})}};
    w.handleAttach(req,res).catch(e=>resolve({code:500,body:{err:e.message}}));
    process.nextTick(()=>{req.emit('data',JSON.stringify(payload));req.emit('end')});
  })
}
run();
" && _ok "attach ghost 400" || _ng "attach 未拒绝未知"

# ---- Case 7: buildFrontend 注入 ----
echo "--- Case 7: buildFrontend ---"
html=$(node -e "console.log(require('$CWEB').buildFrontend())")
echo "$html" | grep -q "18060" && _ok "HTML 注入 PORT" || _ng "PORT 未注入"
echo "$html" | grep -qF "$CREW_STATE" && _ok "HTML 注入 CREW_STATE" || _ng "CREW_STATE 未注入"

# ---- Case 8: inbox 计数分类 ----
echo "--- Case 8: inbox 分类 ---"
# alice 现在只有 1 pending;补一条 delivered + 一条老 .msg
cat > "$CREW_STATE/inbox/alice/0002-d.json" <<'JSON'
{ "id": "e2", "ts": "x", "from": {"kind":"session","id":"y"}, "note": "d",
  "delivery": {"state":"delivered","wokeAt":"x","consumedAt":null} }
JSON
echo "old" > "$CREW_STATE/inbox/alice/0003-l.msg"
node -e "
const w=require('$CWEB');
const c=w.readInboxCounts('alice');
process.exit(c.pending===1&&c.delivered===1&&c.legacy===1&&c.total===3?0:1)
" && _ok "inbox pending=1 delivered=1 legacy=1 total=3" || _ng "inbox 计数不对"

# ---- Case 9: 启真服务器 + curl 冒烟 ----
echo "--- Case 9: 真服务器 healthz + /api/state ---"
PORT=$((30000 + RANDOM % 5000))
CREW_WEB_PORT=$PORT node "$CWEB" >"$T/web.log" 2>&1 &
PID=$!
sleep 0.8
# healthz
code=$(node -e "require('http').get('http://127.0.0.1:$PORT/healthz',r=>{console.log(r.statusCode);process.exit(0)}).on('error',()=>{console.log('000');process.exit(0)})")
[ "$code" = "200" ] && _ok "/healthz 200" || _ng "/healthz code=$code"
# /api/state
data=$(node -e "let d='';require('http').get('http://127.0.0.1:$PORT/api/state',r=>{r.on('data',c=>d+=c);r.on('end',()=>console.log(d))}).on('error',()=>{})")
echo "$data" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);process.exit(Array.isArray(j.sessions)&&j.sessions.length===2?0:1)}catch(e){process.exit(1)}})" \
  && _ok "/api/state 结构正常 sessions=2" || _ng "/api/state 输出异常: $(echo $data | head -c 200)"
kill $PID 2>/dev/null; wait $PID 2>/dev/null

echo
echo "=== crew-web.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
