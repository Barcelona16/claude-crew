#!/usr/bin/env python3
"""crew_proxy.config — config constants, loaders, and helpers.

Zero third-party deps (stdlib only).
"""

import json
import logging
import os
import re
import shutil
import subprocess
import sys

# Mutable config values that callers may monkey-patch at runtime (e.g. tests set
# crew_proxy.CREW_BIN). Resolve them lazily from the facade module.
_PATCHABLE = frozenset({"CREW_BIN"})

def __getattr__(name):
    if name in _PATCHABLE:
        import sys as _sys
        mod = _sys.modules.get("crew_proxy")
        if mod is not None:
            return getattr(mod, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


# ── config ──────────────────────────────────────────────────────────────────────
def _cfg_dir():
    return os.environ.get("CREW_CONFIG_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "claude-crew"
    )

CFG_DIR   = _cfg_dir()
KEYS_FILE = os.path.join(CFG_DIR, "keys.conf")
POLICY    = os.path.join(CFG_DIR, "key-policy.conf")
USAGE_FILE = os.path.join(CFG_DIR, "usage.json")
GATEWAY_AUTH = os.environ.get("GATEWAY_AUTH") or os.path.join(CFG_DIR, "gateway-auth.json")
CCR_CFG   = os.environ.get("CREW_CCR_CONFIG") or os.path.join(CFG_DIR, "ccr-providers.json")
CCR_URL   = (os.environ.get("CREW_CCR_URL") or "http://127.0.0.1:3456").rstrip("/")
CCR_V3_ADAPTER = os.environ.get("CREW_CCR_V3_ADAPTER") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "ccr_v3.py"
)
PORT      = int(os.environ.get("CREW_PROXY_PORT", "8788"))
FAIL_N    = int(os.environ.get("CREW_PROXY_FAILS", "3"))
COOLDOWN  = float(os.environ.get("CREW_PROXY_COOLDOWN", "60"))
STATE_FILE = os.environ.get("CREW_PROXY_STATE") or os.path.expanduser(
    "~/.local/share/claude-crew/proxy-state.json"
)
FAIL_CODES = {401, 403, 429}  # plus any 5xx and connection errors (see _is_fail)

# model-windows.conf path (used by windows.calibrate_model_window; monkey-patchable)
MW_CONF = os.path.join(os.environ.get("CREW_CONFIG_DIR")
                       or os.path.expanduser("~/.config/claude-crew"),
                       "model-windows.conf")


# _passthrough 退避重试(2026-09-01):单 key 会话遇 429/5xx/连接错时,proxy 自己退避重发同一
# 请求(不换模型/不换 key——纯"等几秒重试"),吸收瞬时波动,claude 侧少报 API error。全 env 可调。
PT_MAX_RETRY   = int(os.environ.get("CREW_PROXY_MAX_RETRY", "2"))       # 额外重试次数(最多打 1+N 次)
PT_RETRY_BASE  = float(os.environ.get("CREW_PROXY_RETRY_BASE", "1.0"))  # 指数退避基数秒
PT_RETRY_MAX   = float(os.environ.get("CREW_PROXY_RETRY_MAX", "8.0"))   # 单次退避上限秒
PT_RETRY_BUDGET= float(os.environ.get("CREW_PROXY_RETRY_BUDGET", "20.0"))  # 总退避预算秒(超了停)

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
    """Crew's CCR 3 provider map -> list of {name, models[], api_key}."""
    try:
        with open(CCR_CFG) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    return cfg.get("Providers") or cfg.get("providers") or []


def load_ccr_gateway_key():
    """Return crew's private CCR 3 loopback gateway key, if configured.

    Claude Code talks to crew-proxy using the harmless session token ``test``.
    CCR 3 instead authenticates every gateway request against APIKEYS, which is
    managed by :mod:`ccr_v3`.  Never pass Claude's token through to CCR: it is
    not an upstream provider credential and it is not a CCR gateway key.
    """
    try:
        with open(CCR_CFG) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return ""
    gateway = cfg.get("gateway")
    if isinstance(gateway, dict):
        value = gateway.get("api_key") or gateway.get("apiKey")
        if isinstance(value, str) and value.strip():
            return value.strip()
    value = cfg.get("APIKEY")
    return value.strip() if isinstance(value, str) else ""


COOLDOWN_FILE = os.path.join(CFG_DIR, "cooldown.conf")


def load_cooldown():
    """cooldown.conf -> {daily_quota, transient, retryafter_max} in seconds.

    Optional file; absent -> {} and callers fall back to the single COOLDOWN constant
    (so behavior is byte-identical to before this feature — the default-harmless rule)."""
    out = {}
    try:
        with open(COOLDOWN_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                try:
                    out[k.strip()] = float(v.strip())
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return out


def cooldown_for(code, retry_after):
    """Pick a cooldown duration (seconds) for a failure, per cooldown.conf.

    - No cooldown.conf at all -> fall back to the single COOLDOWN constant (harmless default).
    - 429 with a Retry-After <= retryafter_max -> use that Retry-After verbatim (upstream knows best).
    - 429 with a large/absent Retry-After -> daily_quota (quota exhausted, park for a day).
    - anything else (401/403/5xx/conn error) -> transient (short cooldown).
    """
    conf = load_cooldown()
    if not conf:
        return COOLDOWN
    transient = conf.get("transient", COOLDOWN)
    if code == 429:
        ra_max = conf.get("retryafter_max", 300.0)
        if retry_after is not None and retry_after <= ra_max:
            return retry_after
        return conf.get("daily_quota", 86400.0)
    return transient


def parse_retry_after(headers):
    """Extract Retry-After seconds from response headers; None if absent/unparseable.
    Only the delta-seconds form is honored (HTTP-date form is rare here and ignored)."""
    if headers is None:
        return None
    raw = headers.get("Retry-After") or headers.get("retry-after")
    if raw is None:
        return None
    try:
        return float(str(raw).strip())
    except (ValueError, TypeError):
        return None


def load_gateway_auth():
    """gateway-auth.json -> {login_key: {maps_to, allow_models, erp, admin}}. Empty dict if absent
    (the dashboard's login-table section then just shows nothing — harmless default)."""
    try:
        with open(GATEWAY_AUTH) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for k, v in data.items():
        if k.startswith("__") or not isinstance(v, dict):
            continue  # __doc__ etc. are comments, not login entries
        out[k] = {"maps_to": str(v.get("maps_to", "")),
                  "allow_models": list(v.get("allow_models") or []),
                  "erp": str(v.get("erp", "")),
                  "admin": bool(v.get("admin"))}
    return out


def sync_ccr_config():
    """Apply the provider map through CCR 3's authenticated management RPC.

    The adapter performs an atomic CCR configuration save and restarts its
    gateway when needed. It deliberately never edits CCR's SQLite file.
    """
    if not os.path.isfile(CCR_V3_ADAPTER):
        log.error("CCR 3 adapter is missing: %s", CCR_V3_ADAPTER)
        return False
    try:
        r = subprocess.run([sys.executable, CCR_V3_ADAPTER, "apply", "--provider-map", CCR_CFG],
                           timeout=30,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if r.returncode:
            log.error("CCR 3 provider-map apply failed (rc=%s): %s", r.returncode,
                      r.stdout.decode("utf-8", "replace").strip())
            return False
        log.info("CCR 3 provider-map applied")
        return True
    except Exception as e:
        log.error("CCR 3 provider-map apply failed: %s", e)
        return False


def mask_key(key):
    """Show only enough of a real API key to recognize it, never the secret itself:
    'sk-…3f9a' (last 4). Empty/short keys collapse to '…'. Used everywhere a key would
    otherwise surface in an API response or the dashboard."""
    if not key:
        return "…"
    tail = key[-4:] if len(key) >= 4 else key
    return "sk-…" + tail


def provider_for(realmodel, api_key, providers):
    """Find the CCR provider serving `realmodel` with `api_key` (mirrors crew's ccr_provider_for)."""
    for p in providers:
        if realmodel in (p.get("models") or []) and (p.get("api_key") or p.get("apiKey")) == api_key:
            return p.get("name")
    return None


# ── crew CLI bridge (crew is the single state-mutation entry point) ───────────────
CREW_STATE = os.environ.get("CREW_STATE") or os.path.expanduser("~/.local/share/claude-crew")
# 2026-10-20 修:launchd 起 proxy 时 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin,shutil.which
# 落空 → 兜底裸名 "crew" → FileNotFoundError → dashboard Sessions 表永远空
# ("crew exec failed: No such file or directory: 'crew'")。加显式路径探测兜底:
# which > ~/.local/bin/crew(install.sh 装的默认位)> repo bin/crew > 裸名(最终报错)。
def _find_crew_bin():
    found = shutil.which("crew")
    if found:
        return found
    for cand in (os.path.expanduser("~/.local/bin/crew"),
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "crew")):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return "crew"
# CREW_BIN is computed in the facade module (monkey-patchable at runtime).
# Resolved lazily via __getattr__ below.
# Names/aliases/models we will ever pass to a subprocess or write as a filename. Strict
# allowlist — anything with a shell metacharacter or path separator is rejected outright.
SAFE_NAME = re.compile(r"^[A-Za-z0-9._,-]+$")


def _crew_bin():
    """Resolve the crew CLI path. Bare `CREW_BIN` as a LOAD_GLOBAL inside a function does
    NOT trigger PEP 562 module __getattr__ (that hook only fires on module.attr / from-
    import), so we resolve it explicitly through the facade proxy registered in sys.modules.
    Falls back to _find_crew_bin() if the facade isn't reachable."""
    mod = sys.modules.get("crew_proxy") or sys.modules.get("__main__")
    bin_ = getattr(mod, "CREW_BIN", None) if mod is not None else None
    return bin_ or _find_crew_bin()


def run_crew(args, timeout=10):
    """Exec `crew <args...>` with shell=False (never string-built). Returns (stdout, err|None)."""
    try:
        p = subprocess.run([_crew_bin(), *args], capture_output=True, text=True,
                           timeout=timeout, shell=False)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        return None, f"crew exec failed: {e}"
    if p.returncode != 0:
        return None, (p.stderr or p.stdout or f"crew exited {p.returncode}").strip()
    return p.stdout, None


def _http_err_summary(e, limit=200):
    """Best-effort error-message summary from an urllib HTTPError for the dashboard log
    (2026-10-20). Reads the body without consuming it for the relay path — e.read() on an
    HTTPError can only be done once, so we peek via a copy; on any failure falls back to
    the exception string. Used ONLY for display, never for control flow."""
    try:
        raw = e.read()
        e.read = lambda: raw  # put it back for the later _relay(e)
        txt = raw.decode("utf-8", "replace")
        try:
            j = json.loads(txt)
            for k in ("message", "error", "error.message"):
                v = j.get(k) if isinstance(j, dict) else None
                if not v and isinstance(j.get("error"), dict):
                    v = j["error"].get("message")
                if v:
                    return f"HTTP {e.code}: {str(v)[:limit]}"
            return f"HTTP {e.code}: {txt[:limit]}"
        except (json.JSONDecodeError, AttributeError, TypeError):
            return f"HTTP {e.code}: {txt[:limit]}"
    except Exception:
        return f"HTTP {getattr(e, 'code', '?')}: {str(e)[:limit]}"


def _read_state_field(name, field):
    """Read one <name>.<field> state file under CREW_STATE. Returns '' when absent."""
    # SAFE_NAME 校验防路径穿越(name 来自 crew ls --json / dashboard 输入,不信任)。
    if not SAFE_NAME.match(name or ""):
        return ""
    try:
        with open(os.path.join(CREW_STATE, f"{name}.{field}"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def _api_sessions_fallback():
    """crew CLI 不可用时,直接读 state 目录组装 sessions(降级只读视图)。
    2026-10-20 修:dashboard Sessions 表以前 crew 一挂就整表消失;现在降级展示
    name/backend/key/dir(state 文件在就在),tmux/status 标 unknown。"""
    sessions = []
    try:
        for fn in os.listdir(CREW_STATE):
            if not fn.endswith(".backend"):
                continue
            name = fn[:-len(".backend")]
            sessions.append({
                "name": name,
                "backend": _read_state_field(name, "backend") or "?",
                "key": _read_state_field(name, "key") or "?",
                "dir": _read_state_field(name, "dir") or "-",
                "sid": _read_state_field(name, "sid") or "",
                "tmux": None, "status": "unknown (crew CLI 不可用,降级读 state)",
            })
    except OSError:
        pass
    return {"sessions": sessions, "degraded": True}
