#!/usr/bin/env node
'use strict';
// crew-notify.js — crew 会话间消息投递 helper。
//
// 三件事:
// ① 写 JSON 信封到 $CREW_STATE/inbox/<name>/NNNN-ts.json(权威副本)
// ② 镜像 append 到 agent-bridge/logs/feedback.jsonl(可视化;面板 + 未来 crew 前端零改动可见)
// ③ 提供子命令给 crew inbox 消费时"回写 ack + 归档到 consumed/"
//
// 信封字段:
//   { id, ts, from:{kind,id}, note, delivery:{state,wokeAt,consumedAt} }
// kind: 'session'(会话间,id=发送会话名) | 'erp'(咚咚,id=erp;暂不由本 helper 写)
// state: 'pending'(已落盘未唤醒) → 'delivered'(已 tmux 唤醒) → 'acked'(已消费)
//
// 用法:
//   crew-notify.js write --to <name> --from <session|erp:id> --note <text> [--id <id>]
//       打印新信封文件路径到 stdout。crew send/notify 调用。
//   crew-notify.js ack --to <name> [--limit N]
//       消费 <name> 全部 pending 信封:回写 acked+consumedAt,移到 consumed/,同时镜像追加
//       ack 记录到 feedback.jsonl(replyOut=false 但带 delivery.state=acked,供前端渲染绿态)。
//       返回消费的条目 JSON 数组(stdout 一行一 JSON),供 crew inbox 打印。
//   crew-notify.js mark-woke --to <name> --id <id>
//       crew wake 成功后回调,把该 id 信封的 delivery.wokeAt=now,state=delivered。
//
// exit: 0=成功  1=参数错  2=目标 inbox 目录问题  3=文件 IO 失败

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const CREW_STATE = process.env.CREW_STATE ||
  process.env.XDG_DATA_HOME && path.join(process.env.XDG_DATA_HOME, 'claude-crew') ||
  path.join(process.env.HOME || '/tmp', '.local', 'share', 'claude-crew');

// feedback.jsonl 路径:默认 agent-bridge 的 logs/;env 覆写供测试。
const FEEDBACK_JSONL = process.env.FEEDBACK_JSONL ||
  '/work/agent-bridge/logs/feedback.jsonl';

function parseArgs(argv) {
  const o = { _sub: argv[0] };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--to') o.to = argv[++i];
    else if (a === '--from') o.from = argv[++i];        // "session:work" 或 "erp:wangqiwang1"
    else if (a === '--note') o.note = argv[++i];
    else if (a === '--id') o.id = argv[++i];
    else if (a === '--limit') o.limit = parseInt(argv[++i], 10);
    else if (a === '--project') o.project = argv[++i];
    // 2026-09-03 stage2 · v3.1 升级 2:允许指定 channel/kind,支持 crew-auto-done(Stop hook 回执)
    else if (a === '--channel') o.channel = argv[++i];  // 默认 'crew-native'
    else if (a === '--kind') o.kind = argv[++i];        // 默认无(write 时可选写入 envelope.kind)
  }
  return o;
}

function newId() { return crypto.randomBytes(6).toString('hex'); }
function nowISO() { return new Date().toISOString(); }
function pad4(n) { return String(n).padStart(4, '0'); }

function inboxDir(to) { return path.join(CREW_STATE, 'inbox', to); }
function consumedDir(to) { return path.join(inboxDir(to), 'consumed'); }

// 原子写:tmp+rename 同目录 rename 原子(与 crew-register 同套路)。
function writeJSON(file, obj) {
  const tmp = file + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

function readEnvelope(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

// 解析 --from "kind:id" → {kind, id}
function parseFrom(spec) {
  if (!spec) return { kind: 'unknown', id: '' };
  const i = spec.indexOf(':');
  if (i < 0) return { kind: 'session', id: spec };
  const kind = spec.slice(0, i);
  const id = spec.slice(i + 1);
  return { kind, id };
}

// 镜像到 feedback.jsonl(agent-bridge 面板可见)。字段对齐 send.js:
//   ts / project / pin=from.id / sender=from.id / note / session=to / source='session' / replyOut=false
// 追加 delivery 对象让新前端能读黄绿状态(老面板不认这字段,自动忽略,无副作用)。
function mirrorToFeedback(envelope, to, project) {
  try {
    fs.mkdirSync(path.dirname(FEEDBACK_JSONL), { recursive: true });
    const rec = {
      ts: envelope.ts,
      project: project || 'claude-crew',
      pin: envelope.from.id,
      sender: envelope.from.id,
      note: envelope.note,
      session: to,
      source: envelope.from.kind === 'session' ? 'session' : 'private',
      replyOut: false,
      // 扩展字段:面板老版忽略,新前端读它渲染黄绿。
      delivery: envelope.delivery,
      envelopeId: envelope.id,
      // 2026-09-02 [coding PR 建议 · comm-redesign spec]:channel 标签,agent-bridge/feedback-drain.js
      // 据此过滤重复消费。默认 'crew-native'(SendMessage 镜像及一般 crew 会话间信封)。
      // 2026-09-03 stage2 扩展:envelope.channel 覆盖(如 'crew-auto-done' 用于 Stop hook 自动回执)。
      // 老 drain/前端不认此字段,当无标签处理,零破坏。
      channel: envelope.channel || 'crew-native',
    };
    fs.appendFileSync(FEEDBACK_JSONL, JSON.stringify(rec) + '\n');
    return true;
  } catch (e) {
    // 镜像失败不阻断主流程(inbox 仍是权威),仅 stderr 记
    process.stderr.write('crew-notify: mirror-to-feedback failed: ' + e.message + '\n');
    return false;
  }
}

// ---- 子命令:write ----
// 落权威副本 + 镜像 feedback.jsonl。stdout 打印信封文件路径。
function cmdWrite(o) {
  if (!o.to || !o.note) return 1;
  const from = parseFrom(o.from);
  fs.mkdirSync(inboxDir(o.to), { recursive: true });
  // 序号 = 现有 .json/.msg 文件数 + 1(与老 cmd_send 同风格)
  let entries = [];
  try { entries = fs.readdirSync(inboxDir(o.to)).filter((f) => f.endsWith('.json') || f.endsWith('.msg')); } catch (_) {}
  const idx = entries.length + 1;
  const ts = nowISO();
  const id = o.id || newId();
  const envelope = {
    id, ts, from, note: o.note,
    delivery: { state: 'pending', wokeAt: null, consumedAt: null },
  };
  // 2026-09-03 stage2:允许写入 channel/kind,支持 crew-auto-done(Stop hook 回执)。
  // 未指定则 mirrorToFeedback fallback 到 'crew-native'。kind 常见值:'turn-done'。
  if (o.channel) envelope.channel = o.channel;
  if (o.kind) envelope.kind = o.kind;
  const fname = pad4(idx) + '-' + ts.replace(/[:.]/g, '-') + '.json';
  const fpath = path.join(inboxDir(o.to), fname);
  try { writeJSON(fpath, envelope); } catch (e) {
    process.stderr.write('crew-notify: write envelope failed: ' + e.message + '\n');
    return 3;
  }
  mirrorToFeedback(envelope, o.to, o.project);
  process.stdout.write(fpath + '\n');
  return 0;
}

// ---- 子命令:mark-woke ----
// wake 成功后调,把该 id 信封 delivery.wokeAt=now, state=delivered。
// 找不到 id 的信封 → 静默 0(可能已被消费/清理)。
function cmdMarkWoke(o) {
  if (!o.to || !o.id) return 1;
  const dir = inboxDir(o.to);
  let entries = [];
  try { entries = fs.readdirSync(dir).filter((f) => f.endsWith('.json')); } catch (_) { return 0; }
  for (const f of entries) {
    const fpath = path.join(dir, f);
    const env = readEnvelope(fpath);
    if (env && env.id === o.id) {
      env.delivery.state = 'delivered';
      env.delivery.wokeAt = nowISO();
      try { writeJSON(fpath, env); } catch (_) { return 3; }
      return 0;
    }
  }
  return 0;
}

// ---- 子命令:ack ----
// 消费全部 pending/delivered 信封:回写 acked+consumedAt,移到 consumed/,
// stdout 一行一 JSON 打印被消费的信封(供 crew inbox 拼接展示)。
// 老 .msg 纯文本兼容:也读也删(但不生成 ack,老通道无 delivery 概念)。
function cmdAck(o) {
  if (!o.to) return 1;
  const dir = inboxDir(o.to);
  if (!fs.existsSync(dir)) { return 0; }
  const con = consumedDir(o.to);
  fs.mkdirSync(con, { recursive: true });
  let entries = [];
  try { entries = fs.readdirSync(dir).filter((f) => f.endsWith('.json') || f.endsWith('.msg')); } catch (_) { return 0; }
  entries.sort();
  const limit = o.limit || 1000;
  let n = 0;
  for (const f of entries) {
    if (n >= limit) break;
    const fpath = path.join(dir, f);
    if (f.endsWith('.json')) {
      const env = readEnvelope(fpath);
      if (!env) continue;
      env.delivery.state = 'acked';
      env.delivery.consumedAt = nowISO();
      // 归档:先写 consumed/ 再删原(避免中间态丢失)
      const target = path.join(con, f);
      try {
        writeJSON(target, env);
        fs.unlinkSync(fpath);
      } catch (e) {
        process.stderr.write('crew-notify: archive failed for ' + f + ': ' + e.message + '\n');
        continue;
      }
      // 镜像追加一条 ack 记录到 feedback.jsonl,供前端渲染绿态(旧记录 delivery=pending 保持不变;
      // 新增记录 replyOut=false + delivery.state=acked 表示"这条被消费了")。
      try {
        fs.appendFileSync(FEEDBACK_JSONL, JSON.stringify({
          ts: env.delivery.consumedAt,
          project: o.project || 'claude-crew',
          pin: env.from.id, sender: env.from.id, note: '',
          session: o.to,
          source: env.from.kind === 'session' ? 'session' : 'private',
          replyOut: false,
          delivery: env.delivery,
          envelopeId: env.id,
          ackOf: env.id,
        }) + '\n');
      } catch (_) {}
      process.stdout.write(JSON.stringify(env) + '\n');
      n++;
    } else if (f.endsWith('.msg')) {
      // 老纯文本:读 + 删(无 ack)
      let note = '';
      try { note = fs.readFileSync(fpath, 'utf8'); } catch (_) {}
      try { fs.unlinkSync(fpath); } catch (_) {}
      process.stdout.write(JSON.stringify({
        id: null, ts: null, from: { kind: 'legacy', id: '' }, note,
        delivery: { state: 'acked', wokeAt: null, consumedAt: nowISO() },
      }) + '\n');
      n++;
    }
  }
  return 0;
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o._sub === 'write') return cmdWrite(o);
  if (o._sub === 'ack') return cmdAck(o);
  if (o._sub === 'mark-woke') return cmdMarkWoke(o);
  process.stderr.write('usage: crew-notify.js {write|ack|mark-woke} --to <name> [--from k:i] [--note t] [--id x] [--limit N] [--project P]\n');
  return 1;
}

module.exports = {
  parseArgs, parseFrom, cmdWrite, cmdAck, cmdMarkWoke,
  inboxDir, consumedDir, mirrorToFeedback,
};

if (require.main === module) process.exit(main());
