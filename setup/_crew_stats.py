#!/usr/bin/env python3
"""crew_proxy.stats — request counters, token usage series, and usage parsing."""

import json
import logging
import os
import random
import threading
import time

from _crew_config import log, USAGE_FILE

# latency.json sits next to usage.json (same CFG_DIR), same atomic-0600 persistence.
LATENCY_FILE = os.path.join(os.path.dirname(USAGE_FILE), "latency.json")

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

    def record(self, alias, model, status, ok, forced, failover, latency=None,
               err_summary=None, ttft=None):
        with self._lock:
            self.totals["requests"] += 1
            self.totals["ok" if ok else "fail"] += 1
            k = self._key(alias)
            k["requests"] += 1
            k["ok" if ok else "fail"] += 1
            self._model(model)["requests"] += 1
            entry = {
                "t": round(time.time() - self._t0, 1),
                # 2026-10-20:相对秒看不出请求发生在几点;补墙钟 epoch,前端渲染 HH:MM:SS
                "ts": round(time.time(), 0),
                "model": model, "alias": alias, "status": status,
                "ok": ok, "forced": forced, "failover": failover,
            }
            # 2026-10-20:失败请求记录错误摘要(截断),前端 hover/展开可见 —— 以前 400/401
            # 只显示状态码,真实上游错误信息看不到(prompt is too long 之类只能翻 proxy 日志)。
            if not ok and err_summary:
                entry["err"] = str(err_summary)[:200]
            if latency is not None:
                entry["ms"] = round(latency * 1000)
            # 2026-10-28:流式首 token 延迟(仅流式请求有);与总耗时 ms 并列在日志行里。
            if ttft is not None:
                entry["ttft_ms"] = round(ttft * 1000)
            self._logs.append(entry)
            if len(self._logs) > self.LOG_MAX:
                del self._logs[:-self.LOG_MAX]
        # Feed the 24h latency distribution OUTSIDE this lock (LATENCY has its own lock;
        # never nest locks). Best-effort: telemetry must never break the forward path.
        if latency is not None:
            try:
                LATENCY.add(model, latency, ok, ttft_s=ttft)
            except Exception as e:
                log.warning("latency add failed: %s", e)

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
            # 2026-10-20 ctx 校准:每模型最大成功 input = 真实窗口上界证据(GLM-5.2 这类
            # 报错不带数字时,统计兜底靠它)。维护成本 O(1)。
            if in_tok > m.get("max_in", 0):
                m["max_in"] = in_tok
            if self._logs and self._logs[-1]["alias"] == alias:
                self._logs[-1]["in_tok"] = in_tok
                self._logs[-1]["out_tok"] = out_tok

    def max_input_for(self, model):
        """Largest successful input seen for this model (upper-bound evidence for
        window calibration). 0 when nothing recorded."""
        with self._lock:
            return self._model(model).get("max_in", 0)

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

    def labels(self):
        """Every login label that has recorded usage (keys of the bucket store). Includes
        'direct' (non-gateway traffic) and orphans (a login since removed from the auth
        table) — so the admin usage view can surface traffic the login table forgot."""
        with self._lock:
            return sorted(k for k, m in self._buckets.items() if m)

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
            elif isinstance(login, str):
                src = {bts: dict(v) for bts, v in self._buckets.get(login, {}).items() if bts >= cutoff}
            else:
                # 别名视角: 跨多个 usage 标签(别名 + 对应 key 值)按 bucket 聚合
                src = {}
                for lb in login:
                    for bts, v in self._buckets.get(lb, {}).items():
                        if bts < cutoff:
                            continue
                        m = src.setdefault(bts, {"turns": 0, "inTok": 0, "outTok": 0})
                        m["turns"] += v["turns"]; m["inTok"] += v["inTok"]; m["outTok"] += v["outTok"]
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
            "login": (login[0] if isinstance(login, list) else login) if login is not None else "__all__",
            "buckets": buckets,
            "daily": daily_list,
            "totals": {
                "newTokens": tot_new, "turns": tot_turns,
                "perReqNew": round(tot_new / tot_turns) if tot_turns else 0,
                "days": len(daily_list),
            },
        }


USAGE = UsageSeries()


class LatencySeries:
    """Per-model request-latency distribution over the last 24h, bucketed hourly.

    STATS.record() feeds this whenever a latency is known — BOTH the alias-routed CCR
    path (_route, incl. every failover attempt) and the no-policy passthrough path.
    Exact counters (n / ok / sum_ms) per bucket; a 64-sample reservoir of successful
    latencies (plus streaming TTFT) per (model, hour) so P50/P90/P99 can be answered
    with bounded memory. This proxy sees at most hundreds of req/hour/model, so the
    reservoir stays effectively exact in practice and the worst case is ~300KB.

    Persists to latency.json the same way UsageSeries does (atomic write, 0600,
    throttled flush, load-on-boot with relative prune) so a restart does NOT wipe the
    24h window. Records only — never content."""

    BUCKET_SEC = 3600            # hourly buckets
    WINDOW_SEC = 24 * 3600        # the "24h" the dashboard reports
    PRUNE_GRACE_SEC = 2 * 3600   # keep 2 extra hours so restart gaps don't drop edge data
    SAMPLE_CAP = 64               # reservoir size per (model, hour) bucket
    FLUSH_MIN_SEC = 20

    def __init__(self, file=None):
        self._lock = threading.Lock()
        self._file = file or LATENCY_FILE
        # model -> {hour_bucket_ts -> {"n","ok","sum_ms","samp":[ms...],"i":seen,
        #                              "tsamp":[ttft_ms...],"ti":ttft_seen}}
        self._buckets = {}
        self._last_flush = 0.0
        self._dirty = False

    def _bucket_ts(self, now):
        return int(now // self.BUCKET_SEC) * self.BUCKET_SEC

    @staticmethod
    def _reservoir(bucket, samp_key, seen_key, ms):
        # Algorithm R: fill until cap, then replace a random earlier slot — unbiased
        # estimates even when a bucket outgrows the cap.
        samp = bucket[samp_key]
        seen = bucket[seen_key] + 1
        bucket[seen_key] = seen
        if len(samp) < LatencySeries.SAMPLE_CAP:
            samp.append(ms)
        else:
            j = random.randint(0, seen - 1)
            if j < LatencySeries.SAMPLE_CAP:
                samp[j] = ms

    def add(self, model, latency_s, ok, ttft_s=None, now=None):
        if latency_s is None:
            return
        if now is None:
            now = time.time()
        ms = max(0, round(latency_s * 1000))
        tms = None
        if ttft_s is not None:
            tms = max(0, round(ttft_s * 1000))
        bts = self._bucket_ts(now)
        with self._lock:
            mm = self._buckets.setdefault(model, {})
            b = mm.get(bts)
            if b is None:
                b = {"n": 0, "ok": 0, "sum_ms": 0, "samp": [], "i": 0,
                     "tsamp": [], "ti": 0}
                mm[bts] = b
            b["n"] += 1
            if ok:
                b["ok"] += 1
                b["sum_ms"] += ms
                self._reservoir(b, "samp", "i", ms)
                if tms is not None:
                    self._reservoir(b, "tsamp", "ti", tms)
            self._dirty = True

    def prune(self, now=None):
        if now is None:
            now = time.time()
        cutoff = now - self.WINDOW_SEC - self.PRUNE_GRACE_SEC
        with self._lock:
            for model in list(self._buckets):
                mm = self._buckets[model]
                for bts in list(mm):
                    if bts < cutoff:
                        del mm[bts]
                if not mm:
                    del self._buckets[model]

    @staticmethod
    def _pct(samp, prefix=""):
        if not samp:
            return {}
        samp = sorted(samp)
        n = len(samp)
        def p(pct):
            rank = max(1, min(n, -(-pct * n // 100)))  # nearest-rank, ceil
            return samp[rank - 1]
        return {f"{prefix}p50Ms": p(50), f"{prefix}p90Ms": p(90),
                f"{prefix}p99Ms": p(99), f"{prefix}sampled": n}

    def report(self, now=None):
        """Merge the last 24h of buckets per model -> P50/P90/P99 (reservoir), avg,
        request count, success rate. Failures are counted in n/ok but excluded from
        latency percentiles (they return fast and would skew the tail)."""
        if now is None:
            now = time.time()
        cutoff = now - self.WINDOW_SEC
        rows = []
        with self._lock:
            for model, mm in self._buckets.items():
                n = ok = 0
                total = 0
                samp = []
                tsamp = []
                for bts, b in mm.items():
                    if bts < cutoff:
                        continue
                    n += b["n"]
                    ok += b["ok"]
                    total += b["sum_ms"]
                    samp.extend(b["samp"])
                    tsamp.extend(b["tsamp"])
                if not n:
                    continue
                row = {"model": model, "n": n, "ok": ok,
                       "successRate": round(ok / n, 3)}
                if ok:
                    row["avgMs"] = round(total / ok)
                    row.update(self._pct(samp))
                    if tsamp:
                        row.update(self._pct(tsamp, "ttft"))
                rows.append(row)
        rows.sort(key=lambda r: -r["n"])
        return {"windowH": self.WINDOW_SEC // 3600, "models": rows}

    def snapshot(self):
        with self._lock:
            return {
                "version": 1,
                "bucketSec": self.BUCKET_SEC,
                "buckets": {
                    model: {str(bts): dict(v) for bts, v in mm.items()}
                    for model, mm in self._buckets.items()
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
            os.makedirs(os.path.dirname(self._file), exist_ok=True)
            tmp = self._file + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._file)
        except OSError as e:
            log.warning("latency flush failed: %s", e)
            return  # leave _dirty=True so the next flush retries
        with self._lock:
            self._last_flush = now
            self._dirty = False

    def load(self):
        try:
            with open(self._file) as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return
        if not isinstance(data, dict) or not isinstance(data.get("buckets"), dict):
            return
        restored = {}
        for model, mm in data["buckets"].items():
            if not isinstance(mm, dict):
                continue
            out = {}
            for bts, v in mm.items():
                try:
                    out[int(bts)] = {
                        "n": int(v.get("n", 0)), "ok": int(v.get("ok", 0)),
                        "sum_ms": int(v.get("sum_ms", 0)),
                        "samp": [int(x) for x in v.get("samp", [])],
                        "i": int(v.get("i", 0)),
                        "tsamp": [int(x) for x in v.get("tsamp", [])],
                        "ti": int(v.get("ti", 0)),
                    }
                except (ValueError, TypeError, AttributeError):
                    continue
            if out:
                restored[str(model)] = out
        with self._lock:
            self._buckets = restored
        # Prune relative to the newest restored bucket (same rationale as UsageSeries):
        # data may predate wall-clock after a long downtime; drop only what is older
        # than the series' own latest point.
        newest = max((bts for mm in restored.values() for bts in mm), default=None)
        if newest is not None:
            self.prune(now=newest + self.BUCKET_SEC)


LATENCY = LatencySeries()


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
