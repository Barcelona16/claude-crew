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


def _needs_responses(model: str) -> bool:
    """GPT-6 系模型必须走 OpenAI Responses API(llm-gw 实测 2026-10-26)。

    llm-gw 的 /v1/chat/completions 对这些模型拒绝 function tools 与
    reasoning_effort 共存(400 "Function tools with reasoning_effort are not
    supported … use /v1/responses");GPT-5.x 系不受影响。与 bin/crew
    ensure_model_in_ccr / sync-models 的判定保持同规则(改一处必同步另一处)。
    """
    return model.lower().startswith("gpt-6")


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
    # 2026-10-16 二次 401 防复发:强制关闭 CCR 原生 Claude Code 集成。
    # profile.claudeCode.enabled=true 时 CCR 每次 saveConfig 都会"接管"
    # ~/.claude/settings.json(写 :3456 直连 + apiKeyHelper),把 crew 修复
    # 一次次踩回去 → 所有非 crew 起的会话 401。crew 走 crew-proxy(:8788),
    # 这层集成与 crew 架构冲突,apply 时三层全关(总闸/claudeCode/ profiles[])。
    profile = result.get("profile")
    if not isinstance(profile, dict):
        profile = {}
    profile["enabled"] = False
    claude_code = profile.get("claudeCode")
    if not isinstance(claude_code, dict):
        claude_code = {}
    claude_code["enabled"] = False
    profile["claudeCode"] = claude_code
    profiles = profile.get("profiles")
    if isinstance(profiles, list):
        for entry in profiles:
            if isinstance(entry, dict) and entry.get("agent") == "claude-code":
                entry["enabled"] = False
    result["profile"] = profile
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
    # 2026-10-26 防复发守卫:llm-gw 的 GPT-6 系在 /v1/chat/completions 拒绝
    # function tools + reasoning_effort(实测 gpt-6-sol / gpt-6.1-sol;GPT-5.x 不受
    # 影响),必须以 type=openai_responses 走 /v1/responses。手改 map 或旧版脚本
    # 落地回 chat/completions 形态时,在 validate 就拦下,而不是等会话 400。
    # 豁免:joycode 本地代理(:8765)的 provider 对外是 chat/completions 入口,
    # 但其内部按上游 adapterType 自动转 Responses API(joycode_proxy.py),不受限。
    problems = []
    for provider in providers:
        if not isinstance(provider, dict):
            continue
        base_url = str(provider.get("api_base_url") or "")
        if "127.0.0.1" in base_url or "localhost" in base_url:
            continue
        for model in provider.get("models", []) if isinstance(provider.get("models"), list) else []:
            if not (isinstance(model, str) and model):
                continue
            if _needs_responses(model) and provider.get("type") != "openai_responses":
                problems.append(
                    f"provider '{provider.get('name')}' model '{model}' is a GPT-6 family model "
                    f"but is not routed via /v1/responses (need type='openai_responses' and "
                    f"api_base_url without '/chat/completions'; got type={provider.get('type')!r}, "
                    f"api_base_url={base_url!r}). chat/completions rejects function tools with "
                    f"reasoning_effort for these models (400, 2026-10-26 incident)."
                )
    if problems:
        for problem in problems:
            print(f"invalid provider map: {problem}", file=sys.stderr)
        return 1
    print(f"validated {len(providers)} provider(s) and {len(models)} model(s)", file=sys.stderr)
    return 0


def command_client_key(path: Path) -> int:
    print(map_gateway_key(read_provider_map(path)))
    return 0

def command_drift(path: Path) -> int:
    """Compare the provider map against CCR 3's live configuration.

    Exit 0 = no drift; 1 = drift found (report + the apply command to fix);
    2 = CCR RPC unreachable (distinct from drift so callers can prompt to
    start CCR first).  Read-only: it never saves, because key changes must go
    through an explicit human-run ``apply`` (CLAUDE.md §3, 2026-10-16 incident).
    """
    provider_map = read_provider_map(path)
    gateway_key = map_gateway_key(provider_map)
    wanted = {p["name"]: p for p in map_providers(provider_map)}
    live = rpc_call("getConfig", [])
    if not isinstance(live, dict):
        raise CcrRpcError("CCR getConfig returned an invalid response")

    problems: list[str] = []

    def _mask(value: str) -> str:
        return (value[:8] + "…" + value[-4:]) if len(value) > 14 else value

    # 1) gateway key: what crew-proxy sends must be accepted by live CCR.
    #    (The 2026-10-16 401: map's gateway key hand-edited without apply.)
    live_keys = live.get("APIKEYS") or []
    accepted = {(e.get("key") or "") for e in live_keys if isinstance(e, dict)}
    if gateway_key not in accepted and live.get("APIKEY") != gateway_key:
        problems.append(
            f"gateway key drift: provider map sends {_mask(gateway_key)} but live CCR "
            f"accepts {sorted(_mask(k) for k in accepted) or '(none)'} — rerun "
            f"`{sys.argv[0]} apply` (or crew proxy sync) and restart crew-proxy"
        )

    # 2) providers: every map provider must exist live with the same key+models.
    live_providers = {p.get("name"): p for p in (live.get("Providers") or [])
                      if isinstance(p, dict)}
    for name, want in wanted.items():
        got = live_providers.get(name)
        if got is None:
            problems.append(f"provider '{name}' missing in live CCR (map-only)")
            continue
        if (got.get("api_key") or "") != (want.get("api_key") or ""):
            problems.append(
                f"provider '{name}' api_key drift: map {_mask(want.get('api_key') or '')} "
                f"vs live {_mask(got.get('api_key') or '')}"
            )
        want_models = {m for m in (want.get("models") or []) if isinstance(m, str) and m}
        got_models = {m for m in (got.get("models") or []) if isinstance(m, str) and m}
        if want_models != got_models:
            problems.append(
                f"provider '{name}' model drift: map-only {sorted(want_models - got_models)} "
                f"live-only {sorted(got_models - want_models)}"
            )

    # 3) live-only providers are informational (user's own CCR entries), not drift.

    if problems:
        print("CCR drift detected:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print("fix: rerun apply (ccr_v3.py apply) so CCR 3 accepts the map's keys",
              file=sys.stderr)
        return 1
    print("no drift: provider map matches live CCR configuration", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Apply a claude-crew provider map to CCR 3")
    parser.add_argument("command", choices=("apply", "validate", "client-key", "drift"))
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
    if args.command == "drift":
        return command_drift(args.provider_map)
    return command_client_key(args.provider_map)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CcrRpcError as exc:
        print(f"ccr_v3: {exc}", file=sys.stderr)
        raise SystemExit(2)
