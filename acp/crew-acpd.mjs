#!/usr/bin/env node
/**
 * crew-acpd — 把 JIMDB 平台的 dsh 进程内子代理(teammate)暴露成 ACP server(2026-10-19)。
 *
 * 架构:本机 stdio ACP server(session 协议 = ACP),后端对接平台 HTTP 消息面:
 *   session/new    → 绑定一个平台角色会话(<role>-pipe-<pid>);cwd 形如 "pipe://<pid>/<role>"
 *                    也可不绑(临时会话)——list 出全部成员供客户端挑。
 *   session/list   → GET /api/projects 拉流水线 × 角色,每个成员一个可 resume 的 session 条目。
 *   session/resume → 同 new(按 sessionId=成员名接上,历史经 session/load 由客户端拉或 prompt 触发回显)。
 *   session/prompt → POST /api/send 投递文本(deliverToSession → teammate steer);
 *                    随后轮询 /api/messages 增量,新 assistant 消息转 ACP session/update 流式吐给客户端。
 *   session/close  → 断开(不动远端会话)。
 *
 * 与 dsh 原生 dsh-acp 的区别:那个只服务 root/新 agent(碰不到 agent-team teammate);
 * 本适配层专门把 teammate 通道协议化。零 dsh 改动、零平台改动——纯本机桥。
 *
 * 用法(stdio,供任何 ACP 客户端拉起):
 *   crew-acpd                      # env: JIMDB_BASE(默认 http://11.91.165.248:3200) JIMDB_ERP(默认 wangqiwang1)
 * 客户端配置示例(Zed / 任意 ACP client):
 *   {"command": "/Users/<you>/Desktop/claude-crew/acp/crew-acpd.mjs", "args": []}
 * 手动冒烟:
 *   echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}' | crew-acpd
 */
import { agent, ndJsonStream } from '@agentclientprotocol/sdk'
import process from 'node:process'
import { Readable, Writable } from 'node:stream'

const BASE = process.env.JIMDB_BASE || 'http://11.91.165.248:3200'
const ERP = process.env.JIMDB_ERP || 'wangqiwang1'

const log = (...a) => process.stderr.write(`[crew-acpd] ${a.join(' ')}\n`)

async function api(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { 'X-ERP': ERP, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  })
  if (!res.ok) throw new Error(`${method} ${path} → HTTP ${res.status}`)
  return res.json()
}

/** 全部流水线 × 角色成员(session/list 数据源)。 */
async function listMembers() {
  const j = await api('GET', '/api/projects')
  const out = []
  for (const p of j.projects ?? []) {
    for (const s of p.sessions ?? []) {
      // 只列流水线成员(独立会话组跳过,ACP 场景是连流水线角色)
      if (!/^PIPE-/i.test(p.name)) continue
      out.push({ member: s.name, pid: p.name, role: s.role })
    }
  }
  return out
}

/** 拉某成员面板消息(增量用:返回带内部 id 的原始数组)。 */
async function fetchMessages(member, pid) {
  const q = `session=${encodeURIComponent(member)}${pid ? `&project=${encodeURIComponent(pid)}` : ''}`
  const j = await api('GET', `/api/messages?${q}&n=200`)
  return j.messages ?? []
}

/** ACP cwd 编码:pipe://<pid>/<role> → member = <role>-pipe-<pid 无 PIPE- 前缀的小写>。
 * 平台成员命名约定:member = "<role>-pipe-<流水号小写>"(如 designer-pipe-20261019-wand3,
 * pid 段不含 PIPE- 前缀)。cwd 里保留完整 pid(PIPE-20261019-wand3)便于人读,解析时剥前缀。 */
function cwdToMember(cwd) {
  const m = /^pipe:\/\/([^/]+)\/([a-z]+)$/i.exec(cwd ?? '')
  if (!m) return undefined
  const pidRaw = m[1], role = m[2]
  const pid = pidRaw.replace(/^PIPE-/i, '').toLowerCase()
  return { member: `${role}-pipe-${pid}`, pid, role }
}

// 活跃 ACP session 表:sessionId → { member, pid, role, known: Set(已推给客户端的消息签名), poller }
const active = new Map()
let sessionSeq = 0

const app = agent({ name: 'crew-acpd', version: '0.1.0' })

app.onRequest('initialize', async () => ({
  protocolVersion: 1,
  agentCapabilities: {
    loadSession: false,
    listSessions: true,
    // prompt 流 + 会话关闭;不做 permission(平台侧已 bypass)/ elicitation
  },
  authMethods: [],
}))

// session/new:params.cwd = pipe://<pid>/<role>(客户端按 list 的 cwd 字段构造)。
app.onRequest('session/new', async (cx) => {
  const { params, client } = cx   // SDK handler 收 context{params,requestId,signal,client},非裸 params
  log('session/new cwd =', params?.cwd ?? '(未绑定)')
  const target = cwdToMember(params?.cwd)
  if (!target) {
    // 未指定目标:开一个"未绑定"会话,客户端应先 list 再 resume 指定角色
    const id = `acp-${++sessionSeq}`
    active.set(id, { member: null, pid: null, role: null, known: new Set() })
    return { sessionId: id }
  }
  // 校验成员存在
  const members = await listMembers()
  const hit = members.find(m => m.member === target.member)
  if (!hit) throw new Error(`无此角色会话:${target.member}(session/list 查看可用)`)
  const id = `acp-${++sessionSeq}`
  const rec = { member: hit.member, pid: hit.pid, role: hit.role, known: new Set(), poller: null }
  active.set(id, rec)
  // 首次连接:把既有历史里【最近一条 assistant 消息之前的部分】标记为已读(不回放全史,只跟新消息)。
  const hist = await fetchMessages(rec.member, rec.pid)
  for (const m of hist) rec.known.add(sig(m))
  log(`session ${id} → ${rec.member} (历史 ${hist.length} 条标记已读,只跟新)`)
  return { sessionId: id }
})

app.onRequest('session/list', async () => {
  const members = await listMembers()
  return {
    // 成员名 <role>-pipe-<pid> 里的 role 才是语义角色(平台 sessions[].role 恒 'teammate')
    sessions: members.map(m => {
      const role = m.member.split('-pipe-')[0]
      return {
        sessionId: m.member,
        cwd: `pipe://${m.pid}/${role}`,
        title: `${role} · ${m.pid}`,
      }
    }),
  }
})

// resume:按 sessionId(=成员名)直接接上(不回放历史 —— 客户端要历史可发一条 "总结当前进展" prompt)。
app.onRequest('session/resume', async (cx) => {
  const { params } = cx
  const member = params.sessionId
  const members = await listMembers()
  const hit = members.find(m => m.member === member)
  if (!hit) throw new Error(`无此角色会话:${member}`)
  const id = `acp-${++sessionSeq}`
  const rec = { member: hit.member, pid: hit.pid, role: hit.role, known: new Set(), poller: null }
  const hist = await fetchMessages(rec.member, rec.pid)
  for (const m of hist) rec.known.add(sig(m))
  active.set(id, rec)
  return { sessionId: id }
})

// prompt:投递文本 → 轮询增量 → session/update 流式推送 → stopReason。
app.onRequest('session/prompt', async (cx) => {
  const { params, client } = cx
  try { return await handlePrompt(params, client) }
  catch (e) { log('prompt error:', e && e.stack || e); throw e }
})

async function handlePrompt(params, ctx) {
  const rec = active.get(params.sessionId)
  if (!rec || !rec.member) throw new Error('会话未绑定角色(先 session/list + session/new pipe://…)')
  const text = (params.prompt ?? []).filter(b => b.type === 'text').map(b => b.text).join('\n')
  if (!text) throw new Error('空 prompt')
  // ① 投递给 teammate(平台 deliverToSession → steer)
  const r = await api('POST', '/api/send', { session: rec.member, text })
  if (r.ok !== true) throw new Error(`投递失败:${r.err ?? 'unknown'}`)
  // ② 客户端自显输入,不 echo;直接进轮询。
  // ACP wire 格式(2026-10-19 修复):session/update 的 params 是嵌套形态
  //   {sessionId, update: {sessionUpdate: 'agent_message_chunk', content: {type:'text', text}}}
  // 原实现误用扁平形态 {sessionId, sessionUpdate:{type,...}} —— SDK 客户端 zod 校验直接拒收
  // (Invalid params),角色回复永远流不回客户端。集成测试 ⑯ 拦截此缺陷。
  const push = async text => ctx.notify('session/update', {
    sessionId: params.sessionId,
    update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } },
  })
  // ③ 轮询增量:deadline 10 分钟;首轮回复可能要几十秒(角色跑一轮),耐心等;
  //    收到回复后进入 settle 检测(连续 20s 无新 assistant 消息 → end_turn)。
  const deadline = Date.now() + 10 * 60_000
  let lastNewAt = 0
  while (Date.now() < deadline) {
    await sleep(3000)
    const msgs = await fetchMessages(rec.member, rec.pid).catch(() => [])
    let fresh = false
    for (const m of msgs) {
      const s = sig(m)
      if (rec.known.has(s)) continue
      rec.known.add(s)
      if (m.replyOut !== true) continue   // user/工具回执不推;只推角色 assistant 输出
      fresh = true
      await push(`${m.note ?? ''}\n`)
    }
    if (fresh) lastNewAt = Date.now()
    // settle:已有过回复(lastNewAt>0)且 20s 无新动静 → 本轮结束
    if (lastNewAt > 0 && Date.now() - lastNewAt > 20_000) return { stopReason: 'end_turn' }
  }
  return { stopReason: 'end_turn' }
}

app.onRequest('session/close', async (cx) => {
  const { params } = cx
  const rec = active.get(params.sessionId)
  if (rec?.poller) clearInterval(rec.poller)
  active.delete(params.sessionId)
  return {}
})

app.onNotification('session/cancel', () => { /* 轮询循环靠 deadline 自然退;客户端断开即停 */ })

function sig(m) { return `${m.ts}|${(m.note ?? '').slice(0, 48)}` }
const sleep = ms => new Promise(r => setTimeout(r, ms))

// stdio 接线(Node stream → WHATWG stream,SDK 的 ndJsonStream 只认 Web Stream)
const stream = ndJsonStream(Writable.toWeb(process.stdout), Readable.toWeb(process.stdin))
app.connect(stream)
log(`ready · base=${BASE} erp=${ERP}(session/list 看角色;session/new cwd=pipe://<pid>/<role>)`)
