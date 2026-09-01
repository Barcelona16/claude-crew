#!/usr/bin/env node
'use strict';
// crew-status.js — 单会话健康摘要。
//
// 汇总:
// ① 心跳($CREW_STATE/heartbeat/<name>.json):lastHeartbeat / tmuxStatus / paneIdle / ctxPct
// ② inbox($CREW_STATE/inbox/<name>/*.json):未消费信封数 + delivery.state 分布
// ③ pending nudge($CREW_STATE/pending-nudges.jsonl):该会话待补发 nudge 数
// ④ 注册($CREW_STATE/registry 或 project.json.sessions[]):是否注册
//
// exit 契约(CLAUDE.md §5):
//   0=正常返 健康态 JSON / 人类可读
//   4=会话未注册(既没心跳文件也不在 project.json.sessions[])
//
// 用法:
//   crew-status.js <name> [--json]
//   --json 结构化输出;默认人类可读

const fs = require('fs');
const path = require('path');

const CREW_STATE = process.env.CREW_STATE ||
  path.join(process.env.HOME || '/tmp', '.local', 'share', 'claude-crew');

function nowISO() { return new Date().toISOString(); }

function readJSON(f) {
  try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { return null; }
}

function readHeartbeat(name) {
  return readJSON(path.join(CREW_STATE, 'heartbeat', name + '.json'));
}

function readInboxCounts(name) {
  const dir = path.join(CREW_STATE, 'inbox', name);
  let entries = [];
  try { entries = fs.readdirSync(dir); } catch (_) { return { total: 0, pending: 0, delivered: 0, legacy: 0 }; }
  let pending = 0, delivered = 0, legacy = 0;
  for (const f of entries) {
    if (f === 'consumed') continue;
    const fpath = path.join(dir, f);
    if (f.endsWith('.json')) {
      const env = readJSON(fpath);
      if (env && env.delivery) {
        if (env.delivery.state === 'pending') pending++;
        else if (env.delivery.state === 'delivered') delivered++;
      }
    } else if (f.endsWith('.msg')) {
      legacy++;
    }
  }
  return { total: pending + delivered + legacy, pending, delivered, legacy };
}

function readPendingNudges(name) {
  const f = path.join(CREW_STATE, 'pending-nudges.jsonl');
  try {
    const raw = fs.readFileSync(f, 'utf8').trim();
    if (!raw) return 0;
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return 0;
    return parsed.filter((x) => x && x.session === name).length;
  } catch (_) { return 0; }
}

// 是否被 crew 注册过:CREW_STATE 里存在任一 <name>.<key> state 文件 或 心跳文件在。
function isRegistered(name) {
  if (readHeartbeat(name)) return true;
  try {
    const files = fs.readdirSync(CREW_STATE);
    for (const f of files) {
      if (f.startsWith(name + '.')) return true;
    }
  } catch (_) {}
  return false;
}

// 心跳新鲜度:>180s 视为 stale(方案 §8.1)
function heartbeatFreshness(hb) {
  if (!hb || !hb.ts) return 'unknown';
  const ageMs = Date.now() - new Date(hb.ts).getTime();
  if (isNaN(ageMs)) return 'unknown';
  if (ageMs > 180 * 1000) return 'stale';
  return 'fresh';
}

function summarize(name) {
  const hb = readHeartbeat(name);
  const inbox = readInboxCounts(name);
  const pending = readPendingNudges(name);
  const registered = isRegistered(name);
  return {
    name,
    ts: nowISO(),
    registered,
    heartbeat: {
      last: hb ? hb.ts : null,
      freshness: heartbeatFreshness(hb),
      tmuxStatus: hb ? hb.tmuxStatus : null,     // live / dead / unknown
      paneIdle: hb ? hb.paneIdle : null,
      ctxPct: hb ? hb.ctxPct : null,
    },
    inbox,
    pendingNudges: pending,
  };
}

function humanize(s) {
  const lines = [];
  lines.push(`会话: ${s.name}`);
  lines.push(`  注册: ${s.registered ? '✓' : '✗ 未注册'}`);
  const hb = s.heartbeat;
  if (hb.last) {
    lines.push(`  心跳: ${hb.last} (${hb.freshness})`);
    lines.push(`  tmux: ${hb.tmuxStatus || '?'} · pane: ${hb.paneIdle === null ? '?' : (hb.paneIdle ? 'idle' : 'busy')} · ctx: ${hb.ctxPct === null ? '?' : hb.ctxPct + '%'}`);
  } else {
    lines.push(`  心跳: 无(crew-heartbeat 未启或未采样过)`);
  }
  lines.push(`  inbox: 未消费 ${s.inbox.total} 条 (pending ${s.inbox.pending} / delivered ${s.inbox.delivered} / legacy .msg ${s.inbox.legacy})`);
  lines.push(`  待补发 nudge: ${s.pendingNudges} 条`);
  return lines.join('\n');
}

function main() {
  const argv = process.argv.slice(2);
  let name = null, jsonOut = false;
  for (const a of argv) {
    if (a === '--json') jsonOut = true;
    else if (!a.startsWith('-') && !name) name = a;
  }
  if (!name) {
    process.stderr.write('usage: crew-status.js <name> [--json]\n');
    return 1;
  }
  const s = summarize(name);
  if (!s.registered) {
    if (jsonOut) process.stdout.write(JSON.stringify(s, null, 2) + '\n');
    else process.stderr.write(`crew status: '${name}' 未注册(无 state 也无心跳)\n`);
    return 4;
  }
  if (jsonOut) process.stdout.write(JSON.stringify(s, null, 2) + '\n');
  else process.stdout.write(humanize(s) + '\n');
  return 0;
}

module.exports = { summarize, readHeartbeat, readInboxCounts, readPendingNudges, isRegistered };

if (require.main === module) process.exit(main());
