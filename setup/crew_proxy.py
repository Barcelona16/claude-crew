#!/usr/bin/env python3
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
CCR config (~/.claude-code-router/config.json) must have one provider per (model, key) pair
  (same base_url, different api_key) — crew setup generates these.

Env:
  CREW_PROXY_PORT     listen port (default 8788)
  CREW_CCR_URL        upstream CCR base (default http://127.0.0.1:3456)
  CREW_CONFIG_DIR     config dir (default ~/.config/claude-crew, honors XDG_CONFIG_HOME)
  CREW_CCR_CONFIG     CCR config.json path (default ~/.claude-code-router/config.json)
  CREW_PROXY_FAILS    consecutive failures before a key trips (default 3)
  CREW_PROXY_COOLDOWN tripped-key cooldown seconds (default 60)
  CREW_PROXY_STATE    circuit-breaker state dump (default ~/.local/share/claude-crew/proxy-state.json)
"""

import json
import logging
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── config ──────────────────────────────────────────────────────────────────────
def _cfg_dir():
    return os.environ.get("CREW_CONFIG_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "claude-crew"
    )

CFG_DIR   = _cfg_dir()
KEYS_FILE = os.path.join(CFG_DIR, "keys.conf")
POLICY    = os.path.join(CFG_DIR, "key-policy.conf")
CCR_CFG   = os.environ.get("CREW_CCR_CONFIG") or os.path.expanduser("~/.claude-code-router/config.json")
CCR_URL   = (os.environ.get("CREW_CCR_URL") or "http://127.0.0.1:3456").rstrip("/")
PORT      = int(os.environ.get("CREW_PROXY_PORT", "8788"))
FAIL_N    = int(os.environ.get("CREW_PROXY_FAILS", "3"))
COOLDOWN  = float(os.environ.get("CREW_PROXY_COOLDOWN", "60"))
STATE_FILE = os.environ.get("CREW_PROXY_STATE") or os.path.expanduser(
    "~/.local/share/claude-crew/proxy-state.json"
)
FAIL_CODES = {401, 403, 429}  # plus any 5xx and connection errors (see _is_fail)

logging.basicConfig(
    stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s [crew-proxy] %(message)s", datefmt="%H:%M:%S",
)
log = logging.getLogger("crew-proxy")


def _is_fail(code):
    return code in FAIL_CODES or code >= 500


# ── config loaders (re-read on each request; files are tiny) ──────────────────────
def load_keys():
    """keys.conf -> {alias: api_key}."""
    out = {}
    try:
        with open(KEYS_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return out


def load_policy():
    """key-policy.conf -> {realmodel: [alias, ...]} (priority order)."""
    out = {}
    try:
        with open(POLICY) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                model, aliases = line.split("=", 1)
                out[model.strip()] = aliases.split()
    except FileNotFoundError:
        pass
    return out


def load_ccr_providers():
    """CCR config -> list of {name, models[], api_key}."""
    try:
        with open(CCR_CFG) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    return cfg.get("Providers") or cfg.get("providers") or []


def provider_for(realmodel, api_key, providers):
    """Find the CCR provider serving `realmodel` with `api_key` (mirrors crew's ccr_provider_for)."""
    for p in providers:
        if realmodel in (p.get("models") or []) and (p.get("api_key") or p.get("apiKey")) == api_key:
            return p.get("name")
    return None


# ── crew CLI bridge (crew is the single state-mutation entry point) ───────────────
CREW_STATE = os.environ.get("CREW_STATE") or os.path.expanduser("~/.local/share/claude-crew")
CREW_BIN = os.environ.get("CREW_BIN") or shutil.which("crew") or "crew"
# Names/aliases/models we will ever pass to a subprocess or write as a filename. Strict
# allowlist — anything with a shell metacharacter or path separator is rejected outright.
SAFE_NAME = re.compile(r"^[A-Za-z0-9._,-]+$")


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



# ── circuit breaker (per key alias) ───────────────────────────────────────────────
class Breaker:
    """Per-alias consecutive-failure counter with a cooldown trip. Thread-safe."""

    def __init__(self):
        self._lock = threading.Lock()
        self._fails = {}      # alias -> consecutive failure count
        self._tripped = {}    # alias -> cooldown-expiry epoch
        self._load()

    def healthy(self, alias, now):
        exp = self._tripped.get(alias)
        if exp is None:
            return True
        if now >= exp:            # cooldown elapsed -> auto-recover
            self._tripped.pop(alias, None)
            self._fails[alias] = 0
            return True
        return False

    def pick(self, aliases, now):
        """Highest-priority healthy alias; None if every alias is tripped."""
        with self._lock:
            for a in aliases:
                if self.healthy(a, now):
                    return a
            return None

    def record_ok(self, alias):
        with self._lock:
            if self._fails.get(alias):
                self._fails[alias] = 0
            self._persist()

    def record_fail(self, alias, now):
        """Increment; trip at FAIL_N. Returns True if this failure tripped the key."""
        with self._lock:
            n = self._fails.get(alias, 0) + 1
            self._fails[alias] = n
            tripped = False
            if n >= FAIL_N:
                self._tripped[alias] = now + COOLDOWN
                tripped = True
                log.warning("key '%s' TRIPPED after %d fails; cooling down %.0fs", alias, n, COOLDOWN)
            self._persist()
            return tripped

    def snapshot(self, aliases, now):
        """Per-alias {consec_fails, state, cooldown_left} for the dashboard. Read-only:
        does NOT mutate (unlike healthy(), which auto-recovers) so /api/status is side-effect free."""
        out = {}
        with self._lock:
            for a in aliases:
                exp = self._tripped.get(a)
                if exp is not None and now < exp:
                    out[a] = {"consec_fails": self._fails.get(a, 0), "state": "tripped",
                              "cooldown_left": round(exp - now)}
                else:
                    out[a] = {"consec_fails": self._fails.get(a, 0), "state": "healthy",
                              "cooldown_left": 0}
        return out

    # -- persistence (best effort; state survives restart) --
    def _persist(self):
        try:
            os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"fails": self._fails, "tripped": self._tripped}, f)
            os.replace(tmp, STATE_FILE)
        except OSError:
            pass

    def _load(self):
        try:
            with open(STATE_FILE) as f:
                d = json.load(f)
            self._fails = {str(k): int(v) for k, v in (d.get("fails") or {}).items()}
            self._tripped = {str(k): float(v) for k, v in (d.get("tripped") or {}).items()}
        except (FileNotFoundError, json.JSONDecodeError, ValueError):
            pass


BREAKER = Breaker()


class Stats:
    """Request-level counters + a bounded in-memory log ring buffer for the dashboard.
    Deliberately NOT persisted (keeps proxy-state.json small; "recent activity" resets on
    restart) and NOT parsing response bodies (no token/cost accounting this version)."""

    LOG_MAX = 200

    def __init__(self):
        self._lock = threading.Lock()
        self.totals = {"requests": 0, "ok": 0, "fail": 0}
        self.per_key = {}   # alias -> {requests, ok, fail}
        self._logs = []     # list of dicts, newest last, capped at LOG_MAX
        self._t0 = time.time()

    def _key(self, alias):
        return self.per_key.setdefault(alias, {"requests": 0, "ok": 0, "fail": 0})

    def record(self, alias, model, status, ok, forced, failover):
        with self._lock:
            self.totals["requests"] += 1
            self.totals["ok" if ok else "fail"] += 1
            k = self._key(alias)
            k["requests"] += 1
            k["ok" if ok else "fail"] += 1
            self._logs.append({
                "t": round(time.time() - self._t0, 1),
                "model": model, "alias": alias, "status": status,
                "ok": ok, "forced": forced, "failover": failover,
            })
            if len(self._logs) > self.LOG_MAX:
                del self._logs[:-self.LOG_MAX]

    def status(self):
        with self._lock:
            return {"totals": dict(self.totals),
                    "per_key": {a: dict(v) for a, v in self.per_key.items()}}

    def logs(self, n):
        with self._lock:
            return self._logs[-n:][::-1]  # newest first


STATS = Stats()


# ── dashboard (single self-contained page; vanilla JS polling, no build step) ─────
DASHBOARD_HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>crew-proxy</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:#0d1117;color:#c9d1d9}
header{padding:12px 18px;border-bottom:1px solid #21262d;display:flex;gap:16px;align-items:baseline;flex-wrap:wrap}
h1{font-size:16px;margin:0;color:#58a6ff}
.muted{color:#8b949e;font-size:12px}
main{padding:18px;display:grid;gap:22px;max-width:1100px}
section h2{font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:#8b949e;margin:0 0 8px}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #21262d;white-space:nowrap}
th{color:#8b949e;font-weight:600}
td.dir{color:#8b949e;max-width:280px;overflow:hidden;text-overflow:ellipsis}
.pill{padding:1px 8px;border-radius:10px;font-size:12px}
.live,.healthy{background:#132e1a;color:#3fb950}
.tripped,.fail{background:#3a1416;color:#f85149}
.resumable{background:#1c2330;color:#58a6ff}
.new{background:#2b2416;color:#d29922}
button{font:inherit;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;padding:3px 10px;cursor:pointer}
button:hover{background:#30363d}
button.danger{border-color:#5a1e1e}button.danger:hover{background:#3a1416}
#logs{max-height:280px;overflow:auto}
.err{color:#f85149;font-size:12px}
.dim{color:#6e7681}
dialog{background:#161b22;color:#c9d1d9;border:1px solid #30363d;border-radius:10px;padding:18px;min-width:320px}
dialog input,dialog select{font:inherit;width:100%;padding:5px;margin:4px 0 12px;background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:6px}
label{font-size:12px;color:#8b949e}
</style></head><body>
<header>
  <h1>crew-proxy</h1>
  <span class="muted" id="meta"></span>
  <span class="muted" id="totals"></span>
  <span class="muted dim" style="margin-left:auto" id="tick"></span>
</header>
<main>
  <section><h2>Keys</h2><table id="keys"><thead><tr>
    <th>alias</th><th>state</th><th>requests</th><th>ok</th><th>fail</th><th>consec</th><th>cooldown</th>
  </tr></thead><tbody></tbody></table></section>

  <section><h2>Sessions</h2>
    <div class="err" id="sess-err"></div>
    <table id="sessions"><thead><tr>
      <th>name</th><th>status</th><th>model</th><th>key</th><th>dir</th><th></th>
    </tr></thead><tbody></tbody></table>
  </section>

  <section><h2>Recent requests</h2><div id="logs"><table><thead><tr>
    <th>t</th><th>model</th><th>key</th><th>status</th><th></th>
  </tr></thead><tbody></tbody></table></div></section>

  <section><button id="addbtn">+ add key / provider (writes CCR config)</button></section>
</main>

<dialog id="editdlg"><form method="dialog">
  <h2 id="edittitle">edit session</h2>
  <label>model</label><input id="edit-model" placeholder="preset name">
  <label>key (alias, empty to clear)</label><input id="edit-key" placeholder="alias or blank">
  <div style="display:flex;gap:8px;justify-content:flex-end">
    <button value="cancel">cancel</button><button id="edit-save" value="save">save</button>
  </div>
</form></dialog>

<dialog id="adddlg"><form method="dialog">
  <h2>add key + CCR provider</h2>
  <label>alias</label><input id="add-alias" placeholder="gw2">
  <label>api key</label><input id="add-key" placeholder="sk-...">
  <label>model</label><input id="add-model" placeholder="model name (must match a preset)">
  <label>base url</label><input id="add-base" placeholder="https://api.provider.com/v1/chat/completions">
  <label>transformer</label><select id="add-tf"><option>Anthropic</option><option>OpenAI</option></select>
  <div style="display:flex;gap:8px;justify-content:flex-end">
    <button value="cancel">cancel</button><button id="add-save" value="save" class="danger">write CCR config</button>
  </div>
</form></dialog>

<script>
const $=s=>document.querySelector(s), tb=s=>document.querySelector(s+' tbody');
function pill(s){return `<span class="pill ${s}">${s}</span>`}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}

async function jget(u){const r=await fetch(u);if(!r.ok)throw new Error(r.status);return r.json()}
async function jpost(u,b){const r=await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});return r.json()}

async function refresh(){
  try{
    const s=await jget('/api/status');
    $('#meta').textContent=`:${s.port} -> ${s.ccr_url}  ·  trip@${s.fail_n} cooldown ${s.cooldown}s`;
    $('#totals').textContent=`req ${s.totals.requests}  ok ${s.totals.ok}  fail ${s.totals.fail}`;
    tb('#keys').innerHTML=s.keys.map(k=>`<tr><td>${esc(k.alias)}</td><td>${pill(k.state)}</td>
      <td>${k.requests}</td><td>${k.ok}</td><td>${k.fail}</td><td>${k.consec_fails}</td>
      <td>${k.cooldown_left?k.cooldown_left+'s':'-'}</td></tr>`).join('')||'<tr><td class=dim colspan=7>no key activity yet</td></tr>';
  }catch(e){$('#meta').innerHTML='<span class=err>proxy status unavailable</span>'}

  try{
    const d=await jget('/api/sessions');
    $('#sess-err').textContent=d.error||'';
    tb('#sessions').innerHTML=(d.sessions||[]).map(x=>`<tr>
      <td>${esc(x.name)}</td><td>${pill(x.status)}</td><td>${esc(x.model)}</td><td>${esc(x.key)}</td>
      <td class=dir title="${esc(x.dir)}">${esc(x.dir)}</td>
      <td><button onclick="editSess('${esc(x.name)}','${esc(x.model)}','${esc(x.key)}')">edit</button>
          <button class=danger onclick="killSess('${esc(x.name)}')">kill</button></td></tr>`).join('')
      ||'<tr><td class=dim colspan=6>no sessions</td></tr>';
  }catch(e){$('#sess-err').textContent='sessions unavailable'}

  try{
    const l=await jget('/api/logs?n=100');
    tb('#logs table').innerHTML=(l.logs||[]).map(x=>`<tr><td class=dim>${x.t}s</td><td>${esc(x.model)}</td>
      <td>${esc(x.alias)}</td><td>${x.ok?pill('healthy'):'<span class=err>'+esc(x.status)+'</span>'}</td>
      <td class=dim>${x.failover?'failover':''}${x.forced?' forced':''}</td></tr>`).join('')
      ||'<tr><td class=dim colspan=5>no requests yet</td></tr>';
  }catch(e){}
  $('#tick').textContent='updated '+new Date().toLocaleTimeString();
}

let editName=null;
function editSess(name,model,key){editName=name;$('#edittitle').textContent='edit '+name;
  $('#edit-model').value=model==='-'?'':model;$('#edit-key').value=key==='-'?'':key;$('#editdlg').showModal()}
$('#edit-save').onclick=async()=>{await jpost('/api/session/config',
  {name:editName,model:$('#edit-model').value.trim(),key:$('#edit-key').value.trim()});setTimeout(refresh,200)};

async function killSess(name){if(!confirm('kill session "'+name+'"? (removes tmux + crew state; transcript kept)'))return;
  const r=await jpost('/api/session/kill',{name});if(r&&r.error)alert(r.error);setTimeout(refresh,300)}

$('#addbtn').onclick=()=>$('#adddlg').showModal();
$('#add-save').onclick=async()=>{
  if(!confirm('Write a new provider into your CCR config? A backup is made first.'))return;
  const r=await jpost('/api/ccr/provider',{alias:$('#add-alias').value.trim(),key:$('#add-key').value.trim(),
    model:$('#add-model').value.trim(),base_url:$('#add-base').value.trim(),transformer:$('#add-tf').value});
  alert(r&&r.ok?('added. backup: '+r.backup_path+'\nRun `crew up` or kickstart CCR to reload.'):('failed: '+(r&&r.error)));
  setTimeout(refresh,200)};

refresh();setInterval(refresh,3000);
</script></body></html>"""


# ── HTTP handler ──────────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):  # silence default access log
        pass

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n) if n else b""

    def _fwd_headers(self):
        """Client headers minus hop-by-hop; Host rewritten to CCR."""
        skip = {"host", "content-length", "connection", "transfer-encoding",
                "proxy-connection", "keep-alive"}
        out = {k: v for k, v in self.headers.items() if k.lower() not in skip}
        return out

    def _send_err(self, code, msg):
        body = json.dumps({"error": {"message": msg, "type": "crew_proxy_error"}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

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

    # -- dashboard data endpoints (read-only) --
    def _api_status(self):
        now = time.time()
        st = STATS.status()
        aliases = sorted(set(st["per_key"]) | set(load_policy().get("*", [])) |
                         {a for aliases in load_policy().values() for a in aliases})
        brk = BREAKER.snapshot(aliases, now)
        keys = []
        for a in sorted(set(st["per_key"]) | set(brk)):
            pk = st["per_key"].get(a, {"requests": 0, "ok": 0, "fail": 0})
            b = brk.get(a, {"consec_fails": 0, "state": "healthy", "cooldown_left": 0})
            keys.append({"alias": a, **pk, **b})
        return {"port": PORT, "ccr_url": CCR_URL, "fail_n": FAIL_N, "cooldown": COOLDOWN,
                "totals": st["totals"], "keys": keys}

    def _api_sessions(self):
        out, err = run_crew(["ls", "--json"])
        if out is None:
            return {"sessions": [], "error": err}
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return {"sessions": [], "error": "crew ls --json returned non-JSON"}

    def _api_logs(self):
        try:
            n = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("n", ["100"])[0])
        except (ValueError, TypeError):
            n = 100
        n = max(1, min(n, Stats.LOG_MAX))
        return {"logs": STATS.logs(n)}


    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/dashboard", "/dashboard/"):
            self._send_html(DASHBOARD_HTML)
        elif path == "/api/status":
            self._send_json(self._api_status())
        elif path == "/api/sessions":
            self._send_json(self._api_sessions())
        elif path == "/api/logs":
            self._send_json(self._api_logs())
        else:
            self._passthrough(b"")

    def do_POST(self):
        body = self._read_body()
        # Only /v1/messages and /v1/chat/completions carry a model to route on.
        path = self.path.split("?")[0]
        if path.endswith("/messages") or path.endswith("/chat/completions"):
            self._route(body)
        else:
            self._passthrough(body)

    # -- plain reverse proxy (no key logic): health, /v1/models, unknown paths --
    def _passthrough(self, body):
        url = CCR_URL + self.path
        req = urllib.request.Request(url, data=body or None, headers=self._fwd_headers(),
                                     method=self.command)
        try:
            resp = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as e:
            self._relay(e, streaming=False)
        except Exception as e:
            self._send_err(502, f"crew-proxy: CCR unreachable: {e}")
        else:
            self._relay(resp, streaming=False)

    # -- key-aware routing with failover --
    def _route(self, body):
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._passthrough(body)  # not JSON we understand; just forward
            return

        model = payload.get("model", "") or ""
        realmodel = model.split(",", 1)[1] if "," in model else model
        stream = bool(payload.get("stream", False))

        policy = load_policy().get(realmodel, [])
        if not policy:
            # No priority policy for this model -> behave as a plain proxy (CCR routes as configured).
            self._passthrough(body)
            return

        keys = load_keys()
        providers = load_ccr_providers()
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
                    self._send_err(502, f"crew-proxy: no usable key for {realmodel}")
                    return
                continue

            provider = provider_for(realmodel, api_key, providers)
            if not provider:
                log.warning("no CCR provider serves '%s' with key '%s'; skipping", realmodel, alias)
                tried.append(alias)
                if len(tried) >= len(policy):
                    self._send_err(502, f"crew-proxy: no CCR provider for {realmodel}/{alias}")
                    return
                continue

            fwd = {**payload, "model": f"{provider},{realmodel}"}
            fwd_body = json.dumps(fwd).encode()
            log.info("→ %-24s via key '%s'%s (stream=%s)", realmodel, alias,
                     " [FORCED]" if forced else "", stream)

            req = urllib.request.Request(
                CCR_URL + self.path, data=fwd_body,
                headers={**self._fwd_headers(), "Content-Type": "application/json"},
                method="POST",
            )
            try:
                resp = urllib.request.urlopen(req, timeout=300)
            except urllib.error.HTTPError as e:
                if _is_fail(e.code) and not forced:
                    BREAKER.record_fail(alias, now)
                    STATS.record(alias, realmodel, e.code, ok=False, forced=forced, failover=bool(tried))
                    tried.append(alias)
                    log.warning("← key '%s' upstream %d; failing over", alias, e.code)
                    if len(tried) >= len(policy):
                        self._relay(e, streaming=False)  # exhausted -> surface last error
                        return
                    continue
                # forced, or a non-failover status (e.g. 400 bad request) -> relay as-is
                STATS.record(alias, realmodel, e.code, ok=not _is_fail(e.code), forced=forced, failover=bool(tried))
                self._relay(e, streaming=False)
                return
            except Exception as e:
                if not forced:
                    BREAKER.record_fail(alias, now)
                    STATS.record(alias, realmodel, "ERR", ok=False, forced=forced, failover=bool(tried))
                    tried.append(alias)
                    log.warning("← key '%s' conn error: %s; failing over", alias, e)
                    if len(tried) >= len(policy):
                        self._send_err(502, f"crew-proxy: all keys failed for {realmodel}: {e}")
                        return
                    continue
                STATS.record(alias, realmodel, "ERR", ok=False, forced=forced, failover=bool(tried))
                self._send_err(502, f"crew-proxy: {e}")
                return

            # header phase reached with a good status -> commit to this key, relay body.
            BREAKER.record_ok(alias)
            STATS.record(alias, realmodel, getattr(resp, "status", 200), ok=True,
                         forced=forced, failover=bool(tried))
            self._relay(resp, streaming=stream)
            return

    # -- relay an upstream response (or HTTPError) back to the client --
    def _relay(self, resp, streaming):
        code = getattr(resp, "status", None) or getattr(resp, "code", 200)
        headers = resp.headers
        ct = headers.get("Content-Type", "application/json")
        self.send_response(code)
        hop = {"connection", "transfer-encoding", "keep-alive", "content-length",
               "proxy-connection"}
        for k, v in headers.items():
            if k.lower() not in hop:
                self.send_header(k, v)
        if streaming:
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            data = resp.read()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass


def main():
    log.info("listening on http://127.0.0.1:%d  ->  CCR %s", PORT, CCR_URL)
    log.info("keys=%s policy=%s ccr=%s", KEYS_FILE, POLICY, CCR_CFG)
    log.info("breaker: trip after %d fails, cooldown %.0fs", FAIL_N, COOLDOWN)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("stopped")


if __name__ == "__main__":
    main()
