#!/usr/bin/env node
'use strict';
// crew-wake.js — crew wake 的核心:把一句已知 nudge 注入目标会话 tmux,触发它消费 inbox。
//
// 迁移自 agent-bridge/wake.js(阶段 1,crew v2 §A/E)。原 wake.js 是 agent-bridge 内进程
// require + CLI 双用;这里收进 crew 本体,drainNudge 改指向 crew inbox(数据面留 agent-bridge,
// 运行时/触达归 crew)。整套 tmux 逻辑(精确名/paneIdle/双 Enter/pending 队列)原样搬来,
// 这些判据都是过去踩坑固化的(见各函数注释),不动语义。
//
// exit(CLI):0=已唤醒  1=会话不存在(tmux 无此名,消息留 inbox 等下次)  2=非 idle 已入 pending
//            3=tmux 不可用(list-sessions 失败/tmux 未装)
//
// 用法(进程内): const { wake } = require('./crew-wake.js'); wake(session, note)
// 用法(命令行): node crew-wake.js <session> [--note <text>] [--no-queue]
const { spawnSync } = require('child_process');
const path = require('path');

// nudge 落 pending 的队列文件。CREW_STATE 优先(与 crew 其他状态同目录),
// WAKE_PENDING_FILE env 可覆写(测试指向临时路径,不碰生产队列)。
const PENDING_FILE = process.env.WAKE_PENDING_FILE ||
  path.join(process.env.CREW_STATE || path.join(process.env.HOME || '/tmp', '.crew'), 'pending-nudges.jsonl');

function sleepSync(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

// 唤醒提示:幂等(粘连/重复/会话正忙都无所谓),指向 crew inbox 消费本会话全部未处理消息。
// 别改成"把消息内容塞进提示"——无游标时代丢早到消息的老坑(wake.js 文件头有记)。
// 首行嵌动作纪律(2026-08-29 用户拍板:快答不靠记忆靠机制)。
function drainNudge(session) {
  const s = session;
  return '收到新的 @' + s + ' 反馈【第一动作:先秒回触发者一句执行回执(收到+怎么干+预计),再动手处理】' +
    '→ 请运行:crew inbox ' + s + '  (拿到本会话全部未处理消息,逐条处理完再停;别只处理最新一条)';
}

// tmux 精确名解析。2026-08-29 用户实测踩:has-session -t 是【前缀匹配】——查 crew-work 会误命中
// crew-workflow-code。改用 list-sessions 全量拉回后精确名比对,彻底杜绝前缀劫持。
// 解析顺序:原名 → crew-<原名> → 都不在返回 {name:null}。
// tmux 本身不可用(未装/list-sessions 失败)返回 {tmuxDead:true},CLI 据此 exit 3。
function tmuxExactName(target) {
  const out = spawnSync('tmux', ['list-sessions', '-F', '#{session_name}'], { timeout: 3000, encoding: 'utf8' });
  if (out.error || out.status === null) return { tmuxDead: true, name: null };
  if (out.status !== 0) {
    // "no server running" = tmux 没起,视为无此会话(非 tmux 二进制缺失);其余非 0 也当无会话
    return { tmuxDead: false, name: null };
  }
  const names = String(out.stdout || '').split('\n').map((s) => s.trim()).filter(Boolean);
  // 2026-09-01 修:crew-<target> 优先于裸名 target。之前反着来,work + crew-work 双胞胎时
  // 裸名劫持真会话的 crew- pane,nudge 全打到空壳,真 work 从没被唤醒。crew 主流程都用
  // crew-<name> 命名(见 crew-launcher 的 new-session),裸名多来自 adopt 外部工具建的
  // 老 tmux —— 前者优先,后者兜底,不会误伤 adopt 场景。
  const prefixed = 'crew-' + target;
  if (names.indexOf(prefixed) >= 0) return { tmuxDead: false, name: prefixed };
  if (names.indexOf(target) >= 0) return { tmuxDead: false, name: target };
  return { tmuxDead: false, name: null };
}

// pane idle 判据。非 idle 硬 nudge 会进 tmux 输入缓冲后被 REPL 当前 turn 吞掉。
// 判据(AND 4 条):
//   ① 全 pane 有空 ❯ 输入框(Claude Code REPL 空闲特征;编辑中/忙态无此空框)
//      底部提示行空格是 U+00A0 NBSP,必须 hex 字符类 [\x20\xa0] 才匹配
//   ② 全 pane 不含 spinner 字符(✻/✽/⠴/⠦/⠋/⠙/⠹/⠸/⠼/⠶/⠧/⠇/⠏ 等 Braille + Ink 常用)
//      REPL turn 里持续 tool call 时 pane 里必有 spinner · 是 REPL 忙态最强信号
//   ③ 全 pane 不含 "queued messages" / "Press up to edit"(REPL turn 里 send-keys 送入
//      被 TUI 排队等消费的确凿信号,此时 nudge 就算送进也会卡)
//   ④ 700ms 间隔两次全 pane 快照一致(spinner 毫秒级重绘,静态摘要不动)
function paneIdle(paneName) {
  try {
    const cap = () => {
      const r = spawnSync('tmux', ['capture-pane', '-t', paneName, '-p'], { timeout: 2000, encoding: 'utf8' });
      if (r.status !== 0) return null;
      return String(r.stdout || '');
    };
    const s1 = cap();
    if (s1 === null) return true;
    if (!/❯[\x20\xa0]*(\n|$)/.test(s1)) return false;
    // spinner 检测:Ink 常用 Braille + ✻/✽ 星号
    if (/[✻✽⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠶]/.test(s1)) return false;
    // TUI 排队消息标记
    if (/queued messages|Press up to edit/.test(s1)) return false;
    sleepSync(700);
    const s2 = cap();
    if (s2 === null) return true;
    if (/[✻✽⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠶]/.test(s2)) return false;
    if (/queued messages|Press up to edit/.test(s2)) return false;
    return s1 === s2;
  } catch (_) { return true; }
}

// 双 Enter 注入(2026-08-21 修):文本(-l)与 Enter 分两步发间隔微秒级——Claude REPL 重绘/忙时
// Enter 被吃、文本滞留输入框。修法:①文本与 Enter 间隔 150ms;②400ms 后补一次 Enter(幂等)。
function sendKeysDouble(paneName, text) {
  spawnSync('tmux', ['send-keys', '-t', paneName, '-l', text], { timeout: 3000 });
  sleepSync(150);
  spawnSync('tmux', ['send-keys', '-t', paneName, 'Enter'], { timeout: 3000 });
  sleepSync(400);
  spawnSync('tmux', ['send-keys', '-t', paneName, 'Enter'], { timeout: 3000 });
}

// ---- pending nudge 队列(nudge 串台根治:非 idle 落队列,绝不找下家 pane) ----
// 文件格式:整个数组一次 JSON.stringify(读也整体 parse)。曾错写成逐行 JSON.parse 导致嵌套膨胀。
// 去重:同 session+note 排队中只留一条(防连环 nudge 挤爆)。上限 100。
function readPending() {
  try {
    const fs = require('fs');
    const raw = fs.readFileSync(PENDING_FILE, 'utf8').trim();
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_) { return []; }
}

function writePending(items) {
  const fs = require('fs');
  fs.mkdirSync(path.dirname(PENDING_FILE), { recursive: true });
  const tmp = PENDING_FILE + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(items) + '\n');
  fs.renameSync(tmp, PENDING_FILE);
}

function queuePendingNudge(session, note, ts) {
  try {
    const existing = readPending();
    if (existing.some((x) => x.session === session && x.note === note)) return;
    existing.push({ ts: ts || null, session, note });
    writePending(existing.length > 100 ? existing.slice(-100) : existing);
  } catch (_) {}
}

function takePendingNudges(limit) {
  const items = readPending();
  return items.slice(0, limit || 100);
}

function savePendingNudges(items) {
  try { writePending(Array.isArray(items) ? items : []); } catch (_) {}
}

// 补发一条:目标 idle 才发。返回 'dead'(会话没了,条目作废) / true(发了) / false(还忙,留下轮)
function flushOne(item) {
  const r = tmuxExactName(item.session);
  if (r.tmuxDead) return false;      // tmux 挂了,下轮再试
  if (!r.name) return 'dead';         // 会话没了,条目作废
  if (!paneIdle(r.name)) return false;
  try { sendKeysDouble(r.name, item.note); return true; } catch (_) { return false; }
}

// 核心 wake:返回 {code, real} —— code 见 CLI exit 契约(0/1/2/3)。
// opts.note 覆写默认 drainNudge;opts.noQueue=true 时非 idle 不入 pending(纯探测)。
function wake(session, opts) {
  opts = opts || {};
  const target = session;
  const r = tmuxExactName(target);
  if (r.tmuxDead) return { code: 3, real: null };
  if (!r.name) return { code: 1, real: null };
  const note = opts.note || drainNudge(target);
  // 非 idle 不硬 nudge(拼进输入框/被吞,串台根因),落 pending 队列;绝不找下家 pane。
  if (!paneIdle(r.name)) {
    if (!opts.noQueue) queuePendingNudge(target, note, opts.ts);
    return { code: 2, real: r.name };
  }
  try {
    sendKeysDouble(r.name, note);
    return { code: 0, real: r.name };
  } catch (_) {
    return { code: 3, real: r.name };
  }
}

module.exports = {
  wake, drainNudge, tmuxExactName, paneIdle, sendKeysDouble,
  queuePendingNudge, takePendingNudges, savePendingNudges, flushOne,
  PENDING_FILE,
};

// ---- CLI ----
if (require.main === module) {
  const argv = process.argv.slice(2);
  let session = null, note = null, noQueue = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--note') note = argv[++i];
    else if (a === '--no-queue') noQueue = true;
    else if (!a.startsWith('-') && !session) session = a;
  }
  if (!session) {
    process.stderr.write('usage: crew-wake.js <session> [--note <text>] [--no-queue]\n');
    process.exit(1);
  }
  const { code, real } = wake(session, { note, noQueue });
  if (code === 0) { process.stdout.write('woke ' + real + '\n'); process.exit(0); }
  if (code === 1) { process.stdout.write('NOT-woke: 会话 ' + session + ' 不存在(crew-' + session + ' 也不在),消息留 inbox 等下次触发\n'); process.exit(1); }
  if (code === 2) { process.stdout.write('NOT-woke: ' + real + ' 存在但非 idle(编辑中/满 context),nudge 已入 pending 队列,idle 时补发\n'); process.exit(2); }
  process.stdout.write('NOT-woke: tmux 不可用(未装或 server 未起)\n'); process.exit(3);
}
