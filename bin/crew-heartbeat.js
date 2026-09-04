#!/usr/bin/env node
'use strict';
// crew-heartbeat.js — crew 会话心跳采样守护进程。
//
// 职责:每 HEARTBEAT_INTERVAL 秒(默认 60)扫一遍所有 tmux 会话,
// 采样 { tmux 存在, paneIdle, ctxPct, ts } → 写 $CREW_STATE/heartbeat/<name>.json。
// crew status 读这些文件展示会话健康。
//
// 单例:$CREW_STATE/heartbeat/heartbeat.pid 反查存活 PID —— 撞见活的就 exit 0(不重复起)。
//
// 采样源:
// - tmux list-sessions:得到全部 tmux name(带 crew- 前缀的和不带的),再和 $CREW_STATE/*.tmux
//   / registry 里的 crew 会话名做映射(name → tmuxname);找不到 tmux 的 crew 会话记 tmux=dead。
// - tmux capture-pane -p:抓底部内容
//   ① paneIdle:复用 crew-wake.js 的判据(空 ❯ 框 + 700ms 快照稳定)
//   ② ctxPct:正则 /(\d+)% context used/ —— Claude Code REPL 底部固定文案
//
// 用法:
//   crew-heartbeat.js [--interval 60] [--once]
//     --once   只采样一次就退,cron / 测试用
//   crew-heartbeat.js --status  打印当前守护进程 PID / 上次采样时间(不采样)
//
// exit: 0=正常退 / 6=已有单例在跑(单例保护)

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const CREW_STATE = process.env.CREW_STATE ||
  path.join(process.env.HOME || '/tmp', '.local', 'share', 'claude-crew');
const HB_DIR = path.join(CREW_STATE, 'heartbeat');
const PID_FILE = path.join(HB_DIR, 'heartbeat.pid');
const INTERVAL = parseInt(process.env.HEARTBEAT_INTERVAL || '60', 10) * 1000;

function nowISO() { return new Date().toISOString(); }
function sleepSync(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function ensureDir() { fs.mkdirSync(HB_DIR, { recursive: true }); }

// 原子写(和 crew-notify 一致的套路)
function writeJSON(file, obj) {
  const tmp = file + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

// 拿全部 tmux 会话名(list-sessions 精确名列表)
function listTmux() {
  const r = spawnSync('tmux', ['list-sessions', '-F', '#{session_name}'], { timeout: 3000, encoding: 'utf8' });
  if (r.status !== 0) return { dead: r.error || r.status === null, names: [] };
  return { dead: false, names: String(r.stdout || '').split('\n').map((s) => s.trim()).filter(Boolean) };
}

// 拿全部 crew 会话名:CREW_STATE 里 *.tmux / *.sid / registry 覆盖到的名字集合。
// 不用 crew ls(那是 shell 输出解析,脆弱)。心跳只关心"我们记过的会话",tmux 里冒出来的
// 陌生 name 由 crew adopt 走另一条路,不归心跳采样。
function listCrewSessions() {
  const names = new Set();
  try {
    for (const f of fs.readdirSync(CREW_STATE)) {
      // 排除 heartbeat/inbox/consumed/pending-nudges.jsonl 等目录/杂项
      if (f === 'inbox' || f === 'heartbeat' || f.startsWith('.')) continue;
      const m = f.match(/^(.+)\.(tmux|sid|backend|key|dir|policy|tmuxname|notmux|fgpid|policy_body|pintmux)$/);
      if (m) names.add(m[1]);
    }
  } catch (_) {}
  return Array.from(names);
}

// tmux name 解析:同 crew-wake 的 tmuxExactName(优先原名,退 crew-<name>)
function resolveTmux(target, tmuxNames) {
  // 2026-09-01 修:crew-<target> 优先。双胞胎 tmux(裸名空壳 + crew- 真会话)时,裸名劫持
  // 真会话的坑。crew 主流程都用 crew- 前缀,前者优先后者兜底,不会误伤 adopt 场景。
  const pref = 'crew-' + target;
  if (tmuxNames.indexOf(pref) >= 0) return pref;
  if (tmuxNames.indexOf(target) >= 0) return target;
  return null;
}

// pane idle 判据(和 crew-wake.js 完全一致 —— 抄过来别 require,避免耦合)
// AND 4 条:❯ 空框 · 底部 20 行无 spinner · 底部 20 行无 queued messages 标记 · 700ms 快照一致
// (spinner + queued 只在 pane 底部状态行 · 历史滚动区里的 ✽ 是老 turn 遗留 · 不算忙)
function paneIdle(paneName) {
  try {
    const cap = () => {
      const r = spawnSync('tmux', ['capture-pane', '-t', paneName, '-p'], { timeout: 2000, encoding: 'utf8' });
      if (r.status !== 0) return null;
      return String(r.stdout || '');
    };
    const bottomOf = (s) => s.split('\n').slice(-20).join('\n');
    const s1 = cap();
    if (s1 === null) return { idle: true, snapshot: '' };
    if (!/❯[\x20\xa0]*(\n|$)/.test(s1)) return { idle: false, snapshot: s1 };
    const b1 = bottomOf(s1);
    if (/[✻✽⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠶]/.test(b1)) return { idle: false, snapshot: s1 };
    if (/queued messages|Press up to edit/.test(b1)) return { idle: false, snapshot: s1 };
    sleepSync(700);
    const s2 = cap();
    if (s2 === null) return { idle: true, snapshot: s1 };
    const b2 = bottomOf(s2);
    if (/[✻✽⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠶]/.test(b2)) return { idle: false, snapshot: s2 };
    if (/queued messages|Press up to edit/.test(b2)) return { idle: false, snapshot: s2 };
    return { idle: b1 === b2, snapshot: s2 };
  } catch (_) { return { idle: true, snapshot: '' }; }
}

// 抓 ctxPct:Claude REPL 底部 "N% context used"。抓不到返 null(可能 REPL 状态未渲染)。
function extractCtxPct(snapshot) {
  if (!snapshot) return null;
  const m = snapshot.match(/(\d+)% context used/);
  return m ? parseInt(m[1], 10) : null;
}

// pending nudge flush(阶段 2 §E:收编 agent-bridge/pending-nudge-flusher.js)。
// crew-wake.js 里非 idle 会话的 nudge 落进 $CREW_STATE/pending-nudges.jsonl,本函数每次
// 心跳采样后扫队列,给 idle 的会话补发。flushOne 返回:
//   true    → 补发成功(条目 drop)
//   false   → 目标还忙(条目留下轮)
//   'dead'  → tmux 里没这会话了(条目作废 drop,避免死信卡队列)
function flushPendingNudges() {
  let wake;
  try { wake = require('./crew-wake.js'); } catch (_) { return { flushed: 0, remain: 0 }; }
  const items = wake.takePendingNudges(100);
  if (!items.length) return { flushed: 0, remain: 0 };
  const remain = [];
  let flushed = 0;
  for (const it of items) {
    const r = wake.flushOne(it);
    if (r === true) flushed++;
    else if (r === 'dead') {/* drop */}
    else remain.push(it);
  }
  try { wake.savePendingNudges(remain); } catch (_) {}
  return { flushed, remain: remain.length };
}

// 采样一次全部已知 crew 会话,写入 heartbeat/<name>.json;顺带 flush pending nudge。
function sampleAll() {
  ensureDir();
  const crewNames = listCrewSessions();
  const { dead: tmuxDead, names: tmuxNames } = listTmux();
  const ts = nowISO();
  const results = [];
  for (const name of crewNames) {
    let record;
    if (tmuxDead) {
      record = { name, ts, tmux: null, tmuxStatus: 'unknown', paneIdle: null, ctxPct: null };
    } else {
      const real = resolveTmux(name, tmuxNames);
      if (!real) {
        record = { name, ts, tmux: null, tmuxStatus: 'dead', paneIdle: null, ctxPct: null, claudePid: null };
      } else {
        // 2026-09-02 P1 修:tmux session 活 ≠ claude REPL 活。20 会话 REPL 优雅退出
        // (pane 底部残留 "Resume this session with: claude --resume ..." 就是证据),
        // 但 tmux session/paneIdle 判据继续报 live/idle,前端/watcher 完全失灵。
        // 权威判据:pane_pid → ps --ppid 找 bin/claude 子进程。无 → tmuxStatus=dead-repl
        // (tmux 活但 REPL 死)+ paneIdle=null 不误导;ctx 也抓不到就 null。
        // env CREW_HEARTBEAT_SKIP_CLAUDE_CHECK=1 绕过(测试用,fake tmux 里没真 claude 进程)
        let claudePid = null;
        if (process.env.CREW_HEARTBEAT_SKIP_CLAUDE_CHECK === '1') {
          claudePid = -1;  // 假 pid 让下面 !claudePid 判 false 走 live 路径
        } else {
          const paneInfo = spawnSync('tmux', ['list-panes', '-t', real, '-F', '#{pane_pid}'], { timeout: 2000, encoding: 'utf8' });
          if (paneInfo.status === 0) {
            const panePid = String(paneInfo.stdout || '').trim().split('\n')[0];
            if (panePid) {
              const ps = spawnSync('ps', ['--no-headers', '-o', 'pid,cmd', '--ppid', panePid], { timeout: 2000, encoding: 'utf8' });
              if (ps.status === 0) {
                const m = String(ps.stdout || '').split('\n').find((l) => /bin\/claude/.test(l));
                if (m) claudePid = parseInt(m.trim().split(/\s+/)[0], 10);
              }
            }
          }
        }
        if (!claudePid) {
          // tmux 活但 REPL 死 —— 会话僵尸态
          record = { name, ts, tmux: real, tmuxStatus: 'dead-repl', paneIdle: null, ctxPct: null, claudePid: null };
        } else {
          const { idle, snapshot } = paneIdle(real);
          record = {
            name, ts, tmux: real, tmuxStatus: 'live',
            paneIdle: idle, ctxPct: extractCtxPct(snapshot), claudePid,
          };
        }
      }
    }
    try { writeJSON(path.join(HB_DIR, name + '.json'), record); } catch (_) {}
    results.push(record);
  }
  // 采样完顺手扫 pending 队列(合流 flusher)
  const flush = flushPendingNudges();
  // 采样完顺手 crew-watcher 巡检告警(2026-09-02 · 通用观察者)
  let watch = { staleFired: 0, staleSkipped: 0 };
  try { watch = require('./crew-watcher.js').sweepOnce(); } catch (_) {}
  return { ts, count: results.length, results,
           pendingFlushed: flush.flushed, pendingRemain: flush.remain,
           watcher: watch };
}

// 单例保护:PID 文件里的进程若还活着 → exit 6。stale 则重写(带自己 PID)。
function acquireSingleton() {
  ensureDir();
  try {
    const raw = fs.readFileSync(PID_FILE, 'utf8').trim();
    const old = parseInt(raw, 10);
    if (old && old !== process.pid) {
      try {
        process.kill(old, 0);  // signal 0 = 探活,活着抛没错
        return false;           // 老的还在,让位
      } catch (_) { /* stale,继续 */ }
    }
  } catch (_) {}
  fs.writeFileSync(PID_FILE, String(process.pid));
  return true;
}

function releaseSingleton() {
  try {
    const raw = fs.readFileSync(PID_FILE, 'utf8').trim();
    if (parseInt(raw, 10) === process.pid) fs.unlinkSync(PID_FILE);
  } catch (_) {}
}

function main() {
  const argv = process.argv.slice(2);
  let once = false, interval = INTERVAL, status = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--once') once = true;
    else if (a === '--interval') interval = parseInt(argv[++i], 10) * 1000;
    else if (a === '--status') status = true;
  }
  if (status) {
    try {
      const pid = fs.readFileSync(PID_FILE, 'utf8').trim();
      let alive = false;
      try { process.kill(parseInt(pid, 10), 0); alive = true; } catch (_) {}
      let lastSample = null;
      try {
        // 找最新一个 <name>.json 的 ts
        const files = fs.readdirSync(HB_DIR).filter((f) => f.endsWith('.json'));
        for (const f of files) {
          try {
            const j = JSON.parse(fs.readFileSync(path.join(HB_DIR, f), 'utf8'));
            if (!lastSample || j.ts > lastSample) lastSample = j.ts;
          } catch (_) {}
        }
      } catch (_) {}
      process.stdout.write(JSON.stringify({ pid, alive, lastSample }, null, 2) + '\n');
    } catch (_) {
      process.stdout.write(JSON.stringify({ pid: null, alive: false }, null, 2) + '\n');
    }
    return 0;
  }
  if (once) { sampleAll(); return 0; }
  if (!acquireSingleton()) {
    process.stderr.write('crew-heartbeat: 已有守护进程在跑(PID 见 ' + PID_FILE + ')\n');
    return 6;
  }
  process.on('SIGTERM', () => { releaseSingleton(); process.exit(0); });
  process.on('SIGINT', () => { releaseSingleton(); process.exit(0); });
  // 主循环:立即采一次,然后每 interval 采一次
  for (;;) {
    try { sampleAll(); } catch (e) { process.stderr.write('crew-heartbeat: sample err ' + e.message + '\n'); }
    sleepSync(interval);
  }
}

module.exports = {
  sampleAll, listCrewSessions, resolveTmux, paneIdle, extractCtxPct,
  HB_DIR, PID_FILE,
};

if (require.main === module) process.exit(main());
