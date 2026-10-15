#!/usr/bin/env python3
"""Tests for translate_prompt_too_long + _relay error translation (2026-10-15).

Claude Code's auto-compact keys on the literal substring "prompt is too long"
(case-insensitive) in the error message it receives; the llm-gw GLM gateway
answers context overflow with code 1261 "Prompt exceeds max length", which does
NOT match, so sessions die instead of compacting. crew-proxy._relay rewrites
recognized non-Anthropic overflow errors into Anthropic's envelope. These tests
pin that behavior, including the exact strings observed in production logs
(ccr-20261015111921.log, req-7d/7e/7f) and the passthrough guarantees.

Run:  python3 -m pytest test/crew_proxy_ptl.py  (or: python3 test/crew_proxy_ptl.py)
"""

import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "setup"))

import crew_proxy  # noqa: E402  (module-level: safe, main() is __main__-guarded)

T = crew_proxy.translate_prompt_too_long

# Exact error observed in production: llm-gw GLM code 1261 wrapped by CCR.
GLM_1261 = {
    "error": {
        "cause": '{"error":{"code":"1261","message":"Prompt exceeds max length"}}',
        "code": 400,
        "message": "模型服务调用失败",
        "status": "FAILED_RESPONSE",
    },
    "requestId": "17920666198873cea696d8270407c95c0988c8a16f94f",
    "result": None,
}

# CCR's wrapper form ("Error from provider(...)") — what the client actually sees.
CCR_WRAPPED = {
    "type": "error",
    "error": {
        "type": "Error from provider(GLM-5.3: 400)",
        "message": "Error from provider(GLM-5.3: 400): " + json.dumps(GLM_1261, ensure_ascii=False),
    },
}


def zsr(text):
    """Claude Code's isPromptTooLong classifier (substring, case-insensitive)."""
    n = text.lower()
    return "prompt is too long" in n or "input is too long for requested model" in n


def test_glm_1261_translated():
    out = T(json.dumps(GLM_1261).encode())
    assert out is not None
    assert zsr(json.loads(out)["error"]["message"])


def test_ccr_wrapped_translated():
    out = T(json.dumps(CCR_WRAPPED).encode())
    assert out is not None
    assert zsr(json.loads(out)["error"]["message"])


def test_openai_context_length():
    oai = {"error": {"message": "This model's maximum context length is 131072 tokens. "
                                "However, you requested 200000 tokens. Please reduce the length of the messages.",
                     "code": "context_length_exceeded"}}
    out = T(json.dumps(oai).encode())
    assert out is not None
    assert zsr(json.loads(out)["error"]["message"])


def test_normal_400_passthrough():
    body = json.dumps({"error": {"message": "messages.0.content: field required"}}).encode()
    assert T(body) is None


def test_auth_error_passthrough():
    body = json.dumps({"error": {"message": "invalid api key"}}).encode()
    assert T(body) is None


def test_non_json_passthrough():
    assert T(b"<html>Gateway Timeout</html>") is None
    assert T(b"") is None


def test_non_object_json_passthrough():
    assert T(b'["prompt too long"]') is None


# ── _relay integration (headers + body rewrite) ─────────────────────────────────

class _FakeResp:
    def __init__(self, payload, status=400):
        self._payload = payload
        self.status = status
        self.headers = {"Content-Type": "application/json", "X-Upstream-Header": "keep-me",
                        "Transfer-Encoding": "chunked", "Connection": "keep-alive",
                        "Content-Length": "999"}
        self._done = False

    def read(self, n=-1):
        if self._done:
            return b""
        self._done = True
        return self._payload


class _FakeSelf:
    def __init__(self):
        self.sent = []
        self.code = None
        self.wfile = _W()

    def send_response(self, code):
        self.code = code

    def send_header(self, k, v):
        self.sent.append((k, v))

    def end_headers(self):
        pass


class _W(io.RawIOBase):
    def __init__(self):
        self.body = b""

    def write(self, data):
        self.body += data
        return len(data)

    def flush(self):
        pass


def _relay(payload, status=400):
    fs = _FakeSelf()
    crew_proxy.Handler._relay(fs, _FakeResp(payload, status), streaming=False)
    return fs


def test_relay_rewrites_glm_error():
    fs = _relay(json.dumps(GLM_1261).encode())
    doc = json.loads(fs.wfile.body)
    assert zsr(doc["error"]["message"])
    hdrs = dict(fs.sent)
    assert hdrs["Content-Length"] == str(len(fs.wfile.body))  # CL matches NEW body
    assert ("X-Upstream-Header", "keep-me") in fs.sent         # custom header kept
    lower = [k.lower() for k, _ in fs.sent]
    assert "transfer-encoding" not in lower                    # hop-by-hop stripped
    assert lower.count("content-length") == 1
    assert lower.count("content-type") == 1


def test_relay_normal_error_untouched():
    body = json.dumps({"error": {"message": "some other 400"}}).encode()
    fs = _relay(body)
    assert b"some other 400" in fs.wfile.body


def test_relay_success_body_untouched():
    fs = _relay(json.dumps(GLM_1261).encode(), status=200)
    assert b"1261" in fs.wfile.body  # 200 never enters the translation branch


def test_relay_404_untouched():
    body = json.dumps({"error": {"message": "model not found"}}).encode()
    fs = _relay(body, status=404)
    assert b"model not found" in fs.wfile.body


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ✓ {name}")
            except AssertionError as e:
                failures += 1
                print(f"  ✗ {name}: {e}")
    print("OK" if not failures else f"{failures} FAILED")
    sys.exit(1 if failures else 0)
