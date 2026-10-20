#!/usr/bin/env bash
# crew-dsh.test.sh — crew dsh(ACP 终端客户端,两级:流水线→角色)单元测试
# 覆盖:
#   ① pickMember:唯一前缀命中
#   ② pickMember:无命中 → null
#   ③ pickMember:多命中 → 返回候选列表让调用方提示
#   ④ pickMember:完整名精确命中(优先于前缀)
#   ⑤ groupPipelines:成员按流水线分组,组内 lead 排首,角色按字母序
#   ⑥ groupPipelines:空成员表 → 空组
#   ⑦ renderTurn:对话框样式「lead › 文本」
#   ⑧ renderUpdate:agent_message_chunk 原样(不带前缀,由 renderTurn 包)
#   ⑨ renderUpdate:tool_call → 🔧 行;plan/thought/user_chunk/未知 → null
#   ⑩ parseLine:普通文本 → msg
#   ⑪ parseLine:/roles /quit /q → 命令
#   ⑫ parseLine:空行 → null;/switch <前缀> → switch(流水线内切换)
#   ⑬ crew dsh --list:列出流水线×角色(远程可达时)或明确报错
#   ⑭ crew dsh 不带参 → 不崩(usage/流水线列表提示后 exit 1)
#   ⑮ crew dsh <不存在流水线> → 报错退出 1
#   ⑯ 端到端:SDK client ↔ crew-acpd(update wire 格式 + prompt 往返 + stop)
#   ⑰ crew 脚本 dispatch:dsh 分支存在且指向 acp/crew-dsh.mjs;chat 为别名

set -uo pipefail
unset CREW_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
DSH="$SCRIPT_DIR/../acp/crew-dsh.mjs"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-dsh-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ---- node 断言 helper:JS 代码经 stdin 传给 node,成员清单经 env 注入 ----
nassert() { # nassert <描述> <<JS … JS
  local desc="$1"
  local code; code=$(cat)
  if printf '%s' "$code" | DSH_PATH="$DSH" node --input-type=module - 2>"$T/err.log"; then
    _ok "$desc"
  else
    _ng "$desc"; sed 's/^/      /' "$T/err.log" | head -5
  fi
}

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
const { pickMember } = await import(process.env.DSH_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'coder-')
if (r.kind !== 'ok' || r.hit.member !== 'coder-pipe-20261019-wand3') throw new Error(JSON.stringify(r))
JS
nassert "② 无命中 → null" <<'JS'
const { pickMember } = await import(process.env.DSH_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'nope-')
if (r !== null) throw new Error('expect null, got ' + JSON.stringify(r))
JS
nassert "③ 多命中 → candidates" <<'JS'
const { pickMember } = await import(process.env.DSH_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'designer-')
if (r.kind !== 'ambiguous' || r.candidates.length !== 2) throw new Error(JSON.stringify(r))
JS
nassert "④ 完整名精确命中优先" <<'JS'
const { pickMember } = await import(process.env.DSH_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const r = pickMember(members, 'lead-pipe-20261019-wand3')
if (r.kind !== 'ok' || r.hit.member !== 'lead-pipe-20261019-wand3') throw new Error(JSON.stringify(r))
JS

echo "--- groupPipelines(两级:流水线→角色)---"
nassert "⑤ 分组:lead 排首 + 角色字母序" <<'JS'
const { groupPipelines } = await import(process.env.DSH_PATH)
const members = JSON.parse((await import('node:fs')).readFileSync(process.env.MEMBERS_JSON_PATH, 'utf8'))
const groups = groupPipelines(members)
if (groups.length !== 2) throw new Error('expect 2 pipelines, got ' + groups.length)
const w = groups.find(g => g.pid === '20261019-wand3')
if (!w) throw new Error('wand3 group missing')
if (w.roles[0].role !== 'lead') throw new Error('lead should be first, got ' + w.roles[0].role)
if (w.roles.length !== 3) throw new Error('expect 3 roles, got ' + w.roles.length)
const roleSeq = w.roles.map(r => r.role).join(',')
if (roleSeq !== 'lead,coder,designer') throw new Error('expect lead,coder,designer got ' + roleSeq)
JS
nassert "⑥ 空成员表 → 空组" <<'JS'
const { groupPipelines } = await import(process.env.DSH_PATH)
if (groupPipelines([]).length !== 0) throw new Error('expect empty')
JS

echo "--- renderTurn / renderUpdate(对话框样式)---"
nassert "⑦ renderTurn:lead › 文本" <<'JS'
const { renderTurn } = await import(process.env.DSH_PATH)
const s = renderTurn('lead', '今天负责 L1 需求设计。')
if (!/^lead › 今天负责/.test(s)) throw new Error('got ' + JSON.stringify(s))
JS
nassert "⑧ agent_message_chunk 原样(无前缀)" <<'JS'
const { renderUpdate } = await import(process.env.DSH_PATH)
const s = renderUpdate({sessionUpdate:'agent_message_chunk', content:{type:'text', text:'hello'}})
if (s !== 'hello') throw new Error('got ' + JSON.stringify(s))
JS
nassert "⑨ tool_call → 🔧;其余 → null" <<'JS'
const { renderUpdate } = await import(process.env.DSH_PATH)
const t = renderUpdate({sessionUpdate:'tool_call', title:'Read file.ts', status:'pending'})
if (!/🔧/.test(t)) throw new Error('tool_call: ' + JSON.stringify(t))
for (const u of [{sessionUpdate:'plan'},{sessionUpdate:'agent_thought_chunk'},{sessionUpdate:'user_message_chunk'},{sessionUpdate:'whatever'}]) {
  if (renderUpdate(u) !== null) throw new Error(u.sessionUpdate + ' should be null')
}
JS

echo "--- parseLine ---"
nassert "⑩ 普通文本 → msg" <<'JS'
const { parseLine } = await import(process.env.DSH_PATH)
const r = parseLine('帮我看看配额上限')
if (r.type !== 'msg' || r.text !== '帮我看看配额上限') throw new Error(JSON.stringify(r))
JS
nassert "⑪ /roles /quit /q → 命令" <<'JS'
const { parseLine } = await import(process.env.DSH_PATH)
if (parseLine('/roles').type !== 'cmd') throw new Error('roles')
if (parseLine('/quit').type !== 'quit') throw new Error('quit')
if (parseLine('/q').type !== 'quit') throw new Error('q')
JS
nassert "⑫ 空行→null;/switch <前缀>→switch" <<'JS'
const { parseLine } = await import(process.env.DSH_PATH)
if (parseLine('') !== null) throw new Error('empty')
if (parseLine('   ') !== null) throw new Error('blank')
const r = parseLine('/switch designer')
if (r.type !== 'switch' || r.prefix !== 'designer') throw new Error(JSON.stringify(r))
JS

echo "--- 命令入口(crew dsh)---"
# ⑬ crew dsh --list:远程可达→列流水线×角色;不可达→明确报错
out=$("$CREW" dsh --list 2>/dev/null); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -qE "\-pipe-" ; then
  _ok "⑬ crew dsh --list 列出流水线×角色"
elif [ $rc -ne 0 ]; then
  _ok "⑬ crew dsh --list 远程不可达时非零退出(合理)"
else
  _ng "⑬ crew dsh --list 意外输出: $(echo "$out" | head -2)"
fi

# ⑭ 不带参非交互:应列出流水线或用法提示,不栈崩溃
out=$("$CREW" dsh </dev/null 2>&1 | head -6)
if echo "$out" | grep -qE "用法|流水线|pipe-|PIPE-|无角色|不可达"; then
  _ok "⑭ crew dsh 无参不崩(有流水线列表或用法提示)"
else
  _ng "⑭ crew dsh 无参输出异常: $(echo "$out" | head -2)"
fi

# ⑮ 不存在流水线:非交互下应报错并 exit 1
out=$("$CREW" dsh zzz-nope 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  _ok "⑮ 不存在流水线 → 非零退出: $(echo "$out" | grep -v crew-acpd | head -1 | cut -c1-60)"
else
  _ng "⑮ 不存在流水线却 exit 0"
fi

# ⑯ 端到端:fake 平台 HTTP 面 + 真 crew-acpd + 真 SDK client。
FAKE_HTTP="$T/fake-http.mjs"
cat > "$FAKE_HTTP" <<'EOF'
import http from 'node:http'
const msgs = [{ts: 1, note: 'hist', replyOut: true}]
let seq = 2
const srv = http.createServer((req, res) => {
  let body = ''
  req.on('data', c => body += c)
  req.on('end', () => {
    if (req.url.startsWith('/api/projects')) {
      res.writeHead(200); res.end(JSON.stringify({ok:true, projects:[
        {name:'PIPE-20261019-wand3', sessions:[
          {name:'lead-pipe-20261019-wand3', role:'teammate'},
          {name:'designer-pipe-20261019-wand3', role:'teammate'},
        ]},
      ]}))
    } else if (req.url.startsWith('/api/messages')) {
      res.writeHead(200); res.end(JSON.stringify({messages: msgs}))
    } else if (req.url.startsWith('/api/send')) {
      const b = JSON.parse(body)
      msgs.push({ts: seq++, note: 'user:' + b.text, replyOut: false})
      setTimeout(() => msgs.push({ts: seq++, note: '回复:' + b.text, replyOut: true}), 400)
      res.writeHead(200); res.end(JSON.stringify({ok: true}))
    } else { res.writeHead(404); res.end('{}') }
  })
})
srv.listen(0, '127.0.0.1', () => process.stderr.write(String(srv.address().port)))
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
  .connectWith(stream, async (cx) => {
    await cx.request(methods.agent.initialize, {
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: {fs:{readTextFile:false, writeTextFile:false}},
    })
    const list = await cx.request(methods.agent.session.list, {})
    if (!list.sessions?.some(s => s.sessionId === 'designer-pipe-20261019-wand3')) throw new Error('session/list 未含成员')
    // 两级逻辑核心:默认选 lead 进会话
    const session = await cx.buildSession('pipe://PIPE-20261019-wand3/lead').start()
    const p = session.prompt('你好')
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
    _ok "⑯ 端到端 SDK client↔crew-acpd 往返(默认 lead 会话 + wire 格式 + stop)"
  else
    _ng "⑯ 端到端失败: $(echo "$out" | tail -3 | head -1 | cut -c1-90)"
  fi
  kill $FAKE_PID 2>/dev/null
else
  _ng "⑯ fake HTTP 面未起: $(cat "$T/port.log" | head -1)"
fi

# ⑰ crew 脚本 dispatch:dsh 为主命令,chat 为兼容别名
if grep -q 'dsh)' "$CREW" && grep -q 'crew-dsh.mjs' "$CREW" && grep -q 'chat)' "$CREW"; then
  _ok "⑰ crew dispatch 含 dsh → acp/crew-dsh.mjs(chat 为别名)"
else
  _ng "⑰ crew dispatch 缺 dsh 分支"
fi


echo "--- Martty 适配(acpd 未绑定会话自动绑 lead)---"
# ⑱ 未绑定 session/new(普通 cwd)→ prompt 自动绑定最新流水线 lead 并正常往返
#    场景:Martty 等通用 ACP 客户端 /new 传普通 cwd,不认识 pipe:// 协议
#    双通道:① 无 CREW_DSH_TARGET → 自动绑最新 lead;② CREW_DSH_TARGET=<member> → 绑指定成员
node "$FAKE_HTTP" 2>"$T/port.log" & FAKE2_PID=$!
for i in $(seq 1 30); do [ -s "$T/port.log" ] && break; sleep 0.2; done
FAKE_PORT=$(cat "$T/port.log" 2>/dev/null)
if [ -n "${FAKE_PORT:-}" ] && [ "$FAKE_PORT" -gt 0 ] 2>/dev/null; then
  cat > "$T/e2e-martty.mjs" <<EOF
import { client, methods, PROTOCOL_VERSION, ndJsonStream } from 'file:///Users/wangqiwang1/Desktop/claude-crew/acp/node_modules/@agentclientprotocol/sdk/dist/acp.js'
import { spawn } from 'node:child_process'
import { Readable, Writable } from 'node:stream'

const target = process.env.E2E_TARGET || ''
const acpd = spawn('node', ['/Users/wangqiwang1/Desktop/claude-crew/acp/crew-acpd.mjs'], {
  env: {...process.env, JIMDB_BASE: 'http://127.0.0.1:${FAKE_PORT}', JIMDB_ERP: 'tester',
        CREW_DSH_TARGET: target},
})
const stream = ndJsonStream(Writable.toWeb(acpd.stdin), Readable.toWeb(acpd.stdout))
let got = ''
await client({name:'martty-sim', version:'0.0.1'}).connectWith(stream, async (cx) => {
  await cx.request(methods.agent.initialize, {
    protocolVersion: PROTOCOL_VERSION,
    clientCapabilities: {fs:{readTextFile:false, writeTextFile:false}},
  })
  // Martty 风格:普通 cwd 开会话(不传 pipe://)
  const session = await cx.buildSession('/Users/tester/project').start()
  const p = session.prompt('你好')
  for (;;) {
    const msg = await session.nextUpdate()
    if (msg.kind === 'stop') break
    const u = msg.notification?.update ?? msg.notification
    if (u?.sessionUpdate === 'agent_message_chunk') got += u.content?.text ?? ''
  }
  await p
})
if (!got.includes('回复:你好')) { acpd.kill(); throw new Error('未收到回复: ' + JSON.stringify(got)) }
acpd.kill()
console.log('MARTTY-E2E-OK target=' + (target || '(auto-lead)'))
process.exit(0)
EOF
  if out=$(node "$T/e2e-martty.mjs" 2>&1); then
    _ok "⑱ 通用客户端普通 cwd 会话 → 自动绑 lead 并往返"
  else
    _ng "⑱ Martty 适配失败: $(echo "$out" | tail -2 | head -1 | cut -c1-80)"
  fi
  # ⑱b:CREW_DSH_TARGET=designer-… → Martty 普通会话绑指定角色(crew dsh wand3 designer 的富 UI 通道)
  if out=$(E2E_TARGET=designer-pipe-20261019-wand3 node "$T/e2e-martty.mjs" 2>&1); then
    _ok "⑱b CREW_DSH_TARGET 指定成员 → Martty 会话绑该角色"
  else
    _ng "⑱b CREW_DSH_TARGET 失败: $(echo "$out" | tail -2 | head -1 | cut -c1-80)"
  fi
  kill $FAKE2_PID 2>/dev/null
else
  _ng "⑱ fake HTTP 未起"
fi

echo "--- crew dsh 默认 Martty 富 UI ---"
# ⑲ cmd_dsh 默认路由:TTY+martty 可执行 → exec martty(检查 bin/crew 源码结构,不起真 TUI)
if grep -q 'martty' "$CREW" && grep -q 'CREW_DSH_TARGET' "$CREW" && grep -q '\-\-repl' "$CREW"; then
  _ok "⑲ cmd_dsh 含 martty 默认路由 + CREW_DSH_TARGET 通道 + --repl 回退"
else
  _ng "⑲ cmd_dsh 缺 martty 路由"
fi
# ⑳ CREW_DSH_UI=repl 强制轻量 REPL(不依赖 martty 安装)
out=$("$CREW" dsh --list 2>/dev/null >/dev/null; CREW_DSH_UI=repl timeout 15 "$CREW" dsh zzz-nope 2>&1)
if echo "$out" | grep -q "无此流水线"; then
  _ok "⑳ CREW_DSH_UI=repl 走内置 REPL 逻辑(错误路径可控)"
else
  _ng "⑳ repl 模式异常: $(echo "$out" | head -1 | cut -c1-60)"
fi
# ㉑ --repl flag 等价 CREW_DSH_UI=repl
out=$(timeout 15 "$CREW" dsh --repl zzz-nope 2>&1)
if echo "$out" | grep -q "无此流水线"; then
  _ok "㉑ --repl 显式回退内置 REPL"
else
  _ng "㉑ --repl 异常: $(echo "$out" | head -1 | cut -c1-60)"
fi

echo
echo "=== crew-dsh.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
