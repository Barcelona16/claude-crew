#!/usr/bin/env python3
"""Tests for crew-proxy: circuit breaker logic + end-to-end failover against a mock upstream.

Run:  python3 setup/test_crew_proxy.py
Exits non-zero on any failure. No third-party deps.
"""
import importlib.util
import json
import os
import tempfile
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

# ── build an isolated config env, then import crew_proxy fresh ────────────────────
_tmp = tempfile.mkdtemp(prefix="crewproxy-test-")
_cfg = os.path.join(_tmp, "config")
os.makedirs(_cfg, exist_ok=True)

# keys.conf: three aliases
with open(os.path.join(_cfg, "keys.conf"), "w") as f:
    f.write("k1=KEY_ONE\nk2=KEY_TWO\nk3=KEY_THREE\n")
# key-policy.conf: model M prefers k1 > k2 > k3
with open(os.path.join(_cfg, "key-policy.conf"), "w") as f:
    f.write("MODEL_X = k1 k2 k3\n")

# CCR config: one provider per (model, key) pair
_ccr_cfg = os.path.join(_tmp, "ccr.json")
with open(_ccr_cfg, "w") as f:
    json.dump({"Providers": [
        {"name": "p1", "models": ["MODEL_X"], "api_key": "KEY_ONE"},
        {"name": "p2", "models": ["MODEL_X"], "api_key": "KEY_TWO"},
        {"name": "p3", "models": ["MODEL_X"], "api_key": "KEY_THREE"},
    ]}, f)

_state = os.path.join(_tmp, "state.json")

# Mock upstream (stands in for CCR). Decides pass/fail based on which provider was routed.
MOCK = {"fail_providers": set(), "hits": []}

class MockCCR(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        model = body.get("model", "")
        provider = model.split(",", 1)[0]
        MOCK["hits"].append(provider)
        if provider in MOCK["fail_providers"]:
            code = MOCK.get("fail_code", 429)
            payload = json.dumps({"error": {"message": f"forced {code} for {provider}"}}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            if MOCK.get("retry_after") is not None:
                self.send_header("Retry-After", str(MOCK["retry_after"]))
            self.end_headers()
            self.wfile.write(payload)
        else:
            payload = json.dumps({"ok": True, "provider": provider,
                                  "usage": {"input_tokens": 10, "output_tokens": 20}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

_mock_srv = ThreadingHTTPServer(("127.0.0.1", 0), MockCCR)
_mock_port = _mock_srv.server_address[1]
threading.Thread(target=_mock_srv.serve_forever, daemon=True).start()

# env must be set BEFORE importing crew_proxy (module reads env at import)
os.environ["CREW_CONFIG_DIR"] = _cfg
os.environ["CREW_CCR_CONFIG"] = _ccr_cfg
os.environ["CREW_CCR_URL"] = f"http://127.0.0.1:{_mock_port}"
os.environ["CREW_PROXY_STATE"] = _state
os.environ["CREW_PROXY_FAILS"] = "3"
os.environ["CREW_PROXY_COOLDOWN"] = "2"
os.environ["CREW_PROXY_PORT"] = "0"

_spec = importlib.util.spec_from_file_location("crew_proxy", os.path.join(HERE, "crew_proxy.py"))
cp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cp)

# start the proxy on an ephemeral port
_proxy_srv = ThreadingHTTPServer(("127.0.0.1", 0), cp.Handler)
_proxy_port = _proxy_srv.server_address[1]
threading.Thread(target=_proxy_srv.serve_forever, daemon=True).start()
PROXY = f"http://127.0.0.1:{_proxy_port}"

FAILS = 0
def check(name, cond):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}")

def post(model="MODEL_X", headers=None):
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(PROXY + "/v1/messages",
                                 data=json.dumps({"model": model, "stream": False}).encode(),
                                 headers=h, method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

def reset():
    MOCK["hits"].clear()
    MOCK["retry_after"] = None
    cp.BREAKER._fails.clear()
    cp.BREAKER._tripped.clear()

# ── unit: Breaker state machine ───────────────────────────────────────────────────
print("Breaker unit:")
b = cp.Breaker.__new__(cp.Breaker)   # fresh, skip __init__'s state load
b._lock = __import__("threading").Lock(); b._fails = {}; b._tripped = {}
now = 1000.0
check("all healthy initially", b.pick(["k1", "k2", "k3"], now) == "k1")
check("fail 1 no trip", b.record_fail("k1", now) is False)
check("fail 2 no trip", b.record_fail("k1", now) is False)
check("fail 3 trips", b.record_fail("k1", now) is True)
check("k1 now unhealthy -> picks k2", b.pick(["k1", "k2", "k3"], now) == "k2")
check("success resets k2", (b.record_ok("k2"), b._fails.get("k2", 0))[1] == 0)
check("cooldown recovers k1", b.pick(["k1"], now + 3) == "k1")

# ── integration: failover 429 primary -> backup ──────────────────────────────────
print("Integration failover (429):")
reset(); MOCK["fail_providers"] = {"p1"}; MOCK["fail_code"] = 429
code, body = post()
check("first request succeeds (via backup)", code == 200)
check("landed on p2 after p1 failed", body.get("provider") == "p2")
check("p1 was attempted then p2", MOCK["hits"] == ["p1", "p2"])

# ── integration: primary trips after N, later requests skip it ────────────────────
print("Integration trip-and-skip:")
reset(); MOCK["fail_providers"] = {"p1"}; MOCK["fail_code"] = 500
for _ in range(3):
    post()  # each hits p1 (fail) then p2 (ok) -> 3 k1 fails => trip
check("k1 tripped after 3 fails", not cp.BREAKER.healthy("k1", time.time()))
MOCK["hits"].clear()
code, body = post()
check("next request skips tripped p1", MOCK["hits"] == ["p2"])
check("still succeeds on p2", code == 200 and body.get("provider") == "p2")

# ── integration: all keys tripped -> hard-forward top key, surface real error ─────
print("Integration all-tripped passthrough:")
reset(); MOCK["fail_providers"] = {"p1", "p2", "p3"}; MOCK["fail_code"] = 503
# trip all three (breaker keys on the alias, not the provider name)
for alias in ("k1", "k2", "k3"):
    for _ in range(3):
        cp.BREAKER.record_fail(alias, time.time())
MOCK["hits"].clear()
code, body = post()
check("all tripped -> surfaces upstream 503", code == 503)
check("forced onto top-priority p1 only", MOCK["hits"] == ["p1"])

# ── integration: 400 (non-failover) relayed as-is, no trip ────────────────────────
print("Integration non-failover status:")
reset(); MOCK["fail_providers"] = {"p1"}; MOCK["fail_code"] = 400
code, _ = post()
check("400 relayed, not failed over", code == 400 and MOCK["hits"] == ["p1"])
check("p1 not counted as failure", cp.BREAKER._fails.get("p1", 0) == 0)

# ── affinity: X-Crew-Prefer-Key bumps a lower-priority alias to the front ──────────
print("Affinity header (X-Crew-Prefer-Key):")
reset(); MOCK["fail_providers"] = set()
code, body = post(headers={"X-Crew-Prefer-Key": "k2"})
check("prefer k2 -> lands on p2 first", code == 200 and body.get("provider") == "p2")
check("only p2 hit (no p1 attempt)", MOCK["hits"] == ["p2"])
reset(); MOCK["fail_providers"] = set()
code, body = post(headers={"X-Crew-Prefer-Key": "nope"})  # not in policy -> ignored
check("unknown prefer ignored -> default k1/p1", body.get("provider") == "p1")
reset(); MOCK["fail_providers"] = set()
code, body = post()  # no header -> unchanged default behavior
check("no header -> default k1/p1 (harmless)", body.get("provider") == "p1")
# preferred but tripped -> falls through to normal policy order
reset(); MOCK["fail_providers"] = set()
for _ in range(3):
    cp.BREAKER.record_fail("k2", time.time())
code, body = post(headers={"X-Crew-Prefer-Key": "k2"})
check("preferred-but-tripped falls back to k1", body.get("provider") == "p1")

# ── tiered cooldown: 429 with small Retry-After uses that value verbatim ───────────
print("Tiered cooldown (cooldown.conf + Retry-After):")
# write a cooldown.conf into the test config dir
with open(os.path.join(_cfg, "cooldown.conf"), "w") as f:
    f.write("daily_quota=86400\ntransient=7\nretryafter_max=300\n")
# 429 with Retry-After=5 (<= max) -> k1 tripped for ~5s (verbatim), not transient/daily
reset(); MOCK["fail_providers"] = {"p1"}; MOCK["fail_code"] = 429; MOCK["retry_after"] = 5
for _ in range(3):
    post()  # p1 fails 3x -> trip
now = time.time()
exp = cp.BREAKER._tripped.get("k1", 0)
check("429 small Retry-After -> ~5s cooldown", 3 <= (exp - now) <= 7)
# 429 with no Retry-After -> daily_quota (86400)
reset(); MOCK["fail_providers"] = {"p2"}; MOCK["fail_code"] = 429; MOCK["retry_after"] = None
for _ in range(3):
    post(headers={"X-Crew-Prefer-Key": "k2"})  # force onto p2 path? p2 fails -> failover, but k2 fails counted
now = time.time()
exp2 = cp.BREAKER._tripped.get("k2", 0)
check("429 no Retry-After -> daily_quota (~86400)", exp2 - now > 80000)
# 500 (non-429) -> transient (7s per our cooldown.conf)
reset(); MOCK["fail_providers"] = {"p1"}; MOCK["fail_code"] = 500; MOCK["retry_after"] = None
for _ in range(3):
    post()
now = time.time()
exp3 = cp.BREAKER._tripped.get("k1", 0)
check("500 -> transient (~7s)", 4 <= (exp3 - now) <= 10)
os.remove(os.path.join(_cfg, "cooldown.conf"))  # clean up so later tests use default

# ── dashboard read endpoints ──────────────────────────────────────────────────────
print("Dashboard read endpoints:")
def get(path):
    req = urllib.request.Request(PROXY + path)
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
code, html = get("/dashboard")
check("/dashboard serves HTML", code == 200 and b"<!doctype html>" in html[:40].lower())
code, raw = get("/api/status")
st = json.loads(raw)
check("/api/status has totals + keys", "totals" in st and "keys" in st)
code, raw = get("/api/logs?n=5")
check("/api/logs returns a list", isinstance(json.loads(raw).get("logs"), list))

# ── write endpoints: session config (stage C) ────────────────────────────────────
print("Write: session config (stage C):")
def jpost(path, obj):
    req = urllib.request.Request(PROXY + path, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

# point crew state at the test tmpdir so writes are isolated
os.makedirs(os.path.join(_tmp, "state"), exist_ok=True)
cp.CREW_STATE = os.path.join(_tmp, "state")
code, r = jpost("/api/session/config", {"name": "demo", "model": "MODEL_X", "key": "k1"})
check("config write ok", code == 200 and r.get("ok"))
check("wrote demo.backend", open(os.path.join(cp.CREW_STATE, "demo.backend")).read() == "MODEL_X")
check("wrote demo.key", open(os.path.join(cp.CREW_STATE, "demo.key")).read() == "k1")
code, r = jpost("/api/session/config", {"name": "demo", "key": ""})
check("empty key clears file", not os.path.exists(os.path.join(cp.CREW_STATE, "demo.key")))

# ── injection defense ─────────────────────────────────────────────────────────────
print("Injection defense:")
code, r = jpost("/api/session/config", {"name": "demo; rm -rf /", "model": "X"})
check("shell-metachar name rejected (config)", code == 400 and not r.get("ok"))
code, r = jpost("/api/session/kill", {"name": "$(touch /tmp/pwned)"})
check("shell-metachar name rejected (kill)", code == 400 and not r.get("ok"))
code, r = jpost("/api/session/config", {"name": "demo", "model": "a/../b"})
check("path-sep model rejected", code == 400 and not r.get("ok"))

# ── write endpoints: CCR provider add (stage D) ───────────────────────────────────
print("Write: CCR provider add (stage D):")
cp.KEYS_FILE = os.path.join(_cfg, "keys.conf")
cp.CCR_CFG = _ccr_cfg
code, r = jpost("/api/ccr/provider", {"alias": "k4", "key": "KEY_FOUR", "model": "MODEL_X",
                                       "base_url": "https://api.example.com/v1/chat/completions",
                                       "transformer": "OpenAI"})
check("provider add ok", code == 200 and r.get("ok"))
check("backup file created", os.path.exists(r.get("backup_path", "")))
_ccr = json.load(open(_ccr_cfg))
check("new provider MODEL_X-k4 present", any(p["name"] == "MODEL_X-k4" for p in _ccr["Providers"]))
check("keys.conf has k4", "k4=KEY_FOUR" in open(cp.KEYS_FILE).read())
code, r = jpost("/api/ccr/provider", {"alias": "k4", "key": "x", "model": "MODEL_X",
                                       "base_url": "https://x", "transformer": "OpenAI"})
check("duplicate provider rejected", code == 409 and not r.get("ok"))
code, r = jpost("/api/ccr/provider", {"alias": "bad;alias", "key": "x", "model": "MODEL_X",
                                       "base_url": "https://x", "transformer": "OpenAI"})
check("bad alias rejected", code == 400 and not r.get("ok"))
code, r = jpost("/api/ccr/provider", {"alias": "k5", "key": "x", "model": "MODEL_X",
                                       "base_url": "ftp://nope", "transformer": "OpenAI"})
check("non-http base_url rejected", code == 400 and not r.get("ok"))

# ── gateway login table: add / update / delete + erp join + injection ─────────────
print("Gateway login table (/api/gateway/auth):")
cp.GATEWAY_AUTH = os.path.join(_tmp, "gateway-auth.json")
# add a ticket mapped to a real alias k1, limited to MODEL_X
code, r = jpost("/api/gateway/auth", {"login": "ticket1", "maps_to": "k1",
                                      "allow_models": ["MODEL_X"], "erp": "alice"})
check("add login ticket1", code == 200 and r.get("ok"))
_auth = json.load(open(cp.GATEWAY_AUTH))
check("ticket1 persisted", _auth.get("ticket1", {}).get("maps_to") == "k1")
check("gateway-auth.json is 0600", (os.stat(cp.GATEWAY_AUTH).st_mode & 0o777) == 0o600)
# maps_to must be a real alias in keys.conf
code, r = jpost("/api/gateway/auth", {"login": "bad", "maps_to": "nosuchalias"})
check("maps_to must exist in keys.conf", code == 400 and not r.get("ok"))
# injection: login key with shell metachars rejected
code, r = jpost("/api/gateway/auth", {"login": "a;rm -rf /", "maps_to": "k1"})
check("shell-metachar login rejected", code == 400 and not r.get("ok"))
# injection: bad model name in allow_models rejected
code, r = jpost("/api/gateway/auth", {"login": "t2", "maps_to": "k1", "allow_models": ["a/../b"]})
check("bad model name rejected", code == 400 and not r.get("ok"))
# update existing
code, r = jpost("/api/gateway/auth", {"login": "ticket1", "maps_to": "k2",
                                      "allow_models": [], "erp": "bob"})
check("update ticket1 -> k2/all/bob", code == 200 and r.get("ok"))
_auth = json.load(open(cp.GATEWAY_AUTH))
check("update persisted", _auth["ticket1"]["maps_to"] == "k2" and _auth["ticket1"]["allow_models"] == [])
# erp join shows up in /api/status keys
code, raw = get("/api/status")
_st = json.loads(raw)
_k2 = next((k for k in _st["keys"] if k["alias"] == "k2"), {})
check("erp joins onto k2 in status", _k2.get("erp") == "bob")
check("status has auth rows", any(a["login"] == "ticket1" for a in _st.get("auth", [])))
# delete
code, r = jpost("/api/gateway/auth", {"login": "ticket1", "delete": True})
check("delete ticket1", code == 200 and r.get("ok"))
check("ticket1 gone", "ticket1" not in json.load(open(cp.GATEWAY_AUTH)))
code, r = jpost("/api/gateway/auth", {"login": "ghost", "delete": True})
check("delete missing -> 404", code == 404)

# ── usage parsing (unit) ──────────────────────────────────────────────────────────
print("Usage parsing (unit):")
check("anthropic non-stream", cp.parse_usage(
    json.dumps({"usage": {"input_tokens": 12, "output_tokens": 34}}).encode()) == (12, 34))
check("openai non-stream", cp.parse_usage(
    json.dumps({"usage": {"prompt_tokens": 5, "completion_tokens": 7}}).encode()) == (5, 7))
_sse = (b'data: {"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":1}}}\n\n'
        b'data: {"type":"content_block_delta"}\n\n'
        b'data: {"type":"message_delta","usage":{"output_tokens":250}}\n\n'
        b'data: [DONE]\n\n')
check("anthropic SSE (max in, max out)", cp.parse_usage(_sse) == (100, 250))
check("garbage -> (0,0)", cp.parse_usage(b"not json at all") == (0, 0))
check("empty -> (0,0)", cp.parse_usage(b"") == (0, 0))
check("no usage field -> (0,0)", cp.parse_usage(json.dumps({"ok": 1}).encode()) == (0, 0))

# ── usage end-to-end: a successful request counts tokens ──────────────────────────
print("Usage end-to-end:")
reset(); cp.STATS.__init__(); MOCK["fail_providers"] = set()
code, body = post()
check("request ok", code == 200)
time.sleep(0.1)  # usage recorded after relay
_stat = cp.STATS.status()
check("totals count tokens", _stat["totals"]["in_tokens"] == 10 and _stat["totals"]["out_tokens"] == 20)
check("per-key k1 tokens", _stat["per_key"].get("k1", {}).get("out_tokens") == 20)
check("per-model MODEL_X tokens", _stat["per_model"].get("MODEL_X", {}).get("in_tokens") == 10)

print()
if FAILS:
    print(f"{FAILS} check(s) FAILED")
    raise SystemExit(1)
print("all checks passed")
