#!/usr/bin/env node
// crew-v2-migration-audit.js — v1.2 §9.1 · Day 14 sunset audit
// 遍历所有 project.json sessions[],检测每个 session 是否已挂载 crew v2(心跳存在 + tmux 会话存在)。
// 输出未挂载列表 + 最近活跃时间(feedback.jsonl 最后出现)· exit 0 全挂 / exit 1 有未挂
//
// 用途:
//   - Day 4-13 每日 cron 跑,输出报告到 work
//   - Day 14 sunset 前必须 exit 0 才能进 Phase 4(老通道下线)
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const CREW_STATE = process.env.CREW_STATE ||
  path.join(process.env.HOME || '/tmp', '.local', 'share', 'claude-crew');
const FEEDBACK_JSONL = process.env.FEEDBACK_JSONL ||
  '/work/agent-bridge/logs/feedback.jsonl';
const SCAN_ROOTS = (process.env.CREW_SCAN_ROOTS || '/work').split(',').filter(Boolean);

function readJSON(f) {
  try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { return null; }
}

// 遍历 registry:所有 project.json sessions[] · 返 [{name, project, cfgPath}]
function listAllSessions() {
  const out = [];
  for (const root of SCAN_ROOTS) {
    let entries;
    try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (_) { continue; }
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      const cfgPath = path.join(root, e.name, '.chaos-bridge', 'project.json');
      const cfg = readJSON(cfgPath);
      if (!cfg || !Array.isArray(cfg.sessions)) continue;
      for (const s of cfg.sessions) {
        const name = typeof s === 'string' ? s : (s && s.name);
        if (name) out.push({ name, project: cfg.name || e.name, cfgPath });
      }
    }
  }
  return out;
}

// 会话挂载判据:
//   1) $CREW_STATE/heartbeat/<name>.json 存在(说明 crew heartbeat 采过样)
//   2) 心跳文件 mtime < 24h(近期活跃,非陈旧)
// 二者同时满足才算挂载。
function isMounted(name) {
  const hbFile = path.join(CREW_STATE, 'heartbeat', name + '.json');
  try {
    const st = fs.statSync(hbFile);
    const ageHours = (Date.now() - st.mtimeMs) / 3600000;
    return ageHours < 24;
  } catch (_) { return false; }
}

// 从 feedback.jsonl 尾部找该会话最近出现的 ts(粗略活跃度)· 只扫最后 5000 行避免全文件加载
function lastFeedbackTs(name) {
  try {
    // 简单 tail 5000 行(大文件时用 readTail 更佳,先粗)
    const raw = fs.readFileSync(FEEDBACK_JSONL, 'utf8');
    const lines = raw.split('\n');
    const start = Math.max(0, lines.length - 5000);
    for (let i = lines.length - 1; i >= start; i--) {
      const line = lines[i];
      if (!line) continue;
      // 关键字段:session=<name> 或 pin=<name> 或 sender=<name> 都算活跃
      if (line.indexOf('"session":"' + name + '"') !== -1 ||
          line.indexOf('"sender":"' + name + '"') !== -1) {
        try {
          const j = JSON.parse(line);
          if (j.ts) return j.ts;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return null;
}

function fmtAge(iso) {
  if (!iso) return '(无活动)';
  const ms = Date.now() - new Date(iso).getTime();
  if (isNaN(ms) || ms < 0) return '(无活动)';
  const h = ms / 3600000;
  if (h < 24) return Math.floor(h) + 'h 前';
  return Math.floor(h / 24) + 'd 前';
}

function runAudit() {
  const all = listAllSessions();
  const mounted = [];
  const unmounted = [];
  for (const s of all) {
    if (isMounted(s.name)) {
      mounted.push(s);
    } else {
      s.lastActive = lastFeedbackTs(s.name);
      unmounted.push(s);
    }
  }
  const now = new Date().toISOString();
  return { now, total: all.length, mounted, unmounted };
}

function printReport(r) {
  console.log('=== crew v2 migration audit @ ' + r.now + ' ===');
  console.log('✓ 已挂载 crew v2: ' + r.mounted.length + ' 会话');
  if (r.unmounted.length === 0) {
    console.log('✓ 所有会话都已挂载 · Phase 4 sunset 可放行');
    return;
  }
  console.log('✗ 未挂载: ' + r.unmounted.length + ' 会话');
  // 按最近活跃时间倒序(最近活跃的排前 · 最需要紧急挂)
  const sorted = r.unmounted.slice().sort((a, b) => {
    const ta = a.lastActive ? new Date(a.lastActive).getTime() : 0;
    const tb = b.lastActive ? new Date(b.lastActive).getTime() : 0;
    return tb - ta;
  });
  for (const s of sorted) {
    const age = fmtAge(s.lastActive);
    const activeHint = s.lastActive && (Date.now() - new Date(s.lastActive).getTime()) < 24 * 3600000
      ? '  · ★活跃 · 必须挂' : '';
    console.log('  - ' + s.name.padEnd(18) + ' · ' + s.project.padEnd(15) + ' · 最后活跃 ' + age + activeHint);
  }
  console.log();
  console.log('Phase 4 sunset ❌ blocked · 请对活跃未挂会话执行 `crew register <name>` 或 launcher 重启带 crew v2');
}

if (require.main === module) {
  const r = runAudit();
  printReport(r);
  process.exit(r.unmounted.length === 0 ? 0 : 1);
}

module.exports = { runAudit, listAllSessions, isMounted, lastFeedbackTs };
