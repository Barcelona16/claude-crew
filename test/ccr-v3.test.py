#!/usr/bin/env python3
"""Unit tests for CCR 3 provider-map/RPC adaptation."""

import importlib.util
import json
import os
from pathlib import Path
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
