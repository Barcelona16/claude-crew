#!/usr/bin/env node
'use strict';
// crew-web.js — crew 独立 web 前端。单文件 node 内置 http,零依赖。
//
// 职责:
// ① GET  /            → 返回 web/frontend.html + {{PLACEHOLDER}} 注入
// ② GET  /api/state   → 聚合快照 JSON:每会话 { name, status, model, key, dir,
//                       ctxPct, lastHeartbeat, inboxCount, pendingNudges, inbound[], outbound[] }
// ③ POST /api/switch  → 白名单调 crew <name> --key K --model M(严格校验 name/key/model)
// ④ POST /api/attach  → 返回 tmux attach 命令行(不代执行,前端展示复制)
// ⑤ GET  /healthz     → 200
//
// 数据源(全只读):
// - feedback.jsonl 尾 2000 行(readTail 512KB 读回,与 agent-bridge/lib/panel-core.js 一致)
// - $CREW_STATE/heartbeat/<name>.json(crew-heartbeat 采样产出)
// - $CREW_STATE/inbox/<name>/*.json + *.msg(未消费统计)
// - $CREW_STATE/pending-nudges.jsonl(待补发)
// - $CREW_STATE/<name>.tmux/.sid/.backend/.key/.dir(会话 state)
// - CCR config.json(切换菜单的 keys / models 列表来源;白名单校验用)
//
// 用法:
//   crew-web.js [--port 18060]
// env:
//   CREW_WEB_PORT       端口(默认 18060)
//   CREW_STATE          crew 状态目录
//   FEEDBACK_JSONL      feedback.jsonl 路径(默认 /work/agent-bridge/logs/feedback.jsonl)

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const url = require('url');

const CREW_STATE = process.env.CREW_STATE ||
  path.join(process.env.HOME || '/tmp', '.local', 'share', 'claude-crew');
const FEEDBACK_JSONL = process.env.FEEDBACK_JSONL ||
  '/work/agent-bridge/logs/feedback.jsonl';
const PORT = parseInt(process.env.CREW_WEB_PORT || '18060', 10);
const SCRIPT_DIR = __dirname;
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const FRONTEND_HTML = path.join(REPO_ROOT, 'web', 'frontend.html');
const CCR_CONFIG = path.join(process.env.HOME || '/root', '.claude-code-router', 'config.json');

// ---- 工具 ----
function readTail(file, n) {
  try {
    const stat = fs.statSync(file);
    const size = Math.min(stat.size, 512 * 1024);
    const buf = Buffer.alloc(size);
    const fd = fs.openSync(file, 'r');
    fs.readSync(fd, buf, 0, size, stat.size - size);
    fs.closeSync(fd);
    const lines = buf.toString('utf8').split('\n').filter((l) => l.trim());
    return lines.slice(-n);
  } catch (_) { return []; }
}

function readJSON(f) {
  try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { return null; }
}

// listCrewSessions:两路兜底
//   ① $CREW_STATE 里 <name>.<key> state 文件(crew 管理的会话)
//   ② tmux list-sessions 里的名字(去 crew- 前缀;work 等 agent-bridge 侧启的会话由此纳入)
// 不用 feedback.jsonl 的 session 字段兜底 —— 那里可能存 erp 名(咚咚会话粘性时 session=erp),
// 把外部 erp 当 crew 会话拉进来会污染。想让某会话上面板:要么写 CREW_STATE state,要么起 tmux。
function listCrewSessions() {
  const names = new Set();
  try {
    for (const f of fs.readdirSync(CREW_STATE)) {
      if (f === 'inbox' || f === 'heartbeat' || f.startsWith('.')) continue;
      const m = f.match(/^(.+)\.(tmux|sid|backend|key|dir|policy|tmuxname|notmux|fgpid|policy_body|pintmux)$/);
      if (m) names.add(m[1]);
    }
  } catch (_) {}
  try {
    const r = spawnSync('tmux', ['list-sessions', '-F', '#{session_name}'], { timeout: 2000, encoding: 'utf8' });
    if (r.status === 0) {
      for (const line of String(r.stdout || '').split('\n')) {
        const t = line.trim();
        if (!t) continue;
        names.add(t.startsWith('crew-') ? t.slice(5) : t);
      }
    }
  } catch (_) {}
  return Array.from(names);
}

// 读会话 state key(照 crew-session get)
function readState(name, key) {
  try { return fs.readFileSync(path.join(CREW_STATE, name + '.' + key), 'utf8').trim(); } catch (_) { return ''; }
}

// inbox 计数(与 crew-status 一致的分类)
function readInboxCounts(name) {
  const dir = path.join(CREW_STATE, 'inbox', name);
  let entries = [];
  try { entries = fs.readdirSync(dir); } catch (_) { return { total: 0, pending: 0, delivered: 0, legacy: 0 }; }
  let pending = 0, delivered = 0, legacy = 0;
  for (const f of entries) {
    if (f === 'consumed') continue;
    if (f.endsWith('.json')) {
      const env = readJSON(path.join(dir, f));
      if (env && env.delivery) {
        if (env.delivery.state === 'pending') pending++;
        else if (env.delivery.state === 'delivered') delivered++;
      }
    } else if (f.endsWith('.msg')) legacy++;
  }
  return { total: pending + delivered + legacy, pending, delivered, legacy };
}

function readPendingNudges(name) {
  const f = path.join(CREW_STATE, 'pending-nudges.jsonl');
  try {
    const raw = fs.readFileSync(f, 'utf8').trim();
    if (!raw) return 0;
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr.filter((x) => x && x.session === name).length : 0;
  } catch (_) { return 0; }
}

// 从 feedback.jsonl 拿本会话最近 N 条 inbound / outbound。
// 归属规则(照抄 agent-bridge/lib/panel-core.js:206-213):
//   inbound = !replyOut && session == 本会话
//   outbound = replyOut && sender == 本会话
// 来源:from.kind = source(private=erp, session=session, group=group);fallback pin。
//
// state 判定(2026-09-01 修:老记录不该被判 stale):
//   - 有 delivery 字段 → 用真实 state(pending/delivered/acked)
//   - 无 delivery 字段(#3 之前的老记录)→ 按 replyOut 兜底:发出的当 acked(咚咚发出即完事),
//     收到的当 delivered(不 stale 红,不苛刻)
//
// ack 合并:crew-notify.js 消费时会再 append 一条 ackOf=<id> 空 note 的镜像。
// 用它反向把原信封记录的 state 提升到 acked——避免前端看到"pending 已 30 分钟"却其实早消费了。
function readMessages(name, limit) {
  const lines = readTail(FEEDBACK_JSONL, 2000);
  // 先扫一遍收集 ack 镜像的 envelope id 集合
  const ackedIds = new Set();
  for (const l of lines) {
    let r; try { r = JSON.parse(l); } catch (_) { continue; }
    if (r && r.ackOf) ackedIds.add(r.ackOf);
  }
  const inbound = [], outbound = [];
  for (const l of lines) {
    let r; try { r = JSON.parse(l); } catch (_) { continue; }
    if (!r) continue;
    // ackOf 镜像行本身不作独立消息,只用于合并
    if (r.ackOf) continue;
    const sess = r.session || 'work';
    let state;
    if (r.delivery && r.delivery.state) state = r.delivery.state;
    else state = r.replyOut ? 'acked' : 'delivered';   // 老记录兜底,不判 stale 红
    // 若这条 envelope 有 ack 镜像 → 合并为 acked
    if (r.envelopeId && ackedIds.has(r.envelopeId)) state = 'acked';
    const rec = {
      ts: r.ts,
      from: { kind: r.source === 'session' ? 'session' : (r.source === 'group' ? 'group' : 'erp'),
              id: r.pin || r.sender || '' },
      to: sess,
      note: (r.note || '').slice(0, 200),
      state,
      envelopeId: r.envelopeId || null,
    };
    if (!r.replyOut && sess === name) inbound.push(rec);
    else if (r.replyOut && r.sender === name) outbound.push(rec);
  }
  return { inbound: inbound.slice(-limit), outbound: outbound.slice(-limit) };
}

// tmux 活 pane 名(精确名 → 或 crew- 前缀)。心跳文件里已有 tmux 字段,这里做兜底。
function resolveTmux(name) {
  const hb = readJSON(path.join(CREW_STATE, 'heartbeat', name + '.json'));
  if (hb && hb.tmux) return hb.tmux;
  const r = spawnSync('tmux', ['list-sessions', '-F', '#{session_name}'], { timeout: 2000, encoding: 'utf8' });
  if (r.status !== 0) return null;
  const names = String(r.stdout || '').split('\n').map((s) => s.trim()).filter(Boolean);
  if (names.indexOf(name) >= 0) return name;
  if (names.indexOf('crew-' + name) >= 0) return 'crew-' + name;
  return null;
}

// 会话卡片数据聚合
function sessionCard(name, msgLimit) {
  const hb = readJSON(path.join(CREW_STATE, 'heartbeat', name + '.json'));
  const inbox = readInboxCounts(name);
  const pending = readPendingNudges(name);
  const msgs = readMessages(name, msgLimit || 20);
  return {
    name,
    tmux: hb ? hb.tmux : resolveTmux(name),
    status: hb ? hb.tmuxStatus : null,       // live / dead / unknown / null=心跳未采
    paneIdle: hb ? hb.paneIdle : null,
    ctxPct: hb ? hb.ctxPct : null,
    lastHeartbeat: hb ? hb.ts : null,
    model: readState(name, 'backend'),
    key: readState(name, 'key'),
    dir: readState(name, 'dir'),
    sid: readState(name, 'sid'),
    inboxCount: inbox.total,
    inbox,
    pendingNudges: pending,
    inbound: msgs.inbound,
    outbound: msgs.outbound,
  };
}

// CCR 里所有 key(别名 → 真值)。切换菜单 + 白名单来源。
function listKeys() {
  const cfg = readJSON(CCR_CONFIG);
  if (!cfg) return [];
  // keys.conf 别名(有些环境用 keys.conf,有些直接 provider.api_key 里)
  // 这里保守:遍历 Providers[].api_key 拿唯一集合作为 key 白名单
  const set = new Set();
  const providers = cfg.Providers || cfg.providers || [];
  for (const p of providers) if (p && p.api_key) set.add(p.api_key);
  return Array.from(set);
}

// CCR 里某 key 支持的模型 —— 全部 provider 的 models union
function listModelsForKey(key) {
  const cfg = readJSON(CCR_CONFIG);
  if (!cfg) return [];
  const providers = cfg.Providers || cfg.providers || [];
  const models = new Set();
  for (const p of providers) {
    if (p && p.api_key === key && Array.isArray(p.models)) {
      for (const m of p.models) models.add(p.name ? p.name + ',' + m : m);
    }
  }
  return Array.from(models);
}

function listAllModels() {
  const cfg = readJSON(CCR_CONFIG);
  if (!cfg) return [];
  const providers = cfg.Providers || cfg.providers || [];
  const models = new Set();
  for (const p of providers) {
    if (p && Array.isArray(p.models)) for (const m of p.models) models.add(p.name ? p.name + ',' + m : m);
  }
  return Array.from(models);
}

// ---- 前端 HTML 加载 + 占位符注入 ----
function buildFrontend() {
  let tpl;
  try { tpl = fs.readFileSync(FRONTEND_HTML, 'utf8'); }
  catch (e) { return '<!doctype html><h1>crew web</h1><p>frontend.html 缺失:' + e.message + '</p>'; }
  return tpl
    .replace(/{{PORT}}/g, String(PORT))
    .replace(/{{CREW_STATE}}/g, esc(CREW_STATE))
    .replace(/{{FEEDBACK_JSONL}}/g, esc(FEEDBACK_JSONL));
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

// ---- HTTP handlers ----
function sendJSON(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function sendHTML(res, code, html) {
  res.writeHead(code, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
}

function sendText(res, code, txt) {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(txt);
}

function readBody(req) {
  return new Promise((resolve) => {
    let d = ''; req.on('data', (c) => d += c); req.on('end', () => resolve(d));
  });
}

// /api/state:全会话聚合快照
function handleState(req, res, u) {
  const msgLimit = parseInt(u.query.msgLimit || '20', 10);
  const names = listCrewSessions();
  const sessions = names.map((n) => sessionCard(n, msgLimit));
  // 排序:两级——先按"有无消息活动"分组,组内按 ts 倒序。
  //   ① 有消息:latestMsgTs 越新越靠前(真实活动)
  //   ② 无消息:退到 lastHeartbeat 排后(心跳时间几乎同批,细分意义有限)
  // 这样活跃会话永远置顶,无活动的按心跳沉底,避免"一堆同心跳时间"的中间挤成一片。
  const latestMsg = (s) => {
    let m = '';
    for (const arr of [s.inbound, s.outbound]) {
      for (const x of arr || []) if (x.ts && x.ts > m) m = x.ts;
    }
    return m;
  };
  sessions.sort((a, b) => {
    const ma = latestMsg(a), mb = latestMsg(b);
    if (ma && mb) return mb.localeCompare(ma);
    if (ma) return -1;
    if (mb) return 1;
    return (b.lastHeartbeat || '').localeCompare(a.lastHeartbeat || '');
  });
  sendJSON(res, 200, {
    ts: new Date().toISOString(),
    port: PORT,
    crewState: CREW_STATE,
    feedbackJsonl: FEEDBACK_JSONL,
    sessions,
    keys: listKeys(),
    models: listAllModels(),
  });
}

// /api/switch:白名单调 crew <name> --key K --model M
async function handleSwitch(req, res) {
  if (req.method !== 'POST') return sendJSON(res, 405, { ok: false, err: 'method not allowed' });
  const body = await readBody(req);
  let payload; try { payload = JSON.parse(body); } catch (_) { return sendJSON(res, 400, { ok: false, err: 'bad json' }); }
  const { name, key, model } = payload || {};
  // 白名单严格:name 必须是已知会话,key/model 必须在 CCR 集合内
  const knownNames = listCrewSessions();
  const knownKeys = new Set(listKeys());
  const knownModels = new Set(listAllModels());
  if (!name || knownNames.indexOf(name) < 0) return sendJSON(res, 400, { ok: false, err: 'unknown session: ' + name });
  if (key && !knownKeys.has(key)) return sendJSON(res, 400, { ok: false, err: 'unknown key' });
  if (model && !knownModels.has(model)) return sendJSON(res, 400, { ok: false, err: 'unknown model' });
  if (!key && !model) return sendJSON(res, 400, { ok: false, err: 'need key or model' });
  const args = [name];
  if (key) args.push('--key', key);
  if (model) args.push('--model', model);
  const CREW = path.join(SCRIPT_DIR, 'crew');
  const r = spawnSync(CREW, args, { encoding: 'utf8', timeout: 30000, env: { ...process.env, CREW_NO_MENU: '1' } });
  sendJSON(res, r.status === 0 ? 200 : 500, {
    ok: r.status === 0, exit: r.status, stdout: r.stdout, stderr: r.stderr,
  });
}

// /api/attach:返回 tmux attach 命令行(不代 exec,浏览器展示复制)
async function handleAttach(req, res) {
  if (req.method !== 'POST') return sendJSON(res, 405, { ok: false, err: 'method not allowed' });
  const body = await readBody(req);
  let payload; try { payload = JSON.parse(body); } catch (_) { return sendJSON(res, 400, { ok: false, err: 'bad json' }); }
  const { name } = payload || {};
  const knownNames = listCrewSessions();
  if (!name || knownNames.indexOf(name) < 0) return sendJSON(res, 400, { ok: false, err: 'unknown session' });
  const tmux = resolveTmux(name);
  if (!tmux) return sendJSON(res, 404, { ok: false, err: 'tmux session not found for ' + name });
  sendJSON(res, 200, { ok: true, command: 'tmux attach -t ' + tmux, tmux });
}

function handleRequest(req, res) {
  const u = url.parse(req.url, true);
  try {
    if (u.pathname === '/healthz') return sendText(res, 200, 'ok');
    if (u.pathname === '/' || u.pathname === '/index.html') return sendHTML(res, 200, buildFrontend());
    if (u.pathname === '/api/state') return handleState(req, res, u);
    if (u.pathname === '/api/switch') return handleSwitch(req, res);
    if (u.pathname === '/api/attach') return handleAttach(req, res);
    sendText(res, 404, 'not found: ' + u.pathname);
  } catch (e) {
    process.stderr.write('[crew-web] handler err: ' + e.stack + '\n');
    sendJSON(res, 500, { ok: false, err: e.message });
  }
}

module.exports = {
  buildFrontend, sessionCard, listCrewSessions, listKeys, listAllModels,
  readMessages, readInboxCounts, readPendingNudges,
  handleState, handleSwitch, handleAttach, handleRequest,
  PORT, CREW_STATE, FEEDBACK_JSONL,
};

// ---- CLI ----
if (require.main === module) {
  const argv = process.argv.slice(2);
  let port = PORT;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') port = parseInt(argv[++i], 10);
  }
  const server = http.createServer(handleRequest);
  server.listen(port, () => {
    console.log('[crew-web] listening on :' + port);
    console.log('[crew-web] state: ' + CREW_STATE);
    console.log('[crew-web] feedback: ' + FEEDBACK_JSONL);
  });
}
