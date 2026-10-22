#!/usr/bin/env python3
"""JoyCode local proxy — OpenAI/Anthropic-compatible, reads VS Code session credentials.

Portable: paths/secret/port come from env with sensible defaults, so it works for any user.
  JOYCODE_PORT        listen port (default 8765)
  JOYCODE_VSCODE_DB   path to VS Code's state.vscdb (default: ~/Library/.../Code/.../state.vscdb)
  JOYCODE_HMAC_SECRET JoyCode gateway HMAC secret (environment takes precedence)
  JOYCODE_HMAC_SECRET_FILE user-owned 0600 regular file; required without environment secret
  JOYCODE_UPSTREAM_TIMEOUT upstream timeout in seconds (default 300)

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
import socket
import select
import stat
import math
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Responses API 兼容层(同目录;joycode GPT-6.x 系 adapterType=openai-response 需要)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _responses_compat as rcompat

# ── config (env-overridable; cross-platform, no hardcoded home path) ────────────
def _default_vscode_db():
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return os.path.join(home, "Library/Application Support/Code/User/globalStorage/state.vscdb")
    # Linux (and other XDG platforms)
    return os.path.join(home, ".config/Code/User/globalStorage/state.vscdb")

VSCODE_DB = os.environ.get("JOYCODE_VSCODE_DB") or _default_vscode_db()
# Portable credential file: a dump of {jdhLoginInfo, remoteModelConfigs} produced by
# `crew joycode-export` on an IDE machine. Lets a host WITHOUT a JoyCode IDE (e.g. a cloud
# container) run this proxy — read in preference to the VS Code sqlite when present.
CREW_HOME = os.environ.get("CREW_HOME") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "claude-crew")
LOGIN_FILE = os.environ.get("JOYCODE_LOGIN_FILE") or os.path.join(CREW_HOME, "joycode-login.json")
# Credential sync (only meaningful on an IDE machine): a background thread periodically reads
# THIS machine's live login from sqlite and pushes it to every target in this file. Each line
# is "<name>\t<push-command>" where {file} is a temp 0600 dump. Re-read every cycle, so targets
# added after the proxy started are picked up on the next pass. Cloud hosts (no sqlite login /
# no targets) just idle — nothing to push.
SYNC_TARGETS = os.environ.get("JOYCODE_SYNC_TARGETS") or os.path.join(CREW_HOME, "joycode-sync-targets.conf")
SYNC_INTERVAL = int(os.environ.get("CREW_JOYCODE_SYNC_INTERVAL", "1800"))
COLOR_GATEWAY_APPID = "joycode_ide"
COLOR_GATEWAY_PATH  = "/api"
# Supply the gateway signing secret through the environment; never store it in source.
def _load_hmac_secret():
    supplied = os.environ.get("JOYCODE_HMAC_SECRET")
    if supplied:
        if supplied != supplied.strip():
            raise RuntimeError("JOYCODE_HMAC_SECRET must be nonempty without surrounding whitespace")
        return supplied
    path = os.environ.get("JOYCODE_HMAC_SECRET_FILE")
    if not path:
        raise RuntimeError("Configure JOYCODE_HMAC_SECRET or JOYCODE_HMAC_SECRET_FILE")
    fd = None
    try:
        before = os.lstat(path)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or stat.S_IMODE(before.st_mode) != 0o600):
            raise ValueError()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError()
        if (not stat.S_ISREG(after.st_mode) or after.st_uid != os.getuid()
                or stat.S_IMODE(after.st_mode) != 0o600):
            raise ValueError()
        with os.fdopen(fd, "r", encoding="utf-8") as source:
            fd = None
            secret = source.read(65537).strip()
        if not secret or len(secret) > 65536:
            raise ValueError()
        return secret
    except (OSError, ValueError, UnicodeError):
        raise RuntimeError("JOYCODE_HMAC_SECRET_FILE must be a readable, user-owned 0600 regular file with a nonempty secret") from None
    finally:
        if fd is not None:
            os.close(fd)


def _load_upstream_timeout():
    try:
        value = float(os.environ.get("JOYCODE_UPSTREAM_TIMEOUT", "300"))
        if not math.isfinite(value) or value <= 0:
            raise ValueError()
        return value
    except ValueError:
        raise RuntimeError("JOYCODE_UPSTREAM_TIMEOUT must be a positive finite number") from None


HMAC_SECRET = _load_hmac_secret()
UPSTREAM_TIMEOUT = _load_upstream_timeout()
CHAT_FUNCTION_ID    = "chat_completions"
ANTHROPIC_FUNCTION_ID = "anthropic_completions"
# OpenAI Responses API 模型(JoyCode 的 GPT-6.x 系,adapterType=openai-response):
# chat_completions functionId 会 1032,必须走 responses_completions(color 网关)。
RESPONSES_FUNCTION_ID = "responses_completions"
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
    # 1) portable credential file (works with no IDE — e.g. a cloud container)
    try:
        with open(LOGIN_FILE) as f:
            data = json.load(f)
        info = data.get("jdhLoginInfo") or {}
        if info:
            return info, data.get("remoteModelConfigs", [])
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    # 2) VS Code globalStorage sqlite (a machine with the JoyCode IDE logged in)
    conn = sqlite3.connect(VSCODE_DB)
    c = conn.cursor()
    c.execute("SELECT value FROM ItemTable WHERE key='JoyCoder.joycoder-fe'")
    row = c.fetchone()
    conn.close()
    if not row:
        raise RuntimeError(f"no JoyCode credentials — put a login file at {LOGIN_FILE} "
                           "(crew joycode-import <file>), or open VS Code and log in to JoyCode")
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

    @staticmethod
    def _fix_content_empty(body):
        """joycode 上游把正文全塞进 reasoning_content、content 恒为空(实测 GLM-5.3 流式/非流式
        皆如此)。当 message.content 为空且 reasoning_content 非空时,把 reasoning_content 降级到
        content —— 否则 CCR 的 OpenAI transformer 会把正文当 thinking,Claude Code 收到空回复。
        非流式:完整 chat completion JSON。"""
        try:
            d = json.loads(body)
        except Exception:
            return body
        msg = (d.get("choices") or [{}])[0].get("message")
        if isinstance(msg, dict) and not msg.get("content") and msg.get("reasoning_content"):
            msg["content"] = msg["reasoning_content"]
            msg["reasoning_content"] = ""
            return json.dumps(d, ensure_ascii=False).encode()
        return body

    @staticmethod
    def _fix_stream_delta(js):
        """流式:修正单个 chunk 的 delta —— content 空且 reasoning_content 非空时降级。"""
        try:
            choices = js.get("choices") or []
            for ch in choices:
                delta = ch.get("delta") or {}
                if not delta.get("content") and delta.get("reasoning_content"):
                    delta["content"] = delta["reasoning_content"]
                    delta["reasoning_content"] = ""
            return js
        except Exception:
            return js

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
        # 剥离 CCR 类 "provider/Model" 前缀再查 label(如 joycode-oai/GPT-6.1 Sol → GPT-6.1 Sol)
        bare = resolved.split("/", 1)[-1] if "/" in resolved else resolved
        resolved = label_map.get(bare, resolved)

        use_anthropic = (not openai) or any(x in resolved for x in ("Claude", "claude"))
        # adapterType 路由(2026-10-22):remoteModelConfigs 里 extJson.adapterType=openai-response
        # 的模型(GPT-6.x 系)必须走 OpenAI Responses API — 发去 chat/completions 会 1032
        # HTTP调用异常(实测 2026-10-22,同 key 同登录态 GLM/DeepSeek/Claude 全 200)。
        # anthropic 端点由 use_anthropic 决定;其余无 adapterType 的照旧走 chat_completions。
        use_responses = False
        for m in remote:
            if m.get("label") == resolved or m.get("chatApiModel") == resolved:
                adapter = (m.get("extJson") or {}).get("adapterType", "")
                if adapter == "openai-response":
                    use_responses = True
                break

        if resolved != model:
            payload = {**payload, "model": resolved}
            raw = json.dumps(payload).encode()

        if use_anthropic:
            url = _get_url(ANTHROPIC_FUNCTION_ID, "/api/saas/anthropic/v1/messages", info)
        elif use_responses:
            # color 网关 functionId=responses_completions;无 color 时回落 master 直连
            # (master /api/saas/openai/v2/responses 实测同登录态 200)。
            color = (info.get("colorBaseUrl") or "").strip()
            master = (info.get("masterBaseUrl") or info.get("base_url") or "").strip()
            if color:
                url = _gateway_url(RESPONSES_FUNCTION_ID, color.rstrip("/"))
            elif master:
                url = f"{master.rstrip('/')}/api/saas/openai/v2/responses"
            else:
                self._err(500, "No base URL in login info")
                return
        else:
            url = _get_url(CHAT_FUNCTION_ID, "/api/saas/openai/v2/chat/completions", info)

        hdrs = _headers(info)
        if use_anthropic:
            hdrs["anthropic-version"] = "2023-06-01"

        endpoint = "anthropic" if use_anthropic else ("responses" if use_responses else "openai")
        log.info("→ %-10s  model=%-28s  stream=%s", endpoint, resolved, stream)

        # Responses API 格式转换:调用方(chat completions 客户端/CCR)发 messages/max_tokens,
        # Responses API 要 input/max_output_tokens。双向转换,让 GPT-6.x 对 OpenAI 兼容客户端透明。
        if use_responses:
            payload = rcompat.to_responses_request(payload, stream)
            stream = bool(payload.get("stream", False))
            raw = json.dumps(payload).encode()

        req = urllib.request.Request(url, data=raw, headers=hdrs, method="POST")
        try:
            resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
        except urllib.error.HTTPError as e:
            try:
                log.error("upstream HTTP %d", e.code)
                self._err(e.code, "Upstream HTTP request failed")
            finally:
                e.close()
            return
        except Exception as e:
            log.error("upstream error: %s", e)
            self._err(502, str(e))
            return

        stop = threading.Event()
        cancelled = threading.Event()
        watcher = threading.Thread(target=self._watch_cancel,
                                   args=(resp, stop, cancelled), daemon=True)
        watcher.start()
        try:
            self._forward_response(resp, stream, use_responses, endpoint, t0)
        except (BrokenPipeError, ConnectionResetError):
            cancelled.set()
        except Exception:
            if not cancelled.is_set():
                if stream:
                    try:
                        self._sse_error("Upstream stream read failed", "stream_read_error")
                    except (OSError, ValueError):
                        pass
                else:
                    self._err(502, "Upstream response read failed")
        finally:
            stop.set()
            try:
                resp.close()
            finally:
                watcher.join(timeout=0.5)

    def _watch_cancel(self, resp, stop, cancelled):
        while not stop.wait(0.1):
            try:
                readable, _, _ = select.select([self.connection], [], [], 0)
                if not readable:
                    continue
                if self.connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT):
                    continue
            except BlockingIOError:
                continue
            except (OSError, ValueError):
                if stop.is_set():
                    return
            cancelled.set()
            try:
                resp.fp.raw._sock.shutdown(socket.SHUT_RDWR)
            except (AttributeError, OSError):
                pass
            resp.close()
            return

    def _sse_write(self, obj):
        self.wfile.write(("data: " + json.dumps(obj, ensure_ascii=False) + "\n\n").encode())
        self.wfile.flush()

    def _sse_error(self, message, code):
        self._sse_write({"error": {"message": message, "type": "upstream_error", "code": code}})

    def _forward_response(self, resp, stream, use_responses, endpoint, t0):
        enc = resp.headers.get("Content-Encoding", "")
        if not stream:
            body = _decompress(resp.read(), enc)
            if use_responses:
                try:
                    document = json.loads(body)
                    if document.get("error") or document.get("status") != "completed":
                        self._err(502, "Responses upstream did not complete successfully")
                        return
                    body = json.dumps(rcompat.responses_to_chat(document)).encode()
                except Exception:
                    self._err(502, "Responses conversion failed")
                    return
            body = self._fix_content_empty(body)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.close_connection = True
            self._stream_response(resp, enc, use_responses)
        log.info("← %-10s  %.1fs", endpoint, time.time() - t0)

    def _stream_response(self, resp, enc, use_responses):
        import zlib
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS) if "gzip" in enc else None
        state = {}
        pending = []
        terminal = False
        end_seen = False
        failed = False
        marker = chr(91) + "DONE" + chr(93)

        def consume(line):
            nonlocal terminal, end_seen, failed
            text = line.decode("utf-8").strip()
            if not text or text.startswith(":"):
                return
            if text.startswith("event:"):
                if not use_responses:
                    pending.append(line + b"\n")
                return
            if text.startswith(("id:", "retry:")):
                return
            if not text.startswith("data:"):
                raise ValueError("Invalid SSE line")
            text = text[5:].strip()
            if text.startswith("data:"):
                text = text[5:].strip()
            if text == marker:
                end_seen = True
                if not use_responses:
                    terminal = True
                return
            if end_seen:
                raise ValueError("Data after stream end")
            ev = json.loads(text)
            if not isinstance(ev, dict):
                raise ValueError("Invalid SSE object")
            etype = ev.get("type", "")
            response = ev.get("response") or {}
            error_event = ("error" in ev or etype in ("error", "response.failed")
                           or response.get("status") == "failed")
            incomplete = etype == "response.incomplete"
            reason = (response.get("incomplete_details") or {}).get("reason")
            if error_event or (incomplete and reason != "max_output_tokens"):
                failed = True
                state["failed"] = True
                # Error events must never enter older compatibility implementations
                # which mapped errors to assistant content.
                err = ev.get("error") or response.get("error") or {}
                code = err.get("code") if isinstance(err, dict) else None
                self._sse_error("Responses upstream failed" if use_responses else "Upstream failed",
                                code or "upstream_failed")
                return
            if terminal:
                raise ValueError("Unexpected data after terminal event")
            if use_responses:
                if etype == "response.completed" and response.get("status") != "completed":
                    raise ValueError("Invalid Responses terminal status")
                if incomplete and response.get("status") != "incomplete":
                    raise ValueError("Invalid Responses incomplete status")
                ck = rcompat.responses_sse_chunk(ev, state)
                if state.get("failed") or (ck and ck.get("error")):
                    failed = True
                    self._sse_write(ck if ck and ck.get("error") else {
                        "error": {"message": "Responses upstream failed",
                                  "type": "upstream_error", "code": "upstream_failed"}})
                    return
                if ck is None:
                    return
                if incomplete:
                    for choice in ck.get("choices") or []:
                        choice["finish_reason"] = "length"
                choices = ck.get("choices") or []
                if choices and choices[0].get("finish_reason"):
                    if choices[0].get("delta"):
                        content = dict(ck)
                        content.pop("usage", None)
                        content["choices"] = [dict(choices[0], finish_reason=None)]
                        self._sse_write(content)
                    pending.append(dict(ck, choices=[dict(choices[0], delta={})]))
                    terminal = bool(state.get("completed"))
                else:
                    self._sse_write(ck)
            else:
                ev = self._fix_stream_delta(ev)
                if etype == "message_stop":
                    terminal = True
                    pending.append(ev)
                elif any(c.get("finish_reason") for c in ev.get("choices") or []):
                    pending.append(ev)
                else:
                    for header in pending[:]:
                        if isinstance(header, bytes):
                            self.wfile.write(header)
                            pending.remove(header)
                    self._sse_write(ev)

        buf = b""
        while not failed:
            chunk = resp.read1(4096)
            if not chunk:
                if decoder:
                    buf += decoder.flush()
                    if not decoder.eof:
                        raise ValueError("Truncated gzip stream")
                if buf.strip():
                    consume(buf.rstrip(b"\r"))
                break
            buf += decoder.decompress(chunk) if decoder else chunk
            while b"\n" in buf and not failed:
                line, buf = buf.split(b"\n", 1)
                consume(line.rstrip(b"\r"))
        if failed:
            return
        if not terminal or (use_responses and (not state.get("completed") or state.get("failed"))):
            self._sse_error("Upstream stream ended without a valid terminal event", "missing_terminal")
            return
        for frame in pending:
            if isinstance(frame, bytes):
                self.wfile.write(frame)
            else:
                self._sse_write(frame)
        if use_responses or end_seen:
            self.wfile.write(("data: " + marker + "\n\n").encode())
        self.wfile.flush()


def _read_vscode_login():
    """The live jdhLoginInfo+models straight from the VS Code sqlite (IDE machines only).
    Returns the {jdhLoginInfo, remoteModelConfigs} dump dict, or None if not available."""
    try:
        conn = sqlite3.connect(VSCODE_DB)
        cur = conn.cursor()
        cur.execute("SELECT value FROM ItemTable WHERE key='JoyCoder.joycoder-fe'")
        row = cur.fetchone()
        conn.close()
    except Exception:
        return None
    if not row:
        return None
    try:
        d = json.loads(row[0])
    except Exception:
        return None
    info = d.get("jdhLoginInfo") or {}
    if not info:
        return None
    return {"jdhLoginInfo": info, "remoteModelConfigs": d.get("remoteModelConfigs", [])}


def _read_targets():
    """[(name, push_cmd)] from SYNC_TARGETS; skips comments/blank. Re-read each cycle so
    targets added after startup are picked up next pass."""
    out = []
    try:
        with open(SYNC_TARGETS) as f:
            for ln in f:
                ln = ln.rstrip("\n")
                if not ln.strip() or ln.lstrip().startswith("#") or "\t" not in ln:
                    continue
                name, cmd = ln.split("\t", 1)
                if name.strip() and cmd.strip():
                    out.append((name.strip(), cmd))
    except (FileNotFoundError, OSError):
        pass
    return out


def sync_once():
    """Export THIS machine's live login and run each target's push command. No-op (and no
    temp file) when there's no IDE login here or no targets — so it's safe on cloud hosts."""
    dump = _read_vscode_login()
    if dump is None:
        return  # not an IDE machine / not logged in — nothing to push
    targets = _read_targets()
    if not targets:
        return
    fd, path = tempfile.mkstemp(prefix="jcsync-", suffix=".json")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(dump, f)
        ok = 0
        for name, tmpl in targets:
            cmd = tmpl.replace("{file}", path)
            try:
                subprocess.run(cmd, shell=True, timeout=120,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                ok += 1
                log.info("sync -> %s  OK", name)
            except Exception as e:
                log.warning("sync -> %s  FAILED: %s", name, str(e)[:80])
        log.info("sync: pushed %d/%d target(s)", ok, len(targets))
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _sync_loop():
    while True:
        try:
            sync_once()
        except Exception as e:
            log.warning("sync loop error: %s", e)
        time.sleep(max(30, SYNC_INTERVAL))


def main():
    try:
        info, _ = _load_state()
        log.info("logged in as %s (%s)", info.get("realName", ""), info.get("erp", ""))
    except Exception as e:
        log.warning("%s", e)

    server = ThreadingHTTPServer(("127.0.0.1", PROXY_PORT), Handler)
    log.info("listening on http://127.0.0.1:%d", PROXY_PORT)
    log.info("endpoints: /v1/messages  /v1/chat/completions  /v1/models")
    # Credential sync: only an IDE machine has a live login to push. Start the loop always —
    # it self-checks each cycle (no login here / no targets => idle), so it's harmless on
    # cloud hosts and needs no separate daemon.
    if _read_vscode_login() is not None:
        log.info("sync: this host has a JoyCode login — will push to targets in %s every %ds",
                 SYNC_TARGETS, max(30, SYNC_INTERVAL))
    threading.Thread(target=_sync_loop, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("stopped")


if __name__ == "__main__":
    main()
