# Per-key token usage: self-service login + line chart — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a contributor log in with their own key and see their own token usage over time as a jimdb-chaos-style pure-canvas line chart.

**Architecture:** crew-proxy gains a thread-safe `UsageSeries` that buckets token usage per login-key into 10-min windows, persisted to `CFG_DIR/usage.json` (atomic write, read on boot). The gateway forwards an `X-Crew-Login` header so the proxy can attribute usage to the login key (default-harmless: absent → falls back to the real alias). A read-only `/api/usage` endpoint authenticates by key and a self-contained `/usage` page renders the chart inline.

**Tech Stack:** Python 3.6+ stdlib only (`http.server`, `urllib`, `json`, `threading`, `os`, `atexit`); vanilla JS + `<canvas>` for the chart (no build, no external libs).

**Spec:** `docs/superpowers/specs/2026-08-17-per-key-usage-chart-design.md`

## Global Constraints

- **Zero third-party deps.** stdlib only, both Python and JS. Python 3.6+ compatible.
- **Default-harmless.** No `X-Crew-Login` header, no `admin` field, no `usage.json` → behavior byte-identical to today. Every new field is optional with a safe default.
- **Never on the hot path.** Usage recording and disk flush must never block or slow request forwarding. `UsageSeries.add` is an in-memory locked increment; disk I/O is throttled on a background thread + `atexit`.
- **Counts only, never content.** Store token counts and request counts, never prompt/response text.
- **Concurrency-correct.** `UsageSeries.add` holds `self._lock` for the whole read-modify-write and accumulates directly by `(login, bucketTs)` — it must NOT reuse the `Stats._logs[-1]` "last request" heuristic (that can misattribute under concurrent requests to the same key).
- **crew-proxy stays 127.0.0.1.** Only the gateway (`:8790`) faces outward. The `/usage` page and `/api/usage` are served by crew-proxy on its local port.
- Test runner convention: `setup/test_crew_proxy.py` and `crew-gateway/test_gateway.py` are plain scripts — a `check(name, cond)` helper prints `ok`/`FAIL` and the script exits non-zero if any failed. Run with `python3 <file>`.

---

### Task 1: `UsageSeries` core — bucketing, prune, in-memory series

**Files:**
- Modify: `setup/crew_proxy.py` (add class after `Stats` / `STATS`, around line 387)
- Test: `setup/test_crew_proxy.py` (append a new section before the final summary block at line 354)

**Interfaces:**
- Consumes: nothing (new module-global `USAGE`).
- Produces:
  - `class UsageSeries` with:
    - `BUCKET_SEC = 600`, `WINDOW_DAYS = 7`
    - `add(self, login, in_tok, out_tok, now=None)` — locked; bumps `(login, bucket)` by `{turns:+1, inTok:+in, outTok:+out}`; no-op if both tokens 0 AND we still want a turn counted → count the turn whenever called (see step 3).
    - `series(self, login, days=7, now=None)` → the data-contract dict (built in Task 4; in THIS task return buckets list only, see below)
    - `_bucket_ts(self, now)` → `int(now // 600) * 600`
    - `prune(self, now=None)` — drop buckets older than `now - WINDOW_DAYS*86400`
  - module-global `USAGE = UsageSeries()`

- [ ] **Step 1: Write the failing test**

Append to `setup/test_crew_proxy.py` before the `print()` summary at line 354:

```python
# ── UsageSeries unit: bucketing + prune ───────────────────────────────────────────
print("UsageSeries unit:")
us = cp.UsageSeries()
t = 1_000_000.0  # fixed epoch seconds
us.add("personal", 10, 20, now=t)
us.add("personal", 5, 7, now=t + 60)          # same 10-min bucket
us.add("jimdbtest", 1, 2, now=t)              # different login, same bucket
b0 = us._bucket_ts(t)
check("same 10-min window merges", us._buckets["personal"][b0] == {"turns": 2, "inTok": 15, "outTok": 27})
check("distinct login separate", us._buckets["jimdbtest"][b0] == {"turns": 1, "inTok": 1, "outTok": 2})
us.add("personal", 3, 4, now=t + 700)         # next bucket (700s > 600)
check("next window is a new bucket", len(us._buckets["personal"]) == 2)
us.add("personal", 9, 9, now=t + 8 * 86400)   # 8 days later
us.prune(now=t + 8 * 86400)
check("prune drops >7d-old buckets", all(bts >= (t + 8 * 86400) - 7 * 86400 for bts in us._buckets["personal"]))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 setup/test_crew_proxy.py`
Expected: FAIL with `AttributeError: module 'crew_proxy' has no attribute 'UsageSeries'`

- [ ] **Step 3: Write minimal implementation**

In `setup/crew_proxy.py`, after the `STATS = Stats()` line (line 387), add:

```python
class UsageSeries:
    """Per-login-key token usage bucketed into fixed time windows, for the self-service
    usage chart. Separate from Stats (which counts by real alias): here the dimension is
    the client LOGIN key, so two tickets that map to the same real key stay distinct.

    Thread-safe: add() holds the lock for the whole read-modify-write and accumulates
    directly by (login, bucket) — it never relies on a 'last request' heuristic, so it is
    correct under concurrent requests sharing one login key. Counts only, never content."""

    BUCKET_SEC = 600          # 10-minute buckets
    WINDOW_DAYS = 7

    def __init__(self):
        self._lock = threading.Lock()
        # login -> {bucket_ts(int) -> {"turns", "inTok", "outTok"}}
        self._buckets = {}

    def _bucket_ts(self, now):
        return int(now // self.BUCKET_SEC) * self.BUCKET_SEC

    def add(self, login, in_tok, out_tok, now=None):
        if now is None:
            now = time.time()
        bts = self._bucket_ts(now)
        with self._lock:
            series = self._buckets.setdefault(login, {})
            b = series.setdefault(bts, {"turns": 0, "inTok": 0, "outTok": 0})
            b["turns"] += 1
            b["inTok"] += int(in_tok or 0)
            b["outTok"] += int(out_tok or 0)

    def prune(self, now=None):
        if now is None:
            now = time.time()
        cutoff = now - self.WINDOW_DAYS * 86400
        with self._lock:
            for login in list(self._buckets):
                series = self._buckets[login]
                for bts in list(series):
                    if bts < cutoff:
                        del series[bts]
                if not series:
                    del self._buckets[login]


USAGE = UsageSeries()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 setup/test_crew_proxy.py`
Expected: PASS (all checks `ok`, including prior sections)

- [ ] **Step 5: Commit**

```bash
git add setup/crew_proxy.py setup/test_crew_proxy.py
git commit -m "feat(crew-proxy): UsageSeries — per-login-key token buckets + prune"
```

---

### Task 2: Persistence — atomic flush to `usage.json` + load on boot

**Files:**
- Modify: `setup/crew_proxy.py` (extend `UsageSeries`; add `USAGE_FILE` constant near line 62; call `USAGE.load()` at startup)
- Test: `setup/test_crew_proxy.py` (append after Task 1's section)

**Interfaces:**
- Consumes: `UsageSeries` from Task 1; `CFG_DIR` (line 51).
- Produces:
  - `USAGE_FILE = os.path.join(CFG_DIR, "usage.json")` (module constant)
  - `UsageSeries.snapshot(self)` → JSON-serializable dict `{"version":1,"bucketSec":600,"buckets":{login:{str(ts):{...}}}}`
  - `UsageSeries.flush(self, force=False)` — atomic write to `USAGE_FILE` (temp + `os.replace`, chmod 0600), throttled by `FLUSH_MIN_SEC = 20` unless `force`
  - `UsageSeries.load(self)` — read `USAGE_FILE`, restore + prune; missing/garbled → empty

- [ ] **Step 1: Write the failing test**

Append to `setup/test_crew_proxy.py`:

```python
# ── UsageSeries persistence: flush → load round-trip ──────────────────────────────
print("UsageSeries persistence:")
us2 = cp.UsageSeries()
us2.add("personal", 100, 200, now=1_000_000.0)
us2.flush(force=True)
check("usage.json written", os.path.exists(cp.USAGE_FILE))
import stat as _stat_mod
check("usage.json is 0600", (os.stat(cp.USAGE_FILE).st_mode & 0o777) == 0o600)
us3 = cp.UsageSeries()
us3.load()
b = us3._bucket_ts(1_000_000.0)
check("round-trips buckets", us3._buckets["personal"][b] == {"turns": 1, "inTok": 100, "outTok": 200})
# garbled file → empty, no crash
with open(cp.USAGE_FILE, "w") as f:
    f.write("{ not json")
us4 = cp.UsageSeries()
us4.load()
check("garbled file loads empty (default-harmless)", us4._buckets == {})
os.remove(cp.USAGE_FILE)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 setup/test_crew_proxy.py`
Expected: FAIL with `AttributeError: 'UsageSeries' object has no attribute 'flush'` (or `USAGE_FILE` missing)

- [ ] **Step 3: Write minimal implementation**

In `setup/crew_proxy.py`, add the constant near the other `CFG_DIR`-derived paths (after line 54):

```python
USAGE_FILE = os.path.join(CFG_DIR, "usage.json")
```

Add `import atexit` to the import block (after `import threading`, line 38).

Extend `UsageSeries`: add `FLUSH_MIN_SEC = 20` as a class attribute, add `self._last_flush = 0.0` and `self._dirty = False` in `__init__`, set `self._dirty = True` at the end of `add` (inside the lock), and add these methods:

```python
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
            self._dirty = False
            self._last_flush = now
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
        self.prune()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 setup/test_crew_proxy.py`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add setup/crew_proxy.py setup/test_crew_proxy.py
git commit -m "feat(crew-proxy): UsageSeries persistence — atomic usage.json flush + load"
```

---

### Task 3: Wire usage recording — `record_usage(login=...)` + gateway `X-Crew-Login`

**Files:**
- Modify: `setup/crew_proxy.py:358` (`Stats.record_usage` signature), `:992` and `:1111` (call sites), and add the `X-Crew-Login` read in `_route`/`_passthrough`
- Modify: `crew-gateway/gateway.py:138-144` (`_fwd_headers`), `:171` and `:177` (`_forward` call + signature)
- Test: `setup/test_crew_proxy.py` (append) and `crew-gateway/test_gateway.py` (append)

**Interfaces:**
- Consumes: `USAGE.add(login, in_tok, out_tok)` from Task 1; `Stats.record_usage` from existing code.
- Produces:
  - `Stats.record_usage(self, alias, model, in_tok, out_tok, login=None)` — unchanged behavior for its own counters; additionally, the CALLER passes the login so `USAGE.add` can be invoked. (Decision: call `USAGE.add` from the call sites, NOT inside `Stats`, to keep `Stats` free of the new global. `record_usage` gains an optional `login` param only if needed for the log line; simpler is to leave `Stats.record_usage` untouched and call `USAGE.add` right after it. Use that simpler form — see step 3.)
  - crew-proxy reads `self.headers.get("X-Crew-Login")` and passes it as `login` (default = the alias used).
  - gateway `_fwd_headers(self, prefer_alias, login)` sets `out["X-Crew-Login"] = login`; `_forward(self, path, body, prefer_alias, login, model)`.

- [ ] **Step 1: Write the failing tests**

Append to `setup/test_crew_proxy.py`:

```python
# ── usage attributed to X-Crew-Login (falls back to alias) ────────────────────────
print("Usage login attribution:")
reset(); cp.STATS.__init__(); cp.USAGE.__init__(); MOCK["fail_providers"] = set()
code, body = post(headers={"X-Crew-Login": "jimdbtest"})
check("request ok", code == 200)
time.sleep(0.1)
check("usage bucketed under login 'jimdbtest'", "jimdbtest" in cp.USAGE._buckets)
check("not bucketed under alias k1", "k1" not in cp.USAGE._buckets)
_bt = cp.USAGE._bucket_ts(time.time())
_b = cp.USAGE._buckets["jimdbtest"][_bt]
check("login bucket has in=10 out=20", _b["inTok"] == 10 and _b["outTok"] == 20)

reset(); cp.STATS.__init__(); cp.USAGE.__init__(); MOCK["fail_providers"] = set()
code, body = post()  # no X-Crew-Login header
time.sleep(0.1)
check("no header -> falls back to alias k1 (default-harmless)", "k1" in cp.USAGE._buckets)
```

Append to `crew-gateway/test_gateway.py` (mirror its existing `check`/request helpers; assert the forwarded header). Add near the other forward-header assertions:

```python
# ── forwarded request carries X-Crew-Login = matched login key ────────────────────
print("X-Crew-Login forwarding:")
CAPTURED.clear()
code, _ = call(key="jimdbtest", model="GLM-5.2")   # a login whose allow_models permits GLM-5.2
check("forwarded", code == 200)
check("X-Crew-Login header set to login key",
      CAPTURED and CAPTURED[-1].get("X-Crew-Login") == "jimdbtest")
check("X-Crew-Prefer-Key still the maps_to alias",
      CAPTURED[-1].get("X-Crew-Prefer-Key") == "personal")
```

(If `crew-gateway/test_gateway.py` does not already capture forwarded headers, add a `CAPTURED = []` list its mock crew-proxy handler appends `dict(self.headers)` to, and a `call(key, model)` helper — follow the existing mock/handler pattern in that file. Read the file first to match its exact harness names.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 setup/test_crew_proxy.py`
Expected: FAIL — `"jimdbtest" in cp.USAGE._buckets` is False (usage still bucketed by alias only)

Run: `python3 crew-gateway/test_gateway.py`
Expected: FAIL — `X-Crew-Login` header absent

- [ ] **Step 3: Write minimal implementation**

**crew_proxy.py** — at the two success call sites, call `USAGE.add` using the login header (falling back to the alias). At line ~1108-1113 (the `_route` success path), change:

```python
            if captured:
                try:
                    it, ot = parse_usage(captured)
                    STATS.record_usage(alias, realmodel, it, ot)
                    USAGE.add(self.headers.get("X-Crew-Login") or alias, it, ot)
                except Exception:
                    pass
```

At line ~989-994 (the `_passthrough` success path), change:

```python
                if captured:
                    try:
                        it, ot = parse_usage(captured)
                        STATS.record_usage("direct", model, it, ot)
                        USAGE.add(self.headers.get("X-Crew-Login") or "direct", it, ot)
                    except Exception:
                        pass
```

(`Stats.record_usage` signature is left unchanged — no `login` param needed.)

**gateway.py** — thread the login through. Change `_fwd_headers` (line 138):

```python
    def _fwd_headers(self, prefer_alias, login):
        """Client headers minus hop-by-hop, plus affinity + login headers for crew-proxy."""
        skip = {"host", "content-length", "connection", "transfer-encoding",
                "proxy-connection", "keep-alive"}
        out = {k: v for k, v in self.headers.items() if k.lower() not in skip}
        out["X-Crew-Prefer-Key"] = prefer_alias
        out["X-Crew-Login"] = login
        return out
```

Change the `do_POST` forward call (line 171) — the matched login key is `key`:

```python
        # 4. forward to crew-proxy verbatim (streaming SSE passes through untouched).
        self._forward(path, body, prefer, key, model)
```

Change `_forward` (line 177):

```python
    def _forward(self, path, body, prefer_alias, login, model):
        url = DOWNSTREAM + path
        req = urllib.request.Request(url, data=body or None,
                                     headers=self._fwd_headers(prefer_alias, login), method="POST")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 setup/test_crew_proxy.py` → Expected: PASS
Run: `python3 crew-gateway/test_gateway.py` → Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add setup/crew_proxy.py setup/test_crew_proxy.py crew-gateway/gateway.py crew-gateway/test_gateway.py
git commit -m "feat: attribute token usage by login-key (gateway forwards X-Crew-Login)"
```

---

### Task 4: `series()` data contract + `/api/usage` authenticated endpoint

**Files:**
- Modify: `setup/crew_proxy.py` (add `UsageSeries.series`; extend `load_gateway_auth` for `admin`; add `_api_usage` method; route it in `do_GET` at line 752)
- Test: `setup/test_crew_proxy.py` (append)

**Interfaces:**
- Consumes: `UsageSeries` (Tasks 1-2); `load_gateway_auth()` (line 178).
- Produces:
  - `UsageSeries.series(self, login, days=7, now=None)` → dict:
    `{"generatedAt": <ms>, "bucketMin": 10, "windowH": days*24, "login": login,
      "buckets": [{"t": ms, "newTokens", "inputSum", "outputSum", "turns", "perReqNew"}...],
      "daily": [{"day": "YYYY-MM-DD", "newTokens", "turns", "perReqNew"}...],
      "totals": {"newTokens", "turns", "perReqNew", "days"}}`.
    If `login is None`, sum across all logins.
  - `load_gateway_auth()` entries gain `"admin": bool(v.get("admin"))`.
  - `_api_usage(self)` — reads key from `x-api-key` or `Authorization: Bearer`; 401 if not in auth table; normal user → own login; admin → honors `?key=<login>` or `?key=__all__`.

- [ ] **Step 1: Write the failing test**

Append to `setup/test_crew_proxy.py`. First ensure the test's gateway-auth file has an admin + a normal user (the test writes its own config; add these entries to that file, or write them here):

```python
# ── /api/usage: auth + own-vs-admin scope + data contract ─────────────────────────
print("/api/usage endpoint:")
# seed a known auth table for this test
with open(os.path.join(_cfg, "gateway-auth.json"), "w") as f:
    json.dump({
        "personal":  {"maps_to": "k1", "allow_models": [], "erp": "me", "admin": True},
        "jimdbtest": {"maps_to": "k1", "allow_models": ["MODEL_X"], "erp": "me"},
    }, f)
cp.USAGE.__init__()
cp.USAGE.add("jimdbtest", 10, 20, now=time.time())
cp.USAGE.add("personal", 1, 1, now=time.time())

def get_usage(key, query=""):
    req = urllib.request.Request(PROXY + "/api/usage" + query,
                                 headers={"x-api-key": key} if key else {})
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

code, _ = get_usage("nope")
check("unknown key -> 401", code == 401)
code, d = get_usage("jimdbtest")
check("normal user 200", code == 200)
check("normal user sees own login", d["login"] == "jimdbtest")
check("own totals newTokens=30", d["totals"]["newTokens"] == 30)
code, d = get_usage("jimdbtest", "?key=personal")
check("normal user cannot view others (key= ignored)", d["login"] == "jimdbtest")
code, d = get_usage("personal", "?key=jimdbtest")
check("admin can view another login", code == 200 and d["login"] == "jimdbtest")
code, d = get_usage("personal", "?key=__all__")
check("admin __all__ sums all logins", d["login"] == "__all__" and d["totals"]["newTokens"] == 32)
check("buckets carry perReqNew", d["buckets"][0].get("perReqNew") is not None)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 setup/test_crew_proxy.py`
Expected: FAIL — `/api/usage` returns 404 (route not added) or `series` missing

- [ ] **Step 3: Write minimal implementation**

In `load_gateway_auth` (line 192-194) add the admin field:

```python
        out[k] = {"maps_to": str(v.get("maps_to", "")),
                  "allow_models": list(v.get("allow_models") or []),
                  "erp": str(v.get("erp", "")),
                  "admin": bool(v.get("admin"))}
```

Add `UsageSeries.series` (after `load`):

```python
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
```

Add the `_api_usage` handler method (near `_api_status`, ~line 710):

```python
    def _api_usage(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        try:
            days = max(1, min(30, int(q.get("days", ["7"])[0])))
        except ValueError:
            days = 7
        key = self.headers.get("x-api-key")
        if not key:
            auth_h = self.headers.get("Authorization", "")
            if auth_h.lower().startswith("bearer "):
                key = auth_h[7:].strip()
        auth = load_gateway_auth()
        entry = auth.get(key) if key else None
        if entry is None:
            return self._send_json({"error": "unauthorized"}, 401)
        want = q.get("key", [None])[0]
        if entry.get("admin") and want:
            login = None if want == "__all__" else want
        else:
            login = key
        return self._send_json(USAGE.series(login, days=days))
```

Route it in `do_GET` (line 752, add a branch):

```python
        elif path == "/api/usage":
            self._api_usage()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 setup/test_crew_proxy.py`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add setup/crew_proxy.py setup/test_crew_proxy.py
git commit -m "feat(crew-proxy): /api/usage — authenticated per-login series (admin can view any)"
```

---

### Task 5: `/usage` self-service page — jimdb-chaos canvas chart

**Files:**
- Modify: `setup/crew_proxy.py` (add `USAGE_HTML` string constant near `DASHBOARD_HTML` ~line 452; route `/usage` in `do_GET` line 752)
- Test: manual (browser) + one smoke check in `setup/test_crew_proxy.py`

**Interfaces:**
- Consumes: `GET /api/usage` (Task 4); `_send_html` (line 697).
- Produces: `USAGE_HTML` served at `GET /usage`.

- [ ] **Step 1: Write the failing smoke test**

Append to `setup/test_crew_proxy.py`:

```python
# ── /usage page serves HTML with the chart canvas ─────────────────────────────────
print("/usage page:")
req = urllib.request.Request(PROXY + "/usage")
r = urllib.request.urlopen(req, timeout=10)
html = r.read().decode()
check("/usage returns html", r.status == 200 and "<canvas" in html and "tokenChart" in html)
check("/usage references /api/usage", "/api/usage" in html)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 setup/test_crew_proxy.py`
Expected: FAIL — `/usage` 404s (routed to `_passthrough`), no canvas

- [ ] **Step 3: Write minimal implementation**

Add `USAGE_HTML` near `DASHBOARD_HTML` (line ~452). Self-contained page: a key input that stores in `sessionStorage`, fetches `/api/usage` with `x-api-key`, renders totals cards + per-day bars + a pure-canvas dual-line chart ported from jimdb-chaos `monitor.js:drawTokenChart` (single time-axis; lines for `inputSum` #6cf, `outputSum` #e0a94f, `newTokens` #8f8 emphasized; grid `#20252e`; `fmtClock` ticks; nearest-bucket hover tooltip). Admin gets a `<select>` populated from a separate `/api/usage?key=__all__`-derived list is out of scope — keep admin switching to a free-text "view login" box that re-fetches with `?key=<value>`.

```python
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
</style></head><body>
<div class=bar>
 <input id=key type=password placeholder="输入你的 key 登录" size=32>
 <input id=viewas placeholder="(admin) 查看某 login / __all__" size=26 style=display:none>
 <button id=login>登录</button>
 <span id=meta class=dim></span>
</div>
<div id=totals></div>
<div id=daily></div>
<div id=chartWrap><canvas id=tokenChart></canvas><div id=tokenTip></div></div>
<script>
let KEY=sessionStorage.getItem('crewKey')||'', VIEW='', _d=null, _geom=null;
const $=s=>document.querySelector(s);
function fmtK(n){if(n==null)return '—';if(n>=1e6)return (n/1e6).toFixed(2)+'M';if(n>=1e3)return (n/1e3).toFixed(0)+'k';return String(Math.round(n));}
function fmtClock(ms){const d=new Date(ms),p=x=>String(x).padStart(2,'0');return p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());}
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}
async function load(){
  if(!KEY)return;
  let url='/api/usage?days=7'+(VIEW?('&key='+encodeURIComponent(VIEW)):'');
  let r;try{r=await fetch(url,{headers:{'x-api-key':KEY}});}catch(e){$('#meta').textContent='网络错误';return;}
  if(r.status===401){$('#meta').textContent='key 无效';return;}
  const d=await r.json();_d=d;
  $('#meta').textContent='登录: '+d.login+' · 近 '+(d.windowH/24)+' 天 · '+d.buckets.length+' 点';
  renderTotals(d);renderDaily(d);draw();
}
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
```

Route it in `do_GET` (line 752):

```python
        elif path in ("/usage", "/usage/"):
            self._send_html(USAGE_HTML)
```

- [ ] **Step 4: Run test + manual browser check**

Run: `python3 setup/test_crew_proxy.py` → Expected: PASS (smoke check)
Manual: start crew-proxy locally, open `http://127.0.0.1:8788/usage`, log in with a key, confirm chart + cards render and hover works. If you cannot run a browser, say so explicitly.

- [ ] **Step 5: Commit**

```bash
git add setup/crew_proxy.py setup/test_crew_proxy.py
git commit -m "feat(crew-proxy): /usage self-service page — jimdb-chaos canvas token chart"
```

---

### Task 6: Boot wiring — load on startup, background flush, atexit; example config

**Files:**
- Modify: `setup/crew_proxy.py` (call `USAGE.load()` + start flush thread in `main`/server bootstrap; register `atexit`)
- Modify: `setup/gateway-auth.json.example` (add `"admin": true` to `personal`)
- Test: covered by Task 2 round-trip; add a startup smoke check if a `main` entry exists.

**Interfaces:**
- Consumes: `UsageSeries.load/flush` (Task 2); the server bootstrap (find `ThreadingHTTPServer(... Handler)` + `serve_forever` in `crew_proxy.py`).

- [ ] **Step 1: Locate the server bootstrap**

Run: `grep -nE "def main|serve_forever|ThreadingHTTPServer|__main__" setup/crew_proxy.py`
Read that region to find where the server starts.

- [ ] **Step 2: Wire load + flush thread + atexit**

At the start of the server bootstrap (before `serve_forever`), add:

```python
    USAGE.load()
    log.info("usage series loaded (%d logins)", len(USAGE._buckets))

    def _usage_flusher():
        while True:
            time.sleep(UsageSeries.FLUSH_MIN_SEC)
            USAGE.flush()
    threading.Thread(target=_usage_flusher, daemon=True).start()
    atexit.register(lambda: USAGE.flush(force=True))
```

- [ ] **Step 3: Update the example config**

In `setup/gateway-auth.json.example`, change the `personal` line to include admin:

```json
{
  "personal": { "maps_to": "personal", "allow_models": [], "erp": "wangqiwang1", "admin": true },
  "jimdbtest": { "maps_to": "personal", "allow_models": ["GLM-5.2"], "erp": "wangqiwang1" }
}
```

- [ ] **Step 4: Run the full suite**

Run: `python3 setup/test_crew_proxy.py` → Expected: PASS
Run: `python3 crew-gateway/test_gateway.py` → Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add setup/crew_proxy.py setup/gateway-auth.json.example
git commit -m "feat(crew-proxy): boot-load usage + background flush + atexit; example admin flag"
```

---

### Task 7: Deploy to dev machine + verify end-to-end

**Files:**
- Modify: `crew-gateway/deploy/run.sh` (no change expected; usage.json lands in `/work/config` via `CFG_DIR`)
- Action: copy updated `crew_proxy.py` + `gateway.py` into the container, restart services, verify.

**Interfaces:**
- Consumes: the deployed container `crew` on `11.91.165.248` (files at `/work/`, config `/work/config`).

- [ ] **Step 1: Copy updated files into the container**

```bash
scp setup/crew_proxy.py root@11.91.165.248:/tmp/crew_proxy.py
scp /Users/wangqiwang1/Desktop/crew-gateway/gateway.py root@11.91.165.248:/tmp/gateway.py
ssh root@11.91.165.248 'docker cp /tmp/crew_proxy.py crew:/work/crew_proxy.py && docker cp /tmp/gateway.py crew:/work/gateway.py'
```

- [ ] **Step 2: Add admin flag to the live auth table**

```bash
ssh root@11.91.165.248 'docker exec crew python3 - <<PY
import json,io
p="/work/config/gateway-auth.json"
d=json.load(open(p))
d.setdefault("personal",{})["admin"]=True
json.dump(d,open(p,"w"))
print(d)
PY'
```

- [ ] **Step 3: Restart services**

```bash
ssh root@11.91.165.248 'docker exec crew bash -lc "cd /work && bash run.sh"'
```

- [ ] **Step 4: Verify end-to-end**

```bash
# a real call to generate usage
ssh root@11.91.165.248 'curl -s -m40 http://127.0.0.1:8790/v1/messages -H "content-type: application/json" -H "x-api-key: jimdbtest" -d "{\"model\":\"GLM-5.2\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" | head -c 200'
# usage series for that login
ssh root@11.91.165.248 'curl -s -m10 http://127.0.0.1:8788/api/usage -H "x-api-key: jimdbtest" | head -c 400'
# usage.json persisted
ssh root@11.91.165.248 'docker exec crew cat /work/config/usage.json | head -c 300'
```

Expected: the call returns a GLM-5.2 response; `/api/usage` shows `login: jimdbtest` with `totals.newTokens > 0`; `usage.json` exists with a `jimdbtest` bucket.

- [ ] **Step 5: Confirm the page loads**

The `/usage` page is on crew-proxy's local port (`:8788`, 127.0.0.1 only). To view it from a laptop, tunnel: `ssh -L 8788:127.0.0.1:8788 root@11.91.165.248`, then open `http://127.0.0.1:8788/usage` and log in with a key. (Do NOT expose `:8788` externally — only `:8790` faces outward.) If browser access isn't available, verify via the curl checks in Step 4 and say so.

- [ ] **Step 6: No code commit** (deploy step). Note completion in the task tracker.

---

## Self-Review

**Spec coverage:**
- §A `UsageSeries` (buckets/prune/flush/load) → Tasks 1-2 ✓
- §B gateway `X-Crew-Login` + proxy wiring → Task 3 ✓
- §C auth for `/api/usage` (401 / own / admin / `__all__`) → Task 4 ✓
- §D data contract (buckets/daily/totals/perReqNew) → Task 4 `series()` ✓
- §E `/usage` page (login bar, totals cards, daily bars, canvas chart, hover, admin view box, 30s refresh) → Task 5 ✓
- Boot load + flush thread + atexit; example admin flag → Task 6 ✓
- Deploy + verify → Task 7 ✓
- Concurrency correctness (add() locked, direct accumulation, no `_logs[-1]` reuse) → Task 1 impl + Global Constraints ✓

**Placeholder scan:** all code steps carry real code; test steps carry real asserts. Task 3's gateway test notes to read the file first for exact harness names (the file's helper names weren't confirmed) — this is a documented lookup, not a placeholder.

**Type consistency:** `UsageSeries._buckets` shape `{login: {int ts: {turns,inTok,outTok}}}` consistent across add/prune/snapshot/load/series. `series()` return keys (`generatedAt, bucketMin, windowH, login, buckets[], daily[], totals`) match the `/usage` JS reader and the spec contract. `_fwd_headers(prefer_alias, login)` / `_forward(path, body, prefer_alias, login, model)` signatures consistent between definition and call site.
