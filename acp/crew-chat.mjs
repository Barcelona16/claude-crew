#!/usr/bin/env node
/**
 * crew-chat —— crew acp 的终端 ACP 客户端(2026-10-19)。
 *
 * 用途:在 iTerm 里交互式连远程 dsh 进程内角色子代理(designer/coder/reviewer/tester/lead)。
 *      这是被删掉的裸 HTTP 版 crew chat(2427b7f)的 ACP 继任者:不再直连平台消息面,
 *      而是经 stdio 拉起 crew-acpd(ACP server),走标准 ACP 协议(session/list → new → prompt)。
 *
 * 架构(REPL):
 *   spawn crew-acpd → SDK client() → initialize → request(session/list)
 *   → 挑角色(参数前缀 / 交互菜单)→ buildSession(pipe://<pid>/<role>) → prompt 循环。
 *   agent_message_chunk 流式打印;tool_call 打 🔧 行;plan/thought 静默。
 *   命令:/list /switch <前缀> /quit
 *
 * 用法:
 *   crew chat                 # 交互菜单挑角色
 *   crew chat designer-       # 前缀直连(多命中时列候选)
 *   crew chat --list          # 只列角色不进 REPL
 * 环境变量:JIMDB_BASE / JIMDB_ERP(透传给 crew-acpd)、CREW_ACPD(覆盖 acpd 路径)
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

/** renderUpdate(update) → string | null
 * agent_message_chunk 文本直出;tool_call → 🔧 行;plan/thought/user_chunk → null(静默)。 */
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

/** parseLine(line) → {type:'msg', text} | {type:'cmd', name} | {type:'switch', prefix} | {type:'quit'} | null
 * 空行/纯空白 → null;/list → cmd;/quit /q → quit;/switch <p> → switch;其余(含未知斜杠)→ msg。 */
export function parseLine(line) {
  const s = (line ?? '').trim()
  if (!s) return null
  if (s === '/quit' || s === '/q' || s === 'exit') return { type: 'quit' }
  if (s === '/list') return { type: 'cmd', name: 'list' }
  if (s.startsWith('/switch')) {
    const prefix = s.slice('/switch'.length).trim()
    if (!prefix) return { type: 'cmd', name: 'switch-noarg' }
    return { type: 'switch', prefix }
  }
  return { type: 'msg', text: s }
}

// ---------- 主流程(仅直跑执行;被 import 时不跑)----------

const log = (...a) => process.stderr.write(`[crew-chat] ${a.join(' ')}\n`)
const sleep = ms => new Promise(r => setTimeout(r, ms))

export async function main() {
  const argv = process.argv.slice(2)
  const listOnly = argv.includes('--list')
  const prefixArg = argv.find(a => !a.startsWith('--'))

  // 拉 acpd 子进程(stdio)
  const acpd = spawn('node', [ACPD], {
    env: process.env,
    stdio: ['pipe', 'pipe', 'inherit'],
  })
  const cleanup = () => { try { acpd.kill() } catch {} }
  process.on('exit', cleanup)
  process.on('SIGINT', () => { cleanup(); process.exit(130) })
  process.on('SIGTERM', () => { cleanup(); process.exit(143) })

  const stream = ndJsonStream(Writable.toWeb(acpd.stdin), Readable.toWeb(acpd.stdout))

  await client({ name: 'crew-chat', version: '0.1.0' })
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
      if (!init.agentCapabilities?.listSessions) {
        throw new Error('acpd 未声明 listSessions 能力')
      }

      const fetchMembers = async () => {
        const list = await cx.request(methods.agent.session.list, {})
        return (list.sessions ?? []).map(s => ({
          member: s.sessionId,
          pid: (s.cwd?.match(/^pipe:\/\/(.+)\/[^/]+$/)?.[1] ?? '').replace(/^PIPE-/i, '').toLowerCase(),
          role: s.title?.split(' · ')[0] ?? s.sessionId.split('-pipe-')[0],
        }))
      }

      let members = await fetchMembers()
      if (listOnly) {
        for (const m of members) console.log(`  ${m.member}  (pipe://PIPE-${m.pid?.toUpperCase()}/${m.role})`)
        console.log(`(${members.length} 个角色会话)`)
        // 显式收尾:acpd 子进程 stdio 若不关闭,node 不退出(实测 --list 打完挂死)
        acpd.kill()
        process.exit(0)
      }

      let target
      if (prefixArg) {
        const r = pickMember(members, prefixArg)
        if (r === null) { console.error(`✗ 无此角色会话:${prefixArg}(--list 查看)`); acpd.kill(); process.exit(1) }
        if (r.kind === 'ambiguous') {
          console.error('✗ 前缀多命中,请更精确:')
          for (const c of r.candidates) console.error(`    ${c.member}`)
          acpd.kill(); process.exit(1)
        }
        target = r.hit
      } else if (!process.stdin.isTTY) {
        console.error('用法: crew chat [角色前缀](如 designer-)| --list 列角色')
        console.error('可用角色:')
        for (const m of members) console.error(`  ${m.member}`)
        acpd.kill(); process.exit(1)
      } else {
        console.log('可用角色:')
        members.forEach((m, i) => console.log(`  ${i + 1}. ${m.member}`))
        const rl0 = readline.createInterface({ input: process.stdin, output: process.stdout })
        const answer = (await rl0.question('选序号或前缀: ')).trim()
        rl0.close()
        if (!answer) { console.error('未选,退出'); acpd.kill(); process.exit(1) }
        const r = /^\d+$/.test(answer)
          ? (members[+answer - 1] ? { kind: 'ok', hit: members[+answer - 1] } : null)
          : pickMember(members, answer)
        if (!r || r.kind !== 'ok') { console.error('✗ 无效选择,退出'); acpd.kill(); process.exit(1) }
        target = r.hit
      }

      // 会话构建:cwd = pipe://PIPE-<pid大写>/<role>
      const cwdOf = (m) => `pipe://PIPE-${(m.pid || m.member.split('-pipe-')[1]).toUpperCase()}/${m.role}`
      console.log(`\n🏛 连上 ${target.member} —— 直接输入消息;/list 列角色;/switch <前缀> 切换;/quit 退出\n`)

      let session = await cx.buildSession(cwdOf(target)).start()

      const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
      rl.on('line', (line) => { handleLine(line).catch(e => console.log(`✗ ${e.message ?? e}`)) })
      rl.on('close', () => { cleanup(); process.exit(0) })

      async function handleLine(line) {
        const p = parseLine(line)
        if (!p) return
        if (p.type === 'quit') { rl.close(); return }
        if (p.type === 'cmd' && p.name === 'list') {
          const l2 = await cx.request(methods.agent.session.list, {})
          for (const s of l2.sessions ?? []) console.log(`  ${s.sessionId}  (${s.title ?? ''})`)
          return
        }
        if (p.type === 'cmd' && p.name === 'switch-noarg') { console.log('用法: /switch <前缀>'); return }
        if (p.type === 'switch') {
          const members2 = await fetchMembers()
          const r = pickMember(members2, p.prefix)
          if (!r || r.kind !== 'ok') {
            console.log(r?.kind === 'ambiguous' ? `✗ 多命中:${r.candidates.map(c => c.member).join(', ')}` : `✗ 无此角色:${p.prefix}`)
            return
          }
          try { session.dispose?.() } catch {}
          session = await cx.buildSession(cwdOf(r.hit)).start()
          console.log(`→ 已切换到 ${r.hit.member}`)
          return
        }
        // msg:prompt + 消费 update 流
        const pending = session.prompt(p.text)
        for (;;) {
          const msg = await session.nextUpdate()
          if (msg.kind === 'stop') break
          const line = renderUpdate(msg.update)
          if (line !== null) process.stdout.write(line)
        }
        await pending
      }

      // 常驻直到 rl close
      await new Promise(() => {})
    })
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch(e => { log('fatal:', e?.stack ?? e); process.exit(1) })
}
