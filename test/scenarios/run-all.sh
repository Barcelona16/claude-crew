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
  # BSD sed 必须显式空备份后缀(macOS),否则 -e 被当成备份文件名
  # baseline 录于 Linux/root(默认 CREW_HOME=/root/.config/claude-crew,
  # CREW_STATE=/root/.local/share/claude-crew);本机用 /tmp 隔离目录跑,
  # 归一化时把本机临时路径前缀映回 baseline 的 /root 前缀(保留子路径),
  # 使 diff 稳定。日期/commit/SID/PID 等运行期变量一并归一。
  # 同一份归一化规则同时应用于 baseline 副本,消除日期/commit 漂移。
  normalize(){
    sed -i '' \
      -e 's|/tmp/crew-v2-test-state|/root/.local/share/claude-crew|g' \
      -e 's|/tmp/crew-v2-test-home|/root/.config/claude-crew|g' \
      -e 's|[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:.]*Z|<TS>|g' \
      -e 's|[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{3\}Z|<TSFILE>|g' \
      -e 's|at [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9:]*|at <DATE>|g' \
      -e 's|crew [0-9a-f]\{7\} ([0-9-]*) \[main\]|crew <VER> (<DATE>) [main]|g' \
      -e 's|pid=[0-9]\+|pid=<PID>|g' \
      -e 's|id=[0-9a-f]\{12\}|id=<ID>|g' \
      -e 's|\[[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} session:|[<TIME> session:|g' \
      -e 's|[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}|<SID>|g' \
      "$1"
  }
  normalize "$out_file"

  if [ "$RECORD" = 1 ]; then
    cp "$out_file" "$BASELINE_DIR/$s.out"
    echo "RECORD $s (ec=$ec)"
    pass=$((pass+1))
  else
    if [ ! -f "$BASELINE_DIR/$s.out" ]; then
      echo "NO-BASELINE $s (先跑 --record)"
      fail=$((fail+1))
    else
      # baseline 也过同一归一化(日期/commit 漂移)
      norm_base="$OUTPUT_DIR/$s.norm-base"
      cp "$BASELINE_DIR/$s.out" "$norm_base"
      normalize "$norm_base"
      if diff -q "$norm_base" "$out_file" >/dev/null 2>&1; then
        echo "PASS $s"
        pass=$((pass+1))
      else
        echo "FAIL $s (diff:)"
        diff -u "$norm_base" "$out_file" | head -20
        fail=$((fail+1))
      fi
    fi
  fi
done

echo
echo "=== Total: $total | Pass: $pass | Fail: $fail ==="
[ "$fail" -eq 0 ]
