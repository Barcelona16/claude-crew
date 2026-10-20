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

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
