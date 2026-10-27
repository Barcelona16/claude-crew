#!/usr/bin/env bash
# test/run-all.sh — claude-crew 统一测试入口(2026-10-28)
#
# 一条命令跑完整个测试套件:
#   - 22 个 bash 测试(test/*.test.sh)
#   - 5 个 python 测试(setup/test_*.py + test/ccr-v3.test.py)
#   - 可选 test/scenarios/run-all.sh(--with-scenarios)
#
# 用法:
#   bash test/run-all.sh                       # 跑全部(串行,最稳)
#   bash test/run-all.sh --with-scenarios     # 加跑 scenarios
#   bash test/run-all.sh --only pid            # 只跑名字含 "pid" 的测试
#   CREW_TIMEOUT=60 bash test/run-all.sh       # 改每测试看门狗秒数(默认 180)
#
# 设计要点(为 macOS / 本环境 SIGTERM 屏蔽 量身定制):
#   1. 提供可移植 `timeout` shim(bin/crew-tmux、bin/crew-launcher、
#      bin/crew.d/dsh.sh 内部都用 GNU `timeout`,macOS 自带没有)。
#   2. 每个测试用「后台+kill -9」看门狗,不依赖 SIGTERM。
#   3. 固定端口测试(autodiscover 19999/19997)与固定状态目录测试
#      (scenarios /tmp/crew-v2-test-state)串行跑,避免冲突。
#   4. 跑完自动清理孤儿 fake_gw / http.server 后台进程。
#
# 退出码:全部 PASS → 0;任一 FAIL → 1。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="$(mktemp -d /tmp/crew-runall.XXXXXX)"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# 1. 可移植 `timeout` shim(放在临时 PATH 最前)
#    语义: timeout SECS CMD ARGS... → 跑 CMD,SECS 后仍未退出则 kill -9
#    保持断言语义("命令须在 N 秒内返回"),不依赖 GNU coreutils。
# ---------------------------------------------------------------------------
SHIM_DIR="$OUT_DIR/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/timeout" <<'SHIM'
#!/usr/bin/env bash
# portable timeout shim: timeout SECONDS CMD [ARGS...]
secs="$1"; shift
[ -z "$secs" ] && { echo "timeout: missing operand" >&2; exit 125; }
[ $# -eq 0 ] && { echo "timeout: missing command" >&2; exit 125; }
"$@" &
pid=$!
( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
watcher=$!
# 等 pid 退出;循环 wait 防信号中断
rc=0
while kill -0 "$pid" 2>/dev/null; do
  sleep 0.1
done
wait "$pid" 2>/dev/null && rc=0 || rc=$?
# 本环境 SIGTERM 屏蔽,看门狗清理必须 kill -9
kill -9 "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
exit "$rc"
SHIM
chmod +x "$SHIM_DIR/timeout"
export PATH="$SHIM_DIR:$PATH"

# macOS 自带 bash 3.2 对 `local -a arr=()` + `set -u` 下 `"${arr[@]}"`
# 会报 unbound variable(bash 4.4 才修)。bin/crew.d/session.sh 等用了这种写法,
# 故优先用 homebrew bash 5.x(若存在),让 `env bash` 解析到新版。
if [ -x /opt/homebrew/bin/bash ]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

# ---------------------------------------------------------------------------
# 2. 参数解析
# ---------------------------------------------------------------------------
ONLY=""
WITH_SCENARIOS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --with-scenarios) WITH_SCENARIOS=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

CREW_TIMEOUT="${CREW_TIMEOUT:-180}"

# ---------------------------------------------------------------------------
# 3. 测试清单: "显示名|类型|相对路径"
# ---------------------------------------------------------------------------
TESTS=(
  "agent-policy|bash|test/agent-policy.test.sh"
  "claude-pid|bash|test/claude-pid.test.sh"
  "crew-dsh|bash|test/crew-dsh.test.sh"
  "crew-ensure-selector|bash|test/crew-ensure-selector.test.sh"
  "crew-help-version|bash|test/crew-help-version.test.sh"
  "crew-integration|bash|test/crew-integration.test.sh"
  "crew-kill|bash|test/crew-kill.test.sh"
  "crew-launcher|bash|test/crew-launcher.test.sh"
  "crew-models-autodiscover|bash|test/crew-models-autodiscover.test.sh"
  "crew-notify|bash|test/crew-notify.test.sh"
  "crew-register|bash|test/crew-register.test.sh"
  "crew-sendmsg-hook|bash|test/crew-sendmsg-hook.test.sh"
  "crew-session|bash|test/crew-session.test.sh"
  "crew-status|bash|test/crew-status.test.sh"
  "crew-statusline|bash|test/crew-statusline.test.sh"
  "crew-stop-hook-integration|bash|test/crew-stop-hook-integration.test.sh"
  "crew-stop-hook|bash|test/crew-stop-hook.test.sh"
  "crew-tmux|bash|test/crew-tmux.test.sh"
  "crew-wake|bash|test/crew-wake.test.sh"
  "crew-watcher|bash|test/crew-watcher.test.sh"
  "crew-web|bash|test/crew-web.test.sh"
  "pane-idle-repl-busy|bash|test/pane-idle-repl-busy.test.sh"
  "py-crew-proxy|py|setup/test_crew_proxy.py"
  "py-crew-proxy-fixes|py|setup/test_crew_proxy_fixes.py"
  "py-joycode-proxy|py|setup/test_joycode_proxy.py"
  "py-responses-compat|py|setup/test_responses_compat.py"
  "py-ccr-v3|py|test/ccr-v3.test.py"
  "crew-proxy-boot|bash|test/crew-proxy-boot.test.sh"
)
[ "$WITH_SCENARIOS" = 1 ] && TESTS+=("scenarios|bash|test/scenarios/run-all.sh")

# ---------------------------------------------------------------------------
# 4. 单测试执行(看门狗 + 计时 + 输出落盘)
# ---------------------------------------------------------------------------
results=()
total_pass=0; total_fail=0; total_time=0

run_one() {
  local name="$1" type="$2" cmd="$3"
  local log="$LOG_DIR/$name.log"

  local t0 dur
  t0=$(date +%s)
  if [ "$type" = "py" ]; then
    python3 "$cmd" >"$log" 2>&1 &
  else
    bash "$cmd" >"$log" 2>&1 &
  fi
  local pid=$!

  # 看门狗:CREW_TIMEOUT 秒后 kill -9
  ( sleep "$CREW_TIMEOUT"; kill -9 "$pid" 2>/dev/null ) &
  local watcher=$!

  # 等测试结束
  while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
  local rc=0
  wait "$pid" 2>/dev/null && rc=0 || rc=$?
  # 本环境 SIGTERM 屏蔽,看门狗清理必须 kill -9(否则 wait 阻塞到 sleep 自然结束)
  kill -9 "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null

  dur=$(( $(date +%s) - t0 ))
  total_time=$((total_time + dur))

  local status="PASS"
  if [ "$rc" -ne 0 ]; then status="FAIL"; total_fail=$((total_fail+1))
  else total_pass=$((total_pass+1)); fi

  local lastline=""
  if [ "$status" = "FAIL" ]; then
    lastline=$(grep -v '^[[:space:]]*$' "$log" | tail -1)
    [ -z "$lastline" ] && lastline="(rc=$rc after ${dur}s)"
  fi
  results+=("$name|$status|${dur}|$lastline")
  printf '%-32s %-5s %4ss  %s\n' "$name" "$status" "$dur" "$lastline"
}

# ---------------------------------------------------------------------------
# 5. 主循环
# ---------------------------------------------------------------------------
overall_start=$(date +%s)
echo "=== claude-crew 测试套件(run-all.sh) ==="
echo "看门狗: ${CREW_TIMEOUT}s/测试 | 输出目录: $OUT_DIR"
echo "------------------------------------------"
for entry in "${TESTS[@]}"; do
  IFS='|' read -r name type cmd <<<"$entry"
  if [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]]; then continue; fi
  # scenarios 需要 CREW_BIN 指向当前仓库 crew
  if [ "$name" = "scenarios" ]; then
    CREW_BIN="$ROOT/bin/crew" run_one "$name" "$type" "$cmd"
  else
    run_one "$name" "$type" "$cmd"
  fi
done

# ---------------------------------------------------------------------------
# 6. 清理孤儿后台进程(本环境 SIGTERM 屏蔽,统一 kill -9)
# ---------------------------------------------------------------------------
echo "------------------------------------------"
echo "清理孤儿进程..."
for pat in 'fake_gw' 'crew-autodisc' 'crew-claudepid' 'http\.server' 'crew-v2-test-state'; do
  pids=$(ps -eo pid,command | grep -E "$pat" | grep -v grep | awk '{print $1}')
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
done

# ---------------------------------------------------------------------------
# 7. 汇总
# ---------------------------------------------------------------------------
wall=$(( $(date +%s) - overall_start ))
echo ""
echo "=== 汇总 ==="
printf '%-32s %-5s %6s  %s\n' "测试" "结果" "耗时" "末行"
for r in "${results[@]}"; do
  IFS='|' read -r n s d l <<<"$r"
  printf '%-32s %-5s %4ss  %s\n' "$n" "$s" "$d" "$l"
done
echo ""
echo "通过: $total_pass / $((total_pass + total_fail))"
echo "总耗时(串行累加): ${total_time}s | 墙钟: ${wall}s"
echo "日志目录: $LOG_DIR"

[ "$total_fail" -eq 0 ]
