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
            self.end_headers()
            self.wfile.write(payload)
        else:
            payload = json.dumps({"ok": True, "provider": provider}).encode()
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

def post(model="MODEL_X"):
    req = urllib.request.Request(PROXY + "/v1/messages",
                                 data=json.dumps({"model": model, "stream": False}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

def reset():
    MOCK["hits"].clear()
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

print()
if FAILS:
    print(f"{FAILS} check(s) FAILED")
    raise SystemExit(1)
print("all checks passed")
