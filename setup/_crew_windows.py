#!/usr/bin/env python3
"""crew_proxy.windows — prompt-too-long translation and context-window auto-calibration."""

import json
import logging
import os
import re
import threading
import time

from _crew_config import log, MW_CONF
# STATS is imported lazily inside maybe_calibrate_from_error to avoid
# any potential import-order issues (stats doesn't import windows).

# Mutable config values that callers may monkey-patch at runtime.
_PATCHABLE = frozenset({"MW_CONF"})

def __getattr__(name):
    if name in _PATCHABLE:
        import sys
        mod = sys.modules.get("crew_proxy")
        if mod is not None:
            return getattr(mod, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

# ── upstream error-message translation (2026-10-15) ─────────────────────────────
# Claude Code's auto-compact / reactive-compact recovery keys on the *text* of the
# error message it receives (see its isPromptTooLong classifier):
#   n.includes("prompt is too long") || n.includes("input is too long for requested model")
# The llm-gw GLM gateway instead answers 400 with {"error":{"cause":"...code":"1261",
# "message":"Prompt exceeds max length"...}} — none of the recognized substrings — so
# Claude Code treats it as an ordinary 400, retries, and dies instead of compacting.
# _translate_upstream_error() rewrites such bodies to the exact Anthropic wording so
# the client's recovery kicks in. Translation happens only on non-2xx, JSON,
# non-streaming bodies; every other byte passes through untouched.
_PTL_SOURCE_PATTERNS = (
    "prompt exceeds max length",   # llm-gw GLM code 1261(英文措辞)
    "prompt too long",
    "exceeds the maximum context length",  # OpenAI variant A
    "maximum context length is",   # OpenAI variant B: "This model's maximum context length is N tokens. However, you requested M..."
    "context length exceeded",
    "input is too long",           # generic short form some gateways emit
    # 2026-10-20 实测补(llm-gw 真实措辞,缺这几种时 CC 压缩恢复不触发 → 会话卡死):
    "longer than the model's context length",  # GLM-5.3-Local: "...(1183203 tokens) is longer than the model's context length (1048576 tokens)"
    "exceeded model token limit",             # kimi-k3: "Your request exceeded model token limit: 1048576 (requested: 1254747)"
    "prompt 超长",                              # GLM code 1261 中文措辞(2026-10-20 实测;上游中英会变,两种都收)
)

# 窗口数字抽取正则(按优先级):匹配到即得真实窗口,自动写 model-windows.conf。
# 2026-10-20 实测三种上游格式:
#   GLM-5.3-Local: "longer than the model's context length (1048576 tokens)"
#   kimi-k3:       "exceeded model token limit: 1048576 (requested: 1254747)"
#   OpenAI 兼容:   "maximum context length is 1048576 tokens. However, you requested..."
_PTL_WINDOW_RES = (
    re.compile(r"context length\D{0,20}(\d{6,9})\s*tokens", re.I),
    re.compile(r"token limit\D{0,10}(\d{6,9})", re.I),
    re.compile(r"maximum context length is\s*(\d{6,9})", re.I),
)

def _ptl_hay(body_bytes):
    """Searchable text from an error body: parse JSON, then keep UN-ESCAPING nested
    stringified-JSON layers (CCR wraps provider errors as {"error":{"cause":"{\"error\":
    {...}"}}) until nothing more parses. Each layer's ensure_ascii=False dump is
    concatenated — so both raw unicode (Prompt 超长) and \\uXXXX-escaped inner strings
    are searchable. Returns the combined haystack (lowercased)."""
    texts = []
    seen = set()
    def _add(s):
        if s and s not in seen:
            seen.add(s)
            texts.append(s.lower())
    def _walk(o, depth=0):
        if depth > 4 or not isinstance(o, (str, dict)):
            return
        if isinstance(o, str):
            _add(o)
            s = o.strip()
            if s[:1] in "{[":
                try:
                    _walk(json.loads(s), depth + 1)   # 展开字符串化嵌套 JSON
                except Exception:
                    pass
            return
        for v in o.values():
            _walk(v, depth + 1)
        _add(json.dumps(o, ensure_ascii=False))
    try:
        doc = json.loads(body_bytes)
    except Exception:
        return body_bytes.decode("utf-8", "replace").lower()
    _walk(doc)
    # 原始字节兜底:raw \\uXXXX 转义序列也在(上面 ensure_ascii=False 覆盖不了
    # 内层字符串自带的字面 \\u 转义——那本来就是 ASCII 可见的)
    return " ".join(texts)


def translate_prompt_too_long(body_bytes):
    """If an error body indicates context overflow in non-Anthropic wording, return
    replacement bytes in Anthropic's format; otherwise return None (pass through)."""
    try:
        doc = json.loads(body_bytes)
    except Exception:
        return None
    if not isinstance(doc, dict):
        return None
    # 2026-10-20:多层展开 hay —— CCR cause 字段是字符串化 JSON,其中文(Prompt 超长)
    # 以 \uXXXX 转义出现,单层 dumps 匹配不到(实测 GLM-5.2 中文措辞漏匹配根因)。
    hay = _ptl_hay(body_bytes)
    if not any(p in hay for p in _PTL_SOURCE_PATTERNS):
        return None
    # Anthropic's native envelope. "prompt is too long: X tokens > Y maximum" carries
    # the token counts Claude Code parses for head-truncation; we don't have them from
    # the GLM gateway, so emit the count-less form the classifier also accepts
    # (zSr uses substring matching, lKe's regex just yields undefined — still triggers).
    out = {"type": "error", "error": {"type": "invalid_request_error",
                                      "message": "prompt is too long: input tokens and max_tokens exceed context limit."}}
    return json.dumps(out, ensure_ascii=False).encode()


# ── context-window auto-calibration(2026-10-20)────────────────────────────────
# 用户洞察:报错那一刻上游就会告诉我们真实窗口 —— "context length (1048576 tokens)"。
# 校准器在 translate 命中(prompt-too-long)时从错误 body 抽窗口数字,写进
# model-windows.conf;launcher 下次起会话就带上真实窗口,压缩不再贴错线。
# 抽不到数字的(GLM-5.2 code 1261 "Prompt 超长"不带数)→ 用 proxy 自己的成功请求
# 统计夹逼:最近成功 max input 是上界,被拒请求估算 tokens 是下界,取保守下界。
# 只在数值变化时写(幂等);线程安全(模块锁);异常静默(校准失败不影响转发)。
_CALIB_LOCK = threading.Lock()
# MW_CONF is resolved lazily from the crew_proxy facade (monkey-patchable).


def _mw_conf_pattern(model):
    """Short lowercase key for a model in model-windows.conf: strip provider prefix
    and variant suffixes ('prov/GLM-5.3-Local-joybuilder' -> 'glm-5.3').
    Family+version stays intact — 'glm-5.3' not 'glm' — so windows differ per
    version (5.2=200k, 5.3=1M) as measured."""
    m = (model or "").split("/")[-1].lower()
    # 后缀词库:部署变体/渠道标记,剥掉后剩 family+version
    suffixes = ("joybuilder", "personal", "local", "newkey", "prod", "flash", "pro")
    parts = m.split("-")
    # 从右往左剥已知后缀段,遇到非后缀词停
    while len(parts) > 1 and parts[-1] in suffixes:
        parts.pop()
    fam = "-".join(parts)
    return fam or m

def extract_window_from_error(body_bytes):
    """Pull the real context window out of an overflow error body. Returns int or None.
    Uses the same multi-layer haystack as translate (numbers can hide inside the
    stringified-JSON cause layer)."""
    if not body_bytes:
        return None
    hay = _ptl_hay(body_bytes)
    for rx in _PTL_WINDOW_RES:
        m = rx.search(hay)
        if m:
            v = int(m.group(1))
            if 50000 <= v <= 20000000:   # 合理窗口域:50k..20M
                return v
    return None

def calibrate_model_window(model, window, source="upstream-error"):
    """Write/refresh one model line in model-windows.conf. Idempotent, thread-safe.
    Returns True when the file changed.

    消费方(launcher/statusline)按「模型名包含 key」首条命中,所以这里必须改写
    *会被该模型命中的现有行*(如 conf 有 kimi=200k,校准 kimi-k3 时改 kimi 行),
    而不是追加 kimi-k3= 行(追加后 kimi= 在前永远先命中,校准白写)。
    精确 key 相等则改;现有行是完整模型名的子串(即会被命中)则改它;都不匹配才追加。"""
    if not model or not window:
        return False
    m = (model or "").split("/")[-1].lower()
    if not m:
        return False
    with _CALIB_LOCK:
        try:
            lines = []
            if os.path.isfile(MW_CONF):
                with open(MW_CONF, encoding="utf-8") as f:
                    lines = f.read().splitlines()
            # 1) 找目标行:精确 == key,或 key 包含现有行(现有行是模型名的子串 →
            #    消费方包含匹配会命中它)。取最长的命中行(最具体)。
            best_idx, best_len = -1, -1
            for i, ln in enumerate(lines):
                s = ln.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k = s.split("=", 1)[0].strip()
                if k and (k == _mw_conf_pattern(model) or k in m) and len(k) > best_len:
                    best_idx, best_len = i, len(k)
            stamp = f"   # auto-calibrated {time.strftime('%Y-%m-%d')} ({source})"
            if best_idx >= 0:
                cur_val = lines[best_idx].split("=", 1)[1].split("#")[0].strip()
                try:
                    if int(cur_val) == window:
                        return False    # 已一致,不写
                except ValueError:
                    pass
                key = lines[best_idx].split("=", 1)[0].strip()
                lines[best_idx] = f"{key}={window}{stamp}"
            else:
                lines.append(f"{_mw_conf_pattern(model)}={window}{stamp}")
            tmp = MW_CONF + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            os.replace(tmp, MW_CONF)
            log.info("[ctx-calibrate] %s -> %d tokens (%s) 写入 %s", m, window, source, MW_CONF)
            return True
        except Exception as e:
            log.warning("[ctx-calibrate] 写 %s 失败: %s", MW_CONF, e)
            return False

def estimate_input_tokens(body_bytes):
    """Rough input-token estimate from a request body: total message text length / 3
    (mixed zh/en heuristic; +tools/system overhead folded into the divisor). Used ONLY
    as the lower-bound evidence in window calibration when the upstream error carries
    no numbers (GLM-5.2 code 1261). Never on the hot path."""
    try:
        doc = json.loads(body_bytes or b"")
        msgs = doc.get("messages") or []
        n = sum(len(str(m.get("content", ""))) for m in msgs if isinstance(m, dict))
        n += len(str(doc.get("system") or ""))
        return int(n / 3)
    except Exception:
        return 0


def maybe_calibrate_from_error(model, body_bytes, req_body=None):
    """Called on a translated prompt-too-long error. Upstream-provided number wins;
    otherwise fall back to our own evidence (user insight: proxy knows what worked):
    - max successful input for this model (stats) U: proven < real window W -> a LOWER
      bound on W (requests up to U are known to succeed)
    - rejected request's estimated tokens R: proven > real window W -> an UPPER bound
      on W (requests of size R fail)
    Safe configured window = U + small margin. The rejected estimate R is NOT a lower
    bound on W — it sits ABOVE W, so writing floor(R) risks W' > W, which deadlocks
    the session (the exact bug we're fixing). Only when we have NO successful-request
    evidence (U=0, e.g. a brand-new model's first-ever overflow) do we fall back to
    floor(R, 10k) as a rough guess."""
    w = extract_window_from_error(body_bytes)
    if w:
        calibrate_model_window(model, w, "upstream-error")
        return
    lower = estimate_input_tokens(req_body)
    from _crew_stats import STATS  # lazy import: avoid circular at module load
    upper = STATS.max_input_for(model) if STATS else 0
    if upper and upper > 50000:
        # Proven-safe max + 10% margin: W' = 1.1*U < W (U<W, margin small). Never
        # exceeds the real window, so compaction fires before upstream rejection.
        calibrate_model_window(model, (upper * 11) // 10, f"stats-upper={upper}")
    elif lower > 50000:
        v = (lower // 10000) * 10000        # 向下取 10k 档,保守(无成功上界时的粗估)
        src = f"stats-fallback rejected_est≈{lower} upper={upper}"
        calibrate_model_window(model, v, src)

