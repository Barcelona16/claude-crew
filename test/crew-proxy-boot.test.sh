#!/usr/bin/env bash
# test/crew-proxy-boot.test.sh — crew_proxy.py 脚本直跑模式冒烟(2026-10-28)
#
# 背景:部署阶段发现 python3 setup/crew_proxy.py 脚本直跑(launchd 即此模式)下,
# GET /api/sessions 崩 NameError: CREW_BIN。根因:PEP 562 模块 __getattr__ 只对
# module.attr / from-import 生效,函数体内裸名 LOAD_GLOBAL 不走它。
# 现有 python 测试全用 `import crew_proxy` 加载,永远测不到这条路径。
#
# 本测试钉住回归:脚本直跑 + GET /api/sessions 必须 200。
# 断言仅一条:HTTP 200 + 非空 body。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

T="$(mktemp -d /tmp/crew-proxy-boot.XXXXXX)"
trap 'rm -rf "$T"; [ -n "${PROXY_PID:-}" ] && kill -9 "$PROXY_PID" 2>/dev/null || true' EXIT

# 造最小配置
mkdir -p "$T/cfg"
cat > "$T/cfg/keys.conf" <<EOF
boot=sk-boot-test-key
EOF
: > "$T/cfg/key-policy.conf"
cat > "$T/cfg/ccr-providers.json" <<EOF
{
  "gateway": {"api_key": "sk-boot-gw"},
  "Providers": [
    {"name": "boot-provider", "api_base_url": "http://127.0.0.1:59999",
     "api_key": "sk-boot-test-key", "models": ["boot-model"]}
  ]
}
EOF

PORT=59888
export CREW_CONFIG_DIR="$T/cfg"
export CREW_CCR_CONFIG="$T/cfg/ccr-providers.json"
export CREW_CCR_URL="http://127.0.0.1:59999"
export CREW_CCR_PORT="59999"
export CREW_PROXY_PORT="$PORT"

# 后台直跑(模拟 launchd:python3 crew_proxy.py)
python3 "$ROOT/setup/crew_proxy.py" >"$T/proxy.log" 2>&1 &
PROXY_PID=$!

# 等端口就绪(最多 10s)
ready=0
for i in $(seq 1 50); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && { ready=1; break; }
  sleep 0.2
done

if [ "$ready" != 1 ]; then
  echo "FAIL: proxy 10s 内未就绪 (log: $(cat "$T/proxy.log" | tail -5))"
  exit 1
fi

# curl /api/sessions → 200 + 非空 body
body=$(curl -s -o "$T/resp.body" -w '%{http_code}' "http://127.0.0.1:$PORT/api/sessions" 2>/dev/null)
if [ "$body" = "200" ] && [ -s "$T/resp.body" ]; then
  echo "PASS: GET /api/sessions → 200, body=$(head -c 120 "$T/resp.body")"
  exit 0
else
  echo "FAIL: GET /api/sessions → http=$body body=$(cat "$T/resp.body" 2>/dev/null)"
  echo "--- proxy.log tail ---"
  tail -20 "$T/proxy.log"
  exit 1
fi
