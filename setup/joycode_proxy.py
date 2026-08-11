#!/usr/bin/env python3
"""JoyCode local proxy — OpenAI/Anthropic-compatible, reads VS Code session credentials.

Portable: paths/secret/port come from env with sensible defaults, so it works for any user.
  JOYCODE_PORT        listen port (default 8765)
  JOYCODE_VSCODE_DB   path to VS Code's state.vscdb (default: ~/Library/.../Code/.../state.vscdb)
  JOYCODE_HMAC_SECRET JoyCode gateway HMAC secret (default: the joycode_ide client app secret)

crew's `ccr` presets route through claude-code-router to this proxy. Two CCR providers use it:
  - `joycode`      (Anthropic transformer -> /v1/messages)          for Claude-family models
  - `joycode-oai`  (OpenAI transformer    -> /v1/chat/completions)  for non-Claude models
Requires you to be logged in to JoyCode inside VS Code (it reads that session).
"""

import gzip
import hashlib
import hmac
import json
import logging
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

# ── config (env-overridable; cross-platform, no hardcoded home path) ────────────
def _default_vscode_db():
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return os.path.join(home, "Library/Application Support/Code/User/globalStorage/state.vscdb")
    # Linux (and other XDG platforms)
    return os.path.join(home, ".config/Code/User/globalStorage/state.vscdb")

VSCODE_DB = os.environ.get("JOYCODE_VSCODE_DB") or _default_vscode_db()
COLOR_GATEWAY_APPID = "joycode_ide"
COLOR_GATEWAY_PATH  = "/api"
# The joycode_ide client app secret (embedded in the JoyCode VS Code extension — not personal).
HMAC_SECRET         = os.environ.get("JOYCODE_HMAC_SECRET", "0691a3f0b37b4a85aeb63ad0fc7db3ed")
CHAT_FUNCTION_ID    = "chat_completions"
ANTHROPIC_FUNCTION_ID = "anthropic_completions"
PROXY_PORT = int(os.environ.get("JOYCODE_PORT", "8765"))

# Claude Code standard IDs → JoyCode chatApiModel
CLAUDE_CODE_MODEL_MAP = {
    "claude-opus-4-7":            "Claude-Opus-4.7",
    "claude-opus-4-7[1m]":        "Claude-Opus-4.7",
    "claude-opus-4-6":            "Claude-Opus-4.6-hq",
    "claude-sonnet-4-6":          "Claude-Sonnet-4.6-hq",
    "claude-sonnet-4-5":          "Claude-Sonnet-4.6-hq",
    "claude-haiku-4-5":           "Claude-Sonnet-4.6-hq",
    "claude-haiku-4-5-20251001":  "Claude-Sonnet-4.6-hq",
    "claude-3-5-sonnet-20241022": "Claude-Sonnet-4.6-hq",
    "claude-3-opus-20240229":     "Claude-Opus-4.6-hq",
}

# ── logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s [joycode] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("joycode")

# ── credentials ───────────────────────────────────────────────────────────────
def _load_state():
    conn = sqlite3.connect(VSCODE_DB)
    c = conn.cursor()
    c.execute("SELECT value FROM ItemTable WHERE key='JoyCoder.joycoder-fe'")
    row = c.fetchone()
    conn.close()
    if not row:
        raise RuntimeError("JoyCode not found in VS Code DB — open VS Code and log in")
    data = json.loads(row[0])
    info = data.get("jdhLoginInfo") or {}
    if not info:
        raise RuntimeError("Not logged in — open VS Code and log in to JoyCode first")
    return info, data.get("remoteModelConfigs", [])

# ── URL building ──────────────────────────────────────────────────────────────
def _hmac(msg):
    return hmac.new(HMAC_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()

def _gateway_url(function_id, origin):
    p = {"appid": COLOR_GATEWAY_APPID, "functionId": function_id,
         "t": str(int(time.time() * 1000))}
    sign = _hmac("&".join(str(p[k]) for k in sorted(p)))
    p["sign"] = sign
    qs = "&".join(f"{k}={urllib.parse.quote(str(v), safe='')}" for k, v in p.items())
    return f"{origin}{COLOR_GATEWAY_PATH}?{qs}"

def _get_url(function_id, raw_path, info):
    color = (info.get("colorBaseUrl") or "").strip()
    master = (info.get("masterBaseUrl") or info.get("base_url") or "").strip()
    if color:
        o = urllib.parse.urlparse(color)
        return _gateway_url(function_id, f"{o.scheme}://{o.netloc}")
    if master:
        o = urllib.parse.urlparse(master)
        return f"{o.scheme}://{o.netloc}{raw_path}"
    raise RuntimeError("No base URL in login info")

def _headers(info):
    return {
        "Content-Type": "application/json; charset=UTF-8",
        "ptKey":     info.get("ptKey", ""),
        "loginType": info.get("loginType", "ERP"),
    }

def _decompress(data, enc):
    return gzip.decompress(data) if "gzip" in enc else data

# ── HTTP handler ──────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # silence default HTTP log; we use our own
        pass

    def _err(self, code, msg):
        body = json.dumps({"error": {"message": msg}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self):
        if self.path == "/v1/models":
            self._models()
        else:
            self._err(404, "not found")

    def do_POST(self):
        path = self.path.split("?")[0]
        if path in ("/v1/chat/completions", "/chat/completions"):
            self._chat(openai=True)
        elif path in ("/v1/messages", "/messages"):
            self._chat(openai=False)
        else:
            self._err(404, f"unknown path {path}")

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n) if n else b"{}"

    def _models(self):
        try:
            _, remote = _load_state()
            data = [
                {"id": m.get("chatApiModel", m.get("label", "")), "object": "model"}
                for m in remote if m.get("chatApiModel") or m.get("label")
            ]
        except Exception as e:
            data = []
            log.warning("models: %s", e)
        body = json.dumps({"object": "list", "data": data}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _chat(self, openai):
        t0 = time.time()
        try:
            info, remote = _load_state()
        except Exception as e:
            log.error("auth: %s", e)
            self._err(500, str(e))
            return

        raw = self._body()
        try:
            payload = json.loads(raw)
        except Exception:
            self._err(400, "invalid JSON")
            return

        model   = payload.get("model", "")
        stream  = payload.get("stream", False)

        # resolve model ID
        resolved = CLAUDE_CODE_MODEL_MAP.get(model, model)
        label_map = {m.get("label", ""): m.get("chatApiModel", m.get("label", ""))
                     for m in remote if m.get("label")}
        resolved = label_map.get(resolved, resolved)

        use_anthropic = (not openai) or any(x in resolved for x in ("Claude", "claude"))

        if resolved != model:
            payload = {**payload, "model": resolved}
            raw = json.dumps(payload).encode()

        if use_anthropic:
            url = _get_url(ANTHROPIC_FUNCTION_ID, "/api/saas/anthropic/v1/messages", info)
        else:
            url = _get_url(CHAT_FUNCTION_ID, "/api/saas/openai/v2/chat/completions", info)

        hdrs = _headers(info)
        if use_anthropic:
            hdrs["anthropic-version"] = "2023-06-01"

        endpoint = "anthropic" if use_anthropic else "openai"
        log.info("→ %-10s  model=%-28s  stream=%s", endpoint, resolved, stream)

        req = urllib.request.Request(url, data=raw, headers=hdrs, method="POST")
        try:
            resp = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as e:
            body = e.read()
            body = _decompress(body, e.headers.get("Content-Encoding", ""))
            log.error("upstream %d: %s", e.code, body.decode()[:200])
            self._err(e.code, body.decode()[:500])
            return
        except Exception as e:
            log.error("upstream error: %s", e)
            self._err(502, str(e))
            return

        ct  = resp.headers.get("Content-Type", "application/json")
        enc = resp.headers.get("Content-Encoding", "")

        if not stream:
            raw_resp = _decompress(resp.read(), enc)
            elapsed = time.time() - t0
            try:
                preview = json.loads(raw_resp)
                content = (preview.get("content") or [{}])[0].get("text", "")
                choices = (preview.get("choices") or [{}])[0].get("message", {}).get("content", "")
                text = (content or choices)[:80].replace("\n", " ")
                log.info("← %-10s  %.1fs  %r", endpoint, elapsed, text)
            except Exception:
                log.info("← %-10s  %.1fs  (%d bytes)", endpoint, elapsed, len(raw_resp))
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Type",
                             "application/json" if "event-stream" in ct else ct)
            self.send_header("Content-Length", str(len(raw_resp)))
            self.end_headers()
            self.wfile.write(raw_resp)
        else:
            # Streaming: use Connection: close; the client treats close as end-of-stream.
            # Do NOT use Transfer-Encoding: chunked — BaseHTTPRequestHandler won't add the
            # chunked framing, so the client would wait forever for the "0\r\n\r\n" terminator.
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Type", ct)
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            total = 0
            if "gzip" in enc:
                data = _decompress(resp.read(), enc)
                self.wfile.write(data)
                total = len(data)
            else:
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    total += len(chunk)
            elapsed = time.time() - t0
            log.info("← %-10s  %.1fs  stream %d bytes", endpoint, elapsed, total)


def main():
    try:
        info, _ = _load_state()
        log.info("logged in as %s (%s)", info.get("realName", ""), info.get("erp", ""))
    except Exception as e:
        log.warning("%s", e)

    server = HTTPServer(("127.0.0.1", PROXY_PORT), Handler)
    log.info("listening on http://127.0.0.1:%d", PROXY_PORT)
    log.info("endpoints: /v1/messages  /v1/chat/completions  /v1/models")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("stopped")


if __name__ == "__main__":
    main()
