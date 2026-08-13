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
import sys
import threading
import time
import urllib.error
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

    def do_GET(self):
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
                    tried.append(alias)
                    log.warning("← key '%s' upstream %d; failing over", alias, e.code)
                    if len(tried) >= len(policy):
                        self._relay(e, streaming=False)  # exhausted -> surface last error
                        return
                    continue
                # forced, or a non-failover status (e.g. 400 bad request) -> relay as-is
                self._relay(e, streaming=False)
                return
            except Exception as e:
                if not forced:
                    BREAKER.record_fail(alias, now)
                    tried.append(alias)
                    log.warning("← key '%s' conn error: %s; failing over", alias, e)
                    if len(tried) >= len(policy):
                        self._send_err(502, f"crew-proxy: all keys failed for {realmodel}: {e}")
                        return
                    continue
                self._send_err(502, f"crew-proxy: {e}")
                return

            # header phase reached with a good status -> commit to this key, relay body.
            BREAKER.record_ok(alias)
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
