#!/usr/bin/env bash
# crew-v2-migration-audit.test.sh — v1.2 §9.1 sunset audit 命令
# 覆盖:
#   ① 全挂载 exit 0
#   ② 有未挂载 exit 1 + 报告未挂列表
#   ③ 心跳文件陈旧(>24h)也算未挂
#   ④ 最近活跃时间从 feedback.jsonl 尾扫得到
#   ⑤ 活跃未挂标 ★活跃 · 必须挂

set -uo pipefail
unset CREW_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
AUDIT="$SCRIPT_DIR/../bin/crew-v2-migration-audit.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-audit.XXX)"
trap 'rm -rf "$T"' EXIT
export CREW_STATE="$T/state"
export CREW_SCAN_ROOTS="$T/work"
export FEEDBACK_JSONL="$T/feedback.jsonl"
mkdir -p "$CREW_STATE/heartbeat" "$CREW_SCAN_ROOTS"

# 造两个 project · sessions=[alice, bob, ghost]
mkdir -p "$CREW_SCAN_ROOTS/proj-A/.chaos-bridge"
cat > "$CREW_SCAN_ROOTS/proj-A/.chaos-bridge/project.json" <<'JSON'
{ "name": "proj-A", "workDir": "/work/proj-A", "sessions": ["alice", "bob"] }
JSON
mkdir -p "$CREW_SCAN_ROOTS/proj-B/.chaos-bridge"
cat > "$CREW_SCAN_ROOTS/proj-B/.chaos-bridge/project.json" <<'JSON'
{ "name": "proj-B", "workDir": "/work/proj-B", "sessions": ["ghost"] }
JSON

# --- Case 1: 全未挂载 exit 1 ---
echo "--- Case 1: 全未挂载 exit 1 ---"
out=$(node "$AUDIT" 2>&1)
ec=$?
[ "$ec" = "1" ] && _ok "exit 1(全 3 会话未挂载)" || _ng "exit=$ec 预期 1"
echo "$out" | grep -q "未挂载: 3 会话" && _ok "未挂载 3 会话报告" || _ng "报告不对:$out"

# --- Case 2: 挂载 2 个 · ghost 未挂 · exit 1 ---
echo "--- Case 2: 部分挂载 ---"
now_iso=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
cat > "$CREW_STATE/heartbeat/alice.json" <<EOF
{"name":"alice","ts":"$now_iso","claudePid":123,"tmuxStatus":"live"}
EOF
cat > "$CREW_STATE/heartbeat/bob.json" <<EOF
{"name":"bob","ts":"$now_iso","claudePid":124,"tmuxStatus":"live"}
EOF
out=$(node "$AUDIT" 2>&1)
ec=$?
[ "$ec" = "1" ] && _ok "有 ghost 未挂 exit 1" || _ng "exit=$ec 预期 1"
echo "$out" | grep -q "已挂载 crew v2: 2" && _ok "已挂载 2 报告" || _ng "已挂载数不对:$out"
echo "$out" | grep -q "ghost" && _ok "未挂列表含 ghost" || _ng "ghost 缺"

# --- Case 3: 全挂载 exit 0 ---
echo "--- Case 3: 全挂载 exit 0 ---"
cat > "$CREW_STATE/heartbeat/ghost.json" <<EOF
{"name":"ghost","ts":"$now_iso","claudePid":125,"tmuxStatus":"live"}
EOF
out=$(node "$AUDIT" 2>&1)
ec=$?
[ "$ec" = "0" ] && _ok "全挂载 exit 0" || _ng "exit=$ec 预期 0"
echo "$out" | grep -q "所有会话都已挂载" && _ok "全挂载 · Phase 4 sunset 可放行" || _ng "文案缺"

# --- Case 4: 心跳陈旧(>24h)也算未挂 ---
echo "--- Case 4: 心跳陈旧 >24h 视为未挂 ---"
touch -d "48 hours ago" "$CREW_STATE/heartbeat/alice.json"
out=$(node "$AUDIT" 2>&1)
ec=$?
[ "$ec" = "1" ] && _ok "alice 心跳陈旧 exit 1" || _ng "exit=$ec 预期 1"
echo "$out" | grep -q "alice" && _ok "alice 视为未挂列出" || _ng "alice 未列"

# --- Case 5: feedback.jsonl 活跃时间 + ★活跃标 ---
echo "--- Case 5: 活跃未挂 ★ 标 ---"
now_recent=$(date -u -d "-3 hours" '+%Y-%m-%dT%H:%M:%S.000Z')
cat > "$FEEDBACK_JSONL" <<EOF
{"ts":"$now_recent","session":"alice","note":"recent activity"}
{"ts":"$now_recent","sender":"alice","note":"sent something"}
EOF
out=$(node "$AUDIT" 2>&1)
echo "$out" | grep -q "★活跃 · 必须挂" && _ok "近 24h 活跃标 ★ 必须挂" || _ng "★ 标缺:$out"

# --- Case 6: crew CLI dispatch v2-migration-audit ---
echo "--- Case 6: crew CLI dispatch ---"
out=$($CREW v2-migration-audit 2>&1)
ec=$?
echo "$out" | grep -q "crew v2 migration audit" && _ok "crew CLI dispatch 到 audit" || _ng "dispatch 失败:$out"

echo
echo "=== crew-v2-migration-audit.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
