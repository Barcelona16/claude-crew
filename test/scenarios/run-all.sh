#!/usr/bin/env bash
# run-all.sh — 跑所有场景测试,输出对比 baseline
#
# 用法:
#   bash test/scenarios/run-all.sh [--record]     # --record 保存输出为 baseline
#   bash test/scenarios/run-all.sh                # 默认 diff mode:对比 baseline
#
# 每 case 独立 sh 脚本,输出到 test/scenarios/output/<case>.out
# --record 时保存到 test/scenarios/baseline/<case>.out(用老 crew 跑一次建立基线)
# 默认 diff mode:新 crew 跑 → 对比 baseline,报差异
#
# 环境变量:
#   CREW_BIN     被测 crew(默认 /work/claude-crew/bin/crew,record baseline 用;
#                 --record 后新 crew 迭代时用 /work/claude-crew-v2/bin/crew)
#   CLAUDE_BIN   mock claude,默认 /bin/echo(不真起 claude)

set -uo pipefail

SCENARIOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_ROOT="$(cd "$SCENARIOS_DIR/../.." && pwd)"
OUTPUT_DIR="$SCENARIOS_DIR/output"
BASELINE_DIR="$SCENARIOS_DIR/baseline"

RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

# 默认被测 crew(record 时 → 老 crew;diff 时 → 新 crew,还没写就用老)
export CREW_BIN="${CREW_BIN:-/work/claude-crew/bin/crew}"
# mock claude,输出参数并立即退,不真起
export CLAUDE_BIN="${CLAUDE_BIN:-/bin/echo}"
# 独立 CREW_STATE 目录,不污染生产
export CREW_STATE="${CREW_STATE:-/tmp/crew-v2-test-state}"
export CREW_HOME="${CREW_HOME:-/tmp/crew-v2-test-home}"
export CREW_CLAUDE_BIN="$CLAUDE_BIN"

# 每次测前清临时状态(不动生产)
rm -rf "$CREW_STATE" "$CREW_HOME"
mkdir -p "$CREW_STATE" "$CREW_HOME/backends" "$OUTPUT_DIR"
[ "$RECORD" = 1 ] && mkdir -p "$BASELINE_DIR"

# 复制模拟 backend conf(单一 backend,不涉及 ccr)
cat > "$CREW_HOME/backends/mock.conf" <<EOF
BASE_URL=http://127.0.0.1:9999
MODEL=mock-model
TOKEN=mocktoken
KEY_MODE=direct
EOF

# 存量老 CLI 测试子命令列表
declare -a SCENARIOS=(
  "01-ls-empty"
  "02-spawn-notmux"
  "03-status-files"
  "04-pin-unpin"
  "05-doctor"
  "06-inbox-send"
  "07-kill-purge"
  "08-adopt-external"
)

total=0; pass=0; fail=0
for s in "${SCENARIOS[@]}"; do
  total=$((total+1))
  script="$SCENARIOS_DIR/$s.sh"
  if [ ! -f "$script" ]; then
    echo "SKIP $s (脚本不存在)"
    continue
  fi
  out_file="$OUTPUT_DIR/$s.out"
  # 每 case 前清状态(隔离)
  rm -rf "$CREW_STATE" 2>/dev/null
  mkdir -p "$CREW_STATE"
  cp "$CREW_HOME/backends/mock.conf" "$CREW_HOME/backends/mock.conf" 2>/dev/null || true
  # 跑(explicit env 传给 subshell,不依赖 export 传递到 bash script)
  env \
    CREW_BIN="$CREW_BIN" \
    CLAUDE_BIN="$CLAUDE_BIN" \
    CREW_STATE="$CREW_STATE" \
    CREW_HOME="$CREW_HOME" \
    CREW_CLAUDE_BIN="$CREW_CLAUDE_BIN" \
    bash "$script" > "$out_file" 2>&1
  ec=$?
  # 归一化:去掉时间戳/PID/临时路径(baseline diff 稳定)
  sed -i \
    -e 's|/tmp/crew-v2-test-state[/A-Za-z0-9._-]*|<STATE>|g' \
    -e 's|/tmp/crew-v2-test-home[/A-Za-z0-9._-]*|<HOME>|g' \
    -e 's|[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:]*Z|<TS>|g' \
    -e 's|pid=[0-9]\+|pid=<PID>|g' \
    -e 's|[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}|<SID>|g' \
    "$out_file"

  if [ "$RECORD" = 1 ]; then
    cp "$out_file" "$BASELINE_DIR/$s.out"
    echo "RECORD $s (ec=$ec)"
    pass=$((pass+1))
  else
    if [ ! -f "$BASELINE_DIR/$s.out" ]; then
      echo "NO-BASELINE $s (先跑 --record)"
      fail=$((fail+1))
    elif diff -q "$BASELINE_DIR/$s.out" "$out_file" >/dev/null 2>&1; then
      echo "PASS $s"
      pass=$((pass+1))
    else
      echo "FAIL $s (diff:)"
      diff -u "$BASELINE_DIR/$s.out" "$out_file" | head -20
      fail=$((fail+1))
    fi
  fi
done

echo
echo "=== Total: $total | Pass: $pass | Fail: $fail ==="
[ "$fail" -eq 0 ]
