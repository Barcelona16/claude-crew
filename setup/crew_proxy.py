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

import atexit
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
USAGE_FILE = os.path.join(CFG_DIR, "usage.json")
# crew demo gif for the /usage intro. Env override, else next to this script, else the
# repo's docs/ (dev). Absent -> the <img> just 404s, harmless.
CREW_DEMO_GIF = os.environ.get("CREW_DEMO_GIF") or next(
    (p for p in (os.path.join(os.path.dirname(os.path.abspath(__file__)), "crew-demo.gif"),
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "crew-demo.gif"))
     if os.path.exists(p)), os.path.join(os.path.dirname(os.path.abspath(__file__)), "crew-demo.gif"))
GATEWAY_AUTH = os.environ.get("GATEWAY_AUTH") or os.path.join(CFG_DIR, "gateway-auth.json")
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


COOLDOWN_FILE = os.path.join(CFG_DIR, "cooldown.conf")


def load_cooldown():
    """cooldown.conf -> {daily_quota, transient, retryafter_max} in seconds.

    Optional file; absent -> {} and callers fall back to the single COOLDOWN constant
    (so behavior is byte-identical to before this feature — the default-harmless rule)."""
    out = {}
    try:
        with open(COOLDOWN_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                try:
                    out[k.strip()] = float(v.strip())
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return out


def cooldown_for(code, retry_after):
    """Pick a cooldown duration (seconds) for a failure, per cooldown.conf.

    - No cooldown.conf at all -> fall back to the single COOLDOWN constant (harmless default).
    - 429 with a Retry-After <= retryafter_max -> use that Retry-After verbatim (upstream knows best).
    - 429 with a large/absent Retry-After -> daily_quota (quota exhausted, park for a day).
    - anything else (401/403/5xx/conn error) -> transient (short cooldown).
    """
    conf = load_cooldown()
    if not conf:
        return COOLDOWN
    transient = conf.get("transient", COOLDOWN)
    if code == 429:
        ra_max = conf.get("retryafter_max", 300.0)
        if retry_after is not None and retry_after <= ra_max:
            return retry_after
        return conf.get("daily_quota", 86400.0)
    return transient


def parse_retry_after(headers):
    """Extract Retry-After seconds from response headers; None if absent/unparseable.
    Only the delta-seconds form is honored (HTTP-date form is rare here and ignored)."""
    if headers is None:
        return None
    raw = headers.get("Retry-After") or headers.get("retry-after")
    if raw is None:
        return None
    try:
        return float(str(raw).strip())
    except (ValueError, TypeError):
        return None


def load_gateway_auth():
    """gateway-auth.json -> {login_key: {maps_to, allow_models, erp, admin}}. Empty dict if absent
    (the dashboard's login-table section then just shows nothing — harmless default)."""
    try:
        with open(GATEWAY_AUTH) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for k, v in data.items():
        if not isinstance(v, dict):
            continue
        out[k] = {"maps_to": str(v.get("maps_to", "")),
                  "allow_models": list(v.get("allow_models") or []),
                  "erp": str(v.get("erp", "")),
                  "admin": bool(v.get("admin"))}
    return out


def mask_key(key):
    """Show only enough of a real API key to recognize it, never the secret itself:
    'sk-…3f9a' (last 4). Empty/short keys collapse to '…'. Used everywhere a key would
    otherwise surface in an API response or the dashboard."""
    if not key:
        return "…"
    tail = key[-4:] if len(key) >= 4 else key
    return "sk-…" + tail


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

    def record_fail(self, alias, now, cooldown=None):
        """Increment; trip at FAIL_N. Returns True if this failure tripped the key.
        cooldown: seconds to park a tripped key (default None -> the single COOLDOWN
        constant, i.e. behavior identical to before tiered cooldown was added)."""
        cd = COOLDOWN if cooldown is None else cooldown
        with self._lock:
            n = self._fails.get(alias, 0) + 1
            self._fails[alias] = n
            tripped = False
            if n >= FAIL_N:
                self._tripped[alias] = now + cd
                tripped = True
                log.warning("key '%s' TRIPPED after %d fails; cooling down %.0fs", alias, n, cd)
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
    """Request-level counters + token usage + a bounded in-memory log ring buffer.
    Token usage is BEST-EFFORT and parsed strictly OFF the forward path (see _relay):
    a missing/garbled usage just means that request isn't counted — it never blocks or
    slows the proxying. Counts only (tokens + request counts), never prompt/response text."""

    LOG_MAX = 200

    def __init__(self):
        self._lock = threading.Lock()
        self.totals = {"requests": 0, "ok": 0, "fail": 0, "in_tokens": 0, "out_tokens": 0}
        self.per_key = {}    # alias -> {requests, ok, fail, in_tokens, out_tokens}
        self.per_model = {}  # model -> {requests, in_tokens, out_tokens}
        self._logs = []      # list of dicts, newest last, capped at LOG_MAX
        self._t0 = time.time()

    def _key(self, alias):
        return self.per_key.setdefault(
            alias, {"requests": 0, "ok": 0, "fail": 0, "in_tokens": 0, "out_tokens": 0})

    def _model(self, model):
        return self.per_model.setdefault(model, {"requests": 0, "in_tokens": 0, "out_tokens": 0})

    def record(self, alias, model, status, ok, forced, failover, latency=None):
        with self._lock:
            self.totals["requests"] += 1
            self.totals["ok" if ok else "fail"] += 1
            k = self._key(alias)
            k["requests"] += 1
            k["ok" if ok else "fail"] += 1
            self._model(model)["requests"] += 1
            entry = {
                "t": round(time.time() - self._t0, 1),
                "model": model, "alias": alias, "status": status,
                "ok": ok, "forced": forced, "failover": failover,
            }
            if latency is not None:
                entry["ms"] = round(latency * 1000)
            self._logs.append(entry)
            if len(self._logs) > self.LOG_MAX:
                del self._logs[:-self.LOG_MAX]

    def record_usage(self, alias, model, in_tok, out_tok):
        """Add token usage to the last-recorded request's key/model. Best-effort; called
        AFTER the response body has been relayed to the client (never on the hot path)."""
        if not in_tok and not out_tok:
            return
        with self._lock:
            self.totals["in_tokens"] += in_tok
            self.totals["out_tokens"] += out_tok
            k = self._key(alias)
            k["in_tokens"] += in_tok
            k["out_tokens"] += out_tok
            m = self._model(model)
            m["in_tokens"] += in_tok
            m["out_tokens"] += out_tok
            if self._logs and self._logs[-1]["alias"] == alias:
                self._logs[-1]["in_tok"] = in_tok
                self._logs[-1]["out_tok"] = out_tok

    def status(self):
        with self._lock:
            return {"totals": dict(self.totals),
                    "per_key": {a: dict(v) for a, v in self.per_key.items()},
                    "per_model": {m: dict(v) for m, v in self.per_model.items()}}

    def logs(self, n):
        with self._lock:
            return self._logs[-n:][::-1]  # newest first


STATS = Stats()


class UsageSeries:
    """Per-login-key token usage bucketed into fixed time windows, for the self-service
    usage chart. Separate from Stats (which counts by real alias): here the dimension is
    the client LOGIN key, so two tickets that map to the same real key stay distinct.

    Thread-safe: add() holds the lock for the whole read-modify-write and accumulates
    directly by (login, bucket) — it never relies on a 'last request' heuristic, so it is
    correct under concurrent requests sharing one login key. Counts only, never content."""

    BUCKET_SEC = 600          # 10-minute buckets
    WINDOW_DAYS = 7
    FLUSH_MIN_SEC = 20

    def __init__(self):
        self._lock = threading.Lock()
        # login -> {bucket_ts(int) -> {"turns", "inTok", "outTok"}}
        self._buckets = {}
        self._last_flush = 0.0
        self._dirty = False

    def _bucket_ts(self, now):
        return int(now // self.BUCKET_SEC) * self.BUCKET_SEC

    def add(self, login, in_tok, out_tok, now=None):
        if now is None:
            now = time.time()
        bts = self._bucket_ts(now)
        with self._lock:
            login_map = self._buckets.setdefault(login, {})
            b = login_map.setdefault(bts, {"turns": 0, "inTok": 0, "outTok": 0})
            b["turns"] += 1
            b["inTok"] += int(in_tok or 0)
            b["outTok"] += int(out_tok or 0)
            self._dirty = True

    def prune(self, now=None):
        if now is None:
            now = time.time()
        cutoff = now - self.WINDOW_DAYS * 86400
        with self._lock:
            for login in list(self._buckets):
                login_map = self._buckets[login]
                for bts in list(login_map):
                    if bts < cutoff:
                        del login_map[bts]
                if not login_map:
                    del self._buckets[login]

    def snapshot(self):
        with self._lock:
            return {
                "version": 1,
                "bucketSec": self.BUCKET_SEC,
                "buckets": {
                    login: {str(bts): dict(v) for bts, v in series.items()}
                    for login, series in self._buckets.items()
                },
            }

    def flush(self, force=False, now=None):
        if now is None:
            now = time.time()
        with self._lock:
            if not force and (not self._dirty or now - self._last_flush < self.FLUSH_MIN_SEC):
                return
        data = self.snapshot()
        try:
            os.makedirs(os.path.dirname(USAGE_FILE), exist_ok=True)
            tmp = USAGE_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, USAGE_FILE)
        except OSError as e:
            log.warning("usage flush failed: %s", e)
            return  # leave _dirty=True so the next flush retries
        with self._lock:
            self._last_flush = now
            self._dirty = False

    def load(self):
        try:
            with open(USAGE_FILE) as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return
        if not isinstance(data, dict) or not isinstance(data.get("buckets"), dict):
            return
        restored = {}
        for login, series in data["buckets"].items():
            if not isinstance(series, dict):
                continue
            out = {}
            for bts, v in series.items():
                try:
                    out[int(bts)] = {"turns": int(v.get("turns", 0)),
                                     "inTok": int(v.get("inTok", 0)),
                                     "outTok": int(v.get("outTok", 0))}
                except (ValueError, TypeError, AttributeError):
                    continue
            if out:
                restored[str(login)] = out
        with self._lock:
            self._buckets = restored
        # Prune relative to the newest restored bucket (data may predate wall-clock,
        # e.g. after a long downtime): drop only what is >WINDOW_DAYS older than the
        # series' own latest point, so a valid round-trip survives.
        newest = max((bts for series in restored.values() for bts in series),
                     default=None)
        if newest is not None:
            self.prune(now=newest + self.BUCKET_SEC)

    def series(self, login, days=7, now=None):
        if now is None:
            now = time.time()
        cutoff = now - days * 86400
        with self._lock:
            if login is None:
                merged = {}
                for series in self._buckets.values():
                    for bts, v in series.items():
                        if bts < cutoff:
                            continue
                        m = merged.setdefault(bts, {"turns": 0, "inTok": 0, "outTok": 0})
                        m["turns"] += v["turns"]; m["inTok"] += v["inTok"]; m["outTok"] += v["outTok"]
                src = merged
            else:
                src = {bts: dict(v) for bts, v in self._buckets.get(login, {}).items() if bts >= cutoff}
        buckets = []
        daily = {}
        tot_new = tot_turns = 0
        for bts in sorted(src):
            v = src[bts]
            new = v["inTok"] + v["outTok"]
            tot_new += new; tot_turns += v["turns"]
            buckets.append({
                "t": bts * 1000,
                "newTokens": new, "inputSum": v["inTok"], "outputSum": v["outTok"],
                "turns": v["turns"],
                "perReqNew": round(new / v["turns"]) if v["turns"] else 0,
            })
            day = time.strftime("%Y-%m-%d", time.localtime(bts))
            dd = daily.setdefault(day, {"day": day, "newTokens": 0, "turns": 0})
            dd["newTokens"] += new; dd["turns"] += v["turns"]
        daily_list = []
        for day in sorted(daily):
            dd = daily[day]
            dd["perReqNew"] = round(dd["newTokens"] / dd["turns"]) if dd["turns"] else 0
            daily_list.append(dd)
        return {
            "generatedAt": int(now * 1000),
            "bucketMin": self.BUCKET_SEC // 60,
            "windowH": days * 24,
            "login": login if login is not None else "__all__",
            "buckets": buckets,
            "daily": daily_list,
            "totals": {
                "newTokens": tot_new, "turns": tot_turns,
                "perReqNew": round(tot_new / tot_turns) if tot_turns else 0,
                "days": len(daily_list),
            },
        }


USAGE = UsageSeries()


# ── usage parsing (best-effort, OFF the forward path) ─────────────────────────────
USAGE_STREAM_CAP = 256 * 1024  # cap the bytes we retain for stream usage scanning


def parse_usage(body_bytes):
    """Extract (input_tokens, output_tokens) from a captured response body. Handles both
    the non-streaming JSON shape and SSE streams. Returns (0, 0) on anything unexpected —
    this is best-effort accounting, never a hard dependency. Supports Anthropic
    (input_tokens/output_tokens) and OpenAI (prompt_tokens/completion_tokens) shapes."""
    if not body_bytes:
        return 0, 0
    try:
        text = body_bytes.decode("utf-8", "replace")
    except Exception:
        return 0, 0

    def _from_usage(u):
        if not isinstance(u, dict):
            return None
        it = u.get("input_tokens", u.get("prompt_tokens"))
        ot = u.get("output_tokens", u.get("completion_tokens"))
        if it is None and ot is None:
            return None
        return int(it or 0), int(ot or 0)

    # Non-streaming: a single JSON object with a top-level "usage".
    stripped = text.lstrip()
    if stripped.startswith("{"):
        try:
            obj = json.loads(stripped)
            r = _from_usage(obj.get("usage"))
            if r:
                return r
        except (json.JSONDecodeError, AttributeError):
            pass

    # Streaming (SSE): scan `data:` lines for usage. Anthropic reports input_tokens in
    # message_start and the final output_tokens in message_delta; OpenAI puts a usage
    # object in the last chunk when stream_options.include_usage is set. We take the max
    # input seen and the max output seen (final cumulative value).
    in_tok = out_tok = 0
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            evt = json.loads(payload)
        except json.JSONDecodeError:
            continue
        # Anthropic: usage nested under the event or under message
        for u in (evt.get("usage"), (evt.get("message") or {}).get("usage")):
            r = _from_usage(u)
            if r:
                in_tok = max(in_tok, r[0])
                out_tok = max(out_tok, r[1])
    return in_tok, out_tok



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
    <th>alias</th><th>erp</th><th>state</th><th>requests</th><th>ok</th><th>fail</th><th>in tok</th><th>out tok</th><th>consec</th><th>cooldown</th>
  </tr></thead><tbody></tbody></table></section>

  <section><h2>Usage by model</h2><table id="models"><thead><tr>
    <th>model</th><th>requests</th><th>in tok</th><th>out tok</th><th>total tok</th>
  </tr></thead><tbody></tbody></table></section>

  <section><h2>Login table (gateway)</h2>
    <table id="auth"><thead><tr>
      <th>login key</th><th>maps to</th><th>allow models</th><th>erp</th><th></th>
    </tr></thead><tbody></tbody></table>
    <button id="authadd" style="margin-top:8px">+ add login key / ticket</button>
  </section>

  <section><h2>Sessions</h2>
    <div class="err" id="sess-err"></div>
    <table id="sessions"><thead><tr>
      <th>name</th><th>status</th><th>model</th><th>key</th><th>dir</th><th></th>
    </tr></thead><tbody></tbody></table>
  </section>

  <section><h2>Recent requests</h2><div id="logs"><table><thead><tr>
    <th>t</th><th>model</th><th>key</th><th>status</th><th>latency</th><th>tokens</th><th></th>
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

<dialog id="authdlg"><form method="dialog">
  <h2 id="auth-title">add login key</h2>
  <label>login key (real key or ticket)</label><input id="auth-login" placeholder="jimdbtest">
  <label>maps to (real alias in keys.conf)</label><input id="auth-mapsto" placeholder="personal">
  <label>allow models (space/comma separated, empty = all)</label><input id="auth-models" placeholder="GLM-5.2">
  <label>erp (contributor)</label><input id="auth-erp" placeholder="wangqiwang1">
  <div style="display:flex;gap:8px;justify-content:flex-end">
    <button value="cancel">cancel</button><button id="auth-save" value="save">save</button>
  </div>
</form></dialog>

<script>
const $=s=>document.querySelector(s), tb=s=>document.querySelector(s+' tbody');
function pill(s){return `<span class="pill ${s}">${s}</span>`}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function kfmt(n){n=n||0;return n>=1e6?(n/1e6).toFixed(1)+'M':n>=1e3?(n/1e3).toFixed(1)+'k':String(n)}

async function jget(u){const r=await fetch(u);if(!r.ok)throw new Error(r.status);return r.json()}
async function jpost(u,b){const r=await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});return r.json()}

async function refresh(){
  try{
    const s=await jget('/api/status');
    $('#meta').textContent=`:${s.port} -> ${s.ccr_url}  ·  trip@${s.fail_n} cooldown ${s.cooldown}s`;
    $('#totals').textContent=`req ${s.totals.requests}  ok ${s.totals.ok}  fail ${s.totals.fail}  ·  tok ${kfmt(s.totals.in_tokens)}in / ${kfmt(s.totals.out_tokens)}out`;
    tb('#keys').innerHTML=s.keys.map(k=>`<tr><td>${esc(k.alias)}</td><td class=dim>${esc(k.erp)||'-'}</td><td>${pill(k.state)}</td>
      <td>${k.requests}</td><td>${k.ok}</td><td>${k.fail}</td><td>${kfmt(k.in_tokens)}</td><td>${kfmt(k.out_tokens)}</td>
      <td>${k.consec_fails}</td><td>${k.cooldown_left?k.cooldown_left+'s':'-'}</td></tr>`).join('')||'<tr><td class=dim colspan=10>no key activity yet</td></tr>';
    tb('#models').innerHTML=(s.models||[]).map(m=>`<tr><td>${esc(m.model)}</td><td>${m.requests}</td>
      <td>${kfmt(m.in_tokens)}</td><td>${kfmt(m.out_tokens)}</td><td>${kfmt((m.in_tokens||0)+(m.out_tokens||0))}</td></tr>`).join('')
      ||'<tr><td class=dim colspan=5>no usage yet</td></tr>';
    tb('#auth').innerHTML=(s.auth||[]).map(a=>`<tr><td>${esc(a.login)}</td><td>${esc(a.maps_to)}</td>
      <td class=dim>${(a.allow_models&&a.allow_models.length)?esc(a.allow_models.join(', ')):'<span class=dim>all</span>'}</td>
      <td class=dim>${esc(a.erp)||'-'}</td>
      <td><button onclick="editAuth('${esc(a.login)}','${esc(a.maps_to)}','${esc((a.allow_models||[]).join(' '))}','${esc(a.erp)}')">edit</button>
          <button class=danger onclick="delAuth('${esc(a.login)}')">del</button></td></tr>`).join('')
      ||'<tr><td class=dim colspan=5>no login keys — click "add" below</td></tr>';
  }catch(e){$('#meta').innerHTML='<span class=err>proxy status unavailable</span>'}

  try{
    const d=await jget('/api/sessions');
    $('#sess-err').textContent=d.error||'';
    tb('#sessions').innerHTML=(d.sessions||[]).map(x=>`<tr>
      <td>${esc(x.name)}</td><td>${pill(x.status)}</td><td>${esc(x.model)}</td><td>${esc(x.key)}</td>
      <td class=dir title="${esc(x.dir)}">${esc(x.dir)}</td>
      <td><button onclick="copyCmd('${esc(x.name)}','${esc(x.model)}','${esc(x.key)}')">copy</button>
          <button onclick="editSess('${esc(x.name)}','${esc(x.model)}','${esc(x.key)}')">edit</button>
          <button class=danger onclick="killSess('${esc(x.name)}')">kill</button></td></tr>`).join('')
      ||'<tr><td class=dim colspan=6>no sessions</td></tr>';
  }catch(e){$('#sess-err').textContent='sessions unavailable'}

  try{
    const l=await jget('/api/logs?n=100');
    tb('#logs table').innerHTML=(l.logs||[]).map(x=>`<tr><td class=dim>${x.t}s</td><td>${esc(x.model)}</td>
      <td>${esc(x.alias)}</td><td>${x.ok?pill('healthy'):'<span class=err>'+esc(x.status)+'</span>'}</td>
      <td class=dim>${x.ms!=null?x.ms+'ms':'-'}</td>
      <td class=dim>${(x.in_tok!=null||x.out_tok!=null)?kfmt(x.in_tok)+'/'+kfmt(x.out_tok):'-'}</td>
      <td class=dim>${x.failover?'failover':''}${x.forced?' forced':''}</td></tr>`).join('')
      ||'<tr><td class=dim colspan=7>no requests yet</td></tr>';
  }catch(e){}
  $('#tick').textContent='updated '+new Date().toLocaleTimeString();
}

let editName=null;
function copyCmd(name,model,key){
  let cmd='crew '+name;
  if(model && model!=='-' && model!=='default') cmd+=' --model '+model;
  if(key && key!=='-') cmd+=' --key '+key;
  navigator.clipboard.writeText(cmd).then(()=>{
    const el=$('#tick'); el.textContent='copied: '+cmd;
  }).catch(()=>{ prompt('copy this command:', cmd); });
}
function editSess(name,model,key){editName=name;$('#edittitle').textContent='edit '+name;
  $('#edit-model').value=model==='-'?'':model;$('#edit-key').value=key==='-'?'':key;$('#editdlg').showModal()}
$('#edit-save').onclick=async()=>{await jpost('/api/session/config',
  {name:editName,model:$('#edit-model').value.trim(),key:$('#edit-key').value.trim()});setTimeout(refresh,200)};

// -- gateway login table edit --
function openAuth(login,mapsto,models,erp){
  $('#auth-title').textContent=login?('edit '+login):'add login key';
  $('#auth-login').value=login||'';$('#auth-login').readOnly=!!login;
  $('#auth-mapsto').value=mapsto||'';$('#auth-models').value=models||'';$('#auth-erp').value=erp||'';
  $('#authdlg').showModal();
}
function editAuth(login,mapsto,models,erp){openAuth(login,mapsto,models,erp)}
$('#authadd').onclick=()=>openAuth('','','','');
$('#auth-save').onclick=async()=>{
  const login=$('#auth-login').value.trim();
  if(!login)return;
  const allow=$('#auth-models').value.trim().split(/[\s,]+/).filter(Boolean);
  const r=await jpost('/api/gateway/auth',
    {login,maps_to:$('#auth-mapsto').value.trim(),allow_models:allow,erp:$('#auth-erp').value.trim()});
  if(r&&r.error)alert('failed: '+r.error);
  setTimeout(refresh,200);
};
async function delAuth(login){
  if(!confirm('delete login key "'+login+'"?'))return;
  const r=await jpost('/api/gateway/auth',{login,delete:true});
  if(r&&r.error)alert('failed: '+r.error);
  setTimeout(refresh,200);
}

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
 #admin{margin-top:26px;border-top:1px solid #21262d;padding-top:16px;display:none}
 #admin h3{margin:16px 0 6px;font-size:13px;color:#8b95a3}
 table{border-collapse:collapse;width:100%;font-size:12px} th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #1a1e26}
 th{color:#6b7684;font-weight:500} .danger{color:#e5534b;border-color:#5a2620}
 .row{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:6px 0}
 h1{font-size:22px;margin:0 0 2px;letter-spacing:.5px} h1 .sub{font-size:12px;color:#6b7684;font-weight:400}
 #intro{margin:18px 0;max-width:720px} #intro img{max-width:100%;border:1px solid #21262d;border-radius:8px}
 #intro .feat{color:#9aa4af;margin:8px 0} #intro code{background:#161b22;border:1px solid #21262d;border-radius:4px;padding:1px 6px}
 #intro a{color:#6cf}
</style></head><body>
<h1>crew-proxy <span class=sub>· 共享 key 网关 & 用量看板</span></h1>
<div class=bar>
 <input id=key type=password placeholder="输入你的 key 登录" size=32>
 <input id=viewas placeholder="(admin) 查看某 login / __all__" size=26 style=display:none>
 <button id=login>登录</button>
 <span id=meta class=dim></span>
</div>
<div id=intro>
 <img src="/crew-demo.gif" alt="crew demo" loading=lazy>
 <p class=feat><b>crew</b> —— 一个人同时开多个 Claude Code 会话、随时切换模型、让不同模型互相对话协作。共享 key 池自动故障切换、限额自动摘除恢复。</p>
 <p class=feat>接入:仓库 <code>git@coding.jd.com:olsd/claude-crew.git</code>(内网) / <code>git@github.com:Barcelona16/claude-crew.git</code>(外网),装好后配一个 backend 指向本网关即可。</p>
</div>
<div id=totals></div>
<div id=health></div>
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
</div>
<script>
let KEY=sessionStorage.getItem('crewKey')||'', VIEW='', _d=null, _geom=null;
const $=s=>document.querySelector(s);
function fmtK(n){if(n==null)return '—';if(n>=1e6)return (n/1e6).toFixed(2)+'M';if(n>=1e3)return (n/1e3).toFixed(0)+'k';return String(Math.round(n));}
function fmtClock(ms){const d=new Date(ms),p=x=>String(x).padStart(2,'0');return p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
async function load(){
  if(!KEY)return;
  let url='/api/usage?days=7'+(VIEW?('&key='+encodeURIComponent(VIEW)):'');
  let r;try{r=await fetch(url,{headers:{'x-api-key':KEY}});}catch(e){$('#meta').textContent='网络错误';return;}
  if(r.status===401){$('#meta').textContent='key 无效';return;}
  const d=await r.json();_d=d;
  $('#intro').style.display='none';
  $('#meta').textContent='登录: '+d.login+' · 近 '+(d.windowH/24)+' 天 · '+d.buckets.length+' 点';
  renderTotals(d);renderDaily(d);draw();
  loadHealth();
  $('#admin').style.display=d.isAdmin?'block':'none';
  if(d.isAdmin)loadAdmin();
}
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
  if(kd){$('#pool').innerHTML='<table><tr><th>key</th><th>模型</th><th>策略</th><th>状态</th><th></th></tr>'+
    (kd.pool||[]).map(p=>'<tr><td>'+esc(p.key_masked)+'</td><td>'+esc((p.models||[]).join(', '))+
      '</td><td>'+esc(Object.keys(p.in_policy||{}).join(', '))+'</td><td>'+(p.state!=='healthy'?'<span style=color:#e5534b>异常'+(p.cooldown_left?' '+p.cooldown_left+'s':'')+'</span>':'<span style=color:#4ec98a>正常</span>')+
      '</td><td><button class=danger data-del="'+esc(p.alias)+'">删</button></td></tr>').join('')+'</table>';
    document.querySelectorAll('#pool [data-del]').forEach(b=>b.onclick=async()=>{
      if(!confirm('删除 key '+b.dataset.del+'?'))return;
      const r=await apost('/api/ccr/provider',{alias:b.dataset.del,delete:true});
      if(!r.ok&&r.body.error){if(confirm(r.body.error+'\\n强制删除?')){await apost('/api/ccr/provider',{alias:b.dataset.del,delete:true,force:true});}}
      loadAdmin();loadHealth();});}
  const pd=await aget('/api/policy');
  if(pd){$('#policy').innerHTML='<table><tr><th>模型</th><th>key 顺序(alias)</th><th></th></tr>'+
    Object.entries(pd.policy||{}).map(([m,al])=>'<tr><td>'+esc(m)+'</td><td><input data-pm="'+esc(m)+'" value="'+esc(al.join(' '))+'" size=30></td><td><button data-ps="'+esc(m)+'">存</button></td></tr>').join('')+'</table>';
    document.querySelectorAll('#policy [data-ps]').forEach(b=>b.onclick=async()=>{
      const inp=document.querySelector('#policy [data-pm="'+CSS.escape(b.dataset.ps)+'"]');
      await apost('/api/policy',{model:b.dataset.ps,aliases:inp.value.trim().split(/\\s+/).filter(Boolean)});
      loadAdmin();});}
  const sd=await aget('/api/status');
  if(sd){$('#logins').innerHTML='<table><tr><th>login</th><th>maps_to</th><th>allow_models</th><th>erp</th><th>admin</th><th></th></tr>'+
    (sd.auth||[]).map(a=>'<tr><td>'+esc(a.login)+'</td><td>'+esc(a.maps_to)+'</td><td>'+esc((a.allow_models||[]).join(' '))+'</td><td>'+esc(a.erp||'')+'</td><td>'+(a.admin?'✓':'')+'</td><td><button class=danger data-dl="'+esc(a.login)+'">删</button></td></tr>').join('')+'</table>';
    document.querySelectorAll('#logins [data-dl]').forEach(b=>b.onclick=async()=>{
      if(!confirm('删除登录 '+b.dataset.dl+'?'))return;
      await apost('/api/gateway/auth',{login:b.dataset.dl,delete:true});loadAdmin();});}
}
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
function draw(){
  const d=_d;if(!d||!d.buckets.length)return;const cv=$('#tokenChart');const dpr=window.devicePixelRatio||1;
  const W0=cv.clientWidth||800,H0=220;cv.width=W0*dpr;cv.height=H0*dpr;const g=cv.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W0,H0);
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
$('#login').onclick=()=>{KEY=$('#key').value.trim();VIEW=$('#viewas').value.trim();sessionStorage.setItem('crewKey',KEY);load();};
if(KEY){$('#key').value=KEY;$('#viewas').style.display='inline-block';load();}
setInterval(()=>{if(KEY)load();},30000);
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

    def _send_gif(self):
        try:
            with open(CREW_DEMO_GIF, "rb") as f:
                body = f.read()
        except OSError:
            return self._send_json({"error": "not found"}, 404)
        self.send_response(200)
        self.send_header("Content-Type", "image/gif")
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
        return self._send_json({"pool": out})

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
        return self._send_json({"pool": pool})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/dashboard", "/dashboard/"):
            self._send_html(DASHBOARD_HTML)
        elif path in ("/usage", "/usage/"):
            self._send_html(USAGE_HTML)
        elif path == "/crew-demo.gif":
            self._send_gif()
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
        # Only /v1/messages and /v1/chat/completions carry a model to route on.
        if path.endswith("/messages") or path.endswith("/chat/completions"):
            self._route(body)
        else:
            self._passthrough(body)

    def _read_json(self, body):
        try:
            return json.loads(body or b"{}")
        except json.JSONDecodeError:
            return None

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
        req = urllib.request.Request(url, data=body or None, headers=self._fwd_headers(),
                                     method=self.command)
        _t = time.time()
        try:
            resp = urllib.request.urlopen(req, timeout=300 if model else 120)
        except urllib.error.HTTPError as e:
            if model:
                STATS.record("direct", model, e.code, ok=not _is_fail(e.code), forced=False, failover=False)
            self._relay(e, streaming=False)
        except Exception as e:
            if model:
                STATS.record("direct", model, "ERR", ok=False, forced=False, failover=False)
            self._send_err(502, f"crew-proxy: CCR unreachable: {e}")
        else:
            if model:
                STATS.record("direct", model, getattr(resp, "status", 200), ok=True,
                             forced=False, failover=False, latency=time.time() - _t)
                captured = self._relay(resp, streaming=stream, capture=True)
                if captured:
                    try:
                        it, ot = parse_usage(captured)
                        STATS.record_usage("direct", model, it, ot)
                        USAGE.add(self.headers.get("X-Crew-Login") or "direct", it, ot)
                    except Exception:
                        pass
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
                _t_send = time.time()
                resp = urllib.request.urlopen(req, timeout=300)
            except urllib.error.HTTPError as e:
                if _is_fail(e.code) and not forced:
                    cd = cooldown_for(e.code, parse_retry_after(e.headers))
                    BREAKER.record_fail(alias, now, cd)
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
                    BREAKER.record_fail(alias, now, cooldown_for(0, None))  # conn error -> transient tier
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
                         forced=forced, failover=bool(tried), latency=time.time() - _t_send)
            captured = self._relay(resp, streaming=stream, capture=True)
            # Token accounting happens HERE — after the body is fully relayed to the
            # client — so parsing never adds latency to the forward path. Best-effort.
            if captured:
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
    def _relay(self, resp, streaming, capture=False):
        code = getattr(resp, "status", None) or getattr(resp, "code", 200)
        headers = resp.headers
        ct = headers.get("Content-Type", "application/json")
        self.send_response(code)
        hop = {"connection", "transfer-encoding", "keep-alive", "content-length",
               "proxy-connection"}
        for k, v in headers.items():
            if k.lower() not in hop:
                self.send_header(k, v)
        buf = bytearray() if capture else None
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
                    if buf is not None and len(buf) < USAGE_STREAM_CAP:
                        buf.extend(chunk)  # retain (capped) for post-relay usage scan
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
            if buf is not None:
                buf.extend(data)
        return bytes(buf) if buf is not None else None


def main():
    log.info("listening on http://127.0.0.1:%d  ->  CCR %s", PORT, CCR_URL)
    log.info("keys=%s policy=%s ccr=%s", KEYS_FILE, POLICY, CCR_CFG)
    log.info("breaker: trip after %d fails, cooldown %.0fs", FAIL_N, COOLDOWN)
    USAGE.load()
    log.info("usage series loaded (%d logins)", len(USAGE._buckets))
    atexit.register(lambda: USAGE.flush(force=True))
    def _usage_flusher():
        while True:
            time.sleep(UsageSeries.FLUSH_MIN_SEC)
            USAGE.flush()
    threading.Thread(target=_usage_flusher, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("stopped")


if __name__ == "__main__":
    main()
