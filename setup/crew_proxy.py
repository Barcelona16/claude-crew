#!/usr/bin/env python3
# CREW_PROXY_REPO_REV: (run `git rev-parse --short HEAD` in the crew repo and fill this when cutting an install)
"""crew-proxy — a thin local reverse proxy between Claude Code and claude-code-router (CCR).

    claude  ->  crew-proxy (:8788)  ->  CCR (:3456)  ->  upstream gateway

It owns key priority + circuit-breaking. For each request it picks the highest-priority
*healthy* key for the requested model, rewrites the request `model` to the CCR provider that
serves that (model, key) pair, and forwards to CCR (path Y: the proxy routes itself; CCR's own
fallback is not used). On an upstream failure status (401/403/429/5xx or a connection error)
observed *before* the body starts streaming, it trips that key and transparently retries the
SAME request with the next healthy key. Claude never sees the switch.

Zero third-party deps (stdlib http.server + urllib).

Config (all under ~/.config/claude-crew unless overridden):
  keys.conf        <alias>=<api-key>                          (existing crew keys file)
  key-policy.conf  <realmodel> = <alias1> <alias2> ...        (priority, high -> low)
CCR 3 keeps its live configuration in SQLite. Crew keeps a separate provider
map (``~/.config/claude-crew/ccr-providers.json`` by default) with one provider
per (model, key) pair, then applies it through CCR's authenticated local RPC.

Env:
  CREW_PROXY_PORT     listen port (default 8788)
  CREW_CCR_URL        upstream CCR base (default http://127.0.0.1:3456)
  CREW_CONFIG_DIR     config dir (default ~/.config/claude-crew, honors XDG_CONFIG_HOME)
  CREW_CCR_CONFIG     crew provider-map path (default ~/.config/claude-crew/ccr-providers.json)
  CREW_CCR_V3_ADAPTER path to ccr_v3.py (default next to this script)
  CREW_CCR_WEB_URL    CCR 3 management URL (default http://127.0.0.1:3458)
  CREW_CCR_WEB_TOKEN  CCR 3 management token; required for provider-map updates
  CREW_PROXY_FAILS    consecutive failures before a key trips (default 3)
  CREW_PROXY_COOLDOWN tripped-key cooldown seconds (default 60)
  CREW_PROXY_STATE    circuit-breaker state dump (default ~/.local/share/claude-crew/proxy-state.json)
"""

# ── sys.path bootstrap: ensure sibling _crew_* modules are importable ──────────
import os as _os
import sys as _sys
_here = _os.path.dirname(_os.path.abspath(__file__))
if _here not in _sys.path:
    _sys.path.insert(0, _here)

# Register a proxy in sys.modules so submodule-level __getattr__ can resolve
# monkey-patched config values (tests load us via module_from_spec without
# registering in sys.modules). The proxy delegates to our own globals dict,
# so cp.GATEWAY_AUTH = ... is visible inside request handlers.
if "crew_proxy" not in _sys.modules:
    class _ConfigProxy:
        def __getattr__(self, name):
            return globals()[name]
        def __setattr__(self, name, value):
            globals()[name] = value
    _sys.modules["crew_proxy"] = _ConfigProxy()

# ── re-export stdlib names that callers/tests may access on this module ────────
import atexit
import json
import logging
import os
import re
import secrets
import shutil
import socket
import select
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── import from split submodules (order matters for dependency chain) ──────────
from _crew_config import (
    CCR_CFG, CCR_URL, CCR_V3_ADAPTER, CFG_DIR, COOLDOWN, COOLDOWN_FILE,
    CREW_DEMO_GIF, CREW_HERO_PNG, CREW_STATE,
    FAIL_CODES, FAIL_N, GATEWAY_AUTH, KEYS_FILE, MW_CONF, POLICY, PORT,
    PT_MAX_RETRY, PT_RETRY_BASE, PT_RETRY_MAX, PT_RETRY_BUDGET,
    REGISTER_ALLOW, REGISTER_MODEL, REGISTER_RETRY_BASE, REGISTER_TEST_URL,
    SAFE_NAME, STATE_FILE, USAGE_FILE,
    _api_sessions_fallback, _cfg_dir, _find_crew_bin, _http_err_summary,
    _is_fail, _raw_gateway_auth, _read_state_field, cooldown_for, load_ccr_gateway_key,
    load_ccr_providers, load_cooldown, load_gateway_auth, load_keys,
    load_policy, mask_key, parse_retry_after, provider_for, register_allow_list,
    run_crew, sync_ccr_config, log,
)
from _crew_windows import (
    _CALIB_LOCK, _PTL_SOURCE_PATTERNS, _PTL_WINDOW_RES, _mw_conf_pattern,
    _ptl_hay, calibrate_model_window, estimate_input_tokens,
    extract_window_from_error, maybe_calibrate_from_error, translate_prompt_too_long,
)
from _crew_breaker import BREAKER, Breaker
from _crew_stats import (
    STATS, USAGE, LATENCY, USAGE_STREAM_CAP, Stats, UsageSeries, LatencySeries, parse_usage,
)
from _crew_server import main

# CREW_BIN is computed here (monkey-patchable at runtime).
CREW_BIN = os.environ.get("CREW_BIN") or _find_crew_bin()

# ── Override config loaders so they read monkey-patchable facade constants ──────
# The _crew_config.py versions read _crew_config's own globals, which don't see
# test patches like `cp.GATEWAY_AUTH = ...`. These re-definitions shadow the
# imported names and resolve against this module's globals (which the patches hit).
def load_gateway_auth():
    """gateway-auth.json -> {login_key: {maps_to, allow_models, erp, admin}}. Empty dict if absent."""
    try:
        with open(GATEWAY_AUTH) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for k, v in data.items():
        if k.startswith("__") or not isinstance(v, dict):
            continue
        out[k] = {"maps_to": str(v.get("maps_to", "")),
                  "allow_models": list(v.get("allow_models") or []),
                  "erp": str(v.get("erp", "")),
                  "admin": bool(v.get("admin"))}
    return out

def _raw_gateway_auth():
    """The gateway-auth.json dict verbatim (including __-prefixed config keys), {} if absent."""
    try:
        with open(GATEWAY_AUTH) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}

def load_keys():
    """keys.conf -> {alias: api_key}. Empty dict if absent."""
    out = {}
    try:
        with open(KEYS_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                alias, key = line.split("=", 1)
                out[alias.strip()] = key.strip()
    except FileNotFoundError:
        pass
    return out

def load_ccr_providers():
    """Crew's CCR 3 provider map -> list of {name, models[], api_key}."""
    try:
        with open(CCR_CFG) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    return cfg.get("Providers") or cfg.get("providers") or []

def run_crew(args, timeout=10):
    """Exec `crew <args...>` with shell=False (never string-built). Returns (stdout, err|None)."""
    try:
        p = subprocess.run([CREW_BIN, *args], capture_output=True, text=True,
                           timeout=timeout, shell=False)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        return None, f"crew exec failed: {e}"
    if p.returncode != 0:
        return None, (p.stderr or p.stdout or f"crew exited {p.returncode}").strip()
    return p.stdout, None

def calibrate_model_window(model, window, source="upstream-error"):
    """Write/refresh one model line in model-windows.conf. Idempotent, thread-safe.
    Returns True when the file changed."""
    if not model or not window:
        return False
    m = (model or "").split("/")[-1].lower()
    if not m:
        return False
    with _CALIB_LOCK:
        try:
            lines = []
            if os.path.isfile(MW_CONF):
                with open(MW_CONF, encoding="utf-8") as f:
                    lines = f.read().splitlines()
            best_idx, best_len = -1, -1
            for i, ln in enumerate(lines):
                s = ln.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k = s.split("=", 1)[0].strip()
                if k and (k == _mw_conf_pattern(model) or k in m) and len(k) > best_len:
                    best_idx, best_len = i, len(k)
            stamp = f"   # auto-calibrated {time.strftime('%Y-%m-%d')} ({source})"
            if best_idx >= 0:
                cur_val = lines[best_idx].split("=", 1)[1].split("#")[0].strip()
                try:
                    if int(cur_val) == window:
                        return False
                except ValueError:
                    pass
                key = lines[best_idx].split("=", 1)[0].strip()
                lines[best_idx] = f"{key}={window}{stamp}"
            else:
                lines.append(f"{_mw_conf_pattern(model)}={window}{stamp}")
            tmp = MW_CONF + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            os.replace(tmp, MW_CONF)
            log.info("[ctx-calibrate] %s -> %d tokens (%s) 写入 %s", m, window, source, MW_CONF)
            return True
        except Exception as e:
            log.warning("[ctx-calibrate] 写 %s 失败: %s", MW_CONF, e)
            return False

def maybe_calibrate_from_error(model, body_bytes, req_body=None):
    """Called on a translated prompt-too-long error. Upstream-provided number wins;
    otherwise fall back to our own evidence (user insight: proxy knows what worked):
    - max successful input for this model (stats) = upper bound
    - rejected request's estimated tokens = lower bound
    Take floor(lower, 10k) — a too-small window only triggers compaction earlier,
    which is safe; a too-large one deadlocks the session (the bug we're fixing)."""
    w = extract_window_from_error(body_bytes)
    if w:
        calibrate_model_window(model, w, "upstream-error")
        return
    lower = estimate_input_tokens(req_body)
    upper = STATS.max_input_for(model) if STATS else 0
    if lower > 50000:
        v = (lower // 10000) * 10000
        src = f"stats-bounds lower≈{lower} upper={upper}"
        calibrate_model_window(model, v, src)
    elif upper:
        calibrate_model_window(model, (upper * 11) // 10, f"stats-upper={upper}")


if __name__ == "__main__":
    main()



# ── /usage self-service page (per-key token usage; pure-canvas chart, no libs) ─────
USAGE_HTML = """<!doctype html><html><head><meta charset=utf-8>
<title>crew · 我的 token 用量</title>
<style>
 body{background:#0e1116;color:#c7d0da;font:13px/1.5 -apple-system,Segoe UI,monospace;margin:0;padding:20px}
 .bar{display:flex;gap:8px;align-items:center;margin-bottom:16px}
 input,button{background:#161b22;color:#c7d0da;border:1px solid #30363d;border-radius:6px;padding:6px 10px;font:inherit}
 button{cursor:pointer} .dim{color:#6b7684}
 #totals{display:flex;gap:14px;margin:14px 0} .tk{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:10px 14px}
 .tk .v{font-size:20px;font-weight:600} .tk .k{color:#6b7684;font-size:11px}
 #daily{display:flex;gap:6px;align-items:flex-end;height:110px;margin:12px 0}
 .dcol{display:flex;flex-direction:column;align-items:center;font-size:10px}
 .dbarwrap{display:flex;align-items:flex-end;height:82px} .dbar{width:16px;background:#3b6ea5;border-radius:2px 2px 0 0}
 .dday{color:#6b7684} #chartWrap{position:relative} canvas{width:100%;height:220px;display:block}
 #tokenTip{position:absolute;display:none;background:#0b0e13;border:1px solid #30363d;border-radius:6px;padding:6px 8px;font-size:11px;pointer-events:none}
 #health{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}
 .hk{background:#161b22;border:1px solid #21262d;border-radius:6px;padding:5px 9px;font-size:12px}
 .hk .st{font-weight:600} .hk.ok .st{color:#4ec98a} .hk.bad .st{color:#e5534b}
 .pill{padding:1px 8px;border-radius:10px;font-size:11px}
 .pill.live,.pill.healthy{background:#132e1a;color:#4ec98a}
 .pill.fail,.pill.tripped{background:#3a1416;color:#e5534b}
 .pill.resumable{background:#1c2330;color:#6cf}
 .pill.new{background:#2b2416;color:#d29922}
 #admin{margin-top:26px;border-top:1px solid #21262d;padding-top:16px;display:none}
 #admin h3{margin:16px 0 6px;font-size:13px;color:#8b95a3}
 table{border-collapse:collapse;width:100%;font-size:12px} th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #1a1e26}
 th{color:#6b7684;font-weight:500} .danger{color:#e5534b;border-color:#5a2620}
 .row{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:6px 0}
 h1{font-size:22px;margin:0 0 2px;letter-spacing:.5px} h1 .sub{font-size:12px;color:#6b7684;font-weight:400}
 #intro{margin:18px 0;max-width:760px} #intro img{max-width:100%;border:1px solid #21262d;border-radius:8px}
 #intro .feat{color:#9aa4af;margin:8px 0} code{background:#161b22;border:1px solid #21262d;border-radius:4px;padding:1px 6px} a{color:#6cf}
 .wrap{max-width:860px;margin:0 auto}
 .card{background:#12161c;border:1px solid #21262d;border-radius:12px;padding:18px;margin:16px 0}
 .quick pre{background:#0b0e13;border:1px solid #21262d;border-radius:8px;padding:10px 12px;overflow:auto;font-size:12px;color:#b8c2cd}
 .hero{text-align:center;margin:10px 0} .hero img{max-width:100%;border-radius:12px;border:1px solid #21262d}
 .authbox{display:flex;flex-direction:column;gap:10px;align-items:center;margin:14px 0}
 .authbox .line{display:flex;gap:8px;flex-wrap:wrap;justify-content:center}
 #regmsg{font-size:12px;max-width:640px;margin:0 auto;text-align:center}
 #regmsg pre{text-align:left;white-space:pre-wrap;color:#e5534b;background:#1a1113;border:1px solid #5a2620;border-radius:6px;padding:8px}
 .adbox{border-top:1px solid #21262d;margin-top:30px;padding-top:8px}
 #dashbar{display:none;align-items:center;gap:12px;flex-wrap:wrap;background:#12161c;border:1px solid #21262d;border-radius:10px;padding:10px 14px;margin:8px 0 4px}
 #dashbar .who{font-weight:600} #dashbar select{background:#161b22;color:#c7d0da;border:1px solid #30363d;border-radius:6px;padding:5px 8px}
 #dashview{display:none}
</style></head><body>
<div class=wrap>

<div id=landing>
<div class="card quick">
 <h3 style="margin-top:0">🚀 快速接入本网关</h3>
 <p class=feat>把本机地址当作 Anthropic API endpoint，用你的 key 直接发请求：</p>
 <pre>ANTHROPIC_BASE_URL=http://__CREW_ADDR__
ANTHROPIC_API_KEY=&lt;你的 key&gt;
# 或直接 curl:
curl http://__CREW_ADDR__/v1/messages -H "x-api-key: &lt;你的 key&gt;" \\
  -H "content-type: application/json" \\
  -d '{"model":"GLM-5.2","max_tokens":256,"messages":[{"role":"user","content":"hi"}]}'</pre>
 <p class=feat>还没有 key？下面 <b>注册你的 key</b>，测试通过即可加入共享池并使用。</p>
</div>

<div class=card>
 <div class=hero><img src="/crew-proxy-hero.png" alt="crew-proxy"></div>
 <div class=authbox>
  <div class=line>
   <input id=key type=password placeholder="输入你的 key 登录" size=30>
   <button id=login>登录</button>
  </div>
  <div class=line>
   <input id=regkey type=password placeholder="注册：粘贴你的真实 key（会用 GLM 实测）" size=42>
   <input id=regerp placeholder="你的 erp 工号（必填）" size=16>
   <button id=reg>注册我的 key</button>
  </div>
  <div id=regmsg></div>
  <span id=meta class=dim></span>
 </div>
</div>
</div>

<div id=dashbar>
 <span class=who id=who></span>
 <span id=adminview style=display:none>查看: <select id=viewsel></select></span>
 <span id=dmeta class=dim></span>
 <button id=logout style=margin-left:auto>退出</button>
</div>

<div id=dashview>
<div id=totals></div>
<div id=svcStatus></div>
<div id=pmeta class=dim style="margin:4px 0 10px;font-size:12px"></div>
<div id=health></div>
<div id=latencyPanel></div>
<div class=card id=sessCard>
 <h3 style="margin:0 0 6px;font-size:13px;color:#8b95a3">运行中会话 <span class=dim style="font-weight:400">· crew ls --json</span></h3>
 <div id=sess-err class=dim style="font-size:12px"></div>
 <table id=sessions><thead><tr><th>name</th><th>status</th><th>model</th><th>key</th><th>dir</th><th></th></tr></thead><tbody></tbody></table>
</div>
<div class=card>
 <h3 style="margin:0 0 6px;font-size:13px;color:#8b95a3">最近请求 <span class=dim style="font-weight:400">· 最近 100 条</span></h3>
 <div id=logs style="max-height:280px;overflow:auto"><table><thead><tr><th>t</th><th>model</th><th>key</th><th>status</th><th>latency</th><th>tokens</th><th></th></tr></thead><tbody></tbody></table></div>
</div>
<div id=daily></div>
<div id=chartWrap><canvas id=tokenChart></canvas><div id=tokenTip></div></div>
<div id=admin>
 <h3>Key 池(真实后端 key)</h3>
 <div id=pool></div>
 <div class=row>
  <input id=ak-key placeholder="新 key" size=20><input id=ak-model placeholder="模型名" size=16>
  <input id=ak-base placeholder="base_url (https://…)" size=30>
  <input id=ak-alias placeholder="alias(内部名)" size=12>
  <button id=ak-add>加 key</button>
 </div>
 <h3>模型策略(优先级顺序)</h3>
 <div id=policy></div>
 <h3>登录表(门票)</h3>
 <div id=logins></div>
 <div class=row>
  <input id=lg-login placeholder="login key" size=16><input id=lg-maps placeholder="maps_to alias" size=12>
  <input id=lg-models placeholder="allow_models(空格分隔,空=全部)" size=24>
  <input id=lg-erp placeholder="erp" size=10><label><input id=lg-admin type=checkbox> admin</label>
  <button id=lg-add>加/改登录</button>
 </div>
 <h3>新注册者默认可用模型</h3>
 <div class=row>
  <input id=ra-list placeholder="空格分隔的模型名(空=重置为内置默认)" size=44>
  <button id=ra-save>保存默认</button>
  <span id=ra-msg class=dim></span>
 </div>
 <h3>应急会话(一键起 detached tmux claude 会话)</h3>
 <div class=row>
  <select id=em-key></select><select id=em-model></select>
  <button id=em-go>一键起会话</button>
 </div>
 <div id=em-msg class=dim style="font-size:12px"></div>
</div>
</div>

<dialog id=editdlg style="background:#161b22;color:#c7d0da;border:1px solid #30363d;border-radius:10px;padding:18px;min-width:320px">
 <form method=dialog>
  <h3 id=edittitle style="margin:0 0 10px;font-size:14px">edit session</h3>
  <div style="font-size:12px;color:#8b95a3">model</div><input id=edit-model style="width:100%;background:#0e1116;border:1px solid #30363d;border-radius:6px;padding:5px;margin:4px 0 10px">
  <div style="font-size:12px;color:#8b95a3">key (alias, empty to clear)</div><input id=edit-key style="width:100%;background:#0e1116;border:1px solid #30363d;border-radius:6px;padding:5px;margin:4px 0 10px">
  <div style="display:flex;gap:8px;justify-content:flex-end">
   <button value=cancel>cancel</button><button id=edit-save value=save>save</button>
  </div>
 </form>
</dialog>

<div class="card adbox" id=intro>
 <h3 style="margin-top:0">想要更强的接入方式？用 crew 🐧</h3>
 <img src="/crew-demo.gif" alt="crew demo" loading=lazy>
 <p class=feat><b>crew</b> —— 一个人同时开多个 Claude Code 会话、随时切换模型、让不同模型互相对话协作；共享 key 池自动故障切换、限额自动摘除恢复。比直接改 base_url 多了：多会话编排、模型热切换、跨模型协作。</p>
 <p class=feat>用 CCR 的话，把 config 里的 <code>api_base_url</code> 改成 <code>http://__CREW_ADDR__</code> 即可；更推荐装 crew 后配一个 backend 指向本网关。</p>
 <p class=feat>仓库：<code>git@coding.jd.com:olsd/claude-crew.git</code>（内网） / <code>git@github.com:Barcelona16/claude-crew.git</code>（外网）</p>
</div>
</div>
<script>
let KEY=sessionStorage.getItem('crewKey')||'', VIEW='', SELFLOGIN='', _d=null, _geom=null;
const $=s=>document.querySelector(s);
function fmtK(n){if(n==null)return '—';if(n>=1e6)return (n/1e6).toFixed(2)+'M';if(n>=1e3)return (n/1e3).toFixed(0)+'k';return String(Math.round(n));}
function fmtClock(ms){const d=new Date(ms),p=x=>String(x).padStart(2,'0');return p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
async function load(){
  if(!KEY)return;
  let url='/api/usage?days=7'+(VIEW?('&key='+encodeURIComponent(VIEW)):'');
  let r;try{r=await fetch(url,{headers:{'x-api-key':KEY}});}catch(e){$('#regmsg').innerHTML='<span style=color:#e5534b>网络错误，无法连接网关</span>';logout(false,true);return;}
  if(r.status===401){logout(true,true);$('#regmsg').innerHTML='<span style=color:#e5534b>❌ 登录失败：key 无效或未注册。请检查后重试，或用下方「注册我的 key」先注册。</span>';return;}
  const d=await r.json();_d=d;
  if(!VIEW)SELFLOGIN=d.login;
  // logged in -> switch from landing to dashboard view
  $('#landing').style.display='none';$('#dashbar').style.display='flex';$('#dashview').style.display='block';
  $('#who').textContent=(d.isAdmin?'管理员 · ':'')+'当前查看: '+d.login;
  $('#dmeta').textContent='近 '+(d.windowH/24)+' 天 · '+d.buckets.length+' 点';
  renderTotals(d);renderDaily(d);draw();
  renderLatency(d.latency);
  renderSvcStatus(d.health);
  loadHealth();
  refreshOps();
  $('#adminview').style.display=d.isAdmin?'inline':'none';
  $('#admin').style.display=d.isAdmin?'block':'none';
  if(d.isAdmin){populateViewsel();loadAdmin();renderEmergency(d.emergency);}
}
function populateViewsel(){
  const sel=$('#viewsel');const logins=(_d&&_d.logins)||[];const orphans=new Set((_d&&_d.orphan_logins)||[]);
  sel.innerHTML='<option value="">我自己('+esc(SELFLOGIN||'')+')</option><option value="__all__">全部人合计</option>'+
    logins.map(l=>'<option value="'+esc(l)+'">'+esc(l)+(orphans.has(l)?(l==='direct'?' · 直连/未走网关':' · 未登录(孤儿)'):'')+'</option>').join('');
  sel.value=VIEW;
}
function logout(clear,keepmsg){if(clear!==false){KEY='';sessionStorage.removeItem('crewKey');}VIEW='';_d=null;
  $('#landing').style.display='';$('#dashbar').style.display='none';$('#dashview').style.display='none';
  if(clear!==false)$('#key').value='';$('#meta').textContent='';if(!keepmsg)$('#regmsg').textContent='';}
async function loadHealth(){
  let r;try{r=await fetch('/api/health',{headers:{'x-api-key':KEY}});}catch(e){return;}
  if(!r.ok)return;const d=await r.json();
  $('#health').innerHTML=(d.pool||[]).map(p=>{const bad=p.state!=='healthy';
    return '<div class="hk '+(bad?'bad':'ok')+'"><span class=dim>'+esc(p.key_masked)+'</span> <span class=st>'+(bad?('异常'+(p.cooldown_left?' '+p.cooldown_left+'s':'')):'正常')+'</span></div>';
  }).join('')||'<span class=dim>池子为空</span>';
}
async function aget(path){const r=await fetch(path,{headers:{'x-api-key':KEY}});return r.ok?r.json():null;}
async function apost(path,obj){const r=await fetch(path,{method:'POST',headers:{'x-api-key':KEY,'Content-Type':'application/json'},body:JSON.stringify(obj)});return {ok:r.ok,body:await r.json().catch(()=>({}))};}
async function loadAdmin(){
  const kd=await aget('/api/keys');
  if(!kd)return;
  $('#pool').innerHTML='<table><tr><th>key</th><th>模型</th><th>策略</th><th>状态</th><th></th></tr>'+
    (kd.pool||[]).map(p=>'<tr><td>'+esc(p.key_masked)+'</td><td>'+esc((p.models||[]).join(', '))+
      '</td><td>'+esc(Object.keys(p.in_policy||{}).join(', '))+'</td><td>'+(p.state!=='healthy'?'<span style=color:#e5534b>异常'+(p.cooldown_left?' '+p.cooldown_left+'s':'')+'</span>':'<span style=color:#4ec98a>正常</span>')+
      '</td><td><button class=danger data-del="'+esc(p.alias)+'">删</button></td></tr>').join('')+'</table>';
  document.querySelectorAll('#pool [data-del]').forEach(b=>b.onclick=async()=>{
    if(!confirm('删除 key '+b.dataset.del+'?'))return;
    const r=await apost('/api/ccr/provider',{alias:b.dataset.del,delete:true});
    if(!r.ok&&r.body.error){if(confirm(r.body.error+'\\n强制删除?')){await apost('/api/ccr/provider',{alias:b.dataset.del,delete:true,force:true});}}
    loadAdmin();loadHealth();});
  const mba=kd.masked_by_alias||{};
  const lbl=a=>(mba[a]||'sk-…')+'('+a+')';
  // The viewed user prefers their own maps_to key at call time (affinity). Show that as a
  // per-row hint, but keep the EDITABLE input at the true STORED order so saving never
  // accidentally persists the per-user reordering.
  const curLogin=(_d&&_d.login)||'';
  const curEntry=(kd.logins||[]).find(x=>x.login===curLogin);
  const prefer=curEntry?curEntry.maps_to:'';
  const hint=al=>prefer&&al.includes(prefer)?' <span class=dim style="font-size:11px">· 实际优先 '+esc(mba[prefer]||prefer)+'</span>':'';
  $('#policy').innerHTML='<table><tr><th>模型</th><th>key 优先级顺序（存储/共享兜底）</th><th></th></tr>'+
    Object.entries(kd.policy||{}).map(([m,al])=>'<tr><td>'+esc(m)+'</td><td><input data-pm="'+esc(m)+'" value="'+esc(al.map(lbl).join(' '))+'" size=40>'+hint(al)+'</td><td><button data-ps="'+esc(m)+'">存</button></td></tr>').join('')+'</table>'+
    '<div class=dim style="font-size:11px;margin-top:4px">输入框是存储的共享兜底顺序；调用时该用户自己的 key 会被自动提到最前（affinity，见「实际优先」）。保存按括号里的 alias 生效。</div>';
  document.querySelectorAll('#policy [data-ps]').forEach(b=>b.onclick=async()=>{
    const inp=document.querySelector('#policy [data-pm="'+CSS.escape(b.dataset.ps)+'"]');
    // extract the alias from each "masked(alias)" token; fall back to the raw token
    const aliases=inp.value.trim().split(/\\s+/).filter(Boolean).map(t=>{const mt=t.match(/\\(([^)]+)\\)\\s*$/);return mt?mt[1]:t;});
    const r=await apost('/api/policy',{model:b.dataset.ps,aliases:aliases});
    if(!r.ok)alert(r.body.error||'保存失败');
    loadAdmin();});
  $('#logins').innerHTML='<table><tr><th>login</th><th>maps_to</th><th>allow_models</th><th>erp</th><th>admin</th><th></th></tr>'+
    (kd.logins||[]).map((a,i)=>'<tr><td title="'+esc(a.login)+'">'+esc(a.login.length>16?a.login.slice(0,6)+'…'+a.login.slice(-4):a.login)+'</td><td>'+esc(a.maps_to)+'</td><td>'+esc((a.allow_models||[]).join(' '))+'</td><td>'+esc(a.erp||'')+'</td><td>'+(a.admin?'✓':'')+'</td><td><button data-le="'+i+'">改</button> <button class=danger data-dl="'+esc(a.login)+'">删</button></td></tr>').join('')+'</table>';
  window._logins=kd.logins||[];
  document.querySelectorAll('#logins [data-le]').forEach(b=>b.onclick=()=>{
    const a=window._logins[+b.dataset.le];if(!a)return;
    $('#lg-login').value=a.login;$('#lg-maps').value=a.maps_to;$('#lg-models').value=(a.allow_models||[]).join(' ');
    $('#lg-erp').value=a.erp||'';$('#lg-admin').checked=!!a.admin;
    $('#lg-login').scrollIntoView({block:'center'});$('#lg-login').focus();});
  document.querySelectorAll('#logins [data-dl]').forEach(b=>b.onclick=async()=>{
    if(!confirm('删除登录 '+b.dataset.dl+'?'))return;
    await apost('/api/gateway/auth',{login:b.dataset.dl,delete:true});loadAdmin();});
  const ra=await aget('/api/register-allow');
  if(ra&&$('#ra-list')){$('#ra-list').value=(ra.allow||[]).join(' ');
    $('#ra-list').placeholder='空格分隔(空=重置为内置默认: '+(ra.builtin||[]).join(' ')+')';}
}
$('#ra-save').onclick=async()=>{
  const models=$('#ra-list').value.trim().split(/\\s+/).filter(Boolean);
  const r=await apost('/api/register-allow',{allow:models});
  if(!r.ok){$('#ra-msg').textContent=r.body.error||'保存失败';}
  else{$('#ra-msg').textContent='已保存: '+((r.body.allow||[]).join(' ')||'(内置默认)');loadAdmin();}
};
let _emKeys=[];
function renderEmergency(em){
  _emKeys=(em&&em.keys)||[];
  $('#em-key').innerHTML='<option value="">选 key…</option>'+_emKeys.map(k=>'<option value="'+esc(k.alias)+'">'+esc(k.alias)+'</option>').join('');
  $('#em-model').innerHTML='';$('#em-msg').textContent='';
}
$('#em-key').onchange=()=>{
  const k=_emKeys.find(x=>x.alias===$('#em-key').value);
  $('#em-model').innerHTML='<option value="">选模型…</option>'+((k&&k.models)||[]).map(m=>'<option value="'+esc(m)+'">'+esc(m)+'</option>').join('');
};
$('#em-go').onclick=async()=>{
  const key=$('#em-key').value,model=$('#em-model').value;
  const msg=$('#em-msg');
  if(!key||!model){msg.innerHTML='<span style="color:#e5534b">先选 key 和模型</span>';return;}
  const btn=$('#em-go');btn.disabled=true;msg.textContent='起会话中(约几秒,spawn detached tmux)…';
  const r=await apost('/api/emergency-session',{key,model});
  btn.disabled=false;
  if(r.ok&&r.body.ok){msg.innerHTML='<span style="color:#4ec98a">✅ 已起会话: <b>'+esc(r.body.session_name)+'</b></span> <span class=dim>· 接入: <code>crew attach '+esc(r.body.session_name)+'</code></span>';}
  else{msg.innerHTML='<span style="color:#e5534b">❌ '+esc(r.body.error||'起会话失败')+'</span>';}
};
$('#ak-add').onclick=async()=>{
  const r=await apost('/api/ccr/provider',{alias:$('#ak-alias').value.trim(),key:$('#ak-key').value.trim(),model:$('#ak-model').value.trim(),base_url:$('#ak-base').value.trim()});
  if(!r.ok)alert(r.body.error||'失败');else{$('#ak-key').value=$('#ak-alias').value='';loadAdmin();}
};
$('#lg-add').onclick=async()=>{
  const models=$('#lg-models').value.trim().split(/\\s+/).filter(Boolean);
  const r=await apost('/api/gateway/auth',{login:$('#lg-login').value.trim(),maps_to:$('#lg-maps').value.trim(),allow_models:models,erp:$('#lg-erp').value.trim(),admin:$('#lg-admin').checked});
  if(!r.ok)alert(r.body.error||'失败');else{$('#lg-login').value='';loadAdmin();}
};
function renderTotals(d){const T=d.totals||{};$('#totals').innerHTML=[
  {v:fmtK(T.newTokens),k:'新增消耗(近7天)'},{v:fmtK(T.turns),k:'请求数'},
  {v:fmtK(T.perReqNew),k:'单次均 token'},{v:(T.days!=null?T.days:'—'),k:'天数'}
].map(c=>'<div class=tk><div class=v>'+c.v+'</div><div class=k>'+c.k+'</div></div>').join('');}
function renderDaily(d){const days=d.daily||[];if(!days.length){$('#daily').innerHTML='<span class=dim>暂无数据</span>';return;}
  const mx=Math.max.apply(null,days.map(x=>x.newTokens||0).concat([1]));
  $('#daily').innerHTML=days.map(x=>{const h=Math.max(2,Math.round((x.newTokens||0)/mx*80));
    return '<div class=dcol title="'+esc(x.day)+' 新增 '+fmtK(x.newTokens)+' · '+fmtK(x.turns)+' 请求"><div>'+fmtK(x.newTokens)+'</div><div class=dbarwrap><div class=dbar style=height:'+h+'px></div></div><div class=dday>'+esc(x.day.slice(5))+'</div></div>';
  }).join('');}
function fmtMs(v){if(v==null)return '—';return v>=1000?(v/1000).toFixed(1)+'s':Math.round(v)+'ms';}
function renderLatency(lat){
  const el=$('#latencyPanel');if(!el)return;
  const rows=(lat&&lat.models)||[];
  if(!rows.length){el.innerHTML='<div class=card><h3 style="margin:0 0 6px;font-size:13px;color:#8b95a3">模型延迟分布(近 '+(lat&&lat.windowH?lat.windowH:24)+'h)</h3><span class=dim>暂无延迟数据</span></div>';return;}
  el.innerHTML='<div class=card><h3 style="margin:0 0 6px;font-size:13px;color:#8b95a3">模型延迟分布(近 '+(lat.windowH||24)+'h)<span class=dim style="font-weight:400"> · 按请求数排序;分位来自成功请求的采样</span></h3>'+
  '<table><tr><th>模型</th><th>请求数</th><th>成功率</th><th>avg</th><th>P50</th><th>P90</th><th>P99</th><th>TTFT P50/P90/P99</th></tr>'+
  rows.map(m=>{const sr=(m.successRate==null?'—':(m.successRate*100).toFixed(0)+'%');
    const ttft=(m.ttftp50Ms==null)?'—':(fmtMs(m.ttftp50Ms)+' / '+fmtMs(m.ttftp90Ms)+' / '+fmtMs(m.ttftp99Ms));
    return '<tr><td>'+esc(m.model)+'</td><td>'+m.n+'</td><td>'+sr+'</td><td>'+fmtMs(m.avgMs)+'</td><td>'+fmtMs(m.p50Ms)+'</td><td>'+fmtMs(m.p90Ms)+'</td><td>'+fmtMs(m.p99Ms)+'</td><td class=dim>'+ttft+'</td></tr>';
  }).join('')+'</table></div>';
}
function renderSvcStatus(h){
  const el=$('#svcStatus');if(!el)return;
  const ok=v=>v?'<span style="color:#4ec98a">✓</span>':'<span style="color:#e5534b">✗</span>';
  el.innerHTML='<div style="margin:4px 0 10px;font-size:12px">服务状态: proxy '+ok(h&&h.proxy)+' <span class=dim>/</span> CCR '+ok(h&&h.ccr)+(h&&h.ccr?'':' <span class=dim>(3456 无响应,转发会失败)</span>')+'</div>';
}
function draw(){
  const cv=$('#tokenChart');const dpr=window.devicePixelRatio||1;
  const W0=cv.clientWidth||800,H0=220;cv.width=W0*dpr;cv.height=H0*dpr;const g=cv.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W0,H0);
  const d=_d;if(!d||!d.buckets.length){_geom=null;return;}   // clear FIRST, then bail — an empty view must blank the chart, not keep the previous key's line
  const padL=52,padR=16,padT=10,padB=22,W=W0-padL-padR,H=H0-padT-padB,bs=d.buckets;
  const t0=bs[0].t,t1=bs[bs.length-1].t+(d.bucketMin||10)*60000,tspan=Math.max(1,t1-t0);
  let mx=1;bs.forEach(b=>{mx=Math.max(mx,b.newTokens||0);});
  const x=ms=>padL+(ms-t0)/tspan*W,y=v=>padT+H-(v/mx)*H;
  g.strokeStyle='#20252e';g.font='10px monospace';g.lineWidth=1;
  for(let i=0;i<=4;i++){const yy=padT+H-(i/4)*H;g.beginPath();g.moveTo(padL,yy);g.lineTo(padL+W,yy);g.stroke();g.textAlign='right';g.fillStyle='#7fa8c9';g.fillText(fmtK(mx*i/4),padL-4,yy+3);}
  g.fillStyle='#8b95a3';g.textAlign='center';for(let i=0;i<=5;i++){const tm=t0+tspan*i/5,xx=x(tm);g.strokeStyle='#1a1e26';g.beginPath();g.moveTo(xx,padT);g.lineTo(xx,padT+H);g.stroke();g.fillText(fmtClock(tm),xx,padT+H+14);}
  function line(color,key,w){g.strokeStyle=color;g.lineWidth=w;g.beginPath();bs.forEach((b,i)=>{const xx=x(b.t+(d.bucketMin||10)*30000),yy=y(b[key]||0);i?g.lineTo(xx,yy):g.moveTo(xx,yy);});g.stroke();}
  line('#6cf','inputSum',1.4);line('#e0a94f','outputSum',1.4);line('#8f8','newTokens',2);
  _geom={padL,W,t0,tspan};
}
document.addEventListener('mousemove',ev=>{const cv=$('#tokenChart'),tip=$('#tokenTip');if(!_d||!_geom)return;const r=cv.getBoundingClientRect();
  if(ev.clientX<r.left||ev.clientX>r.right||ev.clientY<r.top||ev.clientY>r.bottom){tip.style.display='none';return;}
  const tm=_geom.t0+(ev.clientX-r.left-_geom.padL)/_geom.W*_geom.tspan;let best=null,bd=1e18;
  _d.buckets.forEach(b=>{const dd=Math.abs(b.t-tm);if(dd<bd){bd=dd;best=b;}});if(!best){tip.style.display='none';return;}
  tip.innerHTML='<b>'+fmtClock(best.t)+'</b><br><span style=color:#8f8>新增</span> '+fmtK(best.newTokens)+'<br><span style=color:#6cf>in</span> '+fmtK(best.inputSum)+' · <span style=color:#e0a94f>out</span> '+fmtK(best.outputSum)+'<br>turns '+best.turns+' · 均 '+fmtK(best.perReqNew);
  tip.style.display='block';tip.style.left=(ev.clientX-r.left+12)+'px';tip.style.top=(ev.clientY-r.top+8)+'px';});
window.addEventListener('resize',()=>{if(_d)draw();});
$('#login').onclick=()=>{KEY=$('#key').value.trim();VIEW='';if(!KEY)return;sessionStorage.setItem('crewKey',KEY);SELFLOGIN='';load();};
$('#logout').onclick=()=>logout(true);
$('#viewsel').onchange=()=>{VIEW=$('#viewsel').value;load();};
$('#reg').onclick=async()=>{
  const k=$('#regkey').value.trim();const erp=$('#regerp').value.trim();const m=$('#regmsg');const btn=$('#reg');
  if(!k){m.textContent='请先粘贴你的 key';return;}
  if(!erp){m.innerHTML='<span style=color:#e5534b>请填写你的 erp 工号</span>';return;}
  btn.disabled=true;m.textContent='正在用 GLM 实测你的 key…（上游繁忙时会自动重试几次）';
  let r,body;try{r=await fetch('/api/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key:k,erp:erp})});body=await r.json();}catch(e){m.textContent='网络错误: '+e;btn.disabled=false;return;}
  btn.disabled=false;
  if(r.ok&&body.ok){
    m.innerHTML='<span style=color:#4ec98a>✅ 注册成功!</span> 你的 key ('+esc(body.key_masked)+') 已登记。'+
      '<br>你当前可调用的模型: <b>'+esc((body.allow_models||[]).join(', '))+'</b>(需要更多模型找管理员开通)。'+
      '<br>现在就能用它登录看用量,或作为 x-api-key 发请求到本网关。接入方式见上方「快速接入」与下方 crew 介绍。';
    $('#key').value=k;KEY=k;sessionStorage.setItem('crewKey',KEY);load();
  }else if(body.transient){
    m.innerHTML='<span style=color:#e0a94f>⏳ '+esc(body.error||'上游繁忙,请稍后重试')+'</span>'+
      '<br><span class=dim>这不是你的 key 的问题,是上游服务器当前并发已满。点「注册我的 key」再试一次即可。</span>';
  }else{
    m.innerHTML='<span style=color:#e5534b>❌ '+esc(body.error||'注册失败')+'</span>'+
      (body.detail?'<pre>'+esc(body.detail)+'</pre>':'');
  }
};
if(KEY){$('#key').value=KEY;load();}
setInterval(()=>{if(KEY)load();},30000);
// -- v4.0.1 dashboard merge: proxy meta / sessions / recent requests --
function pill(s){return '<span class="pill '+esc(s)+'">'+esc(s)+'</span>'}
let _opsBusy=false;
async function refreshOps(){
  if(_opsBusy)return;_opsBusy=true;
  try{
    const [st,ss,ll]=await Promise.allSettled([
      fetch('/api/status').then(r=>r.ok?r.json():null),
      fetch('/api/sessions').then(r=>r.ok?r.json():null),
      fetch('/api/logs?n=100').then(r=>r.ok?r.json():null)
    ]);
    const pm=$('#pmeta');
    if(st.status==='fulfilled'&&st.value){
      const s=st.value;
      pm.textContent='proxy :'+s.port+' -> '+esc(s.ccr_url||'?')+'  ·  trip@'+s.fail_n+'  cooldown '+(s.cooldown!=null?s.cooldown+'s':'-');
    }else{pm.textContent='proxy status unavailable';}
    const se=$('#sess-err');
    if(ss.status==='fulfilled'&&ss.value){
      const d=ss.value;
      se.textContent=d.error||'';
      $('#sessions tbody').innerHTML=(d.sessions||[]).map(x=>
        `<tr><td>${esc(x.name)}</td><td>${pill(x.status)}</td><td>${esc(x.model)}</td><td>${esc(x.key)}</td>
        <td class=dim title="${esc(x.dir)}">${esc(x.dir)}</td>
        <td><button onclick="copyCmd('${esc(x.name)}','${esc(x.model)}','${esc(x.key)}')">copy</button>
            <button onclick="editSess('${esc(x.name)}','${esc(x.model)}','${esc(x.key)}')">edit</button>
            <button class=danger onclick="killSess('${esc(x.name)}')">kill</button></td></tr>`).join('')
        ||'<tr><td class=dim colspan=6>no sessions</td></tr>';
    }else{se.textContent='sessions unavailable';}
    if(ll.status==='fulfilled'&&ll.value){
      const l=ll.value;
      $('#logs tbody').innerHTML=(l.logs||[]).map(x=>{
        const tm=x.ts?new Date(x.ts*1000).toLocaleTimeString([],{hour12:false}):x.t+'s';
        const err=x.err?('<span style="color:#e5534b" title="'+esc(x.err)+'">'+esc(x.err.slice(0,80))+'</span>'):'';
        return `<tr><td class=dim>${tm}</td><td>${esc(x.model)}</td><td>${esc(x.alias)}</td>
        <td>${x.ok?pill('healthy'):'<span style="color:#e5534b">'+esc(x.status)+'</span>'}</td>
        <td class=dim>${x.ms!=null?x.ms+'ms':'-'}</td>
        <td class=dim>${(x.in_tok!=null||x.out_tok!=null)?fmtK(x.in_tok)+'/'+fmtK(x.out_tok):'-'}</td>
        <td class=dim>${x.failover?'failover ':''}${x.forced?'forced ':''}${err}</td></tr>`}).join('')
        ||'<tr><td class=dim colspan=7>no requests yet</td></tr>';
    }
  }finally{_opsBusy=false;}
}
let editName=null;
function copyCmd(name,model,key){
  let cmd='crew '+name;
  if(model&&model!=='-'&&model!=='default')cmd+=' --model '+model;
  if(key&&key!=='-')cmd+=' --key '+key;
  navigator.clipboard.writeText(cmd).then(()=>{$('#pmeta').textContent='copied: '+cmd;})
    .catch(()=>{prompt('copy this command:',cmd);});
}
function editSess(name,model,key){
  editName=name;$('#edittitle').textContent='edit '+name;
  $('#edit-model').value=model==='-'?'':model;$('#edit-key').value=key==='-'?'':key;
  $('#editdlg').showModal();
}
$('#edit-save').onclick=async()=>{
  await apost('/api/session/config',{name:editName,model:$('#edit-model').value.trim(),key:$('#edit-key').value.trim()});
  setTimeout(refreshOps,200);
};
async function killSess(name){
  if(!confirm('kill session "'+name+'"? (removes tmux + crew state; transcript kept)'))return;
  const r=await apost('/api/session/kill',{name});
  if(!r.ok&&r.body&&r.body.error)alert(r.body.error);
  setTimeout(refreshOps,300);
}
setInterval(()=>{if(KEY)refreshOps();},15000);
</script></body></html>"""




def _ccr_tcp_healthy(timeout=1.0):
    """Cheap CCR liveness probe: open a TCP connection to CCR's listen port.
    connect-success == healthy; 1s cap so a wedged CCR never blocks a request thread.
    The proxy itself is implicitly healthy (this very response is served by it)."""
    try:
        u = urllib.parse.urlparse(CCR_URL)
        host = u.hostname or "127.0.0.1"
        port = u.port or 3456
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except (OSError, ValueError):
        return False


def _fault_for_status(code):
    """HTTP 状态 → 内部故障短名(日志侧分类用;401/403=key 问题,400=路由/请求问题,
    5xx/429=上游繁忙)。连接类错误由调用方自己定 hint(如 ccr-down / stream-broken)。"""
    if code in (401, 403):
        return "upstream-401"
    if code == 400:
        return "upstream-400"
    if code in (429, 500, 502, 503, 504):
        return "upstream-5xx"
    return "unknown"


def classify_error(status, hint, detail=""):
    """统一报错分层标注(2026-10-28,#13):给 proxy 产生的错误加 [layer][fault] 标签 +
    可操作建议,同一文案同时进 error body 与 proxy 日志 —— 两侧一致,会话侧(CC 报错弹窗)
    与日志侧都能一眼定位链路层级。upstream 透传错误(CCR/gateway 回的 400/401/5xx)
    保持 body 原样转发、只在此做日志侧分类,不重写上游文案(避免破坏 claude 的错误解析)。
    status: HTTP 状态码或 "ERR";hint: 内部故障短名(见 _FAULT 表);detail: 附加现场信息。"""
    _FAULT = {
        "ccr-down": ("[proxy][ccr-down]",
                     "crew-proxy 连不上 CCR(:3456)。下一步: 运行 crew doctor;重启 com.claudecrew.ccr "
                     "(launchctl kickstart -k gui/$(id -u)/com.claudecrew.ccr) 后重试。"),
        "joycode-down": ("[proxy][joycode-down]",
                         "CCR→joycode(:8765) 链路不通。下一步: 检查 :8765 是否在跑;重启 com.claudecrew.joycode。"),
        "no-key": ("[proxy][no-key]",
                   "keys.conf 里没有可用 key 别名路由该请求。下一步: crew keys 查看;crew addkey <key> <别名> 加 key。"),
        "no-provider": ("[proxy][no-provider]",
                        "CCR provider map 里没有能路由该模型的 provider。下一步: crew sync-models --key <别名>;"
                        "或 crew model-switch <model> <key>。"),
        "upstream-401": ("[proxy][upstream-401]",
                         "该 key 被上游拒绝(401/403):key 失效或未注册。下一步: 换 key(crew addkey <新key>)后重试。"),
        "upstream-400": ("[proxy][upstream-400]",
                         "上游拒绝了请求(400):模型路由/provider 状态问题。下一步: crew sync-models --key <别名>;"
                         "或 crew model-switch <model> <key>。"),
        "upstream-5xx": ("[proxy][upstream-5xx]",
                         "上游(CCR/joycode/gateway)5xx 或限流:服务繁忙或故障。下一步: crew doctor;查 proxy/CCR/joycode 日志。"),
        "breaker-open": ("[breaker][open]",
                         "熔断中:该 key 连续失败在冷却(cooldown)。下一步: 等冷却结束;确系上游故障先修上游。"),
        "all-failed": ("[breaker][all-failed]",
                       "所有可用 key 都失败(failover 耗尽,含熔断冷却)。下一步: 看最近一条上游错误定位根因;修好后重试。"),
        "stream-broken": ("[proxy][stream-broken]",
                          "流式响应中途断开(BrokenPipe/ConnectionReset/超时)。下一步: 重试请求;持续出现查上游日志。"),
        "unknown": ("[proxy][unknown]",
                    "未知错误,详见 proxy 日志。"),
    }
    tag, sug = _FAULT.get(hint, _FAULT["unknown"])
    msg = f"{tag} {sug}"
    if detail:
        msg = f"{msg} 详情: {detail}"
    return msg


def _emergency_key_models():
    """Admin-only dropdown data for the emergency-session form: [{alias, models}].
    models = real model names that alias can route = provider models whose api_key ==
    keys.conf[alias], unioned with models whose policy chain names the alias. Only
    alias + model names — no key material of any kind."""
    keys = load_keys()
    by_alias = {a: set() for a in keys}
    for p in load_ccr_providers():
        ak = p.get("api_key") or p.get("apiKey")
        for a, kv in keys.items():
            if ak == kv:
                by_alias[a].update(p.get("models") or [])
    for m, aliases in load_policy().items():
        for a in aliases:
            if a in by_alias:
                by_alias[a].add(m)
    return [{"alias": a, "models": sorted(by_alias[a])} for a in sorted(by_alias)]


def _run_crew_spawn(name, key, model, timeout=90):
    """Spawn `crew <name> --key <key> --model <model>` (detached tmux mode).
    Argument list only, shell=False — never a string, never shell=True. The proxy
    runs under launchd with a bare PATH (/usr/bin:/bin:...), so inject the homebrew /
    ~/.local/bin / ~/.npm-global/bin dirs where tmux, node and claude actually live.
    Returns (stdout, err|None)."""
    crew_bin = _find_crew_bin()
    env = os.environ.copy()
    extra = ["/opt/homebrew/bin",
             os.path.expanduser("~/.local/bin"),
             os.path.expanduser("~/.npm-global/bin")]
    env["PATH"] = os.pathsep.join([p for p in extra if os.path.isdir(p)] +
                                  [env.get("PATH", "/usr/bin:/bin")])
    try:
        p = subprocess.run([crew_bin, name, "--key", key, "--model", model],
                           capture_output=True, text=True, timeout=timeout,
                           shell=False, env=env)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        return None, "crew spawn failed: %s" % e
    if p.returncode != 0:
        return None, (p.stderr or p.stdout or "crew exited %d" % p.returncode).strip()
    return p.stdout, None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):  # silence default access log
        pass

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n) if n else b""

    def _fwd_headers(self):
        """Client headers minus hop-by-hop, with CCR 3 loopback auth.

        Client ``Authorization`` and ``x-api-key`` headers authenticate to
        crew-proxy, not CCR.  Replace them with the generated local CCR key so
        a selected crew key never leaks into the CCR control plane.
        """
        skip = {"host", "content-length", "connection", "transfer-encoding",
                "proxy-connection", "keep-alive"}
        out = {k: v for k, v in self.headers.items() if k.lower() not in skip}
        for name in tuple(out):
            if name.lower() in {"authorization", "x-api-key"}:
                del out[name]
        gateway_key = load_ccr_gateway_key()
        if gateway_key:
            out["Authorization"] = f"Bearer {gateway_key}"
            out["x-api-key"] = gateway_key
        return out

    def _send_err(self, code, msg):
        body = json.dumps({"error": {"message": msg, "type": "crew_proxy_error"}}).encode()
        # 客户端可能已断开(上游超时/用户 Ctrl-C 后重连),此时 send_response/end_headers/write
        # 都会抛 BrokenPipeError/ConnectionResetError。这类错误只说明"没人收错误了",
        # 不该再冒泡成 traceback 刷日志 —— 静默返回即可。
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_html(self, html):
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _render_dashboard(self):
        """Unified dashboard = USAGE_HTML with the quick-connect address filled
        from the request's Host (fallback: the server bind address, then
        localhost). Address is injected via placeholder replace — no f-string,
        so the HTML constant stays a plain string."""
        host = self.headers.get("Host")
        if not host:
            try:
                host = "%s:%s" % self.server.server_address
            except Exception:
                host = "127.0.0.1:8788"
        return USAGE_HTML.replace("__CREW_ADDR__", host)

    def _send_static(self, filepath, content_type):
        try:
            with open(filepath, "rb") as f:
                body = f.read()
        except OSError:
            return self._send_json({"error": "not found"}, 404)
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    # -- dashboard data endpoints (read-only) --
    def _api_status(self):
        now = time.time()
        st = STATS.status()
        aliases = sorted(set(st["per_key"]) | set(load_policy().get("*", [])) |
                         {a for aliases in load_policy().values() for a in aliases})
        brk = BREAKER.snapshot(aliases, now)
        # erp per real alias: a login entry with maps_to=<alias> tags that alias's contributor.
        auth = load_gateway_auth()
        erp_by_alias = {}
        for login, e in auth.items():
            mt = e.get("maps_to")
            if mt and mt not in erp_by_alias and e.get("erp"):
                erp_by_alias[mt] = e["erp"]
        keys = []
        for a in sorted(set(st["per_key"]) | set(brk)):
            pk = st["per_key"].get(a, {"requests": 0, "ok": 0, "fail": 0, "in_tokens": 0, "out_tokens": 0})
            b = brk.get(a, {"consec_fails": 0, "state": "healthy", "cooldown_left": 0})
            keys.append({"alias": a, "erp": erp_by_alias.get(a, ""), **pk, **b})
        models = [{"model": m, **v} for m, v in sorted(st["per_model"].items())]
        auth_rows = [{"login": k, "maps_to": v["maps_to"], "allow_models": v["allow_models"],
                      "erp": v["erp"], "admin": bool(v.get("admin"))} for k, v in sorted(auth.items())]
        return {"port": PORT, "ccr_url": CCR_URL, "fail_n": FAIL_N, "cooldown": COOLDOWN,
                "totals": st["totals"], "keys": keys, "models": models, "auth": auth_rows}

    def _api_sessions(self):
        # 2026-10-20:ls --json 对 20+ 会话(tmux+ps 逐个探测)实测 4-5s,系统忙时 >10s;
        # 给 25s 余量,超时才降级读 state(_api_sessions_fallback)。
        out, err = run_crew(["ls", "--json"], timeout=25)
        if out is None:
            # 2026-10-20:crew CLI 挂了不再返回空表,降级直读 state(见 _api_sessions_fallback)
            fb = _api_sessions_fallback()
            fb["error"] = err
            return fb
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            fb = _api_sessions_fallback()
            fb["error"] = "crew ls --json returned non-JSON"
            return fb

    def _api_logs(self):
        try:
            n = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("n", ["100"])[0])
        except (ValueError, TypeError):
            n = 100
        n = max(1, min(n, Stats.LOG_MAX))
        return {"logs": STATS.logs(n)}

    # -- self-service usage series (authenticated by the client's OWN login key) --
    #    x-api-key or Authorization: Bearer <key>. Not in the auth table -> 401.
    #    Normal user sees only their own login; an admin entry may pass ?key=<login>
    #    to view another login, or ?key=__all__ for the summed-all series. Read-only.
    def _client_key(self):
        """The caller's login key from x-api-key or `Authorization: Bearer <key>`,
        or None. Shared by the usage view and every admin-gated endpoint."""
        key = self.headers.get("x-api-key")
        if not key:
            auth_h = self.headers.get("Authorization", "")
            if auth_h.lower().startswith("bearer "):
                key = auth_h[7:].strip()
        return key or None

    def require_admin(self):
        """Return the caller's login key iff it maps to an admin entry, else None.
        Management endpoints call this and 403 on None — enforced on 127.0.0.1 too, so
        exposing them through the gateway is safe (the gateway re-checks as a first gate)."""
        key = self._client_key()
        entry = load_gateway_auth().get(key) if key else None
        return key if (entry and entry.get("admin")) else None

    def _api_usage(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        try:
            days = max(1, min(30, int(q.get("days", ["7"])[0])))
        except ValueError:
            days = 7
        key = self._client_key()
        auth = load_gateway_auth()
        entry = auth.get(key) if key else None
        if entry is None:
            return self._send_json({"error": "unauthorized"}, 401)
        want = q.get("key", [None])[0]
        if entry.get("admin") and want:
            login = None if want == "__all__" else want
        else:
            login = key
        out = USAGE.series(login, days=days)
        out["isAdmin"] = bool(entry.get("admin"))
        # 2026-10-28:每模型最近 24h 延迟分布(P50/P90/P99/avg/请求数/成功率,流式含
        # TTFT 分位)。纯新增字段——模型名+延迟不含 key 材料,与 /api/health 暴露 models
        # 的口径一致,登录用户都可见,辅助模型切换决策。
        out["latency"] = LATENCY.report()
        # 2026-10-28:服务状态行。proxy 自身隐式健康(本响应就是它发的);CCR 用 1s TCP
        # connect 探测 127.0.0.1:3456。纯新增字段,不含任何敏感信息。
        out["health"] = {"proxy": True, "ccr": _ccr_tcp_healthy()}
        if entry.get("admin"):
            # give the admin dropdown the login list here, so it needs no extra (and no
            # unauthenticated /api/status) call through the gateway. Union the login table
            # with every label that actually has usage, so 'direct' and orphaned (removed)
            # logins are viewable too — otherwise their traffic is invisible per-key.
            authset = set(load_gateway_auth().keys())
            usage_labels = set(USAGE.labels())
            out["logins"] = sorted(authset | usage_labels)
            out["orphan_logins"] = sorted(usage_labels - authset)  # usage but no login entry
            # emergency-session form dropdown data: alias + the models each alias routes.
            out["emergency"] = {"keys": _emergency_key_models()}
        return self._send_json(out)

    # -- pool health: any valid login key may see which pool keys are down (health only,
    #    no key material, no alias names — keyed by masked key so users understand slowness
    #    without learning credentials). Unknown key -> 401. --
    def _api_health(self):
        key = self._client_key()
        if not key or key not in load_gateway_auth():
            return self._send_json({"error": "unauthorized"}, 401)
        now = time.time()
        keys = load_keys()
        aliases = sorted(set(keys) | {a for al in load_policy().values() for a in al})
        brk = BREAKER.snapshot(aliases, now)
        out = []
        for a in aliases:
            b = brk.get(a, {"state": "healthy", "cooldown_left": 0})
            out.append({"key_masked": mask_key(keys.get(a, "")),
                        "state": b["state"], "cooldown_left": b["cooldown_left"]})
        # served model names (policy keys) — not secret; lets an unrestricted login discover
        # what the pool offers via /v1/models without needing the admin-only /api/policy.
        return self._send_json({"pool": out, "models": sorted(load_policy().keys())})

    # -- admin: full key pool for management (masked keys + models + policy rank + health).
    #    alias is returned because delete/policy ops target it, but the UI shows the masked
    #    key. Admin-only. --
    def _api_keys(self):
        if not self.require_admin():
            return self._send_json({"error": "admin required"}, 403)
        now = time.time()
        keys = load_keys()
        policy = load_policy()
        providers = load_ccr_providers()
        aliases = sorted(set(keys) | {a for al in policy.values() for a in al})
        brk = BREAKER.snapshot(aliases, now)
        models_by_alias = {}
        for a in aliases:
            ms = set()
            for p in providers:
                if (p.get("api_key") or p.get("apiKey")) == keys.get(a):
                    ms.update(p.get("models") or [])
            models_by_alias[a] = sorted(ms)
        pool = []
        for a in aliases:
            b = brk.get(a, {"consec_fails": 0, "state": "healthy", "cooldown_left": 0})
            in_policy = {m: al.index(a) for m, al in policy.items() if a in al}
            pool.append({"alias": a, "key_masked": mask_key(keys.get(a, "")),
                         "models": models_by_alias.get(a, []), "in_policy": in_policy,
                         "state": b["state"], "cooldown_left": b["cooldown_left"],
                         "consec_fails": b["consec_fails"]})
        auth = load_gateway_auth()
        logins = [{"login": k, "maps_to": v["maps_to"], "allow_models": v["allow_models"],
                   "erp": v["erp"], "admin": bool(v.get("admin"))} for k, v in sorted(auth.items())]
        masked_by_alias = {a: mask_key(keys.get(a, "")) for a in aliases}
        return self._send_json({"pool": pool, "policy": policy, "logins": logins,
                                "masked_by_alias": masked_by_alias})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/dashboard", "/dashboard/"):
            self._send_html(self._render_dashboard())
        elif path in ("/usage", "/usage/"):
            # v4.0.1:统一到 /dashboard,旧链接 302 兼容
            self._send_redirect("/dashboard")
        elif path == "/crew-demo.gif":
            self._send_static(CREW_DEMO_GIF, "image/gif")
        elif path == "/crew-proxy-hero.png":
            self._send_static(CREW_HERO_PNG, "image/png")
        elif path == "/api/status":
            self._send_json(self._api_status())
        elif path == "/api/sessions":
            self._send_json(self._api_sessions())
        elif path == "/api/logs":
            self._send_json(self._api_logs())
        elif path == "/api/usage":
            self._api_usage()
        elif path == "/api/health":
            self._api_health()
        elif path == "/api/keys":
            self._api_keys()
        elif path == "/api/policy":
            self._api_policy_get()
        elif path == "/api/register-allow":
            self._api_register_allow_get()
        else:
            self._passthrough(b"")

    def do_POST(self):
        body = self._read_body()
        path = self.path.split("?")[0]
        # Dashboard write endpoints (state-mutating; strict input validation below).
        if path == "/api/session/kill":
            self._api_session_kill(body); return
        if path == "/api/session/config":
            self._api_session_config(body); return
        if path == "/api/ccr/provider":
            self._api_ccr_provider(body); return
        if path == "/api/gateway/auth":
            self._api_gateway_auth(body); return
        if path == "/api/policy":
            self._api_policy(body); return
        if path == "/api/register-allow":
            self._api_register_allow(body); return
        if path == "/api/register":
            self._api_register(body); return
        if path == "/api/emergency-session":
            self._api_emergency_session(body); return
        # Only /v1/messages and /v1/chat/completions carry a model to route on.
        if path.endswith("/messages") or path.endswith("/chat/completions"):
            if path.endswith("/messages"):
                # 清洗 tool id 里的非法冒号(如 Bash:0),否则严格网关(4.7-joybuilder)会 400。
                body = self._sanitize_tool_ids(body)
            self._route(body)
        else:
            self._passthrough(body)

    def _read_json(self, body):
        try:
            return json.loads(body or b"{}")
        except json.JSONDecodeError:
            return None

    def _sanitize_tool_ids(self, body):
        """Replace ':' with '_' in tool_use.id / tool_result.tool_use_id inside messages.

        Some upstream gateways (e.g. llm-gw's *-joybuilder) enforce tool id pattern
        ^[a-zA-Z0-9_-]+$ and 400 on ids like 'Bash:0' / 'TaskCreate:12' (produced by the
        joycode OpenAI->Anthropic path). A tool_use.id and its paired tool_result.tool_use_id
        get the SAME deterministic replace(':','_'), so they stay matched — no orphaned
        tool_result. Legal ids (no colon) are untouched; if nothing changed, the original
        bytes are returned so usage/billing parsing is byte-identical.
        """
        try:
            payload = json.loads(body or b"{}")
        except (json.JSONDecodeError, ValueError):
            return body
        if not isinstance(payload, dict):
            return body
        msgs = payload.get("messages")
        if not isinstance(msgs, list):
            return body
        changed = False
        for m in msgs:
            if not isinstance(m, dict):
                continue
            content = m.get("content")
            if not isinstance(content, list):
                continue
            for blk in content:
                if not isinstance(blk, dict):
                    continue
                t = blk.get("type")
                if t == "tool_use":
                    _id = blk.get("id")
                    if isinstance(_id, str) and ":" in _id:
                        blk["id"] = _id.replace(":", "_")
                        changed = True
                elif t == "tool_result":
                    _tid = blk.get("tool_use_id")
                    if isinstance(_tid, str) and ":" in _tid:
                        blk["tool_use_id"] = _tid.replace(":", "_")
                        changed = True
        if not changed:
            return body
        return json.dumps(payload).encode()

    # -- stage B: kill a session (delegates to `crew kill`, the canonical teardown) --
    def _api_session_kill(self, body):
        if not self.require_admin():
            return self._send_json({"ok": False, "error": "admin required"}, 403)
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        name = str(d.get("name", ""))
        if not SAFE_NAME.match(name):
            return self._send_json({"ok": False, "error": "invalid session name"}, 400)
        # No --purge from the dashboard: keep the transcript, only tear down tmux + state.
        out, err = run_crew(["kill", name])
        if err:
            return self._send_json({"ok": False, "error": err}, 500)
        return self._send_json({"ok": True, "output": (out or "").strip()})

    # -- stage C: change a session's model/key (single-value crew state files) --
    def _api_session_config(self, body):
        if not self.require_admin():
            return self._send_json({"ok": False, "error": "admin required"}, 403)
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        name = str(d.get("name", ""))
        if not SAFE_NAME.match(name):
            return self._send_json({"ok": False, "error": "invalid session name"}, 400)
        os.makedirs(CREW_STATE, exist_ok=True)

        def _write(field, val, allow_clear):
            path = os.path.join(CREW_STATE, f"{name}.{field}")
            if val == "" and allow_clear:
                if os.path.exists(path):
                    os.remove(path)
                return None
            if not SAFE_NAME.match(val):
                return f"invalid {field}"
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                f.write(val)
            os.replace(tmp, path)
            return None

        changed = []
        if "model" in d:
            e = _write("backend", str(d.get("model", "")), allow_clear=False)
            if e:
                return self._send_json({"ok": False, "error": e}, 400)
            changed.append("model")
        if "key" in d:
            e = _write("key", str(d.get("key", "")), allow_clear=True)
            if e:
                return self._send_json({"ok": False, "error": e}, 400)
            changed.append("key")
        return self._send_json({"ok": True, "changed": changed,
                                "note": "takes effect next `crew <name>` (restart the session to apply now)"})

    # -- admin: one-click emergency session. Spawns a detached tmux claude session via
    #    the crew CLI. Hard safety:
    #    (a) command injection — subprocess uses an argv list, shell=False, never a string.
    #    (b) whitelist — key must be a real keys.conf alias; model must be one THAT key can
    #        actually route (provider models for its api_key ∪ models whose policy chain
    #        names the alias). 400 on anything else, before any subprocess.
    #    (c) auth — same require_admin() gate as every other management endpoint.
    #    Returns ONLY the server-generated session name. No key material, no api_key,
    #    never echoed back (the /api/switch leak lesson).
    def _api_emergency_session(self, body):
        if not self.require_admin():
            return self._send_json({"ok": False, "error": "admin required"}, 403)
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        key = str(d.get("key", "")).strip()
        model = str(d.get("model", "")).strip()
        keys = load_keys()
        if key not in keys:
            return self._send_json({"ok": False, "error": "unknown key alias"}, 400)
        allowed = set()
        for p in load_ccr_providers():
            if (p.get("api_key") or p.get("apiKey")) == keys[key]:
                allowed.update(p.get("models") or [])
        for m, aliases in load_policy().items():
            if key in aliases:
                allowed.add(m)
        if model not in allowed:
            return self._send_json({"ok": False, "error": "model not routable for this key"}, 400)
        # Server-generated unique name only — never trust a client-supplied name.
        name = "emergency-%s-%s-%s" % (key, time.strftime("%Y%m%d-%H%M%S"),
                                       secrets.token_hex(3))
        _, err = _run_crew_spawn(name, key, model)
        if err:
            return self._send_json({"ok": False, "error": err}, 500)
        return self._send_json({"ok": True, "session_name": name})

    # -- stage D: add a key + CCR provider (writes global config; backs up first) --
    def _api_ccr_provider(self, body):
        if not self.require_admin():
            return self._send_json({"ok": False, "error": "admin required"}, 403)
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        if d.get("delete"):
            return self._delete_key(str(d.get("alias", "")), bool(d.get("force")))
        alias = str(d.get("alias", "")); key = str(d.get("key", ""))
        model = str(d.get("model", "")); base_url = str(d.get("base_url", ""))
        transformer = str(d.get("transformer", "OpenAI"))
        # Validate the identifiers we control; key + base_url are opaque values (not exec'd,
        # not used as filenames) so they only need to be non-empty and sane.
        if not SAFE_NAME.match(alias):
            return self._send_json({"ok": False, "error": "invalid alias"}, 400)
        if not SAFE_NAME.match(model):
            return self._send_json({"ok": False, "error": "invalid model"}, 400)
        if transformer not in ("OpenAI", "Anthropic"):
            return self._send_json({"ok": False, "error": "transformer must be OpenAI or Anthropic"}, 400)
        if not key or not base_url.startswith(("http://", "https://")):
            return self._send_json({"ok": False, "error": "key required and base_url must be http(s)"}, 400)

        # 1) keys.conf: add/replace alias line.
        try:
            lines = []
            found = False
            if os.path.exists(KEYS_FILE):
                with open(KEYS_FILE) as f:
                    for ln in f:
                        if ln.strip() and not ln.lstrip().startswith("#") and ln.split("=", 1)[0].strip() == alias:
                            lines.append(f"{alias}={key}\n"); found = True
                        else:
                            lines.append(ln if ln.endswith("\n") else ln + "\n")
            if not found:
                lines.append(f"{alias}={key}\n")
            os.makedirs(os.path.dirname(KEYS_FILE), exist_ok=True)
            with open(KEYS_FILE, "w") as f:
                f.writelines(lines)
            os.chmod(KEYS_FILE, 0o600)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"keys.conf write failed: {e}"}, 500)

        # 2) CCR config: back up, then merge one provider ({model} x {key}).
        try:
            with open(CCR_CFG) as f:
                cfg = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            return self._send_json({"ok": False, "error": f"cannot read CCR config: {e}"}, 500)
        backup = f"{CCR_CFG}.bak.{int(time.time())}"
        try:
            shutil.copy2(CCR_CFG, backup)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"backup failed: {e}"}, 500)
        providers = cfg.setdefault("Providers", cfg.get("providers") and cfg.pop("providers") or [])
        pname = f"{model}-{alias}"
        if any(p.get("name") == pname for p in providers):
            return self._send_json({"ok": False, "error": f"provider '{pname}' already exists"}, 409)
        providers.append({"name": pname, "api_base_url": base_url, "api_key": key,
                          "models": [model], "transformer": {"use": [transformer]}})
        try:
            tmp = CCR_CFG + ".tmp"
            with open(tmp, "w") as f:
                json.dump(cfg, f, indent=2)
            os.replace(tmp, CCR_CFG)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"CCR write failed (backup at {backup}): {e}"}, 500)
        if not sync_ccr_config():
            return self._send_json({"ok": False, "error": "provider map saved but CCR 3 apply failed"}, 502)
        log.info("added CCR provider '%s' + key '%s' (backup %s)", pname, alias, backup)
        return self._send_json({"ok": True, "provider": pname, "backup_path": backup})

    # -- admin: delete a real key from the pool: keys.conf line + matching CCR providers +
    #    strip from every policy line. Refuses to orphan a model (leave it with no keys)
    #    unless force. Backs up all three files first. --
    def _delete_key(self, alias, force=False):
        if not SAFE_NAME.match(alias):
            return self._send_json({"ok": False, "error": "invalid alias"}, 400)
        keys = load_keys()
        if alias not in keys:
            return self._send_json({"ok": False, "error": f"alias '{alias}' not in keys.conf"}, 404)
        # orphan guard: any model whose policy would become empty by removing this alias?
        policy = load_policy()
        orphaned = [m for m, al in policy.items() if al == [alias]]
        if orphaned and not force:
            return self._send_json({"ok": False, "error": "would orphan model(s): "
                                    + ", ".join(sorted(orphaned)) + " (pass force to proceed)"}, 409)
        api_key = keys.get(alias)
        ts = int(time.time())
        # 1) keys.conf: drop the alias line (back up first).
        try:
            if os.path.exists(KEYS_FILE):
                shutil.copy2(KEYS_FILE, f"{KEYS_FILE}.bak.{ts}")
                with open(KEYS_FILE) as f:
                    lines = f.readlines()
                kept = [ln for ln in lines if not (ln.strip() and not ln.lstrip().startswith("#")
                        and ln.split("=", 1)[0].strip() == alias)]
                tmp = KEYS_FILE + ".tmp"
                with open(tmp, "w") as f:
                    f.writelines(kept)
                os.chmod(tmp, 0o600)
                os.replace(tmp, KEYS_FILE)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"keys.conf write failed: {e}"}, 500)
        # 2) key-policy.conf: strip the alias from every line (preserve comments/order).
        try:
            if os.path.exists(POLICY):
                shutil.copy2(POLICY, f"{POLICY}.bak.{ts}")
                with open(POLICY) as f:
                    plines = f.readlines()
                new_plines = []
                for ln in plines:
                    s = ln.strip()
                    if not s or s.startswith("#") or "=" not in s:
                        new_plines.append(ln); continue
                    model, al = s.split("=", 1)
                    rest = [x for x in al.split() if x != alias]
                    new_plines.append(f"{model.strip()} = {' '.join(rest)}\n")
                tmp = POLICY + ".tmp"
                with open(tmp, "w") as f:
                    f.writelines(new_plines)
                os.replace(tmp, POLICY)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"key-policy.conf write failed: {e}"}, 500)
        # 3) CCR config: drop providers whose api_key matches this alias's key (back up).
        try:
            with open(CCR_CFG) as f:
                cfg = json.load(f)
            shutil.copy2(CCR_CFG, f"{CCR_CFG}.bak.{ts}")
            provs = cfg.get("Providers") or cfg.get("providers") or []
            before = len(provs)
            provs = [p for p in provs if (p.get("api_key") or p.get("apiKey")) != api_key]
            cfg["Providers"] = provs
            cfg.pop("providers", None)
            tmp = CCR_CFG + ".tmp"
            with open(tmp, "w") as f:
                json.dump(cfg, f, indent=2)
            os.replace(tmp, CCR_CFG)
            removed = before - len(provs)
        except (FileNotFoundError, json.JSONDecodeError, OSError) as e:
            return self._send_json({"ok": False, "error": f"CCR config update failed: {e}"}, 500)
        if not sync_ccr_config():
            return self._send_json({"ok": False, "error": "provider map saved but CCR 3 apply failed"}, 502)
        log.info("deleted key '%s' (providers removed: %d, force=%s)", alias, removed, force)
        return self._send_json({"ok": True, "deleted": alias, "providers_removed": removed})

    # -- admin: per-model priority policy. GET returns {model: [alias,...]}; POST
    #    {model, aliases:[...]} rewrites that model's line (order = priority);
    #    {model, delete: true} drops the line. Aliases must exist in keys.conf. --
    def _api_policy_get(self):
        if not self.require_admin():
            return self._send_json({"error": "admin required"}, 403)
        return self._send_json({"policy": load_policy()})

    def _api_policy(self, body):
        if not self.require_admin():
            return self._send_json({"ok": False, "error": "admin required"}, 403)
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        model = str(d.get("model", ""))
        if not SAFE_NAME.match(model):
            return self._send_json({"ok": False, "error": "invalid model"}, 400)
        delete = bool(d.get("delete"))
        aliases = []
        if not delete:
            aliases = d.get("aliases") or []
            if not isinstance(aliases, list):
                return self._send_json({"ok": False, "error": "aliases must be a list"}, 400)
            keys = load_keys()
            clean = []
            for a in aliases:
                a = str(a).strip()
                if not SAFE_NAME.match(a):
                    return self._send_json({"ok": False, "error": f"invalid alias '{a}'"}, 400)
                if a not in keys:
                    return self._send_json({"ok": False, "error": f"alias '{a}' not in keys.conf"}, 400)
                clean.append(a)
            aliases = clean
        # rewrite key-policy.conf: replace/drop this model's line, preserve everything else.
        try:
            ts = int(time.time())
            lines = []
            if os.path.exists(POLICY):
                shutil.copy2(POLICY, f"{POLICY}.bak.{ts}")
                with open(POLICY) as f:
                    lines = f.readlines()
            out_lines = []
            found = False
            for ln in lines:
                s = ln.strip()
                if s and not s.startswith("#") and "=" in s and s.split("=", 1)[0].strip() == model:
                    found = True
                    if not delete:
                        out_lines.append(f"{model} = {' '.join(aliases)}\n")
                    # delete: skip the line
                else:
                    out_lines.append(ln)
            if not found and not delete:
                out_lines.append(f"{model} = {' '.join(aliases)}\n")
            os.makedirs(os.path.dirname(POLICY), exist_ok=True)
            tmp = POLICY + ".tmp"
            with open(tmp, "w") as f:
                f.writelines(out_lines)
            os.replace(tmp, POLICY)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"key-policy.conf write failed: {e}"}, 500)
        return self._send_json({"ok": True, "model": model, "aliases": aliases, "deleted": delete})

    # -- self-service registration: NO admin required. A visitor submits their own real
    #    key; we test-call the fixed internal upstream (REGISTER_TEST_URL, not user-supplied
    #    -> no SSRF) with a tiny request. On success the key joins the shared pool for
    #    REGISTER_MODEL (keys.conf + CCR provider + appended to that model's policy) so it
    #    participates in failover. On failure the upstream error is returned verbatim so the
    #    user can see why. Never exposes other keys; cannot touch policy of other models. --
    def _api_register(self, body):
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        key = str(d.get("key", "")).strip()
        if not key or len(key) > 512:
            return self._send_json({"ok": False, "error": "key required (<=512 chars)"}, 400)
        erp = str(d.get("erp", "")).strip()
        if not erp:
            return self._send_json({"ok": False, "error": "erp（工号）必填"}, 400)
        if not SAFE_NAME.match(erp) or len(erp) > 64:
            return self._send_json({"ok": False, "error": "erp 含非法字符或过长"}, 400)
        # 1) test-call the fixed internal upstream with a minimal request. Retry a few times
        #    on TRANSIENT upstream errors (429/503/5xx/conn) — a busy-server "max_concurrency"
        #    spike is not a bad key. Only auth errors (401/403) mean the key is actually bad.
        payload = json.dumps({"model": REGISTER_MODEL, "max_tokens": 8,
                              "messages": [{"role": "user", "content": "ping"}]}).encode()
        last_detail, last_code = "", None
        ok_tested = False
        for attempt in range(4):
            req = urllib.request.Request(REGISTER_TEST_URL, data=payload, method="POST",
                                         headers={"Content-Type": "application/json",
                                                  "Authorization": "Bearer " + key,
                                                  "x-api-key": key})
            try:
                resp = urllib.request.urlopen(req, timeout=30)
                resp.read(4096)
                ok_tested = True
                break
            except urllib.error.HTTPError as e:
                last_code = e.code
                try:
                    last_detail = e.read(2048).decode("utf-8", "replace")
                except Exception:
                    last_detail = ""
                if e.code in (401, 403):
                    # genuine auth failure -> the key is bad, no point retrying.
                    return self._send_json({"ok": False, "stage": "test",
                                            "error": f"key 无效或无权限 (HTTP {e.code})",
                                            "detail": last_detail}, 400)
                # 429/5xx/other -> transient, retry after a short backoff
            except Exception as e:
                last_code, last_detail = None, str(e)
            time.sleep(REGISTER_RETRY_BASE * (attempt + 1))
        if not ok_tested:
            # exhausted retries on a transient condition -> tell the user to retry, do NOT
            # reject the key. 503 so the UI can distinguish "server busy" from "bad key".
            return self._send_json({"ok": False, "stage": "test", "transient": True,
                                    "error": "上游繁忙,暂时无法验证你的 key(并发已满/限流),请稍后重试",
                                    "detail": last_detail}, 503)
        # 2) key passed -> add to the pool. Dedupe by key: if an existing alias already holds
        #    this exact key, reuse it (idempotent re-register); else mint self-<8hex of key>.
        keys = load_keys()
        alias = next((a for a, k in keys.items() if k == key), None)
        if alias is None:
            import hashlib
            alias = "self-" + hashlib.sha256(key.encode()).hexdigest()[:8]
        # keys.conf upsert
        try:
            lines, found = [], False
            if os.path.exists(KEYS_FILE):
                with open(KEYS_FILE) as f:
                    for ln in f:
                        if ln.strip() and not ln.lstrip().startswith("#") and ln.split("=", 1)[0].strip() == alias:
                            lines.append(f"{alias}={key}\n"); found = True
                        else:
                            lines.append(ln if ln.endswith("\n") else ln + "\n")
            if not found:
                lines.append(f"{alias}={key}\n")
            os.makedirs(os.path.dirname(KEYS_FILE), exist_ok=True)
            tmp = KEYS_FILE + ".tmp"
            with open(tmp, "w") as f:
                f.writelines(lines)
            os.chmod(tmp, 0o600); os.replace(tmp, KEYS_FILE)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"keys.conf write failed: {e}"}, 500)
        # 3) CCR providers: clone one provider per model this pool already serves, using the
        #    new key with that model's own base_url + transformer, so the key can serve EVERY
        #    model (not just the one we test-called).
        added_models = []
        try:
            with open(CCR_CFG) as f:
                cfg = json.load(f)
            provs = cfg.get("Providers") or cfg.get("providers") or []
            # model -> (base_url, transformer) template from an existing provider serving it
            tmpl = {}
            for p in provs:
                base = p.get("api_base_url") or p.get("apiBaseUrl") or REGISTER_TEST_URL
                tr = p.get("transformer") or {"use": ["OpenAI"]}
                for m in (p.get("models") or []):
                    tmpl.setdefault(m, (base, tr))
            # guarantee the test model even if no provider enumerated it
            tmpl.setdefault(REGISTER_MODEL, (REGISTER_TEST_URL, {"use": ["OpenAI"]}))
            shutil.copy2(CCR_CFG, f"{CCR_CFG}.bak.{int(time.time())}")
            existing = {p.get("name") for p in provs}
            for m, (base, tr) in tmpl.items():
                pname = f"{m}-{alias}"
                if pname in existing:
                    continue
                provs.append({"name": pname, "api_base_url": base, "api_key": key,
                              "models": [m], "transformer": tr})
                added_models.append(m)
            cfg["Providers"] = provs; cfg.pop("providers", None)
            tmp = CCR_CFG + ".tmp"
            with open(tmp, "w") as f:
                json.dump(cfg, f, indent=2)
            os.replace(tmp, CCR_CFG)
        except (FileNotFoundError, json.JSONDecodeError, OSError) as e:
            return self._send_json({"ok": False, "error": f"CCR config update failed: {e}"}, 500)
        # 4) policy: append alias to EVERY model's line (create lines for models with none).
        try:
            models = sorted(set(tmpl))
            plines = []
            if os.path.exists(POLICY):
                with open(POLICY) as f:
                    plines = f.readlines()
            out, seen = [], set()
            for ln in plines:
                s = ln.strip()
                if s and not s.startswith("#") and "=" in s:
                    m = s.split("=", 1)[0].strip()
                    if m in models:
                        seen.add(m)
                        cur = s.split("=", 1)[1].split()
                        if alias not in cur:
                            cur.append(alias)
                        out.append(f"{m} = {' '.join(cur)}\n")
                        continue
                out.append(ln)
            for m in models:
                if m not in seen:
                    out.append(f"{m} = {alias}\n")
            os.makedirs(os.path.dirname(POLICY), exist_ok=True)
            tmp = POLICY + ".tmp"
            with open(tmp, "w") as f:
                f.writelines(out)
            os.replace(tmp, POLICY)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"policy write failed: {e}"}, 500)
        # 5) create/refresh a gateway-auth login entry for this key so the registrant can only
        #    CALL the default-authorized models (allow_models). login == the key itself.
        #    Never grants admin; if the login already exists, keep its admin/erp but do NOT
        #    widen allow_models automatically (admin manages that afterwards).
        try:
            auth = load_gateway_auth()
            prev = auth.get(key, {})
            entry = {"maps_to": alias,
                     "allow_models": prev.get("allow_models") or register_allow_list(),
                     "erp": erp or prev.get("erp", "")}
            if prev.get("admin"):
                entry["admin"] = True
            # write raw (load_gateway_auth normalizes on read); preserve other logins + __doc__
            raw = {}
            try:
                with open(GATEWAY_AUTH) as f:
                    raw = json.load(f)
            except (FileNotFoundError, json.JSONDecodeError):
                raw = {}
            if not isinstance(raw, dict):
                raw = {}
            raw[key] = entry
            os.makedirs(os.path.dirname(GATEWAY_AUTH), exist_ok=True)
            if os.path.exists(GATEWAY_AUTH):
                shutil.copy2(GATEWAY_AUTH, f"{GATEWAY_AUTH}.bak.{int(time.time())}")
            tmp = GATEWAY_AUTH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(raw, f, indent=2)
            os.chmod(tmp, 0o600); os.replace(tmp, GATEWAY_AUTH)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"gateway-auth write failed: {e}"}, 500)
        log.info("self-registered key alias '%s' into %d models; allow=%s", alias, len(tmpl), entry["allow_models"])
        if added_models and not sync_ccr_config():
            return self._send_json({"ok": False, "error": "provider map saved but CCR 3 apply failed"}, 502)
        return self._send_json({"ok": True, "alias": alias, "models": sorted(set(tmpl)),
                                "allow_models": entry["allow_models"], "key_masked": mask_key(key)})

    # -- default allow-list for NEW self-registrants (admin-editable) --
    #    GET  -> {allow: [...current...], builtin: [...constant fallback...]}
    #    POST {allow: ["ModelA","ModelB"]} -> persist to gateway-auth.json "__register_allow__"
    #    Model names are strict-allowlisted (no shell metachars / commas). Empty list resets
    #    to the built-in constant (removes the override).
    def _api_register_allow_get(self):
        if not self.require_admin():
            return self._send_json({"error": "admin required"}, 403)
        return self._send_json({"allow": register_allow_list(), "builtin": list(REGISTER_ALLOW)})

    def _api_register_allow(self, body):
        if not self.require_admin():
            return self._send_json({"ok": False, "error": "admin required"}, 403)
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        raw_list = d.get("allow")
        if not isinstance(raw_list, list):
            return self._send_json({"ok": False, "error": "allow must be a list"}, 400)
        ok_name = re.compile(r"^[A-Za-z0-9._-]+$")
        models = []
        for m in raw_list:
            m = str(m).strip()
            if not m:
                continue
            if not ok_name.match(m):
                return self._send_json({"ok": False, "error": f"invalid model name: {m!r}"}, 400)
            if m not in models:
                models.append(m)
        try:
            raw = _raw_gateway_auth()
            if not isinstance(raw, dict):
                raw = {}
            if models:
                raw["__register_allow__"] = models
            else:
                raw.pop("__register_allow__", None)  # empty = reset to built-in default
            os.makedirs(os.path.dirname(GATEWAY_AUTH), exist_ok=True)
            if os.path.exists(GATEWAY_AUTH):
                shutil.copy2(GATEWAY_AUTH, f"{GATEWAY_AUTH}.bak.{int(time.time())}")
            tmp = GATEWAY_AUTH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(raw, f, indent=2)
            os.chmod(tmp, 0o600); os.replace(tmp, GATEWAY_AUTH)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"gateway-auth write failed: {e}"}, 500)
        log.info("register-allow default set to %s", register_allow_list())
        return self._send_json({"ok": True, "allow": register_allow_list()})

    # -- gateway login table: add/update/delete an entry in gateway-auth.json --
    #    {login, maps_to, allow_models[], erp}          -> upsert
    #    {login, delete: true}                          -> remove
    # login/maps_to/model names are strict-allowlisted (no shell metachars, no commas).
    def _api_gateway_auth(self, body):
        if not self.require_admin():
            return self._send_json({"ok": False, "error": "admin required"}, 403)
        d = self._read_json(body)
        if d is None:
            return self._send_json({"ok": False, "error": "invalid JSON"}, 400)
        login = str(d.get("login", ""))
        ok_name = re.compile(r"^[A-Za-z0-9._-]+$")
        if not ok_name.match(login):
            return self._send_json({"ok": False, "error": "invalid login key"}, 400)

        auth = load_gateway_auth()

        if d.get("delete"):
            if login not in auth:
                return self._send_json({"ok": False, "error": "login key not found"}, 404)
            auth.pop(login, None)
        else:
            maps_to = str(d.get("maps_to", ""))
            if not ok_name.match(maps_to):
                return self._send_json({"ok": False, "error": "invalid maps_to"}, 400)
            # maps_to must be a real alias in keys.conf.
            if maps_to not in load_keys():
                return self._send_json({"ok": False, "error": f"maps_to '{maps_to}' not in keys.conf"}, 400)
            allow = d.get("allow_models") or []
            if not isinstance(allow, list):
                return self._send_json({"ok": False, "error": "allow_models must be a list"}, 400)
            clean_allow = []
            for m in allow:
                m = str(m).strip()
                if not m:
                    continue
                if not ok_name.match(m):
                    return self._send_json({"ok": False, "error": f"invalid model name '{m}'"}, 400)
                clean_allow.append(m)
            erp = str(d.get("erp", ""))
            if erp and not ok_name.match(erp):
                return self._send_json({"ok": False, "error": "invalid erp"}, 400)
            prev_admin = bool(auth.get(login, {}).get("admin"))
            admin = bool(d["admin"]) if isinstance(d.get("admin"), bool) else prev_admin
            entry = {"maps_to": maps_to, "allow_models": clean_allow, "erp": erp}
            if admin:
                entry["admin"] = True
            auth[login] = entry

        # write back: back up first (if the file exists), then atomic replace, mode 0600.
        try:
            os.makedirs(os.path.dirname(GATEWAY_AUTH), exist_ok=True)
            backup = None
            if os.path.exists(GATEWAY_AUTH):
                backup = f"{GATEWAY_AUTH}.bak.{int(time.time())}"
                shutil.copy2(GATEWAY_AUTH, backup)
            tmp = GATEWAY_AUTH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(auth, f, indent=2)
            os.replace(tmp, GATEWAY_AUTH)
            os.chmod(GATEWAY_AUTH, 0o600)
        except OSError as e:
            return self._send_json({"ok": False, "error": f"gateway-auth write failed: {e}"}, 500)
        return self._send_json({"ok": True, "login": login, "deleted": bool(d.get("delete")),
                                "backup_path": backup})

    # -- plain reverse proxy (no key logic): health, /v1/models, unknown paths, and
    #    policy-less model calls. When model is given (a real completion call), the request
    #    is counted under the synthetic "direct" key so the dashboard shows all traffic. --
    def _passthrough(self, body, model=None, stream=False):
        url = CCR_URL + self.path
        # 2026-09-01 退避重试:仅对 model 请求(非 None)、429/5xx/连接错重试;退避 base*2^k(cap
        # PT_RETRY_MAX),429 带 Retry-After 优先且 cap;总退避不超 PT_RETRY_BUDGET。重试全在 _relay
        # 之前(还没写响应给客户端),流式也安全。400/401/403/2xx 不重试。不换模型/不换 key。
        can_retry = model is not None and PT_MAX_RETRY > 0
        spent = 0.0
        attempt = 0
        while True:
            req = urllib.request.Request(url, data=body or None, headers=self._fwd_headers(),
                                         method=self.command)
            _t = time.time()
            try:
                resp = urllib.request.urlopen(req, timeout=300 if model else 120)
            except urllib.error.HTTPError as e:
                # 可重试码(429/5xx)且还有次数+预算 → 退避重试
                if can_retry and attempt < PT_MAX_RETRY and (e.code == 429 or e.code >= 500):
                    ra = parse_retry_after(e.headers) if e.code == 429 else None
                    delay = ra if (ra is not None) else min(PT_RETRY_BASE * (2 ** attempt), PT_RETRY_MAX)
                    delay = min(delay, PT_RETRY_MAX)
                    if spent + delay <= PT_RETRY_BUDGET:
                        log.info("passthrough retry %d/%d after %.1fs (code=%s model=%s)",
                                 attempt + 1, PT_MAX_RETRY, delay, e.code, model)
                        e.close()
                        time.sleep(delay); spent += delay; attempt += 1
                        continue
                # 不重试(不可重试码 / 次数或预算耗尽)→ 透传错误
                result = self._relay(e, streaming=False, model=model, req_body=body)
                if model and not result["cancelled"]:
                    STATS.record("direct", model, e.code, ok=False, forced=False, failover=False,
                                 latency=time.time() - _t, err_summary=f"HTTP {e.code}")
                return
            except Exception as e:
                # 连接错(timeout/reset 等)也可重试
                if can_retry and attempt < PT_MAX_RETRY:
                    delay = min(PT_RETRY_BASE * (2 ** attempt), PT_RETRY_MAX)
                    if spent + delay <= PT_RETRY_BUDGET:
                        log.info("passthrough retry %d/%d after %.1fs (conn-err model=%s: %s)",
                                 attempt + 1, PT_MAX_RETRY, delay, model, str(e)[:60])
                        time.sleep(delay); spent += delay; attempt += 1
                        continue
                if model:
                    STATS.record("direct", model, "ERR", ok=False, forced=False, failover=False,
                                 latency=time.time() - _t, err_summary=str(e)[:200])
                msg = classify_error(502, "ccr-down", str(e))
                log.warning(msg)
                self._send_err(502, msg)
                return
            else:
                if model:
                    result = self._relay(resp, streaming=stream, capture=True)
                    if not result["cancelled"]:
                        # 流式:result["ttft"]=首 chunk 墙钟;非流式没有首 token 概念,记 None。
                        _ttft = result.get("ttft")
                        if _ttft is not None:
                            _ttft = _ttft - _t
                        STATS.record("direct", model, getattr(resp, "status", 200) if result["ok"] else "ERR",
                                     ok=result["ok"], forced=False, failover=False,
                                     latency=time.time() - _t, err_summary=result["error"],
                                     ttft=_ttft)
                    captured = result["body"]
                    if result["ok"] and captured:
                        try:
                            it, ot = parse_usage(captured)
                            STATS.record_usage("direct", model, it, ot)
                            USAGE.add(self.headers.get("X-Crew-Login") or "direct", it, ot)
                        except Exception:
                            pass
                else:
                    self._relay(resp, streaming=False, model=model)
                return

    # -- key-aware routing with failover --
    def _route(self, body):
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._passthrough(body)  # not JSON we understand; just forward
            return

        model = payload.get("model", "") or ""
        selected_provider, sep, realmodel = model.partition("/")
        if not sep:
            selected_provider = ""
            realmodel = model
        stream = bool(payload.get("stream", False))

        policy = load_policy().get(realmodel, [])
        if not policy:
            # No priority policy for this model -> plain forward to CCR (CCR routes as
            # configured). Still counted, so the dashboard reflects ALL traffic — the key
            # column shows "direct" since no crew-proxy key selection happened here.
            self._passthrough(body, model=realmodel, stream=stream)
            return

        # Affinity: an upstream (e.g. crew-gateway) may hint which key to prefer via
        # X-Crew-Prefer-Key. If that alias is in this model's policy, bump it to the front
        # (failover order for the rest is unchanged). Absent/unknown header -> no effect,
        # so behavior without the header is byte-identical to before.
        prefer = self.headers.get("X-Crew-Prefer-Key")
        if prefer and prefer in policy:
            policy = [prefer] + [a for a in policy if a != prefer]

        keys = load_keys()
        providers = load_ccr_providers()

        # A crew session records the full CCR 3 selector (provider/model).
        # Preserve that explicit key choice for the first try, while retaining
        # the model policy as the failover order.
        if selected_provider:
            preferred_alias = next((alias for alias, key in keys.items()
                                    if provider_for(realmodel, key, providers) == selected_provider), "")
            if preferred_alias in policy:
                policy = [preferred_alias] + [alias for alias in policy if alias != preferred_alias]
        now = time.time()

        tried = []
        while True:
            alias = BREAKER.pick([a for a in policy if a not in tried], now)
            if alias is None:
                # every remaining key tripped -> hard-forward with the top-priority key,
                # surfacing the real upstream error (don't fake success).
                alias = policy[0]
                forced = True
            else:
                forced = False

            api_key = keys.get(alias)
            if not api_key:
                log.warning("alias '%s' not in keys.conf; skipping", alias)
                tried.append(alias)
                if len(tried) >= len(policy):
                    msg = classify_error(502, "no-key", f"realmodel={realmodel}")
                    log.warning(msg)
                    self._send_err(502, msg)
                    return
                continue

            provider = provider_for(realmodel, api_key, providers)
            if not provider:
                log.warning("no CCR provider serves '%s' with key '%s'; skipping", realmodel, alias)
                tried.append(alias)
                if len(tried) >= len(policy):
                    msg = classify_error(502, "no-provider", f"{realmodel}/{alias}")
                    log.warning(msg)
                    self._send_err(502, msg)
                    return
                continue

            # CCR 3 uses ``provider/model`` selectors.  Comma selectors were
            # a CCR 2 convention and are treated as an unknown model in v3.
            fwd = {**payload, "model": f"{provider}/{realmodel}"}
            fwd_body = json.dumps(fwd).encode()
            log.info("→ %-24s via key '%s'%s (stream=%s)", realmodel, alias,
                     " [FORCED]" if forced else "", stream)

            req = urllib.request.Request(
                CCR_URL + self.path, data=fwd_body,
                headers={**self._fwd_headers(), "Content-Type": "application/json"},
                method="POST",
            )
            try:
                _t_send = time.time()
                resp = urllib.request.urlopen(req, timeout=300)
            except urllib.error.HTTPError as e:
                if _is_fail(e.code) and not forced:
                    cd = cooldown_for(e.code, parse_retry_after(e.headers))
                    if len(tried) + 1 >= len(policy):
                        result = self._relay(e, streaming=False, model=realmodel, req_body=body)
                        if not result["cancelled"]:
                            BREAKER.record_fail(alias, time.time(), cd)
                            STATS.record(alias, realmodel, e.code, ok=False, forced=forced,
                                         failover=bool(tried), latency=time.time() - _t_send,
                                         err_summary=f"HTTP {e.code}")
                            log.warning("← key '%s' upstream %d [proxy][%s]; failing over", alias, e.code, _fault_for_status(e.code))
                        return
                    BREAKER.record_fail(alias, now, cd)
                    STATS.record(alias, realmodel, e.code, ok=False, forced=forced, failover=bool(tried),
                                 latency=time.time() - _t_send, err_summary=f"HTTP {e.code}")
                    tried.append(alias)
                    log.warning("← key '%s' upstream %d [proxy][%s]; failing over", alias, e.code, _fault_for_status(e.code))
                    e.close()
                    continue
                # forced, or a non-failover status (e.g. 400 bad request) -> relay as-is
                result = self._relay(e, streaming=False, model=realmodel, req_body=body)
                if not result["cancelled"]:
                    STATS.record(alias, realmodel, e.code, ok=False, forced=forced, failover=bool(tried),
                                 latency=time.time() - _t_send, err_summary=f"HTTP {e.code}")
                return
            except Exception as e:
                if not forced:
                    BREAKER.record_fail(alias, now, cooldown_for(0, None))  # conn error -> transient tier
                    STATS.record(alias, realmodel, "ERR", ok=False, forced=forced, failover=bool(tried),
                                 latency=time.time() - _t_send, err_summary=str(e)[:200])
                    tried.append(alias)
                    log.warning("← key '%s' conn error: %s; failing over", alias, e)
                    if len(tried) >= len(policy):
                        msg = classify_error(502, "all-failed", f"{realmodel}: {e}")
                        log.warning(msg)
                        self._send_err(502, msg)
                        return
                    continue
                STATS.record(alias, realmodel, "ERR", ok=False, forced=forced, failover=bool(tried),
                             latency=time.time() - _t_send, err_summary=str(e)[:200])
                self._send_err(502, f"crew-proxy: {e}")
                return

            # Commit to this key, but do not call it healthy until relay completes.
            result = self._relay(resp, streaming=stream, capture=True)
            if not result["cancelled"]:
                if result["ok"]:
                    BREAKER.record_ok(alias)
                elif not forced:
                    BREAKER.record_fail(alias, time.time(), cooldown_for(0, None))
                # 流式首 token 延迟(TTFT):_relay_body 在首个 chunk 写入时记 result["ttft"];
                # 非流式请求没有该字段,记 None。总耗时=流结束时刻-_t_send(下面 latency)。
                _ttft = result.get("ttft")
                if _ttft is not None:
                    _ttft = _ttft - _t_send
                STATS.record(alias, realmodel, getattr(resp, "status", 200) if result["ok"] else "ERR",
                             ok=result["ok"], forced=forced, failover=bool(tried),
                             latency=time.time() - _t_send, err_summary=result["error"],
                             ttft=_ttft)
            captured = result["body"]
            # Token accounting happens HERE — after the body is fully relayed to the
            # client — so parsing never adds latency to the forward path. Best-effort.
            if result["ok"] and captured:
                try:
                    it, ot = parse_usage(captured)
                    STATS.record_usage(alias, realmodel, it, ot)
                    USAGE.add(self.headers.get("X-Crew-Login") or alias, it, ot)
                except Exception:
                    pass
            return

    # -- relay an upstream response (or HTTPError) back to the client --
    # capture=True tees the body into a capped buffer and returns it (for off-path usage
    # parsing by the caller). Streaming still forwards chunk-by-chunk in real time; we only
    # retain up to USAGE_STREAM_CAP bytes for the post-hoc usage scan, then stop retaining.
    def _relay(self, resp, streaming, capture=False, model=None, req_body=None):
        # The relay owns every response, including HTTPError objects. Never retry
        # from here: headers/body may already have reached the downstream client.
        result = {"ok": False, "cancelled": False, "body": b"", "error": None}
        stop = threading.Event()
        upstream = getattr(getattr(getattr(resp, "fp", None), "raw", None), "_sock", None)
        deadline = time.monotonic() + 300

        def disconnected():
            conn = getattr(self, "connection", None)
            if conn is None:
                return False
            try:
                readable, _, _ = select.select([conn], [], [], 0)
                return bool(readable) and conn.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b""
            except BlockingIOError:
                return False
            except (OSError, ValueError):
                return True

        def interrupt_read():
            # shutdown wakes a blocked urllib read; close is done by its owner,
            # not concurrently by the watcher (BufferedReader.close can block).
            try:
                upstream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        def watch():
            while not stop.wait(0.1):
                if disconnected():
                    result["cancelled"] = True
                    interrupt_read()
                    return
                if time.monotonic() >= deadline:
                    result["error"] = "upstream read budget exceeded"
                    interrupt_read()
                    return

        watcher = None
        try:
            conn = getattr(self, "connection", None)
            if conn is not None:
                conn.settimeout(300)
            if upstream is not None:
                upstream.settimeout(300)
                watcher = threading.Thread(target=watch, daemon=True)
                watcher.start()
            if disconnected():
                result["cancelled"] = True
                self.close_connection = True
                return result
            result["body"] = self._relay_body(resp, streaming, capture, model, req_body, result)
        except (BrokenPipeError, ConnectionResetError):
            if disconnected():
                result["cancelled"] = True
            else:
                result["error"] = "upstream connection reset during read"
        except Exception as exc:
            result["error"] = "upstream relay read/write failed: " + type(exc).__name__
        finally:
            stop.set()
            if watcher is not None:
                watcher.join(0.2)
            try:
                resp.close()
            except Exception:
                result["error"] = result["error"] or "upstream responseclose failed"
        if result["cancelled"] or result["error"]:
            result["ok"] = False
            self.close_connection = True
            if not result["cancelled"]:
                try:
                    if not result.get("started"):
                        msg = classify_error(502, "stream-broken")
                        log.warning(msg)
                        self._send_err(502, msg)
                    elif streaming and not result.get("protocol_error") and result["error"] != "upstream protocol error or missing stream terminal":
                        msg = classify_error(502, "stream-broken")
                        log.warning(msg)
                        self.wfile.write(('event: error\ndata: {"type":"error","error":{"type":"api_error","message":"%s"}}\n\n' % msg).encode())
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    result["cancelled"] = True
        return result

    def _relay_body(self, resp, streaming, capture, model, req_body, result):
        code = getattr(resp, "status", None) or getattr(resp, "code", 200)
        headers = resp.headers
        ct = headers.get("Content-Type", "application/json")
        hop = {"connection", "transfer-encoding", "keep-alive", "content-length",
               "proxy-connection"}
        fwd_headers = [(k, v) for k, v in headers.items() if k.lower() not in hop]

        # Non-streaming upstream error (GLM "Prompt exceeds max length" etc.) ->
        # translate to Anthropic wording so Claude Code's auto-compact triggers.
        # Streaming errors cannot be rewritten mid-flight (headers already sent by
        # the SSE pass-through below), but llm-gw answers context overflow with a
        # plain JSON 400 before any SSE starts, so the streaming path never sees it.
        # Content-Type is not checked: translate_prompt_too_long parses the body and
        # returns None for non-JSON, so a mislabeled header can't cause a misfire.
        data = None
        if not streaming and code >= 400:
            data = resp.read()
            translated = translate_prompt_too_long(data)
            if translated is not None:
                log.info("↑ translated upstream %d error to Anthropic 'prompt is too long' "
                         "(%d bytes -> %d bytes)", code, len(data), len(translated))
                # 2026-10-20 自动校准:错误 body 里就有真实窗口(GLM-5.3/kimi 实测带数字;
                # GLM-5.2 不带 → 用统计兜底:成功 max input 上界 + 被拒请求估算下界)。
                # 写 model-windows.conf,下次 launcher 起会话即用真实窗口。
                # 异常静默,绝不影响转发。
                if model:
                    try:
                        maybe_calibrate_from_error(model, data, req_body=req_body)
                    except Exception as _e:
                        log.warning("[ctx-calibrate] skipped: %s", _e)
                data = translated
                fwd_headers = [(k, v) for k, v in fwd_headers if k.lower() != "content-type"]
                fwd_headers.append(("Content-Type", "application/json"))
            # fall through: `data` now holds either the original or the translated body

        if not streaming and data is None:
            data = resp.read()
        self.send_response(code)
        for k, v in fwd_headers:
            self.send_header(k, v)
        buf = bytearray() if capture else None
        terminal = False
        protocol_error = False
        pending = bytearray()

        def inspect_event(event):
            nonlocal terminal, protocol_error
            lines = event.decode("utf-8", "replace").splitlines()
            if any(line.strip() == "event: error" for line in lines):
                protocol_error = True
                result["protocol_error"] = True
            payload = "\n".join(line[5:].lstrip() for line in lines if line.startswith("data:"))
            if not payload:
                return
            if payload == chr(91) + "DONE" + chr(93):
                terminal = True
                return
            try:
                obj = json.loads(payload)
                if not isinstance(obj, dict):
                    protocol_error = True
                    return
                kind = obj.get("type", "")
                if obj.get("error") is not None or kind in ("error", "response.failed", "response.incomplete"):
                    protocol_error = True
                if kind in ("message_stop", "response.completed"):
                    terminal = True
                if any(c.get("finish_reason") is not None for c in obj.get("choices", []) if isinstance(c, dict)):
                    terminal = True
            except (ValueError, TypeError):
                protocol_error = True
            finally:
                result["protocol_error"] = protocol_error

        if streaming:
            self.send_header("Connection", "close")
            self.end_headers()
            result["started"] = True
            self.close_connection = True
            while True:
                chunk = resp.read1(4096)
                if not chunk:
                    break
                if "ttft" not in result:
                    # 2026-10-28:首 chunk 到达即首 token(TTFT)。调用方(record)拿它减发送
                    # 起点得流式首字节延迟。只记一次,写在任何 flush 之前最贴近上游真实首包。
                    result["ttft"] = time.time()
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    result["cancelled"] = True
                    raise
                pending.extend(chunk)
                # SSE permits LF, CRLF and CR; retain partial events across reads.
                events = re.split(b"\r?\n\r?\n|\r\r", bytes(pending))
                for event in events[:-1]:
                    inspect_event(event)
                pending[:] = events[-1]
                if len(pending) > USAGE_STREAM_CAP:
                    raise ValueError("oversized upstream SSE event")
                if buf is not None and len(buf) < USAGE_STREAM_CAP:
                    buf.extend(chunk[:USAGE_STREAM_CAP - len(buf)])
            if pending.strip():
                # An unterminated SSE event is not dispatched by compliant clients.
                protocol_error = True
            result["ok"] = code < 400 and terminal and not protocol_error
            if not result["ok"]:
                result["error"] = result["error"] or "upstream protocol error or missing stream terminal"
                # Keep original error events verbatim; otherwise explicitly signal
                # failure rather than fabricating a successful stream terminator.
                if not protocol_error and not result["cancelled"] and result["error"] == "upstream protocol error or missing stream terminal":
                    self.wfile.write(b'event: error\ndata: {"type":"error","error":{"type":"api_error","message":"upstream stream ended without terminal"}}\n\n')
                    self.wfile.flush()
        else:
            if data is None:
                data = resp.read()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            result["started"] = True
            try:
                self.wfile.write(data)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                result["cancelled"] = True
                raise
            result["ok"] = code < 400
            if result["ok"]:
                try:
                    obj = json.loads(data)
                    if isinstance(obj, dict) and (obj.get("error") is not None or obj.get("type") == "error" or obj.get("status") in ("failed", "incomplete")):
                        result["ok"] = False
                        result["error"] = "upstream protocol error"
                except (ValueError, TypeError):
                    if "json" in ct:
                        result["ok"] = False
                        result["error"] = "invalid upstream JSON"
            if buf is not None:
                buf.extend(data[:USAGE_STREAM_CAP])
        return bytes(buf) if buf is not None else b""
from _crew_server import main

if __name__ == "__main__":
    main()
