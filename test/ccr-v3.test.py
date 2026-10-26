#!/usr/bin/env python3
"""Unit tests for CCR 3 provider-map/RPC adaptation."""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = Path(__file__).resolve().parent
MODULE = HERE.parent / "setup" / "ccr_v3.py"
spec = importlib.util.spec_from_file_location("ccr_v3", MODULE)
ccr_v3 = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(ccr_v3)


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print(f"ok - {name}")


with tempfile.TemporaryDirectory(prefix="crew-ccr-v3-test-") as tmp:
    root = Path(tmp)
    provider_map = root / "providers.json"
    provider_map.write_text(json.dumps({
        "gateway": {"api_key": "crew-test-key"},
        "Providers": [{
            "name": "key-01-openai",
            "api_base_url": "http://gateway/v1/chat/completions",
            "api_key": "UPSTREAM_KEY",
            "models": ["GLM-5.3"],
            "transformer": {"use": ["OpenAI"]},
        }],
    }), encoding="utf-8")

    old_port = os.environ.get("CREW_CCR_PORT")
    os.environ["CREW_CCR_PORT"] = "3456"
    loaded = ccr_v3.read_provider_map(provider_map)
    merged = ccr_v3.merge_config({"APIKEY": "old", "gateway": {"corePort": 3457}}, loaded)
    check("providers are replaced from the crew map", merged["Providers"] == loaded["Providers"])
    check("known local gateway key is used", merged["APIKEY"] == "crew-test-key")
    check("gateway endpoint remains model port", merged["routerEndpoint"] == "http://127.0.0.1:3456")
    check("existing core gateway configuration is retained", merged["gateway"]["corePort"] == 3457)
    # 2026-10-16 二次 401 防复发:apply 必须关掉 CCR 原生 claudeCode 集成
    # (profile.claudeCode.enabled=true 时 saveConfig 会把 ~/.claude/settings.json 写回
    #  :3456 直连 + apiKeyHelper → 非 crew 起的会话全 401)。三层全关:
    #   profile.enabled / profile.claudeCode.enabled / profile.profiles[] 里 agent=claude-code
    check("merge disables profile.enabled", merged.get("profile", {}).get("enabled") is False)
    check("merge disables profile.claudeCode", merged.get("profile", {}).get("claudeCode", {}).get("enabled") is False)
    check("merge disables claude-code profile entries", all(
        e.get("enabled") is False
        for e in merged.get("profile", {}).get("profiles", [])
        if e.get("agent") == "claude-code"
    ))
    if old_port is None:
        os.environ.pop("CREW_CCR_PORT", None)
    else:
        os.environ["CREW_CCR_PORT"] = old_port

    calls = []

    class RpcHandler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            calls.append((self.headers.get("x-ccr-web-auth"), json.loads(self.rfile.read(length))))
            if calls[-1][1]["method"] == "getConfig":
                payload = {"ok": True, "value": {
                    "gateway": {"corePort": 3457},
                    "customField": "must-survive",
                }}
            else:
                payload = {"ok": True, "value": {}}
            data = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), RpcHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    old_env = {name: os.environ.get(name) for name in ("CREW_CCR_WEB_URL", "CREW_CCR_WEB_TOKEN", "CREW_CCR_PORT")}
    os.environ["CREW_CCR_WEB_URL"] = f"http://127.0.0.1:{server.server_address[1]}"
    os.environ["CREW_CCR_WEB_TOKEN"] = "test-web-token"
    os.environ["CREW_CCR_PORT"] = "3456"
    try:
        ccr_v3.command_apply(provider_map)
    finally:
        server.shutdown()
        for name, value in old_env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    check("apply reads CCR configuration first", calls[0][1]["method"] == "getConfig")
    check("apply authenticates CCR RPC", calls[0][0] == "test-web-token")
    check("apply saves the CCR client key through its dedicated API", calls[1][1]["method"] == "saveApiKeys")
    saved_keys = calls[1][1]["args"][0]
    check("dedicated API receives crew's loopback key", any(
        entry.get("id") == "claude-crew-provider-map" and entry.get("key") == "crew-test-key"
        for entry in saved_keys
    ))
    check("apply saves merged configuration", calls[2][1]["method"] == "saveConfig")
    saved = calls[2][1]["args"][0]
    check("saved configuration carries providers", saved["Providers"][0]["name"] == "key-01-openai")
    check("saveApiKeys ACK cannot discard existing CCR settings", saved["customField"] == "must-survive")

# ---- drift: provider map vs live CCR config divergence check (2026-10-16 401 incident) ----
# 事故根因之一:provider map 的 gateway.api_key 被手改但没重跑 apply,CCR 3 live
# 配置仍持旧 key → crew-proxy 转发必 401。drift 子命令把「map vs live」的分叉
# 显式暴露出来(只报告,不自动改 —— 改 key 必须人工 apply,CLAUDE.md §3 硬约束)。
import contextlib

class _Cap:
    """Capture writes into a list (stdout/stderr redirection for drift tests)."""
    def __init__(self, sink):
        self.sink = sink
    def write(self, s):
        self.sink.append(s)

def _drift_server(responses):
    """Fake CCR RPC server. responses: {method: value}. Returns (server, calls)."""
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length))
            calls.append((self.headers.get("x-ccr-web-auth"), req))
            payload = {"ok": True, "value": responses.get(req["method"], {})}
            data = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, calls

@contextlib.contextmanager
def _drift_env(url):
    old_env = {name: os.environ.get(name) for name in ("CREW_CCR_WEB_URL", "CREW_CCR_WEB_TOKEN")}
    os.environ["CREW_CCR_WEB_URL"] = url
    os.environ["CREW_CCR_WEB_TOKEN"] = "test-web-token"
    try:
        yield
    finally:
        server.shutdown()
        for name, value in old_env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

with tempfile.TemporaryDirectory(prefix="crew-ccr-v3-guard-test-") as tmp:
    root = Path(tmp)
    # 2026-10-26 防复发守卫:GPT-6 系模型在 llm-gw 的 /v1/chat/completions 拒绝
    # function tools + reasoning_effort(400 事故),validate 必须拦下错误形态,
    # 放行 type=openai_responses 的正确形态。GPT-5.x 不受影响,照常放行。
    g6_bad = root / "g6-bad.json"
    g6_bad.write_text(json.dumps({
        "gateway": {"api_key": "k"},
        "Providers": [{
            "name": "GPT-6.1-Sol-A-joybuilder-personal",
            "api_base_url": "http://llm-gw.jd.local/v1/chat/completions",
            "api_key": "UP", "models": ["GPT-6.1-Sol-A-joybuilder"],
            "transformer": {"use": ["OpenAI"]},
        }],
    }), encoding="utf-8")
    buf_err, buf_out = [], []
    _err, _out = sys.stderr, sys.stdout
    sys.stderr, sys.stdout = _Cap(buf_err), _Cap(buf_out)
    try:
        rc = ccr_v3.command_validate(g6_bad)
    finally:
        sys.stderr, sys.stdout = _err, _out
    check("validate: GPT-6 chat/completions form is rejected", rc == 1)
    joined = "".join(buf_err)
    check("validate: rejection names openai_responses fix", "openai_responses" in joined)

    g6_good = root / "g6-good.json"
    g6_good.write_text(json.dumps({
        "gateway": {"api_key": "k"},
        "Providers": [{
            "name": "GPT-6.1-Sol-A-joybuilder-personal",
            "api_base_url": "http://llm-gw.jd.local/v1",
            "api_key": "UP", "models": ["GPT-6.1-Sol-A-joybuilder"],
            "transformer": {"use": ["OpenAI"]},
            "type": "openai_responses",
        }],
    }), encoding="utf-8")
    check("validate: GPT-6 responses form passes", ccr_v3.command_validate(g6_good) == 0)

    g5_map = root / "g5.json"
    g5_map.write_text(json.dumps({
        "gateway": {"api_key": "k"},
        "Providers": [{
            "name": "GPT-5.5-joybuilder-personal",
            "api_base_url": "http://llm-gw.jd.local/v1/chat/completions",
            "api_key": "UP", "models": ["GPT-5.5-joybuilder"],
            "transformer": {"use": ["OpenAI"]},
        }],
    }), encoding="utf-8")
    check("validate: GPT-5.x chat/completions still passes", ccr_v3.command_validate(g5_map) == 0)

    # 豁免:本地 joycode 代理 provider(chat/completions 入口但内部转 responses)不拦
    jc_map = root / "joycode.json"
    jc_map.write_text(json.dumps({
        "gateway": {"api_key": "k"},
        "Providers": [{
            "name": "joycode-oai",
            "api_base_url": "http://127.0.0.1:8765/v1/chat/completions",
            "api_key": "joycode", "models": ["GPT-6.1 Sol", "GPT-6 Sol"],
            "transformer": {"use": ["OpenAI"]},
        }],
    }), encoding="utf-8")
    check("validate: local joycode proxy GPT-6 exemption passes", ccr_v3.command_validate(jc_map) == 0)


with tempfile.TemporaryDirectory(prefix="crew-ccr-drift-test-") as tmp:
    root = Path(tmp)
    drift_map = root / "providers.json"
    drift_map.write_text(json.dumps({
        "gateway": {"api_key": "sk-ccr-map-key"},
        "Providers": [{
            "name": "opus", "api_base_url": "http://gw/v1/chat/completions",
            "api_key": "KEY-A", "models": ["Claude-Opus-4.8-joybuilder"],
            "transformer": {"use": ["OpenAI"]},
        }],
    }), encoding="utf-8")

    # 场景 1:完全一致 → rc=0,无 drift 输出
    server, calls = _drift_server({"getConfig": {
        "APIKEY": "sk-ccr-map-key",
        "APIKEYS": [{"id": "local-gateway", "key": "sk-ccr-map-key", "name": "Local Gateway"}],
        "Providers": [{"name": "opus", "api_key": "KEY-A",
                       "models": ["Claude-Opus-4.8-joybuilder"]}],
    }})
    with _drift_env(f"http://127.0.0.1:{server.server_address[1]}"):
        buf_err, buf_out = [], []
        _err, _out = sys.stderr, sys.stdout
        sys.stderr, sys.stdout = _Cap(buf_err), _Cap(buf_out)
        try:
            rc = ccr_v3.command_drift(drift_map)
        finally:
            sys.stderr, sys.stdout = _err, _out
    check("drift: consistent config returns 0", rc == 0)
    check("drift: consistent config reports no drift", "no drift" in "".join(buf_err + buf_out))

    # 场景 2:gateway key 分叉(事故现场:map 被手改成新 key,live 仍旧 key)
    server, calls = _drift_server({"getConfig": {
        "APIKEY": "sk-ccr-OLD-live-key",
        "APIKEYS": [{"id": "local-gateway", "key": "sk-ccr-OLD-live-key", "name": "Local Gateway"}],
        "Providers": [{"name": "opus", "api_key": "KEY-A",
                       "models": ["Claude-Opus-4.8-joybuilder"]}],
    }})
    with _drift_env(f"http://127.0.0.1:{server.server_address[1]}"):
        buf_err, buf_out = [], []
        _err, _out = sys.stderr, sys.stdout
        sys.stderr, sys.stdout = _Cap(buf_err), _Cap(buf_out)
        try:
            rc = ccr_v3.command_drift(drift_map)
        finally:
            sys.stderr, sys.stdout = _err, _out
    check("drift: gateway key divergence returns 1", rc == 1)
    joined = "".join(buf_err + buf_out)
    check("drift: reports gateway key divergence", "gateway key" in joined and "apply" in joined)

    # 场景 3:provider key 分叉 + 模型集分叉 + live 缺 provider
    server, calls = _drift_server({"getConfig": {
        "APIKEY": "sk-ccr-map-key",
        "APIKEYS": [{"id": "local-gateway", "key": "sk-ccr-map-key", "name": "Local Gateway"}],
        "Providers": [{"name": "opus", "api_key": "KEY-B",
                       "models": ["Claude-Opus-4.8-joybuilder", "EXTRA-MODEL"]}],
    }})
    with _drift_env(f"http://127.0.0.1:{server.server_address[1]}"):
        buf_err, buf_out = [], []
        _err, _out = sys.stderr, sys.stdout
        sys.stderr, sys.stdout = _Cap(buf_err), _Cap(buf_out)
        try:
            rc = ccr_v3.command_drift(drift_map)
        finally:
            sys.stderr, sys.stdout = _err, _out
    check("drift: provider divergence returns 1", rc == 1)
    joined = "".join(buf_err + buf_out)
    check("drift: reports provider key divergence", "api_key" in joined)
    check("drift: reports model-set divergence", "EXTRA-MODEL" in joined)

    # 场景 4:CCR web RPC 不可达 → rc=2(区别于「有 drift」,doctor 据此提示先起 CCR)
    with _drift_env("http://127.0.0.1:1"):
        try:
            ccr_v3.command_drift(drift_map)
            check("drift: unreachable RPC raises", False)
        except ccr_v3.CcrRpcError:
            check("drift: unreachable RPC raises CcrRpcError", True)

print("drift tests done")
