#!/usr/bin/env python3
"""Tests for 2026-10-20 proxy fixes: CREW_BIN fallback, sessions degradation,
err_summary on failed requests, wall-clock ts in log entries.

Run:  python3 setup/test_crew_proxy_fixes.py
Exits non-zero on any failure. No third-party deps.
"""
import importlib.util
import json
import os
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# ── isolated config env (same recipe as test_crew_proxy.py) ─────────────────────
_tmp = tempfile.mkdtemp(prefix="crewproxy-fix-test-")
_cfg = os.path.join(_tmp, "config")
os.makedirs(_cfg, exist_ok=True)
with open(os.path.join(_cfg, "keys.conf"), "w") as f:
    f.write("k1=KEY_ONE\n")
with open(os.path.join(_cfg, "key-policy.conf"), "w") as f:
    f.write("MODEL_X = k1\n")
_ccr_cfg = os.path.join(_tmp, "ccr.json")
with open(_ccr_cfg, "w") as f:
    json.dump({"gateway": {"api_key": "gk"}, "Providers": [
        {"name": "p1", "models": ["MODEL_X"], "api_key": "KEY_ONE"},
    ]}, f)

# fake crew bin: executable that prints a sessions JSON
_state = os.path.join(_tmp, "state")
os.makedirs(_state, exist_ok=True)
os.environ.update({
    "CREW_CONFIG_DIR": _cfg,
    "CREW_STATE": _state,
    "CREW_CCR_CONFIG": _ccr_cfg,
    "CREW_KEYS_FILE": os.path.join(_cfg, "keys.conf"),
    # CREW_BIN deliberately NOT set — tests the fallback path
})

spec = importlib.util.spec_from_file_location("crew_proxy", os.path.join(HERE, "crew_proxy.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

passed = failed = 0
def ok(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name} {extra}")

print("CREW_BIN fallback:")
# T1: _find_crew_bin must return an existing path (which("crew") may or may not hit,
# but the result must be a real file or the bare "crew" sentinel — never an invented path)
bin_found = cp._find_crew_bin()
ok("returns str", isinstance(bin_found, str))
ok("existing or sentinel", bin_found == "crew" or os.path.isfile(bin_found))

print("sessions degradation:")
# T2: _api_sessions_fallback reads state dir (no crew CLI involved)
with open(os.path.join(_state, "alpha.backend"), "w") as f: f.write("prov/GLM-5.3")
with open(os.path.join(_state, "alpha.key"), "w") as f: f.write("k1")
with open(os.path.join(_state, "alpha.dir"), "w") as f: f.write("/tmp")
fb = cp._api_sessions_fallback()
ok("lists state sessions", isinstance(fb.get("sessions"), list) and
   any(s["name"] == "alpha" for s in fb["sessions"]), str(fb))
ok("degraded flag set", fb.get("degraded") is True)
ok("backend read", any(s.get("backend") == "prov/GLM-5.3" for s in fb["sessions"]))

# T3: path traversal rejected (SAFE_NAME)
with open(os.path.join(_state, "beta.backend"), "w") as f: f.write("x")
fb2 = cp._api_sessions_fallback()
ok("no traversal entries", all("/" not in s["name"] for s in fb2["sessions"]))

print("Stats.record err/ts:")
# T4: wall-clock ts + err summary on failure
st = cp.Stats()
st.record("k1", "MODEL_X", 400, ok=False, forced=False, failover=False, err_summary="HTTP 400: prompt is too long")
entry = st.logs(1)[0]
ok("ts is epoch-ish", abs(entry["ts"] - __import__("time").time()) < 5, str(entry.get("ts")))
ok("err captured", entry.get("err") == "HTTP 400: prompt is too long")
st.record("k1", "MODEL_X", 200, ok=True, forced=False, failover=False, latency=0.5)
entry2 = st.logs(1)[0]
ok("no err on success", "err" not in entry2)

print("run_crew timeout surface:")
# T5: run_crew with a nonexistent CREW_BIN returns (None, err) — no raise
old = cp.CREW_BIN
cp.CREW_BIN = "/nonexistent/crew"
out, err = cp.run_crew(["ls", "--json"])
ok("graceful failure", out is None and err and "crew exec failed" in err, f"{out} {err}")
cp.CREW_BIN = old

print("ctx-window auto-calibration (2026-10-20):")
# T6: upstream error carries the window -> extracted verbatim。
# body 结构与 llm-gw 实测一致:外层 {"error":{"cause":"<字符串化 JSON>","code":400,...}}
def _gw_body(inner: dict) -> bytes:
    return json.dumps({"error": {"cause": json.dumps(inner, ensure_ascii=False),
                                 "code": 400, "message": "模型服务调用失败",
                                 "status": "FAILED_RESPONSE"}}, ensure_ascii=False).encode()

b_glm = _gw_body({"code": 400, "type": "BadRequestError",
                  "message": "The input (1183203 tokens) is longer than the model's context length (1048576 tokens)."})
ok("extract glm-5.3 window", cp.extract_window_from_error(b_glm) == 1048576)
b_kimi = _gw_body({"error": {"message": "Invalid request: Your request exceeded model token limit: 1048576 (requested: 1254747)",
                             "type": "invalid_request_error"}})
ok("extract kimi window", cp.extract_window_from_error(b_kimi) == 1048576)
b_glm52 = _gw_body({"error": {"code": "1261", "message": "Prompt 超长"}})
ok("glm-5.2 no number -> None", cp.extract_window_from_error(b_glm52) is None)

# T7: calibrate writes the conf, idempotent, and updates on change
import tempfile as _tf, os as _os
cal_dir = _tf.mkdtemp(prefix="mw-cal-")
cp.MW_CONF = _os.path.join(cal_dir, "model-windows.conf")
with open(cp.MW_CONF, "w") as f:
    f.write("# header\nglm-5.3=1000000\nkimi=1048576\n")
ok("first write updates line", cp.calibrate_model_window("GLM-5.3-Local-joybuilder-personal/GLM-5.3-Local-joybuilder", 1048576) is True)
txt = open(cp.MW_CONF).read()
ok("glm-5.3 line rewritten", "glm-5.3=1048576" in txt and "auto-calibrated" in txt)
ok("other lines kept", "kimi=1048576" in txt and "# header" in txt)
ok("idempotent no-op", cp.calibrate_model_window("GLM-5.3-Local-joybuilder", 1048576) is False)
ok("unknown model appends", cp.calibrate_model_window("qwen-max", 250000) is True)
ok("appended line present", "qwen-max=250000" in open(cp.MW_CONF).read())

# T8: pattern extraction from full provider/model names
ok("pattern strips provider+variants", cp._mw_conf_pattern("prov/GLM-5.3-Local-joybuilder") == "glm-5.3")
ok("pattern keeps family version", cp._mw_conf_pattern("kimi-k3-joybuilder") == "kimi-k3")

# T9: estimate_input_tokens rough sizing
est = cp.estimate_input_tokens(json.dumps({"messages": [{"content": "x"*3000}]}).encode())
ok("estimate ~1000 for 3000 chars", 900 <= est <= 1100, str(est))
ok("estimate garbage -> 0", cp.estimate_input_tokens(b"not json") == 0)

# T10: translate now also matches the two new llm-gw wordings (CC compact recovery)
for name, body in [("glm-5.3 'longer than context length'", b_glm), ("kimi 'exceeded model token limit'", b_kimi), ("glm-5.2 'Prompt 超长'", b_glm52)]:
    t = cp.translate_prompt_too_long(body)
    ok(f"translate fires: {name}", t is not None and b"prompt is too long" in t)

# T11: stats-bounds fallback path (no numbers in error): lower bound wins
cp.MW_CONF = _os.path.join(cal_dir, "mw2.conf")
with open(cp.MW_CONF, "w") as f:
    f.write("glm-5.2=200000\n")
big_req = json.dumps({"messages": [{"content": "y" * 900000}]}).encode()  # ~300k est
cp.maybe_calibrate_from_error("GLM-5.2-joybuilder", b_glm52, req_body=big_req)
line = [l for l in open(cp.MW_CONF).read().splitlines() if l.startswith("glm-5.2=")]
ok("stats fallback floors to 10k", line and line[0].startswith("glm-5.2=300000"),
   str(line and line[0]))

# cleanup calibration confs
import shutil as _sh
_sh.rmtree(cal_dir, ignore_errors=True)

# Relay health: fragmented events, errors after terminal, and read/write failures.
import io
import socket
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch

class RelayResponse:
    status = 200
    headers = {"Content-Type": "text/event-stream"}
    def __init__(self, chunks):
        self.chunks = iter(chunks)
        self.closed = False
    def read1(self, size):
        value = next(self.chunks, b"")
        if isinstance(value, Exception):
            raise value
        return value
    def read(self):
        return self.read1(4096)
    def close(self):
        self.closed = True

def relay_handler(writer=None):
    h = object.__new__(cp.Handler)
    h.wfile = writer if writer is not None else io.BytesIO()
    h.headers = {}
    h.send_response = lambda *a: None
    h.send_header = lambda *a: None
    h.end_headers = lambda: None
    return h

terminal = b'data: {"type":"message_stop"}\n\n'
error_event = b'event: error\ndata: {"type":"error","error":{"message":"upstream rejected"}}\n\n'
for name, chunks, expected in [
    ("fragmented terminal", [terminal[:9], terminal[9:]], True),
    ("CRLF split", [terminal.replace(b"\n", b"\r\n")[:-1], b"\n"], True),
    ("finish plus usage", [b'data: {"choices":[{"finish_reason":"stop"}]}\n\n', b'data: {"usage":{"completion_tokens":7}}\n\n'], True),
    ("missing terminal", [b'data: {"type":"content_block_delta"}\n\n'], False),
    ("error after terminal", [terminal, error_event], False),
    ("malformed event", [b'data: not-json\n\n', terminal], False),
    ("unterminated terminal", [terminal.rstrip()], False),
    ("timeout after terminal", [terminal, TimeoutError()], False),
    ("reset after terminal", [terminal, ConnectionResetError()], False),
]:
    response = RelayResponse(chunks)
    h = relay_handler()
    result = h._relay(response, True, capture=True)
    ok(name, result["ok"] is expected and response.closed and not result["cancelled"])
    if name == "error after terminal":
        ok("original error preserved", h.wfile.getvalue() == terminal + error_event)

class CancelWriter:
    def write(self, chunk):
        raise BrokenPipeError()
    def flush(self):
        pass
response = RelayResponse([terminal])
result = relay_handler(CancelWriter())._relay(response, True)
ok("downstream write cancellation", result["cancelled"] and not result["ok"] and response.closed)

response = RelayResponse([TimeoutError()])
response.headers = {"Content-Type": "application/json"}
result = relay_handler()._relay(response, False)
ok("nonstream read timeout", not result["ok"] and response.closed)
response = RelayResponse([b'{"error":{"message":"rejected"}}'])
response.headers = {"Content-Type": "application/json"}
result = relay_handler()._relay(response, False)
ok("HTTP 200 JSON error", not result["ok"] and response.closed)

# Real sockets: client cancellation must interrupt an otherwise idle upstream read.
server_sock, client_sock = socket.socketpair()
read_sock, peer_sock = socket.socketpair()
class IdleResponse(RelayResponse):
    def __init__(self):
        super().__init__([])
        self.fp = SimpleNamespace(raw=SimpleNamespace(_sock=read_sock))
    def read1(self, size):
        return read_sock.recv(size)
    def close(self):
        super().close()
        read_sock.close()
h = relay_handler()
h.connection = server_sock
response = IdleResponse()
box = []
worker = threading.Thread(target=lambda: box.append(h._relay(response, True)))
worker.start()
time.sleep(0.05)
client_sock.close()
worker.join(2)
ok("idle upstream cancellation bounded", not worker.is_alive() and box and box[0]["cancelled"] and response.closed)
peer_sock.close()
server_sock.close()

# Accelerated clock exercises the absolute budget without a five-minute wait.
server_sock, client_sock = socket.socketpair()
read_sock, peer_sock = socket.socketpair()
h = relay_handler()
h.connection = server_sock
response = IdleResponse()
with patch.object(cp.time, "monotonic", side_effect=[0, 301]):
    result = h._relay(response, True)
ok("absolute read deadline wakes idle upstream", not result["ok"] and not result["cancelled"] and response.closed and result["error"] == "upstream read budget exceeded")
client_sock.close()
server_sock.close()
peer_sock.close()

# Both successful-HTTP call sites must defer health accounting and never replay.
for direct in (False, True):
    for outcome in ("ok", "error", "cancelled"):
        h = relay_handler()
        h.path = "/v1/messages"
        h.command = "POST"
        h._fwd_headers = lambda: {}
        response = RelayResponse([terminal])
        calls = []
        def checked_relay(*args, **kwargs):
            ok("statistics deferred", not calls)
            response.close()
            return {"ok": outcome == "ok", "cancelled": outcome == "cancelled", "body": b"", "error": "read failure" if outcome == "error" else None}
        h._relay = checked_relay
        with patch.object(cp.urllib.request, "urlopen", return_value=response) as opening, patch.object(cp.STATS, "record", side_effect=lambda *a, **kw: calls.append(kw)), patch.object(cp.BREAKER, "record_ok") as healthy, patch.object(cp.BREAKER, "record_fail") as failing:
            body = json.dumps({"model":"MODEL_X", "stream":True}).encode()
            if direct:
                h._passthrough(body, model="MODEL_X", stream=True)
            else:
                h._route(body)
            ok("no post-relay replay", opening.call_count == 1)
            ok("final accounting", (not calls) if outcome == "cancelled" else len(calls) == 1 and calls[0]["ok"] == (outcome == "ok"))
            if not direct:
                ok("breaker final health", healthy.call_count == (outcome == "ok") and failing.call_count == (outcome == "error"))

# Final HTTP errors must also defer accounting and exclude client cancellation.
for direct in (False, True):
    for status in (400, 503):
        for cancelled in (False, True):
            h = relay_handler()
            h.path = "/v1/messages"
            h.command = "POST"
            h._fwd_headers = lambda: {}
            calls = []
            response = cp.urllib.error.HTTPError("http://localhost/test", status, "failure", {}, io.BytesIO(b'{}'))
            def error_relay(resp, **kwargs):
                ok("HTTP error accounting deferred", not calls)
                resp.close()
                return {"ok": False, "cancelled": cancelled, "body": b"", "error": None}
            h._relay = error_relay
            with patch.object(cp.urllib.request, "urlopen", side_effect=response) as opening, patch.object(cp, "PT_MAX_RETRY", 0), patch.object(cp.STATS, "record", side_effect=lambda *a, **kw: calls.append(kw)), patch.object(cp.BREAKER, "record_fail") as failing:
                body = json.dumps({"model": "MODEL_X"}).encode()
                if direct:
                    h._passthrough(body, model="MODEL_X")
                else:
                    h._route(body)
                ok("HTTP error no replay", opening.call_count == 1)
                ok("HTTP error cancellation accounting", len(calls) == (not cancelled))
                if not direct:
                    ok("HTTP error breaker accounting", failing.call_count == (status == 503 and not cancelled))

# Parsing terminal events must be independent of the usage capture cap.
with patch.object(cp, "USAGE_STREAM_CAP", 64):
    response = RelayResponse([b': heartbeat\n\n'] * 20 + [terminal])
    result = relay_handler()._relay(response, True, capture=True)
    ok("terminal beyond capture cap", result["ok"] and len(result["body"]) == 64 and response.closed)
h = relay_handler()
response = RelayResponse([error_event, TimeoutError()])
result = h._relay(response, True)
ok("protocol error followed by timeout preserved", not result["ok"] and h.wfile.getvalue() == error_event and response.closed)
response = RelayResponse([b'{"ok":true}'])
response.headers = {"Content-Type": "application/json"}
result = relay_handler()._relay(response, False)
ok("nonstream success closes response", result["ok"] and response.closed)

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
