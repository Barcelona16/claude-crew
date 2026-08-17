# Per-key token usage: self-service login + time-series line chart

Date: 2026-08-17
Status: design (approved for implementation)

## Goal

A contributor points their client at the gateway and burns tokens. They want to
open a page, log in **with their own key**, and see **their own** token
consumption over time — rendered as a jimdb-chaos-style pure-canvas line chart
(no external charting library).

This is additive to the crew-gateway work already deployed on `11.91.165.248`.
It changes only crew-proxy (mainline, default-harmless) plus one forwarded header
in the gateway.

## Why the current code can't do this

`Stats` (setup/crew_proxy.py) is **in-memory cumulative**:
- per-key counters are keyed by **real alias** (`maps_to`), not the login key —
  so `jimdbtest` and `personal` (both `maps_to: personal`) are indistinguishable.
- there is **no time dimension** — a line chart needs buckets over time.
- everything is **lost on restart** — a container update wipes history.

## Design decisions (confirmed)

1. **Usage dimension: by login-key.** Each login entry (real key OR ticket) gets
   its own series. `jimdbtest` and `personal` are separate lines even though both
   `maps_to: personal`. The gateway already knows the login key at forward time.
2. **Persistence: JSON on disk in `CFG_DIR`.** Buckets are flushed (throttled,
   atomic replace) to `CFG_DIR/usage.json` and read back on boot. Restart-safe,
   backup-able, human-inspectable. 7-day / 10-min buckets ≈ a few hundred KB.

## Components

### A. `UsageSeries` (new, in crew_proxy.py)

A small, self-contained, thread-safe accumulator. One instance, module-global
like `STATS`.

- **Bucket key:** `(login, floor(now / BUCKET_SEC) * BUCKET_SEC)`.
  `BUCKET_SEC = 600` (10 min). `WINDOW_DAYS = 7`.
- **Per bucket, per login:** `{turns, inTok, outTok}`. `newTokens = inTok + outTok`.
- **add(login, in_tok, out_tok):** bump the current bucket for that login; mark
  dirty. Called from `record_usage`.
- **prune():** drop buckets older than `now - WINDOW_DAYS*86400`. Run on load and
  opportunistically on flush.
- **flush():** if dirty and ≥ `FLUSH_MIN_SEC` (e.g. 20 s) since last flush, write
  `CFG_DIR/usage.json` via temp-file + `os.replace` (atomic), `0600`. A background
  daemon thread ticks every `FLUSH_MIN_SEC`; also flush on process exit
  (`atexit`). Throttled so the hot path never blocks on disk.
- **load():** on startup, read `usage.json` if present, prune, restore buckets.
  Missing/garbled file → empty (default-harmless).
- **series(login, days):** build the jimdb-chaos data contract for one login
  (see §D). `login=None` (admin "all") sums across every login.

On-disk shape (`usage.json`):
```json
{
  "version": 1,
  "bucketSec": 600,
  "buckets": { "<login>": { "<epochSec>": {"turns":N,"inTok":N,"outTok":N} } }
}
```

### B. Wiring the login through the record path

- **gateway.py**: when forwarding, add header `X-Crew-Login: <login-key>`
  (the matched client key). Default-harmless: crew-proxy that never receives it
  falls back to the real alias, so behavior is byte-identical without the gateway.
- **crew_proxy.py `_relay` / `record_usage`**: thread a `login` value (read from
  `X-Crew-Login`, default = alias) into `record_usage`, which additionally calls
  `USAGE.add(login, in_tok, out_tok)`. `Stats` per-key/per-model accounting is
  UNCHANGED — this is a parallel, additive series.

### C. Auth for the self-service view

Reuse the existing login-key table (`gateway-auth.json`). No new credential store,
no cookies/sessions.

- New optional field per login entry: `"admin": true` (default absent = normal
  user). `personal` will be marked admin.
- **`GET /api/usage?days=7[&key=<login>]`**: read the caller key from `x-api-key`
  or `Authorization: Bearer`.
  - key not in auth table → **401**.
  - normal user → series for **their own** login only; `key=` param ignored.
  - admin → may pass `key=<otherLogin>` to view anyone, or `key=__all__` for the
    summed all-logins series; default = their own.
- Endpoint is **read-only** and additive: no key → 401, so existing unauthenticated
  behavior is untouched.

### D. Data contract returned by `/api/usage` (matches jimdb-chaos)

```json
{
  "generatedAt": <ms>,
  "bucketMin": 10,
  "windowH": 168,
  "login": "<who>",
  "buckets": [ {"t": <ms>, "newTokens": N, "inputSum": N, "outputSum": N, "turns": N,
                "perReqNew": N} ],
  "daily":   [ {"day": "YYYY-MM-DD", "newTokens": N, "turns": N, "perReqNew": N} ],
  "totals":  {"newTokens": N, "turns": N, "perReqNew": N, "days": N}
}
```
No `ctxWatermark`/`alerts`/`cleans` — those are Claude-session concepts absent
here. The chart is therefore **single-axis** with two lines: `inputSum` and
`outputSum` (plus `newTokens` as the emphasized line), instead of the dual-axis
watermark/newTokens split.

### E. The `/usage` page (new, self-contained)

A second self-contained HTML page served by crew-proxy at `GET /usage` (the
existing `/dashboard` is the ops overview and stays as-is). Vanilla JS, no build.

- **Login bar:** a key input + "登录" button. On submit, store key in
  `sessionStorage` and fetch `/api/usage`. 401 → show "key 无效". Admin sees an
  extra login-picker dropdown (populated from the response) to switch whose series
  they view.
- **Render (jimdb-chaos style, ported inline):**
  - totals cards (新增消耗 / 请求数 / 单次均 token / 天数),
  - per-day bars (`daily[]`, height normalized to max),
  - **pure-canvas line chart** ported from `monitor.js drawTokenChart`: grid
    `#20252e`, dark theme, time axis (`fmtClock`), lines for in/out/new, nearest-
    bucket hover tooltip.
- Auto-refresh every ~30 s while logged in.

## Non-goals / YAGNI

- No cross-restart request-log persistence (only the usage series persists).
- No cookies, JWT, or server-side sessions — the key IS the credential, held in
  `sessionStorage` client-side.
- No per-model breakdown in the chart (totals only); can add later if asked.
- Gateway itself renders nothing — it only forwards `X-Crew-Login`.

## Testing

Extend `setup/test_crew_proxy.py`:
- `UsageSeries.add` buckets by login and by 10-min window; `newTokens = in+out`.
- `prune()` drops buckets older than the window.
- flush → load round-trips (write temp file, reload, series identical); garbled
  file loads as empty (default-harmless).
- `/api/usage`: 401 for unknown key; normal user sees only own login; admin can
  read another login and `__all__`; `days` clamps the window.
- default-harmless: crew-proxy with no `X-Crew-Login` header attributes usage to
  the alias exactly as before (no gateway regression).

Extend `crew-gateway/test_gateway.py`:
- forwarded request carries `X-Crew-Login: <matched login key>`.

## Files touched

- `setup/crew_proxy.py` — `UsageSeries`, `record_usage(login=...)`, `/api/usage`,
  `/usage` page, flush thread + `atexit`, load on boot.
- `setup/test_crew_proxy.py` — new tests above.
- `crew-gateway/gateway.py` — add `X-Crew-Login` forward header.
- `crew-gateway/test_gateway.py` — assert the header.
- `setup/gateway-auth.json.example` — add `"admin": true` to `personal`.
```
