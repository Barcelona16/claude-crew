#!/usr/bin/env node
/**
 * crew-dsh —— crew dsh 的终端 ACP 客户端(2026-10-20,原 crew-chat 更名升级)。
 *
 * 用途:在 iTerm 里交互式连远程 dsh 编排器:先选流水线(lead),进去默认跟 lead 对话,
 *      /switch 在流水线内切子代理(designer/coder/reviewer/tester/…)。
 *
 * 两级结构(用户拍板 2026-10-20):
 *   session/list → groupPipelines 按流水线分组 → 选流水线 → 默认连 lead
 *   → REPL:文本发给当前角色;/switch <role> 流水线内切换;/roles 看角色;/quit 退出
 *
 * 对话框样式:「你 › …」「<role> › …」标准对话渲染。
 *
 * 架构:spawn crew-acpd(stdio)→ SDK client() → request(session/list) → buildSession(pipe://<pid>/<role>)。
 *
 * 用法:
 *   crew dsh                       # 交互:选流水线 → 默认 lead
 *   crew dsh wand3                 # 流水线前缀直连(多命中列候选)
 *   crew dsh wand3 designer        # 流水线 + 角色直连
 *   crew dsh --list                # 列流水线×角色
 * 环境变量:JIMDB_BASE / JIMDB_ERP(透传 crew-acpd)、CREW_ACPD(覆盖 acpd 路径)
 */
import { client, methods, PROTOCOL_VERSION, ndJsonStream } from '@agentclientprotocol/sdk'
import { spawn } from 'node:child_process'
import { Readable, Writable } from 'node:stream'
import readline from 'node:readline/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import process from 'node:process'

const ACPD = process.env.CREW_ACPD || join(dirname(fileURLToPath(import.meta.url)), 'crew-acpd.mjs')

// ---------- 纯函数(单测直接 import)----------

/** pickMember(members, prefix) → {kind:'ok', hit} | {kind:'ambiguous', candidates} | null
 * 完整名精确命中优先;否则前缀/子串匹配(唯一 → ok,多个 → ambiguous,零个 → null)。 */
export function pickMember(members, prefix) {
  if (!prefix) return null
  const exact = members.find(m => m.member === prefix)
  if (exact) return { kind: 'ok', hit: exact }
  const hits = members.filter(m => m.member.startsWith(prefix) || m.member.includes(prefix))
  if (hits.length === 1) return { kind: 'ok', hit: hits[0] }
  if (hits.length > 1) return { kind: 'ambiguous', candidates: hits }
  return null
}

/** groupPipelines(members) → [{pid, roles:[{member,role}]}]
 * 按流水线分组;组内 lead 排首,其余角色字母序。pid 归一小写(去 PIPE- 前缀)。 */
export function groupPipelines(members) {
  const byPid = new Map()
  for (const m of members ?? []) {
    const pid = (m.pid ?? '').replace(/^PIPE-/i, '')
    if (!pid) continue
    if (!byPid.has(pid)) byPid.set(pid, [])
    byPid.get(pid).push(m)
  }
  const groups = []
  for (const [pid, list] of byPid) {
    const roles = [...list].sort((a, b) => {
      const ra = a.role === 'lead' ? 0 : 1, rb = b.role === 'lead' ? 0 : 1
      if (ra !== rb) return ra - rb          // lead 恒首
      return a.role.localeCompare(b.role)     // 其余字母序
    })
    groups.push({ pid, roles })
  }
  groups.sort((a, b) => b.pid.localeCompare(a.pid))  // 新流水线在前(pid 含日期)
  return groups
}

/** renderTurn(role, text) → 'role › text' 对话框行。 */
export function renderTurn(role, text) {
  return `${role} › ${text}`
}

/** renderUpdate(update) → string | null
 * agent_message_chunk 文本原样(前缀由调用方 renderTurn 包);tool_call → 🔧 行;其余 null。 */
export function renderUpdate(u) {
  if (!u || typeof u !== 'object') return null
  switch (u.sessionUpdate) {
    case 'agent_message_chunk':
      if (u.content?.type === 'text') return u.content.text
      return null
    case 'tool_call':
      return `🔧 ${u.title ?? u.toolCallId ?? 'tool'} (${u.status ?? 'pending'})\n`
    default:
      return null
  }
}

/** parseLine(line) → {type:'msg',text} | {type:'cmd',name} | {type:'switch',prefix} | {type:'quit'} | null
 * /roles 列角色;/switch <role> 流水线内切;空行 null;其余文本 msg。 */
export function parseLine(line) {
  const s = (line ?? '').trim()
  if (!s) return null
  if (s === '/quit' || s === '/q' || s === 'exit') return { type: 'quit' }
  if (s === '/roles' || s === '/list') return { type: 'cmd', name: 'roles' }
  if (s.startsWith('/switch')) {
    const prefix = s.slice('/switch'.length).trim()
    if (!prefix) return { type: 'cmd', name: 'switch-noarg' }
    return { type: 'switch', prefix }
  }
  return { type: 'msg', text: s }
}

// ---------- 主流程(仅直跑执行;被 import 时不跑)----------

const log = (...a) => process.stderr.write(`[crew-dsh] ${a.join(' ')}\n`)

export async function main() {
  const argv = process.argv.slice(2)
  const listOnly = argv.includes('--list')
  const posArgs = argv.filter(a => !a.startsWith('--'))
  const [pidArg, roleArg] = posArgs

  const acpdEnv = { ...process.env, CREW_ACPD_QUIET: process.env.CREW_DSH_DEBUG ? '' : '1' }
  const acpd = spawn('node', [ACPD], { env: acpdEnv, stdio: ['pipe', 'pipe', 'inherit'] })
  const cleanup = () => { try { acpd.kill() } catch {} }
  process.on('exit', cleanup)
  process.on('SIGINT', () => { cleanup(); process.exit(130) })
  process.on('SIGTERM', () => { cleanup(); process.exit(143) })

  const stream = ndJsonStream(Writable.toWeb(acpd.stdin), Readable.toWeb(acpd.stdout))

  await client({ name: 'crew-dsh', version: '0.2.0' })
    .onRequest(methods.client.session.requestPermission, async (cx) => {
      const opt = cx.params?.options?.find(o => o.kind === 'allow_once' || o.kind === 'allow_always')
        ?? cx.params?.options?.[0]
      return { outcome: { outcome: 'selected', optionId: opt?.optionId ?? 'allow' } }
    })
    .connectWith(stream, async (cx) => {
      const init = await cx.request(methods.agent.initialize, {
        protocolVersion: PROTOCOL_VERSION,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
      })
      if (!init.agentCapabilities?.listSessions) throw new Error('acpd 未声明 listSessions 能力')

      const fetchMembers = async () => {
        const list = await cx.request(methods.agent.session.list, {})
        return (list.sessions ?? []).map(s => ({
          member: s.sessionId,
          pid: (s.cwd?.match(/^pipe:\/\/(.+)\/[^/]+$/)?.[1] ?? '').replace(/^PIPE-/i, '').toLowerCase(),
          role: s.title?.split(' · ')[0] ?? s.sessionId.split('-pipe-')[0],
        }))
      }

      let members = await fetchMembers()
      const groups = groupPipelines(members)

      if (listOnly) {
        for (const g of groups) {
          console.log(`${g.pid}(PIPE-${g.pid.toUpperCase()})`)
          for (const r of g.roles) console.log(`  ${r.role.padEnd(12)} ${r.member}`)
        }
        console.log(`(${groups.length} 条流水线,${members.length} 个角色)`)
        acpd.kill(); process.exit(0)
      }

      // ---- 第一级:选流水线 ----
      let group
      if (pidArg) {
        // 前缀/子串匹配 pid(如 wand3 / 20261019 / 20261019-wand3)
        const hits = groups.filter(g => g.pid.includes(pidArg.toLowerCase()))
        if (hits.length === 0) { console.error(`✗ 无此流水线:${pidArg}(--list 查看)`); acpd.kill(); process.exit(1) }
        if (hits.length > 1) {
          console.error('✗ 流水线多命中,请更精确:')
          for (const h of hits) console.error(`    ${h.pid}`)
          acpd.kill(); process.exit(1)
        }
        group = hits[0]
      } else if (!process.stdin.isTTY) {
        console.error('用法: crew dsh [流水线前缀 [角色]] | --list')
        console.error('流水线:')
        for (const g of groups) console.error(`  ${g.pid}  (${g.roles.map(r => r.role).join(',')})`)
        acpd.kill(); process.exit(1)
      } else {
        console.log('流水线:')
        groups.forEach((g, i) => console.log(`  ${i + 1}. ${g.pid}  (${g.roles.map(r => r.role).join(',')})`))
        const rl0 = readline.createInterface({ input: process.stdin, output: process.stdout })
        const answer = (await rl0.question('选序号或流水线前缀: ')).trim()
        rl0.close()
        let r = null
        if (/^\d+$/.test(answer)) { if (groups[+answer - 1]) r = groups[+answer - 1] }
        else if (answer) { const h = groups.filter(g => g.pid.includes(answer.toLowerCase())); if (h.length === 1) r = h[0] }
        if (!r) { console.error('✗ 无效选择,退出'); acpd.kill(); process.exit(1) }
        group = r
      }

      // ---- 第二级:选角色(默认 lead)----
      const pickRole = (prefix) => {
        const exact = group.roles.find(r => r.role === prefix)
        if (exact) return exact
        const hits = group.roles.filter(r => r.role.startsWith(prefix))
        if (hits.length === 1) return hits[0]
        if (hits.length > 1) return { ambiguous: hits.map(r => r.role) }
        return null
      }
      let current
      if (roleArg) {
        const r = pickRole(roleArg)
        if (!r) { console.error(`✗ 流水线 ${group.pid} 无此角色:${roleArg}(角色:${group.roles.map(x => x.role).join(',')})`); acpd.kill(); process.exit(1) }
        if (r.ambiguous) { console.error(`✗ 角色多命中:${r.ambiguous.join(',')}`); acpd.kill(); process.exit(1) }
        current = r
      } else {
        current = group.roles.find(r => r.role === 'lead') ?? group.roles[0]
      }

      // ---- 会话 + REPL ----
      const cwdOf = (m) => `pipe://PIPE-${m.pid.toUpperCase()}/${m.role}`
      const banner = `🏛 ${group.pid} · 对话:${current.role}(/switch <role> 切子代理;/roles 看角色;/quit 退出)`
      console.log(`\n${banner}\n`)

      let session = await cx.buildSession(cwdOf(current)).start()

      const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
      const promptUser = () => process.stdout.write(`你 › `)
      promptUser()

      rl.on('line', (line) => { handleLine(line).catch(e => { console.log(`\n✗ ${e.message ?? e}`); promptUser() }) })
      rl.on('close', () => { cleanup(); process.exit(0) })

      async function handleLine(line) {
        const p = parseLine(line)
        if (!p) { promptUser(); return }
        if (p.type === 'quit') { rl.close(); return }
        if (p.type === 'cmd' && p.name === 'roles') {
          console.log(`角色: ${group.roles.map(r => r.role).join('  ')}(当前:${current.role})`)
          promptUser(); return
        }
        if (p.type === 'cmd' && p.name === 'switch-noarg') { console.log('用法: /switch <role>(如 /switch designer)'); promptUser(); return }
        if (p.type === 'switch') {
          const r = pickRole(p.prefix)
          if (!r) { console.log(`✗ 无此角色:${p.prefix}(角色:${group.roles.map(x => x.role).join(',')})`); promptUser(); return }
          if (r.ambiguous) { console.log(`✗ 角色多命中:${r.ambiguous.join(',')}`); promptUser(); return }
          try { session.dispose?.() } catch {}
          current = r
          session = await cx.buildSession(cwdOf(r)).start()
          console.log(`→ 已切换 ${r.role}`)
          promptUser(); return
        }
        // msg:对话框样式——用户行已由 readline 呈现,回车后补显角色前缀待流
        const pending = session.prompt(p.text)
        let first = true
        for (;;) {
          const msg = await session.nextUpdate()
          if (msg.kind === 'stop') break
          const line = renderUpdate(msg.update)
          if (line === null) continue
          if (first) { process.stdout.write(`\n${renderTurn(current.role, '')}`); first = false }
          process.stdout.write(line)
        }
        await pending
        process.stdout.write('\n')
        promptUser()
      }

      await new Promise(() => {})
    })
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch(e => { log('fatal:', e?.stack ?? e); process.exit(1) })
}
