#!/usr/bin/env bash
# claude-pid.test.sh — pane_pid → claude 子进程探测的跨平台测试(2026-10-20)
#
# 根因背景:空壳检测/cmd_ls/heartbeat 用 `ps --no-headers --ppid` 是 Linux-only 语法,
# macOS BSD ps 直接 illegal option rc=1 → claude_pid 恒空 → 每次启动都误判"空壳"kill 活会话,
# heartbeat 把所有 live 会话记 dead-repl → watcher autoheal 连环重起 → resume 混乱。
# 本测试守护探测函数在 Linux 语法不可用时必须走 macOS 兼容路径,且能容忍探测目标
# 不存在(空壳场景)与探测工具缺失(降级不误判 live)。
#
# 覆盖:
#   T1 真 macOS 进程树(sleep 伪装 claude 路径)→ 探测函数必须找到子进程 pid
#   T2 子进程退出后(真空壳)→ 探测必须返回空
#   T3 claude_pid_of 在 bin/crew 里存在且被空壳检测/cmd_ls 调用(源码级守护)
#   T4 heartbeat js 的 ps 调用带 macOS 兼容分支(源码级守护)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
# 重构后:claude_pid_of 整块在 common.sh;抠取/源码守护源指向该 lib
CLIB="$SCRIPT_DIR/../bin/crew.d/common.sh"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

echo "=== claude-pid 跨平台探测测试 ==="

# 探测函数从 bin/crew 里导出单测:source crew 太重(会跑 autoprune 等),
# 用 awk 抠函数体到临时文件再 source。
T="$(mktemp -d /tmp/crew-claudepid.XXXXXX)"
trap 'rm -rf "$T"' EXIT
FUNCS="$T/funcs.sh"

# 抠 claude_pid_of 函数(若存在;不存在则 T3 会失败并提示)
awk '/^claude_pid_of\(\)|^function claude_pid_of/{found=1} found{print; if(/^\}/) exit}' \
  "$CLIB" > "$FUNCS" 2>/dev/null || true

# ---- T1:macOS 真 --ppid 语法不可用 → 兼容路径必须能找到伪装的 claude 子进程 ----
if [ -s "$FUNCS" ] && grep -q "claude_pid_of" "$FUNCS"; then
  # shellcheck disable=SC1090
  source "$FUNCS"
  # 伪装:stub 脚本(shebang 进程 argv[0] 恒为 <path>/bin/claude,ps 可稳定匹配;
  # 不能 exec sleep — exec 会替换 argv,匹配窗口只有几 ms,测试 flaky)。
  FAKE_PARENT="$T/parent.sh"
  cat > "$FAKE_PARENT" <<'EOF'
#!/usr/bin/env bash
# 伪装 pane shell:fork 一个命令行含 /bin/claude 的子进程
"$@" &
echo $! > /tmp/crew-claudepid-test-child.pid
wait
EOF
  chmod +x "$FAKE_PARENT"
  mkdir -p "$T/bin"
  # stub 本体放 $T/bin/claude:名字直接匹配 /bin\/claude/,body 用短 sleep 保持进程活着
  # (探测是 ps 扫描,不依赖时长;2~3s 足够,本环境 SIGTERM 屏蔽用 kill -9 清理)
  printf '#!/usr/bin/env bash\nsleep 5\n' > "$T/bin/claude"
  chmod +x "$T/bin/claude"
  "$FAKE_PARENT" "$T/bin/claude" >/dev/null 2>&1 &
  FAKE_PARENT_PID=$!
  # 轮询探测:子进程 fork 与 ps 扫描存在毫秒级窗口,固定 sleep 是竞态源;
  # 轮询只改执行方式,断言仍是"探测必须找到 claude 子进程"。
  got_pid=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    got_pid="$(claude_pid_of "$FAKE_PARENT_PID" 2>/dev/null || true)"
    [ -n "$got_pid" ] && break
    sleep 0.1
  done
  if [ -n "$got_pid" ] && kill -0 "$got_pid" 2>/dev/null; then
    _ok "T1 兼容路径找到 claude 子进程 (pid=$got_pid)"
  else
    _ng "T1 探测失败:parent=$FAKE_PARENT_PID got='$got_pid'(macOS ps 兼容路径坏了)"
  fi
  # 清理(SIGTERM 在本环境屏蔽,一律 kill -9)
  [ -n "$got_pid" ] && kill -9 "$got_pid" 2>/dev/null
  kill -9 "$FAKE_PARENT_PID" 2>/dev/null
  wait "$FAKE_PARENT_PID" 2>/dev/null
  rm -f /tmp/crew-claudepid-test-child.pid

  # ---- T2:子进程死了(真空壳)→ 必须返回空 ----
  # 重新起一个 parent,子进程立刻退出
  QUICK="$T/quick.sh"
  cat > "$QUICK" <<'EOF'
#!/usr/bin/env bash
"$@" &
wait
EOF
  chmod +x "$QUICK"
  "$QUICK" "$T/bin/claude-quick" >/dev/null 2>&1 &  # 不存在的命令,子进程立即退出
  QPID=$!
  # 轮询等待子进程退出(固定 sleep 是竞态源;断言仍是"探测必须返回空")。
  got2=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    got2="$(claude_pid_of "$QPID" 2>/dev/null || true)"
    [ -z "$got2" ] && break
    sleep 0.1
  done
  if [ -z "$got2" ]; then
    _ok "T2 空壳(无活子进程)返回空"
  else
    _ng "T2 应返回空,得到 '$got2'"
  fi
  kill -9 "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
else
  _ng "T3 bin/crew 缺 claude_pid_of 函数(修复还没做)"
fi

# ---- T3:空壳检测与 cmd_ls 都必须走 claude_pid_of,且每个调用点有兼容回退(源码级守护) ----
# 判据:claude_pid_of 存在;函数体内含 macOS 兼容路径(ps -axo);bin/crew 里不再有
# 内联裸调用的 Linux-only ps(允许 claude_pid_of 函数体内部的快路径)。
FUNCS_BODY="$(awk '/^claude_pid_of\(\)/{found=1} found{print; if(/^\}/) exit}' "$CLIB" 2>/dev/null || true)"
if [ -n "$FUNCS_BODY" ] && printf '%s' "$FUNCS_BODY" | grep -q 'ps -axo pid,ppid'; then
  # 函数外的裸 --ppid 调用(cmd_ls / 空壳检测处)必须已替换
  # 提取"函数外"内容:旧 awk 的 `infn{print}` 会把函数体每行都打印出来,
  # 导致 OUTSIDE 实为全文件(函数内的 Linux 快路径必然命中 → 恒误报)。
  # 正确语义:跳过函数头/函数体/收尾 }(含跳过头行),只留函数外行。
  OUTSIDE="$(awk '/^claude_pid_of\(\)/{infn=1; next} /^\}/ && infn{infn=0; next} !infn' "$CLIB")"
  # 只查非注释行:common.sh 函数前的文档注释含历史 Linux 命令字样,注释非代码,
  # 判据语义是"函数外不得有裸代码级 Linux-only ps 调用"。
  if printf '%s\n' "$OUTSIDE" | grep -v '^[[:space:]]*#' | grep -q 'ps --no-headers -o pid,cmd --ppid'; then
    _ng "T3 claude_pid_of 存在但函数外仍有裸 Linux-only ps 调用"
  else
    _ok "T3 bin/crew 统一走 claude_pid_of(Linux 快路径 + macOS -axo 兼容)"
  fi
else
  _ng "T3 bin/crew 缺 claude_pid_of 或函数缺 macOS 兼容路径"
fi

# ---- T4:heartbeat js 的 ps 带 macOS 兼容(源码级守护) ----
HB="$SCRIPT_DIR/../bin/crew-heartbeat.js"
if grep -q "'-axo', 'pid,ppid,command'" "$HB" 2>/dev/null; then
  _ok "T4 crew-heartbeat.js ps 调用带 macOS 兼容分支(-axo 回退)"
else
  _ng "T4 crew-heartbeat.js 仍是 Linux-only '--ppid'"
fi

echo "=== claude-pid.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" = 0 ]
