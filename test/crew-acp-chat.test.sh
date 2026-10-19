#!/usr/bin/env bash
# crew-acp-chat.test.sh — crew chat(ACP 终端客户端)单元测试
# 覆盖:
#   ① pickMember:唯一前缀命中
#   ② pickMember:无命中 → null
#   ③ pickMember:多命中 → 返回候选列表让调用方提示
#   ④ pickMember:完整名精确命中(优先于前缀)
#   ⑤ renderUpdate:agent_message_chunk 文本直出
#   ⑥ renderUpdate:tool_call → 🔧 标题行
#   ⑦ renderUpdate:plan / agent_thought_chunk / user_message_chunk → 静默(返回 null)
#   ⑧ renderUpdate:未知类型 → 静默
#   ⑨ parseLine:普通文本 → {type:'msg', text}
#   ⑩ parseLine:/list /quit /q → 命令
#   ⑪ parseLine:空行 → null
#   ⑫ parseLine:/switch <前缀> → {type:'switch', prefix}
#   ⑬ crew chat --list:列出角色(远程可达时)或明确报错
#   ⑭ crew chat 不带参 → 不崩(usage 提示后 exit 1)
#   ⑮ crew chat <不存在前缀> → 报错退出 1
#   ⑯ 端到端:SDK client ↔ crew-acpd(update wire 格式 + prompt 往返 + stop)
#   ⑰ crew 脚本 dispatch:chat 分支存在且指向 acp/crew-chat.mjs

set -uo pipefail
unset CREW_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
CHAT="$SCRIPT_DIR/../acp/crew-chat.mjs"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-chat-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ---- node 断言 helper:JS 代码经 stdin 传给 node,成员清单经 env 注入 ----
#    import 用动态 import() + env 传路径(合法 ESM)
nassert() { # nassert <描述> <<JS … JS
  local desc="$1"
  local code; code=$(cat)
  if printf '%s' "$code" | CHAT_PATH="$CHAT" node --input-type=module - 2>"$T/err.log"; then
    _ok "$desc"
  else
    _ng "$desc"; sed 's/^/      /' "$T/err.log" | head -5
  fi
}
export CHAT="$SCRIPT_DIR/../acp/crew-chat.mjs"

cat > "$T/members.json" <<'MJ'
[
  {"member":"designer-pipe-20261019-wand3","pid":"PIPE-20261019-wand3","role":"designer"},
  {"member":"coder-pipe-20261019-wand3","pid":"PIPE-20261019-wand3","role":"coder"},
  {"member":"lead-pipe-20261019-wand3","pid":"PIPE-20261019-wand3","role":"lead"},
  {"member":"designer-pipe-20260914-thcxm","pid":"PIPE-20260914-thcxm","role":"designer"}
]
MJ
export MEMBERS_JSON_PATH="$T/members.json"

echo "--- pickMember ---"
nassert "① 唯一前缀命中 coder-" <<'JS'
const { pickMember } = await import(process.env.CHAT_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'coder-')
if (r.kind !== 'ok' || r.hit.member !== 'coder-pipe-20261019-wand3') throw new Error(JSON.stringify(r))
JS
nassert "② 无命中 → null" <<'JS'
const { pickMember } = await import(process.env.CHAT_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'nope-')
if (r !== null) throw new Error('expect null, got ' + JSON.stringify(r))
JS
nassert "③ 多命中 → candidates" <<'JS'
const { pickMember } = await import(process.env.CHAT_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'designer-')
if (r.kind !== 'ambiguous' || r.candidates.length !== 2) throw new Error(JSON.stringify(r))
JS
nassert "④ 完整名精确命中优先" <<'JS'
const { pickMember } = await import(process.env.CHAT_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'lead-pipe-20261019-wand3')
if (r.kind !== 'ok' || r.hit.member !== 'lead-pipe-20261019-wand3') throw new Error(JSON.stringify(r))
JS
echo "--- renderUpdate ---"
nassert "⑤ agent_message_chunk 文本直出" <<'JS'
const { renderUpdate } = await import(process.env.CHAT_PATH)
const s = renderUpdate({sessionUpdate:'agent_message_chunk', content:{type:'text', text:'hello'}})
if (s !== 'hello') throw new Error('got ' + JSON.stringify(s))
JS
nassert "⑥ tool_call → 🔧 行" <<'JS'
const { renderUpdate } = await import(process.env.CHAT_PATH)
const s = renderUpdate({sessionUpdate:'tool_call', title:'Read file.ts', status:'pending'})
if (!/🔧.*Read file\.ts/.test(s)) throw new Error('got ' + JSON.stringify(s))
JS
nassert "⑦ plan/thought/user_chunk → null" <<'JS'
const { renderUpdate } = await import(process.env.CHAT_PATH)
for (const u of [
  {sessionUpdate:'plan'},
  {sessionUpdate:'agent_thought_chunk'},
  {sessionUpdate:'user_message_chunk'},
]) {
  const s = renderUpdate(u)
  if (s !== null) throw new Error(u.sessionUpdate + ' should be null, got ' + JSON.stringify(s))
}
JS
nassert "⑧ 未知类型 → null" <<'JS'
const { renderUpdate } = await import(process.env.CHAT_PATH)
const s = renderUpdate({sessionUpdate:'whatever_new_thing'})
if (s !== null) throw new Error('got ' + JSON.stringify(s))
JS
echo "--- parseLine ---"
nassert "⑨ 普通文本 → msg" <<'JS'
const { parseLine } = await import(process.env.CHAT_PATH)
const r = parseLine('帮我看看配额上限')
if (r.type !== 'msg' || r.text !== '帮我看看配额上限') throw new Error(JSON.stringify(r))
JS
nassert "⑩ /list /quit /q 命令" <<'JS'
const { parseLine } = await import(process.env.CHAT_PATH)
if (parseLine('/list').type !== 'cmd') throw new Error('list')
if (parseLine('/quit').type !== 'quit') throw new Error('quit')
if (parseLine('/q').type !== 'quit') throw new Error('q')
JS
nassert "⑪ 空行 → null" <<'JS'
const { parseLine } = await import(process.env.CHAT_PATH)
if (parseLine('') !== null) throw new Error('empty')
if (parseLine('   ') !== null) throw new Error('blank')
JS
nassert "⑫ /switch <前缀>" <<'JS'
const { parseLine } = await import(process.env.CHAT_PATH)
const r = parseLine('/switch coder-')
if (r.type !== 'switch' || r.prefix !== 'coder-') throw new Error(JSON.stringify(r))
JS

echo "--- 命令入口 ---"
# ⑬ crew chat --list:走 HTTP 面拉成员列表打到 stdout(远程可达→列角色;不可达→明确报错)
out=$("$CREW" chat --list 2>/dev/null); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -qE "\-pipe-" ; then
  _ok "⑬ crew chat --list 列出角色(${out##*
} $(echo "$out" | grep -c pipe) 行)"
elif [ $rc -ne 0 ]; then
  _ok "⑬ crew chat --list 远程不可达时非零退出(合理): $(echo "$out" | head -1 | cut -c1-50)"
else
  _ng "⑬ crew chat --list 意外输出: $(echo "$out" | head -2)"
fi

# ⑭ 不带参非交互:应列出角色或用法提示,不栈崩溃
out=$("$CREW" chat </dev/null 2>&1 | head -6)
if echo "$out" | grep -qE "用法|designer-pipe|coder-pipe|lead-pipe|选|role|无角色|不可达"; then
  _ok "⑭ crew chat 无参不崩(有角色列表或用法提示)"
else
  _ng "⑭ crew chat 无参输出异常: $(echo "$out" | head -2)"
fi

# ⑮ 不存在前缀:非交互下应报"无此角色"类错误并 exit 1
out=$("$CREW" chat zzz-nope 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  _ok "⑮ 不存在前缀 → 非零退出: $(echo "$out" | head -1 | cut -c1-60)"
else
  _ng "⑮ 不存在前缀却 exit 0: $(echo "$out" | head -1 | cut -c1-60)"
fi

# ⑯ 端到端:fake 平台 HTTP 面 + 真 crew-acpd + 真 SDK client。
#    这是集成核心:验证 update wire 格式嵌套形态(zod 校验)、prompt→session/new、stop 路由。
FAKE_HTTP="$T/fake-http.mjs"
cat > "$FAKE_HTTP" <<'EOF'
import http from 'node:http'
const members = [{member:'designer-pipe-20261019-wand3', pid:'PIPE-20261019-wand3', role:'designer'}]
const msgs = [
  {ts: 1, note: '历史消息(应标记已读不回放)', replyOut: true},
]
let seq = 2
const server = http.createServer((req, res) => {
  let body = ''
  req.on('data', c => body += c)
  req.on('end', () => {
    if (req.url.startsWith('/api/projects')) {
      res.writeHead(200, {'Content-Type':'application/json'})
      res.end(JSON.stringify({ok:true, projects:[{name:'PIPE-20261019-wand3', sessions:[{name:'designer-pipe-20261019-wand3', role:'teammate'}]}]}))
    } else if (req.url.startsWith('/api/messages')) {
      // prompt 注入的消息 + 角色回复
      const q = req.url
      if (q.includes('kick=1')) return_void(res)
      else {
        res.writeHead(200, {'Content-Type':'application/json'})
        res.end(JSON.stringify({messages: msgs}))
      }
    } else if (req.url.startsWith('/api/send')) {
      const b = JSON.parse(body)
      msgs.push({ts: seq++, note: 'user:' + b.text, replyOut: false})
      setTimeout(() => msgs.push({ts: seq++, note: '回复:' + b.text, replyOut: true}), 400)
      res.writeHead(200, {'Content-Type':'application/json'})
      res.end(JSON.stringify({ok:true}))
    } else { res.writeHead(404); res.end('{}') }
  })
})
function return_void(res){ res.writeHead(200); res.end(JSON.stringify({messages:[]})) }
server.listen(0, '127.0.0.1', () => { process.stderr.write(String(server.address().port)) })
EOF
node "$FAKE_HTTP" 2>"$T/port.log" & FAKE_PID=$!
for i in $(seq 1 30); do [ -s "$T/port.log" ] && break; sleep 0.2; done
FAKE_PORT=$(cat "$T/port.log")
if [ -n "$FAKE_PORT" ]; then
  cat > "$T/e2e.mjs" <<EOF
import { client, methods, PROTOCOL_VERSION, ndJsonStream } from 'file:///Users/wangqiwang1/Desktop/claude-crew/acp/node_modules/@agentclientprotocol/sdk/dist/acp.js'
import { spawn } from 'node:child_process'
import { Readable, Writable } from 'node:stream'

const acpd = spawn('node', ['/Users/wangqiwang1/Desktop/claude-crew/acp/crew-acpd.mjs'], {
  env: {...process.env, JIMDB_BASE: 'http://127.0.0.1:${FAKE_PORT}', JIMDB_ERP: 'tester'},
})
const stream = ndJsonStream(Writable.toWeb(acpd.stdin), Readable.toWeb(acpd.stdout))

let gotText = ''
await client({name:'e2e-test', version:'0.0.1'})
  .onRequest(methods.client.session.requestPermission, async () => ({outcome:{outcome:'selected', optionId:'allow'}}))
  .connectWith(stream, async (cx) => {
    const init = await cx.request(methods.agent.initialize, {
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: {fs:{readTextFile:false, writeTextFile:false}},
    })
    if (!init.agentCapabilities?.listSessions) throw new Error('listSessions capability 缺失')
    const list = await cx.request(methods.agent.session.list, {})
    if (!list.sessions?.some(s => s.sessionId === 'designer-pipe-20261019-wand3')) throw new Error('session/list 未含成员')
    const session = await cx.buildSession('pipe://PIPE-20261019-wand3/designer').start()
    const p = session.prompt('你好')
    // 同时消费 update 流
    for (;;) {
      const msg = await session.nextUpdate()
      if (msg.kind === 'stop') break
      const u = msg.notification?.update ?? msg.notification
      if (u?.sessionUpdate === 'agent_message_chunk' && u.content?.type === 'text') gotText += u.content.text
    }
    await p
  })
if (!gotText.includes('回复:你好')) { acpd.kill(); throw new Error('未收到角色回复文本,got: ' + JSON.stringify(gotText)) }
acpd.kill()
console.log('E2E-OK text=' + JSON.stringify(gotText))
process.exit(0)
EOF
  if out=$(node "$T/e2e.mjs" 2>&1); then
    _ok "⑯ 端到端 SDK client↔crew-acpd 往返(wire 格式/会话/prompt/stop)"
  else
    _ng "⑯ 端到端失败: $(echo "$out" | tail -3 | head -1 | cut -c1-90)"
  fi
  kill $FAKE_PID 2>/dev/null
else
  _ng "⑯ fake HTTP 面未起: $(cat "$T/port.log" | head -1)"
fi

# ⑰ crew 脚本 chat 分支存在
if grep -q 'chat)' "$CREW" && grep -q 'crew-chat.mjs' "$CREW"; then
  _ok "⑰ crew dispatch 含 chat 分支 → acp/crew-chat.mjs"
else
  _ng "⑰ crew dispatch 缺 chat 分支"
fi

echo
echo "=== crew-acp-chat.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
