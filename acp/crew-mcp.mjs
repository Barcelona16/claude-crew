#!/usr/bin/env node
/**
 * crew-mcp —— 平台角色子代理的 MCP server(2026-10-19)。
 * 让本机任意 Claude Code 会话(含 crew 起的)直接对话远程 dsh 进程内子代理:
 *   list_role_agents     列全部流水线角色(成员名 + 所属流水线)
 *   ask_role_agent       给某角色发消息并等它的回复(轮询 /api/messages 增量)
 *   send_role_agent      单向发消息(不等回复,fire-and-forget)
 *
 * 与 crew-acpd(ACP server,给 Zed 等 ACP 客户端)同源不同皮:数据面同是平台 API。
 * 注册:claude mcp add jimdb-remote -s user -- node ~/Desktop/claude-crew/acp/crew-mcp.mjs
 * env:JIMDB_BASE(默认 http://11.91.165.248:3200) JIMDB_ERP(默认 wangqiwang1)
 */
import process from 'node:process'

const BASE = process.env.JIMDB_BASE || 'http://11.91.165.248:3200'
const ERP = process.env.JIMDB_ERP || 'wangqiwang1'

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

async function listMembers() {
  const j = await api('GET', '/api/projects')
  const out = []
  for (const p of j.projects ?? []) {
    if (!/^PIPE-/i.test(p.name)) continue
    for (const s of p.sessions ?? []) out.push({ member: s.name, pid: p.name, role: s.role })
  }
  return out
}

async function fetchMessages(member) {
  const j = await api('GET', `/api/messages?session=${encodeURIComponent(member)}&n=200`)
  return j.messages ?? []
}

const sig = m => `${m.ts}|${(m.note ?? '').slice(0, 48)}`
const sleep = ms => new Promise(r => setTimeout(r, ms))

// ---- MCP stdio(JSON-RPC)极简实现:只实现 CC 需要的方法子集 ----
const TOOLS = [
  {
    name: 'list_role_agents',
    description: '列出 JIMDB 平台全部流水线角色子代理(dsh 进程内 teammate)。返回成员名(如 designer-pipe-20261019-wand3)、所属流水线、角色。ask_role_agent/send_role_agent 的 name 参数从这拿。',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'ask_role_agent',
    description: '向平台某角色子代理(如 reviewer-pipe-xxx)发消息并等待其回复。回复 = 该角色随后产生的全部 assistant 消息(带轮询,最多等 3 分钟,20 秒无新输出即收口)。用于向远程 agent 提问/要上下文。',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: '角色成员名(list_role_agents 里的 member)' },
        message: { type: 'string', description: '发给该角色的消息' },
      },
      required: ['name', 'message'],
    },
  },
  {
    name: 'send_role_agent',
    description: '向平台某角色子代理单向发消息(不等回复)。用于下达指令/补充上下文。',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string' },
        message: { type: 'string' },
      },
      required: ['name', 'message'],
    },
  },
]

function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n') }

let buf = ''
let inFlight = 0   // 在途请求数:stdin EOF 后等它归零再退(防管道测试时在途 tools/call 被掐断)
process.stdin.on('data', d => {
  buf += d.toString()
  let i
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim()
    buf = buf.slice(i + 1)
    if (line !== '') {
      inFlight++
      handle(JSON.parse(line)).catch(() => {}).finally(() => {
        inFlight--
        if (process.stdin.readableEnded && inFlight === 0) process.exit(0)
      })
    }
  }
})
process.stdin.on('end', () => { if (inFlight === 0) process.exit(0) })

async function handle(req) {
  const { id, method, params } = req
  try {
    if (method === 'initialize') {
      send({ jsonrpc: '2.0', id, result: { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'jimdb-remote', version: '0.1.0' } } })
      return
    }
    if (method === 'notifications/initialized') return   // 通知无响应
    if (method === 'tools/list') {
      send({ jsonrpc: '2.0', id, result: { tools: TOOLS } })
      return
    }
    if (method === 'tools/call') {
      const tool = params?.name
      const args = params?.arguments ?? {}
      let text
      if (tool === 'list_role_agents') {
        const members = await listMembers()
        text = members.length === 0 ? '(无活动流水线角色)' : members.map(m => `${m.member}  (${m.role} · ${m.pid})`).join('\n')
      } else if (tool === 'send_role_agent' || tool === 'ask_role_agent') {
        const r = await api('POST', '/api/send', { session: args.name, text: args.message })
        if (r.ok !== true) text = `投递失败:${r.err ?? 'unknown'}`
        else if (tool === 'send_role_agent') text = `✅ 已投递给 ${args.name}(不等回复)`
        else {
          // ask:标已知,轮询增量 assistant 输出;20s 静默收口,上限 3min
          const known = new Set()
          for (const m of await fetchMessages(args.name)) known.add(sig(m))
          const deadline = Date.now() + 3 * 60_000
          let lastNew = 0
          const parts = []
          while (Date.now() < deadline) {
            await sleep(3000)
            const msgs = await fetchMessages(args.name).catch(() => [])
            let fresh = false
            for (const m of msgs) {
              const s = sig(m)
              if (known.has(s)) continue
              known.add(s)
              if (m.replyOut === true) { fresh = true; parts.push(m.note ?? '') }
            }
            if (fresh) lastNew = Date.now()
            if (lastNew > 0 && Date.now() - lastNew > 20_000) break
          }
          text = parts.length > 0 ? parts.join('\n\n----\n\n') : `(已投递,3 分钟内无新回复)`
        }
      } else {
        text = `未知工具:${tool}`
      }
      send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text }] } })
      return
    }
    if (id !== undefined) send({ jsonrpc: '2.0', id, result: {} })
  } catch (e) {
    if (id !== undefined) send({ jsonrpc: '2.0', id, error: { code: -32000, message: String(e?.message ?? e) } })
  }
}
