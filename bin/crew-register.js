#!/usr/bin/env node
'use strict';
// crew-register.js — crew register 的核心:读 cwd 判归属,原子写 .chaos-bridge/project.json 的 sessions[]。
//
// 为什么独立 helper(不内联 node -e):JSON 读改写 + 原子落盘 + 归属判定逻辑够复杂,
// 独立文件可单独跑单元测试(test/crew-register.test.sh 直接 exec 本文件断言 exit code)。
//
// 归属判定:遍历 scanRoot(默认 /work)下一级子目录的 .chaos-bridge/project.json,
// 取 workDir 是 dir 前缀(dir === workDir 或 dir 在 workDir 子树下)的那个 project。
// 多个匹配时取 workDir 最长的(最具体的项目根),避免父项目误收子项目会话。
//
// 原子写:tmp 文件 + fs.renameSync(同目录 rename 是原子操作),杜绝并发写半截 JSON。
//
// 用法:
//   crew-register.js --name X [--dir P] [--role sub] [--kind crew] [--bucket B] [--description D] [--scan-root R]
//   crew-register.js --name X --remove [--dir P] [--scan-root R]   反向删除(crew kill --purge 用)
// exit: 0=成功(push 或幂等 no-op 或 remove)  5=找不到归属 project / dir 非任何项目根

const fs = require('fs');
const path = require('path');

const NAME_RE = /^[a-zA-Z][a-zA-Z0-9._-]{1,40}$/;

function parseArgs(argv) {
  const o = { role: 'sub', kind: 'crew', remove: false, scanRoots: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--name') o.name = argv[++i];
    else if (a === '--dir') o.dir = argv[++i];
    else if (a === '--role') o.role = argv[++i];
    else if (a === '--kind') o.kind = argv[++i];
    else if (a === '--bucket') o.bucket = argv[++i];
    else if (a === '--description') o.description = argv[++i];
    else if (a === '--remove') o.remove = true;
    else if (a === '--scan-root') { (o.scanRoots = o.scanRoots || []).push(argv[++i]); }
  }
  return o;
}

// scan 根:显式 --scan-root 优先;否则 CREW_SCAN_ROOT env(逗号分隔);否则 /work。
function resolveScanRoots(explicit) {
  if (explicit && explicit.length) return explicit;
  const env = process.env.CREW_SCAN_ROOT;
  if (env) return env.split(',').map((s) => s.trim()).filter(Boolean);
  return ['/work'];
}

// 列出 scanRoot 下所有 .chaos-bridge/project.json 的 {cfgPath, workDir}。
function listProjectConfigs(scanRoots) {
  const out = [];
  for (const root of scanRoots) {
    let entries;
    try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (_) { continue; }
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      const cfgPath = path.join(root, e.name, '.chaos-bridge', 'project.json');
      let raw;
      try { raw = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch (_) { continue; }
      if (raw && typeof raw.workDir === 'string' && raw.workDir) {
        out.push({ cfgPath, workDir: path.resolve(raw.workDir) });
      }
    }
  }
  return out;
}

// dir 归属:dir === workDir 或 dir 在 workDir 子树下。多匹配取 workDir 最长(最具体)。
function findOwningConfig(dir, configs) {
  const d = path.resolve(dir);
  let best = null;
  for (const c of configs) {
    const w = c.workDir;
    if (d === w || d.startsWith(w + path.sep)) {
      if (!best || w.length > best.workDir.length) best = c;
    }
  }
  return best;
}

function atomicWriteJSON(cfgPath, obj) {
  const tmp = cfgPath + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n');
  fs.renameSync(tmp, cfgPath);
}

// 文件锁:read-modify-write 整体互斥(rename 只保证单次写原子,不防并发 register 丢写)。
// 用 O_CREAT|O_EXCL(openSync 'wx')独占创建锁文件自旋;拿不到就短睡重试;
// 持锁进程死亡遗留的 stale lock(>10s)强制夺锁,避免死锁。返回释放函数。
function acquireLock(cfgPath, timeoutMs) {
  const lockPath = cfgPath + '.lock';
  const deadline = Date.now() + (timeoutMs || 5000);
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, 'wx');
      fs.writeSync(fd, String(process.pid));
      fs.closeSync(fd);
      return () => { try { fs.unlinkSync(lockPath); } catch (_) {} };
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // stale lock 检测:锁文件 mtime 超 10s 视为持锁进程已死,强夺
      try {
        const st = fs.statSync(lockPath);
        if (Date.now() - st.mtimeMs > 10000) { fs.unlinkSync(lockPath); continue; }
      } catch (_) {}
      if (Date.now() > deadline) throw new Error('crew-register: lock timeout on ' + lockPath);
      // 短忙等(无 sleep 系统调用,用 spawnSync 的等价:小循环 + Atomics 睡)
      sleepSync(20 + Math.floor((process.pid % 30)));
    }
  }
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  if (!o.name || !NAME_RE.test(o.name)) {
    process.stderr.write('crew-register: invalid --name (need /^[a-zA-Z][a-zA-Z0-9._-]{1,40}$/)\n');
    return 5;
  }
  const dir = o.dir || process.cwd();
  const scanRoots = resolveScanRoots(o.scanRoots);
  const configs = listProjectConfigs(scanRoots);
  const owner = findOwningConfig(dir, configs);
  if (!owner) {
    process.stderr.write('crew-register: no project.json owns dir ' + path.resolve(dir) +
      ' (scanned ' + scanRoots.join(',') + ')\n');
    return 5;
  }

  const cfgPath = owner.cfgPath;
  const release = acquireLock(cfgPath, 5000);
  try {
    // 锁内重读:锁外读到的可能已被别的 register 改过,必须以锁内快照为准做 modify。
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
    if (!Array.isArray(cfg.sessions)) cfg.sessions = [];
    const idx = cfg.sessions.findIndex((s) => s && s.name === o.name);

    if (o.remove) {
      if (idx < 0) { process.stdout.write('not-registered: ' + o.name + '\n'); return 0; }
      cfg.sessions.splice(idx, 1);
      atomicWriteJSON(cfgPath, cfg);
      process.stdout.write('unregistered: ' + o.name + ' <- ' + cfg.name + '\n');
      return 0;
    }

    if (idx >= 0) {
      // 幂等:已注册就 no-op(不覆盖已有 role/description,尊重人工微调)。
      process.stdout.write('already-registered: ' + o.name + ' in ' + cfg.name + '\n');
      return 0;
    }

    const entry = { name: o.name, role: o.role, kind: o.kind };
    if (o.bucket) entry.bucket = o.bucket;
    entry.description = o.description || (o.name + ' (crew register auto)');
    cfg.sessions.push(entry);
    atomicWriteJSON(cfgPath, cfg);
    process.stdout.write('registered: ' + o.name + ' -> ' + cfg.name + ' (' + cfgPath + ')\n');
    return 0;
  } finally {
    release();
  }
}

if (require.main === module) process.exit(main());
module.exports = { parseArgs, resolveScanRoots, listProjectConfigs, findOwningConfig, atomicWriteJSON };
