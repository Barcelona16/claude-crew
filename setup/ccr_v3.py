#!/usr/bin/env python3
"""Small CCR 3 management-RPC adapter used by claude-crew.

CCR 3 stores its live configuration in SQLite and intentionally migrates away
from ``~/.claude-code-router/config.json``.  crew still needs a durable,
human-readable provider map for key selection and failover, so this module
keeps that map separate and applies it through CCR's authenticated local RPC.

The map is private runtime state (normally
``~/.config/claude-crew/ccr-providers.json``), not a CCR config file.  Its
``Providers`` entries use the public CCR provider schema and are copied into
the CCR 3 configuration on ``apply``.
"""

from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request


class CcrRpcError(RuntimeError):
    """CCR management RPC could not complete."""


def default_provider_map() -> Path:
    crew_home = os.environ.get("CREW_HOME")
    if not crew_home:
        crew_home = os.path.join(
            os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
            "claude-crew",
        )
    return Path(crew_home) / "ccr-providers.json"


def read_provider_map(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise CcrRpcError(f"cannot read provider map {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CcrRpcError(f"invalid provider map {path}: {exc}") from exc

    if not isinstance(value, dict):
        raise CcrRpcError(f"provider map {path} must be a JSON object")
    providers = value.get("Providers") or value.get("providers")
    if not isinstance(providers, list) or not providers:
        raise CcrRpcError(f"provider map {path} has no Providers")
    for index, provider in enumerate(providers, start=1):
        if not isinstance(provider, dict):
            raise CcrRpcError(f"provider map entry {index} is not an object")
        name = provider.get("name")
        models = provider.get("models")
        if not isinstance(name, str) or not name.strip() or not isinstance(models, list) or not models:
            raise CcrRpcError(f"provider map entry {index} needs name and models")
    return value


def map_providers(provider_map: dict[str, object]) -> list[dict[str, object]]:
    raw = provider_map.get("Providers") or provider_map.get("providers") or []
    return [copy.deepcopy(provider) for provider in raw if isinstance(provider, dict)]


def map_gateway_key(provider_map: dict[str, object]) -> str:
    gateway = provider_map.get("gateway")
    if isinstance(gateway, dict):
        value = gateway.get("api_key") or gateway.get("apiKey")
        if isinstance(value, str) and value.strip():
            return value.strip()
    value = provider_map.get("APIKEY")
    if isinstance(value, str) and value.strip():
        return value.strip()
    raise CcrRpcError("provider map is missing gateway.api_key")


def gateway_port() -> int:
    raw = os.environ.get("CREW_CCR_PORT", "3456")
    try:
        port = int(raw)
    except ValueError as exc:
        raise CcrRpcError(f"invalid CREW_CCR_PORT: {raw!r}") from exc
    if not 1 <= port <= 65535:
        raise CcrRpcError(f"invalid CREW_CCR_PORT: {raw!r}")
    return port


def web_url() -> str:
    value = os.environ.get("CREW_CCR_WEB_URL")
    if value:
        return value.rstrip("/")
    return f"http://127.0.0.1:{os.environ.get('CREW_CCR_WEB_PORT', '3458')}"


def rpc_call(method: str, args: list[object]) -> object:
    token = os.environ.get("CREW_CCR_WEB_TOKEN", "").strip()
    if not token:
        raise CcrRpcError("CREW_CCR_WEB_TOKEN is required for CCR 3 management RPC")
    body = json.dumps({"method": method, "args": args}).encode("utf-8")
    request = urllib.request.Request(
        f"{web_url()}/api/ccr/rpc",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-ccr-web-auth": token,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read(4096).decode("utf-8", "replace")
        raise CcrRpcError(f"CCR RPC {method} failed (HTTP {exc.code}): {detail}") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise CcrRpcError(f"CCR RPC {method} failed: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        detail = payload.get("error") if isinstance(payload, dict) else payload
        raise CcrRpcError(f"CCR RPC {method} failed: {detail}")
    return payload.get("value")


def merge_config(current: object, provider_map: dict[str, object]) -> dict[str, object]:
    if not isinstance(current, dict):
        raise CcrRpcError("CCR getConfig returned an invalid response")
    result = copy.deepcopy(current)
    providers = map_providers(provider_map)
    port = gateway_port()
    result["Providers"] = providers
    result.pop("providers", None)
    result["APIKEY"] = map_gateway_key(provider_map)
    result["HOST"] = "127.0.0.1"
    result["PORT"] = port
    result["routerEndpoint"] = f"http://127.0.0.1:{port}"
    result["preferredProvider"] = str(providers[0]["name"])
    gateway = result.get("gateway")
    if not isinstance(gateway, dict):
        gateway = {}
    gateway.update({"enabled": True, "host": "127.0.0.1", "port": port})
    result["gateway"] = gateway
    return result


def merge_gateway_api_keys(current: object, provider_map: dict[str, object]) -> list[dict[str, object]]:
    """Return CCR's existing client keys plus the stable crew loopback key.

    CCR 3 intentionally ignores ``APIKEY`` changes made through ``saveConfig``;
    gateway keys must go through ``saveApiKeys``.  Preserve user/profile keys
    and replace only crew's own managed entry.
    """
    values = current.get("APIKEYS", []) if isinstance(current, dict) else []
    result = [copy.deepcopy(value) for value in values if isinstance(value, dict)
              and value.get("id") != "claude-crew-provider-map"]
    result.append({
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "id": "claude-crew-provider-map",
        "key": map_gateway_key(provider_map),
        "name": "claude-crew local proxy",
    })
    return result


def command_apply(path: Path) -> int:
    provider_map = read_provider_map(path)
    current = rpc_call("getConfig", [])
    # saveApiKeys is a side-effect RPC.  CCR releases return either an ACK or
    # a configuration-shaped object here, so it must never become the merge
    # baseline: only the preceding getConfig result is guaranteed complete.
    rpc_call("saveApiKeys", [merge_gateway_api_keys(current, provider_map)])
    next_config = merge_config(current, provider_map)
    rpc_call("saveConfig", [next_config, {"applyProfile": False}])
    providers = map_providers(provider_map)
    models = {
        model
        for provider in providers
        for model in provider.get("models", [])
        if isinstance(model, str) and model
    }
    print(f"applied {len(providers)} provider(s) and {len(models)} model(s) to CCR 3", file=sys.stderr)
    return 0


def command_validate(path: Path) -> int:
    provider_map = read_provider_map(path)
    map_gateway_key(provider_map)
    providers = map_providers(provider_map)
    models = {
        model
        for provider in providers
        for model in provider.get("models", [])
        if isinstance(model, str) and model
    }
    print(f"validated {len(providers)} provider(s) and {len(models)} model(s)", file=sys.stderr)
    return 0


def command_client_key(path: Path) -> int:
    print(map_gateway_key(read_provider_map(path)))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Apply a claude-crew provider map to CCR 3")
    parser.add_argument("command", choices=("apply", "validate", "client-key"))
    parser.add_argument(
        "--provider-map",
        type=Path,
        default=Path(os.environ.get("CREW_CCR_CONFIG", default_provider_map())),
    )
    args = parser.parse_args(argv)
    if args.command == "apply":
        return command_apply(args.provider_map)
    if args.command == "validate":
        return command_validate(args.provider_map)
    return command_client_key(args.provider_map)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CcrRpcError as exc:
        print(f"ccr_v3: {exc}", file=sys.stderr)
        raise SystemExit(2)
