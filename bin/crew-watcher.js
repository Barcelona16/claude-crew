#!/usr/bin/env node
'use strict';
// crew-watcher.js — crew 观察者告警。基于 crew 已有信号源(inbox 信封 delivery + 心跳 + pending nudge)
// 巡检并生成告警,通知发送者/协调者/会话自己。集成方式:crew-heartbeat 循环里调 sweepOnce(),
// 不新起常驻进程。
//
// 四类告警(逐个上,可通过 env 独立开关):
//   ① Stale Inbox      (CREW_WATCHER_ALERT_STALE=1) —— pending 信封 >N 分钟未 delivered → notify sender
//   ② Silent Session   (CREW_WATCHER_ALERT_SILENT=1) —— 收到派单 >Nh 但从未 replyOut → notify 协调者
//   ③ Context Warning  (CREW_WATCHER_ALERT_CTX=1) —— 心跳 ctxPct >= N% → notify 会话自己
//   ④ Heartbeat Loss   (CREW_WATCHER_ALERT_HB=1) —— 心跳 >Nm 未更新 → notify 协调者
//
// 首版只上告警 1(实测能立刻消化 20+ 条积压);②③④ 预留接口,后续逐个填充。
//
// 去重:$CREW_STATE/watcher-state.json 记 alertedEnvelopeIds,避免每次循环重复告警。
//
// 阈值(env 可调):
//   CREW_WATCHER_STALE_MIN     默认 10(告警 1 pending 分钟阈值)
//   CREW_WATCHER_CTX_PCT       默认 85(告警 3)
//   CREW_WATCHER_SILENT_HOURS  默认 24(告警 2)
//   CREW_WATCHER_HB_LOSS_MIN   默认 5(告警 4)
//
// 用法:
//   crew-watcher.js sweep       手动跑一轮(调试用)
//   crew-watcher.js status      打印当前统计(积压信封数/已告警数/未告警数)
// 或从 crew-heartbeat 里 require('./crew-watcher.js').sweepOnce()

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const CREW_STATE = process.env.CREW_STATE ||
  path.join(process.env.HOME || '/tmp', '.local', 'share', 'claude-crew');
const WATCHER_STATE_FILE = path.join(CREW_STATE, 'watcher-state.json');
const STALE_MIN = parseInt(process.env.CREW_WATCHER_STALE_MIN || '10', 10);
// 2026-09-03 U2 · v1.2 §5.1.1:会话级阈值 override 读 session-config/<name>.json
// watcher.staleMinPrivate / watcher.staleMinSession · fallback 全局 STALE_MIN
function loadSessionThreshold(name, kind) {
  try {
    const cfg = readJSON(path.join(CREW_STATE, 'session-config', name + '.json'));
    if (cfg && cfg.watcher) {
      if (kind === 'private' && Number.isFinite(cfg.watcher.staleMinPrivate)) return cfg.watcher.staleMinPrivate;
      if (kind === 'session' && Number.isFinite(cfg.watcher.staleMinSession)) return cfg.watcher.staleMinSession;
    }
  } catch (_) {}
  return null;
}
// 2026-09-03 U2 · v1.2 §5.1 A5:private 告警只写 log 不发告警 · 死循环兜底
const PRIVATE_ALERT_LOG = path.join(CREW_STATE, 'watcher-alerts.log');

// 开关:告警 1 默认开(首版核心),其它默认关(后续启用)
const ALERT_STALE = process.env.CREW_WATCHER_ALERT_STALE !== '0';
// A:死信上限 · age > MAX_STALE_MIN 的信封不告警(默认 24h)
const MAX_STALE_MIN = parseInt(process.env.CREW_WATCHER_MAX_STALE_MIN || '1440', 10);
// B:斩 watcher 自循环 · from/to 是 crew-watcher 的告警不产生新告警
// C:发件人白名单不咚咚 · from.id 是脚本别名(crew-send/notify/watcher)且找不到真人时静默
const ALERT_CTX = process.env.CREW_WATCHER_ALERT_CTX === '1';
const ALERT_SILENT = process.env.CREW_WATCHER_ALERT_SILENT === '1';
const ALERT_HB = process.env.CREW_WATCHER_ALERT_HB === '1';

// C 方案:dead-repl 自动重建(2026-09-02 用户拍板)——检测心跳 tmuxStatus=dead-repl
// 时,自动尝试 crew <name> 拉回(walk launcher fallback,保 --resume 历史)。
// 2026-09-03:改为默认关(env=1 才开)—— 之前测试污染刷屏事故后决定观察观察再开。
const AUTOHEAL_DEAD_REPL = process.env.CREW_WATCHER_AUTOHEAL === '1';
// 冷却:同一会话 N 分钟只重建一次(默认 10min,防死循环)
const AUTOHEAL_COOLDOWN_MIN = parseInt(process.env.CREW_WATCHER_AUTOHEAL_COOLDOWN_MIN || '10', 10);
// 不自动重建的会话(元协调层 + crew-dev 自己 + 人类工作会话需人工确认)
const AUTOHEAL_BLACKLIST = (process.env.CREW_WATCHER_AUTOHEAL_BLACKLIST || 'crew-dev,work').split(',').map(s => s.trim()).filter(Boolean);

function readJSON(f) { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { return null; } }
function nowMs() { return Date.now(); }

// 状态文件(去重记忆):{ alerted: {envelopeId: alertedAt} }
function loadState() {
  const s = readJSON(WATCHER_STATE_FILE);
  return s && typeof s === 'object' ? s : { alerted: {} };
}
function saveState(s) {
  try {
    const tmp = WATCHER_STATE_FILE + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
    fs.renameSync(tmp, WATCHER_STATE_FILE);
  } catch (_) {}
}

// 扫 inbox 找"未消费"信封(pending 或 delivered 都算 stale;acked 已消费不管)。
// 2026-09-02 修:之前只扫 pending,漏了 delivered —— 但自从 crew send 默认 wake(6433b07)后,
// 信封一秒就 pending→delivered,watcher 从来看不见"送达但没读"最该催的态,导致 backend 派单
// 44 分钟没读也没触发告警。语义上 delivered 才是"应告警"的关键态(pending 说明连 wake 都没做,
// 那是发送端问题;delivered 说明消息已 wake 送到但对方 REPL 没跑 crew inbox 消费,是接收端问题)。
// 2026-09-03 v8:拿 tmux live 会话列表,让 stale 扫过滤已 kill 的 toSession(避免骚扰咚咚)
// 相比 crew-heartbeat.js:resolveTmux 里的 crew-<name> 优先精确匹配,
// 这里**故意**用宽松:把 crew-<name> 前缀剥掉后 + 裸名都塞进 Set —— stale 过滤只需
// "这个 toSession 是不是还有对应的 tmux(不管前缀)",找到就通过,找不到就跳过告警。
// 双前缀 Set 语义更宽松是刻意选择(避免漏放行 adopt 场景)· 不抽 helper 避免破坏内聚。
function listLiveSessions() {
  try {
    const r = spawnSync('tmux', ['list-sessions', '-F', '#{session_name}'], { timeout: 3000, encoding: 'utf8' });
    if (r.status !== 0) return null;   // tmux 挂 → null 保守通过(不误伤)
    const names = String(r.stdout || '').split('\n').map((s) => s.trim()).filter(Boolean);
    const live = new Set();
    for (const n of names) {
      // 前缀 crew- 剥掉视为会话名,裸名也算(adopt 场景)
      if (n.startsWith('crew-')) live.add(n.slice(5));
      live.add(n);
    }
    return live;
  } catch (_) { return null; }
}

function scanStalePending(staleMinThreshold) {
  const out = [];
  const inboxRoot = path.join(CREW_STATE, 'inbox');
  let sessions = [];
  try { sessions = fs.readdirSync(inboxRoot); } catch (_) { return out; }
  const now = nowMs();
  // v8 · 一次拿 live 会话集(不为每条 item 重复 spawn tmux)
  // null = tmux 挂 → 全通过(避免误伤 · 保守)
  const live = listLiveSessions();
  for (const sess of sessions) {
    // v8 修:toSession 已 kill(不在 tmux) → 跳过告警(挂了的收件人再报没意义 · 骚扰用户咚咚)
    // live=null 时不校验(tmux 挂 · 全通过),live 是 Set 时严格校验
    if (live && !live.has(sess)) continue;
    const dir = path.join(inboxRoot, sess);
    let files = [];
    try { files = fs.readdirSync(dir).filter((f) => f.endsWith('.json')); } catch (_) { continue; }
    for (const f of files) {
      const e = readJSON(path.join(dir, f));
      if (!e || !e.delivery) continue;
      const st = e.delivery.state;
      if (st !== 'pending' && st !== 'delivered') continue;   // acked 已消费 / 未知态 跳
      // 2026-09-03 U2 · v1.2 §5.1.1:会话级阈值 override(source=private/session 分别可配)
      const source = e.source || (e.from && e.from.kind) || 'session';
      const thresholdKind = source === 'private' ? 'private' : 'session';
      const effectiveThreshold = loadSessionThreshold(sess, thresholdKind) ?? staleMinThreshold;
      const ageMin = Math.floor((now - new Date(e.ts).getTime()) / 60000);
      if (ageMin < effectiveThreshold) continue;
      out.push({
        toSession: sess, id: e.id, ts: e.ts, ageMin,
        state: st,   // 传下去让告警文本区分"没唤醒"vs"送到但没读"
        source,       // 2026-09-03 U2:private / session 分流
        from: e.from || { kind: 'unknown', id: '' },
        note: (e.note || '').slice(0, 120),
      });
    }
  }
  return out;
}

// 读收信方的心跳(为告警消息添加上下文,让发送者能一眼判断"对方卡还是没看到")
function heartbeatOf(name) {
  return readJSON(path.join(CREW_STATE, 'heartbeat', name + '.json'));
}

// 送告警。发送方是 crew 会话 → crew notify;否则(erp 咚咚)→ send.js。
// 静默失败(告警系统本身不能拖累主循环)。
// 2026-09-02 修:env CREW_WATCHER_DRY_ALERT=1 时只 log 不真发(测试环境用,防污染生产咚咚)。
// env CREW_WATCHER_SEND_JS 可覆写 send.js 路径(测试用 mock)。
function sendAlert(target, note) {
  // 2026-09-02:DRY 模式只影响 erp 咚咚(防测试污染 wangqiwang1 咚咚);
  // session inbox 分支保留(测试还能断言信封落 alice inbox),同时也写 log 供测试审计。
  const dry = process.env.CREW_WATCHER_DRY_ALERT === '1';
  if (dry) {
    try {
      const logf = process.env.CREW_WATCHER_ALERT_LOG;
      if (logf) fs.appendFileSync(logf, JSON.stringify({ ts: nowISO(), target, note: note.slice(0, 200) }) + '\n');
    } catch (_) {}
  }
  try {
    if (target.kind === 'session' && target.id) {
      // 复用 crew-notify.js:直接 spawn crew notify(不用 wake,避免告警轰炸;信封落 inbox,对方
      // 下次 idle 自然消费)
      const CREW = process.env.CREW_BIN || path.join(__dirname, '..', 'bin', 'crew');
      spawnSync(CREW, ['notify', target.id, note, '--no-wake'], {
        timeout: 5000, env: { ...process.env, CREW_SESSION_NAME: 'crew-watcher' },
      });
      return true;
    }
    if (target.kind === 'erp' && target.id) {
      // DRY 时不真调 send.js,避免污染 wangqiwang1 咚咚(测试跑完的告警也不该外发)
      if (dry) return true;
      // send.js 走咚咚私聊(env override 测试用)
      // env 覆写 > box 路径 > 找不到时 spawnSync 自然失败返回 false(watcher 容错)。
      const SEND_JS = process.env.CREW_WATCHER_SEND_JS || '/work/agent-bridge/send.js';
      const r = spawnSync('node', [SEND_JS, '--erp', target.id, note], { timeout: 5000 });
      return r.status === 0;
    }
  } catch (_) {}
  return false;
}

// nowISO 供 dry-alert 使用
function nowISO() { return new Date().toISOString(); }

// 告警 1:Stale Inbox
// 通知发送者(from.id):你 X 分钟前发给 Y 的消息还没被消费;Y 现在 ctxPct=Z paneIdle=W。
// 广播合并(2026-09-02 加):同一发送者 X 分钟内向 N 个目标发的 stale 消息,合并成 1 条汇总告警,
// 避免"广播 12 个 → 12 条独立告警"刷屏。
function alertStale(items, state) {
  if (!ALERT_STALE) return { fired: 0, skipped: items.length };
  let fired = 0, skipped = 0;
  const now = new Date().toISOString();

  // 先过滤:①已 alerted ②死信(age > MAX_STALE_MIN,默认 24h) ③watcher 自循环 ④private log-only
  const SCRIPT_ALIASES = new Set(['crew-send', 'crew-notify', 'crew-watcher']);
  const fresh = items.filter((it) => {
    if (state.alerted[it.id]) return false;
    // B · 死信上限:超 24h 的信封不告警了,反正也不会被读
    if (it.ageMin >= MAX_STALE_MIN) { state.alerted[it.id] = now; return false; }
    // A · 斩 watcher 自循环:watcher 发的告警送到别会话,别会话不消费 → 别再产生新告警
    if (it.from && it.from.id === 'crew-watcher') { state.alerted[it.id] = now; return false; }
    if (it.toSession === 'crew-watcher') { state.alerted[it.id] = now; return false; }
    // 2026-09-03 U2 · v1.2 §5.1 A5:from.kind=private 告警只写 log · 不进入 sendAlert 循环
    // 避免死循环(watcher 送咚咚私聊告警又变新 private stale)
    if (it.source === 'private' || (it.from && it.from.kind === 'private')) {
      try {
        fs.appendFileSync(PRIVATE_ALERT_LOG,
          JSON.stringify({ ts: now, kind: 'private-stale', ...it }) + '\n');
      } catch (_) {}
      state.alerted[it.id] = now;
      return false;
    }
    return true;
  });
  skipped = items.length - fresh.length;
  if (fresh.length === 0) return { fired: 0, skipped };

  // 聚合:{ fromKey: [items...] }
  // D · 修 · 脚本别名兜底不再直接扔 wangqiwang1:
  //   - 找不到真发件人(from.id 是 crew-send/notify/watcher)= 系统告警自身失败,静默 mark alerted
  //   - 真会话名(如 backend/proj-y32g7)才聚合发告警到该会话
  const groups = {};
  for (const it of fresh) {
    let key;
    if (it.from.kind === 'session' && it.from.id && !SCRIPT_ALIASES.has(it.from.id)) {
      key = 'session:' + it.from.id;
    } else {
      // 脚本别名/未知 → 静默 mark alerted(不扰用户)
      state.alerted[it.id] = now;
      skipped++;
      continue;
    }
    (groups[key] = groups[key] || []).push(it);
  }

  for (const [key, gitems] of Object.entries(groups)) {
    const [kind, id] = [key.slice(0, key.indexOf(':')), key.slice(key.indexOf(':') + 1)];
    const target = { kind, id };

    // 自告警短路:crew-watcher 不告警 crew-watcher / 自己发的消息不告警自己(信息价值=0)
    // 这条最常出现在广播场景 —— 发送者=crew-dev,一次发 N 条,告警回自己没意义。
    // 若 target.id === process.env.CREW_SESSION_NAME(watcher 运行在某会话上下文中),跳过。
    if (kind === 'session' && id === (process.env.CREW_SESSION_NAME || '')) {
      // 只发一条汇总给用户,而不是每条给发送者自己
      const note = `[watcher · stale-inbox 自告警短路] 你(${id})${gitems.length} 条 stale 消息(最老 ${Math.max(...gitems.map((x) => x.ageMin))} 分钟)未被消费。目标:${[...new Set(gitems.map((x) => x.toSession))].join(', ')}`;
      if (sendAlert({ kind: 'erp', id: 'wangqiwang1' }, note)) {
        for (const it of gitems) state.alerted[it.id] = now;
        fired += gitems.length;
      } else {
        skipped += gitems.length;
      }
      continue;
    }

    // 单条 or 汇总:1 条独立告警(带完整信封内容),>1 汇总告警(带 target 列表 + 最老 age)
    let note;
    if (gitems.length === 1) {
      const it = gitems[0];
      const hb = heartbeatOf(it.toSession);
      const ctxHint = hb ? `ctxPct=${hb.ctxPct == null ? '?' : hb.ctxPct + '%'} paneIdle=${hb.paneIdle === null ? '?' : hb.paneIdle}` : '(无心跳)';
      // state=pending → "还没唤醒"(发送端问题);state=delivered → "已送到但对方没读"(接收端问题)
      const stateHint = it.state === 'delivered' ? '已送到但对方没消费(REPL 没跑 crew inbox)' : '还没被唤醒(发送端可能漏 wake)';
      note = `[watcher · stale-inbox] 你 ${it.ageMin} 分钟前发给 ${it.toSession} 的消息(id=${it.id})${stateHint}。` +
             `对方当前状态:${ctxHint}。信封内容片段:"${it.note}${it.note.length >= 120 ? '…' : ''}"`;
    } else {
      const oldest = Math.max(...gitems.map((x) => x.ageMin));
      const targets = [...new Set(gitems.map((x) => x.toSession))];
      // 汇总里也带 state 分布,让接收方一眼看出多少是"没唤醒(pending)"多少是"送到没读(delivered)"
      const nDelivered = gitems.filter((x) => x.state === 'delivered').length;
      const nPending = gitems.filter((x) => x.state === 'pending').length;
      const stateHint = nDelivered ? `${nDelivered} 已送到但对方没消费(REPL 没跑 crew inbox)` : '';
      const stateHint2 = nPending ? `${nPending} 未唤醒(发送端可能漏 wake)` : '';
      const combined = [stateHint, stateHint2].filter(Boolean).join(',');
      note = `[watcher · stale-inbox 汇总] 你 ${gitems.length} 条消息 stale(最老 ${oldest} 分钟未消费;${combined})。` +
             `涉及会话:${targets.join(', ')}。逐条查:crew status <name> 或 crew inbox <name> --peek`;
    }

    if (sendAlert(target, note)) {
      for (const it of gitems) state.alerted[it.id] = now;
      fired += gitems.length;
    } else {
      skipped += gitems.length;
    }
  }
  return { fired, skipped };
}

// 主入口:一轮扫描
function sweepOnce() {
  const state = loadState();
  // 清理已 acked/消费的旧记录(否则文件无限膨胀)—— 状态文件里 alerted[id] 存的 id 若在 inbox
  // 里已经不 pending 了(被 acked 归档),就从记录里删。粗暴做法:只保留最近 7 天的 alerted。
  const cutoff = nowMs() - 7 * 24 * 60 * 60 * 1000;
  const cleaned = {};
  for (const [id, ts] of Object.entries(state.alerted || {})) {
    if (new Date(ts).getTime() > cutoff) cleaned[id] = ts;
  }
  state.alerted = cleaned;

  const results = { staleFired: 0, staleSkipped: 0 };

  if (ALERT_STALE) {
    const items = scanStalePending(STALE_MIN);
    const r = alertStale(items, state);
    results.staleFired = r.fired;
    results.staleSkipped = r.skipped;
  }

  // TODO(v2): ALERT_CTX / ALERT_SILENT / ALERT_HB —— 首版只上 stale,其它逐个填。

  // C 方案:dead-repl 自动重建(2026-09-02 用户拍板)
  if (AUTOHEAL_DEAD_REPL) {
    const heal = autohealDeadRepl(state);
    results.healed = heal.healed;
    results.healSkipped = heal.skipped;
    results.healFailed = heal.failed;
  }

  // 2026-09-03 v8 P2(Agent-A1 复审):清扫 dedup + turn marker · age > 7d unlink
  // 长跑累积 · 无清扫会撑爆 state dir。用相同 cutoff(7d)与 alerted 记录同陈旧标准。
  results.markerSwept = sweepStaleMarkers(7 * 24 * 60 * 60 * 1000);

  saveState(state);
  return results;
}

// 清 $CREW_STATE/.dedup/*.stamp + $CREW_STATE/*.turn-*.done · age > ageMs 的 unlink
// 尽力清 · 单文件失败不阻塞下一个 · 返回 {dedup, turn} 计数供 status 显示
function sweepStaleMarkers(ageMs) {
  const cutoff = Date.now() - ageMs;
  const out = { dedup: 0, turn: 0 };
  // .dedup/*.stamp
  const dedupDirPath = path.join(CREW_STATE, '.dedup');
  try {
    for (const f of fs.readdirSync(dedupDirPath)) {
      if (!f.endsWith('.stamp')) continue;
      const fp = path.join(dedupDirPath, f);
      try {
        if (fs.statSync(fp).mtimeMs < cutoff) { fs.unlinkSync(fp); out.dedup++; }
      } catch (_) {}
    }
  } catch (_) { /* dir 不存在 · 首次跑 */ }
  // <self>.turn-<sid>.done marker(Stop hook 幂等)
  try {
    for (const f of fs.readdirSync(CREW_STATE)) {
      if (!/\.turn-.+\.done$/.test(f)) continue;
      const fp = path.join(CREW_STATE, f);
      try {
        if (fs.statSync(fp).mtimeMs < cutoff) { fs.unlinkSync(fp); out.turn++; }
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

// autohealDeadRepl:扫心跳文件找 tmuxStatus=dead-repl,过滤黑名单+冷却期,
// 尝试 crew <name> 拉回(launcher 会走 fallback 众数 backend/key + --resume 保历史)。
// 每次重建咚咚告警,可控可审计。
function autohealDeadRepl(state) {
  const out = { healed: 0, skipped: 0, failed: 0 };
  const hbDir = path.join(CREW_STATE, 'heartbeat');
  let files = [];
  try { files = fs.readdirSync(hbDir).filter((f) => f.endsWith('.json') && !f.startsWith('heartbeat.')); } catch (_) { return out; }
  state.healed = state.healed || {};  // { name: alerteredAt ISO } —— 冷却记忆
  const nowMsVal = nowMs();
  const cooldownMs = AUTOHEAL_COOLDOWN_MIN * 60 * 1000;
  for (const f of files) {
    const name = f.replace(/\.json$/, '');
    if (AUTOHEAL_BLACKLIST.indexOf(name) >= 0) continue;
    const hb = readJSON(path.join(hbDir, f));
    if (!hb || hb.tmuxStatus !== 'dead-repl') continue;
    // 冷却检查
    const lastHeal = state.healed[name];
    if (lastHeal && (nowMsVal - new Date(lastHeal).getTime()) < cooldownMs) {
      out.skipped++;
      continue;
    }
    // 尝试重建:crew <name>(launcher 会 --resume;若 state 丢会 fallback 众数)
    // env CREW_BIN 可覆写(测试用 fake crew 记录调用);默认走 sibling bin/crew
    const CREW = process.env.CREW_BIN || path.join(__dirname, '..', 'bin', 'crew');
    let ok = false, stderr = '';
    try {
      const r = spawnSync(CREW, [name, '--no-tmux'], {
        timeout: 15000, encoding: 'utf8',
        env: { ...process.env, CREW_SESSION_NAME: 'crew-watcher' },
        detached: true,   // 不等它跑,起了就走(claude REPL 起来是分钟级)
      });
      ok = r.status === 0 || r.status === null;  // detached 常 null
      stderr = String(r.stderr || '').slice(0, 200);
    } catch (e) { stderr = String(e.message || e); }
    // 记冷却
    state.healed[name] = new Date().toISOString();
    // 咚咚告警
    const note = `[watcher · autoheal] ${name} 检测到 dead-repl(REPL 挂了但 tmux 活),已尝试 crew ${name} 自动拉回。stderr 摘: ${stderr || '(空)'}`;
    sendAlert({ kind: 'erp', id: 'wangqiwang1' }, note);
    if (ok) out.healed++; else out.failed++;
  }
  return out;
}

function main() {
  const cmd = process.argv[2];
  if (cmd === 'sweep') {
    const r = sweepOnce();
    process.stdout.write(JSON.stringify(r, null, 2) + '\n');
    return 0;
  }
  if (cmd === 'baseline') {
    // 把当前所有 stale pending 信封标记为已 alerted(不追溯告警),用于首次启用或大规模积压后重置。
    // 时间戳用真 ISO now(否则 sweepOnce 里 7 天清理逻辑判 NaN 会误清)。
    const items = scanStalePending(STALE_MIN);
    const state = loadState();
    const now = new Date().toISOString();
    let added = 0;
    for (const it of items) {
      if (!state.alerted[it.id]) { state.alerted[it.id] = now; added++; }
    }
    saveState(state);
    process.stdout.write(JSON.stringify({ baselined: added, totalAlerted: Object.keys(state.alerted).length }, null, 2) + '\n');
    return 0;
  }
  if (cmd === 'status') {
    const items = scanStalePending(STALE_MIN);
    const state = loadState();
    process.stdout.write(JSON.stringify({
      staleMinThreshold: STALE_MIN,
      pendingStaleCount: items.length,
      alertedCount: Object.keys(state.alerted || {}).length,
      alerts: { ALERT_STALE, ALERT_CTX, ALERT_SILENT, ALERT_HB },
      samples: items.slice(0, 5).map((i) => ({ to: i.toSession, from: i.from.id, ageMin: i.ageMin, id: i.id })),
    }, null, 2) + '\n');
    return 0;
  }
  process.stderr.write('usage: crew-watcher.js {sweep|status}\n');
  return 1;
}

module.exports = { sweepOnce, scanStalePending, alertStale, heartbeatOf, sendAlert, loadState, saveState };

if (require.main === module) process.exit(main());
