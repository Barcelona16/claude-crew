#!/usr/bin/env bash
# crew-wake.test.sh — crew wake 单元测试(阶段 1,crew v2 §8.1)
# 覆盖:idle→成功 exit0 / busy→入 pending exit2 / 不存在→exit1 / tmux 挂→exit3 /
#      pending 去重 / drainNudge 指向 crew inbox / crew wake 命令入口透传 /
#      --no-queue 非 idle 不入队 / pane 700ms 前后变化→非 idle
#
# tmux 用 fake:PATH 前置假 tmux 脚本,按 FAKE_TMUX_MODE env 返回预设 list-sessions/capture-pane
# 输出,确定性覆盖各分支,不碰真会话/真 tmux server。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
WAKE="$SCRIPT_DIR/../bin/crew-wake.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-wake-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ---- fake tmux ----
# list-sessions → 打印 FAKE_TMUX_SESSIONS(换行分隔),空则模拟 no server(exit 1)
# capture-pane  → 打印 FAKE_TMUX_PANE 文件内容(测 idle/busy);两次调用可用 FAKE_TMUX_PANE2 模拟变化
# send-keys     → 记录到 $FAKE_TMUX_SENT,exit 0
# FAKE_TMUX_DEAD=1 → 所有子命令 exit 127 模拟 tmux 未装(用不可执行触发 error)
FAKE_BIN="$T/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tmux" <<'FAKE'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  list-sessions)
    if [ -n "${FAKE_TMUX_SESSIONS:-}" ]; then
      printf '%s\n' "$FAKE_TMUX_SESSIONS" | tr ',' '\n'
      exit 0
    else
      echo "no server running on /tmp/tmux-0/default" >&2
      exit 1
    fi
    ;;
  capture-pane)
    # 第二次 capture 若有 PANE2 就返它(模拟 700ms 后画面变化)
    cnt_file="${FAKE_TMUX_CAPCNT:-/dev/null}"
    n=0; [ -f "$cnt_file" ] && n=$(cat "$cnt_file")
    n=$((n+1)); [ "$cnt_file" != /dev/null ] && echo "$n" > "$cnt_file"
    if [ "$n" -ge 2 ] && [ -n "${FAKE_TMUX_PANE2:-}" ] && [ -f "${FAKE_TMUX_PANE2}" ]; then
      cat "${FAKE_TMUX_PANE2}"
    elif [ -n "${FAKE_TMUX_PANE:-}" ] && [ -f "${FAKE_TMUX_PANE}" ]; then
      cat "${FAKE_TMUX_PANE}"
    fi
    exit 0
    ;;
  send-keys)
    [ -n "${FAKE_TMUX_SENT:-}" ] && echo "$*" >> "$FAKE_TMUX_SENT"
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/tmux"

# idle pane 内容:含空 ❯ 输入框(用普通空格,paneIdle 正则 [\x20\xa0] 匹配)
IDLE_PANE="$T/idle.pane"
printf 'some output\n\n❯ \n' > "$IDLE_PANE"
# busy pane:无 ❯ 空框(正在跑)
BUSY_PANE="$T/busy.pane"
printf 'Running tool...\n✳ Thinking\n' > "$BUSY_PANE"

PEND="$T/pending.jsonl"
run_wake() { # run_wake <sessions> <pane> [extra args...]  → 设 fake env 跑 crew-wake.js,回显 exit
  local sessions="$1" pane="$2"; shift 2
  local capcnt="$T/capcnt.$$.$RANDOM"; : > "$capcnt"
  PATH="$FAKE_BIN:$PATH" \
    FAKE_TMUX_SESSIONS="$sessions" FAKE_TMUX_PANE="$pane" FAKE_TMUX_CAPCNT="$capcnt" \
    FAKE_TMUX_SENT="$T/sent.log" WAKE_PENDING_FILE="$PEND" \
    node "$WAKE" "$@" >/dev/null 2>&1
  echo $?
}

# --- Case 1: idle 会话 → 成功 exit 0 ---
echo "--- Case 1: idle → exit 0 ---"
: > "$T/sent.log"
rc=$(run_wake "work" "$IDLE_PANE" work)
[ "$rc" = 0 ] && _ok "idle 会话 wake exit 0" || _ng "exit=$rc(期望 0)"
grep -q "Enter" "$T/sent.log" && _ok "发了 Enter(双 Enter 注入)" || _ng "未发 send-keys"

# --- Case 2: busy 会话 → 入 pending exit 2 ---
echo "--- Case 2: busy → exit 2 + 入 pending ---"
rm -f "$PEND"
rc=$(run_wake "work" "$BUSY_PANE" work)
[ "$rc" = 2 ] && _ok "busy 会话 exit 2" || _ng "exit=$rc(期望 2)"
[ -f "$PEND" ] && node -e "const a=JSON.parse(require('fs').readFileSync('$PEND'));process.exit(a.length===1&&a[0].session==='work'?0:1)" \
  && _ok "nudge 入 pending 队列(1 条,session=work)" || _ng "pending 队列不对"

# --- Case 3: 不存在会话 → exit 1 ---
echo "--- Case 3: 不存在 → exit 1 ---"
rc=$(run_wake "other,crew-else" "$IDLE_PANE" work)
[ "$rc" = 1 ] && _ok "会话不存在 exit 1" || _ng "exit=$rc(期望 1)"

# --- Case 4: tmux server 未起(list-sessions 空)→ 会话不存在 exit 1 ---
echo "--- Case 4: tmux 无 server → exit 1(非会话)---"
capcnt="$T/cc4"; : > "$capcnt"
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="" FAKE_TMUX_PANE="$IDLE_PANE" \
  WAKE_PENDING_FILE="$PEND" node "$WAKE" work >/dev/null 2>&1; echo $?)
[ "$rc" = 1 ] && _ok "no server(list-sessions exit1)→ 判会话不存在 exit 1" || _ng "exit=$rc(期望 1)"

# --- Case 5: tmux 二进制缺失 → exit 3 ---
echo "--- Case 5: tmux 未装 → exit 3 ---"
EMPTY_BIN="$T/emptybin"; mkdir -p "$EMPTY_BIN"  # 无 tmux 的 PATH → spawnSync error
rc=$(PATH="$EMPTY_BIN" /work/node20/bin/node "$WAKE" work >/dev/null 2>&1; echo $?)
[ "$rc" = 3 ] && _ok "tmux 未装 exit 3" || _ng "exit=$rc(期望 3)"

# --- Case 6: pending 去重(同 session+note 只留一条)---
echo "--- Case 6: pending 去重 ---"
rm -f "$PEND"
run_wake "work" "$BUSY_PANE" work >/dev/null
run_wake "work" "$BUSY_PANE" work >/dev/null
cnt=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$PEND')).length)" 2>/dev/null || echo ERR)
[ "$cnt" = "1" ] && _ok "两次 busy wake 去重后 pending 仍 1 条" || _ng "pending=$cnt 条(期望 1)"

# --- Case 7: --no-queue 非 idle 不入队 ---
echo "--- Case 7: --no-queue busy 不入 pending ---"
rm -f "$PEND"
rc=$(run_wake "work" "$BUSY_PANE" work --no-queue)
[ "$rc" = 2 ] && _ok "--no-queue busy 仍 exit 2" || _ng "exit=$rc(期望 2)"
[ ! -f "$PEND" ] && _ok "--no-queue 不写 pending 文件" || { c=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$PEND')).length)" 2>/dev/null||echo 0); [ "$c" = 0 ] && _ok "--no-queue pending 空" || _ng "--no-queue 却入队 $c 条"; }

# --- Case 8: crew-<name> 前缀解析(原名不在,crew- 前缀在)---
echo "--- Case 8: crew- 前缀解析 ---"
: > "$T/sent.log"
rc=$(run_wake "crew-work,other" "$IDLE_PANE" work)
[ "$rc" = 0 ] && _ok "原名不在但 crew-work 在 → 命中 exit 0" || _ng "exit=$rc(期望 0)"

# --- Case 9: drainNudge 指向 crew inbox ---
echo "--- Case 9: drainNudge 措辞 ---"
note=$(node -e "console.log(require('$WAKE').drainNudge('foo'))")
echo "$note" | grep -q "crew inbox foo" && _ok "nudge 含 'crew inbox foo'" || _ng "nudge 未指向 crew inbox:$note"
echo "$note" | grep -q "秒回触发者" && _ok "nudge 含动作纪律(秒回执)" || _ng "nudge 缺动作纪律"

# --- Case 10: pane 700ms 前后变化 → 非 idle(exit 2)---
echo "--- Case 10: 快照前后变化 → 非 idle ---"
rm -f "$PEND"
capcnt="$T/cc10"; : > "$capcnt"
# 第一次 capture 返 IDLE(有 ❯),第二次返 PANE2(不同内容)→ s1!=s2 → 非 idle
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="work" FAKE_TMUX_PANE="$IDLE_PANE" \
  FAKE_TMUX_PANE2="$BUSY_PANE" FAKE_TMUX_CAPCNT="$capcnt" FAKE_TMUX_SENT="$T/sent.log" \
  WAKE_PENDING_FILE="$PEND" node "$WAKE" work >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && _ok "700ms 快照变化(spinner 动)→ 非 idle exit 2" || _ng "exit=$rc(期望 2)"

# --- Case 11: crew wake 命令入口透传 exit ---
echo "--- Case 11: crew wake 命令入口 ---"
capcnt="$T/cc11"; : > "$capcnt"
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="work" FAKE_TMUX_PANE="$IDLE_PANE" \
  FAKE_TMUX_CAPCNT="$capcnt" FAKE_TMUX_SENT="$T/sent.log" WAKE_PENDING_FILE="$PEND" \
  "$CREW" wake work >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && _ok "crew wake work 入口 exit 0" || _ng "crew wake exit=$rc(期望 0)"

# --- Case 12: tmux 双胞胎(work + crew-work 同存)→ crew-work 优先 ---
# 2026-09-01 修:之前裸名优先导致空壳劫持真 crew 会话。
echo "--- Case 12: 双胞胎 tmux → crew-<name> 优先 ---"
SENT12="$T/sent12.log"; : > "$SENT12"
# fake list-sessions 同时返 work + crew-work,wake 应命中 crew-work,send-keys -t crew-work
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="work,crew-work" FAKE_TMUX_PANE="$IDLE_PANE" \
  FAKE_TMUX_SENT="$SENT12" WAKE_PENDING_FILE="$PEND" node "$WAKE" work >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && _ok "双胞胎 wake exit 0" || _ng "exit=$rc(期望 0)"
# send-keys 应打到 crew-work,不打到裸名 work
grep -q -- "-t crew-work" "$SENT12" && ! grep -qE "^-t work[[:space:]]" "$SENT12" \
  && _ok "send-keys 命中 crew-work(裸名 work 未被劫持)" || _ng "打到错 pane: $(cat $SENT12)"

# --- Case 13: 只有裸名(无 crew- 前缀)→ 兜底到裸名 ---
echo "--- Case 13: 只有裸名 → 兜底 ---"
SENT13="$T/sent13.log"; : > "$SENT13"
rc=$(PATH="$FAKE_BIN:$PATH" FAKE_TMUX_SESSIONS="oldsess" FAKE_TMUX_PANE="$IDLE_PANE" \
  FAKE_TMUX_SENT="$SENT13" WAKE_PENDING_FILE="$PEND" node "$WAKE" oldsess >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && _ok "adopt 兼容:只有裸名也能命中 exit 0" || _ng "exit=$rc"
grep -qE "^-t oldsess[[:space:]]" "$SENT13" && _ok "send-keys 打到裸名 oldsess" || _ng "未命中裸名: $(cat $SENT13)"

echo
echo "=== crew-wake.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
