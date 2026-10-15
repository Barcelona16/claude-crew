#!/usr/bin/env bash
# test/crew-launcher.test.sh — crew-launcher 单测(2026-08-30 crew L 重构 Week 3)
# 覆盖 fg/tmux 两模式,policy 注入,sid resume/fresh,backend 加载

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CL="$SCRIPT_DIR/../bin/crew-launcher"
CS="$SCRIPT_DIR/../bin/crew-session"
CT="$SCRIPT_DIR/../bin/crew-tmux"

export CREW_STATE="/tmp/crew-launcher-test-$$"
export CREW_HOME="/tmp/crew-launcher-test-home-$$"
export CREW_CLAUDE_BIN="/bin/echo"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

TEST_PREFIX="test-lchr-$$"

setup() {
  rm -rf "$CREW_STATE" "$CREW_HOME"
  mkdir -p "$CREW_STATE" "$CREW_HOME/backends" "$CREW_HOME/templates"
  cat > "$CREW_HOME/backends/mock.conf" <<EOF
BASE_URL=http://localhost:9999
MODEL=mock-model
TOKEN=mocktoken
KEY_MODE=direct
EOF
  # copy policy templates
  cp /work/claude-crew/templates/*.md "$CREW_HOME/templates/" 2>/dev/null || true
}
teardown() {
  # kill tmux 测试 session
  for s in $(timeout 3 tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "$TEST_PREFIX" || true); do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
  rm -rf "$CREW_STATE" "$CREW_HOME"
  rm -f /tmp/crew-launch-${TEST_PREFIX}*.sh
}

trap teardown EXIT
setup

# --- Case 1: usage error ---
echo "--- Case 1: usage 错误 ---"
"$CL" 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "空命令 → exit 2" || _ng "空命令应 exit 2,实际 $ec" ""
"$CL" spawn 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "spawn 无 --name --mode → exit 2" || _ng "spawn 无参应 exit 2,实际 $ec" ""

# --- Case 2: 缺 backend 报错 ---
echo "--- Case 2: 缺 backend ---"
N="${TEST_PREFIX}-a"
out=$("$CL" spawn --name "$N" --mode fg 2>&1) || true
echo "$out" | grep -q "no backend" && _ok "缺 backend 报错" || _ng "应报 'no backend',实际:$out" ""

# --- Case 3: fg mode 起(mock claude 立退)+ sid 新建 ---
echo "--- Case 3: fg mode + sid 生成 ---"
N="${TEST_PREFIX}-b"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1)
echo "$out" | grep -q "session-id" && _ok "fg mode 输出含 --session-id(新 sid)" || _ng "fg 应输出 --session-id,实际:$out" ""
sid=$("$CS" get "$N" sid 2>/dev/null)
[ -n "$sid" ] && _ok "fg mode 后 sid 存 crew-session=$sid" || _ng "fg 后 sid 未存" ""
"$CS" has "$N" fgpid && _ok "fg mode 记 fgpid" || _ng "fg 未记 fgpid" ""
[ "$("$CS" get "$N" notmux)" = "1" ] && _ok "fg mode notmux=1" || _ng "fg mode notmux 应=1" ""

# --- Case 4: fg mode + 已有 sid → resume(不换新)---
echo "--- Case 4: fg 已有 sid → resume ---"
N="${TEST_PREFIX}-c"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" sid "existing-sid-xyz" >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1)
echo "$out" | grep -q -- "--resume existing-sid-xyz" && _ok "已有 sid → --resume 复用" || _ng "应 --resume 已有 sid,实际:$out" ""

# --- Case 5: --fresh 强制新 sid ---
echo "--- Case 5: --fresh 强制新 sid ---"
N="${TEST_PREFIX}-d"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" sid "should-not-resume" >/dev/null
out=$("$CL" spawn --name "$N" --mode fg --fresh 2>&1)
echo "$out" | grep -q "session-id" && _ok "--fresh 强制 --session-id 新" || _ng "--fresh 应新 sid,实际:$out" ""
echo "$out" | grep -q "should-not-resume" && _ng "--fresh 但仍 resume 老 sid" "" || _ok "--fresh 未 resume 老 sid"

# --- Case 6: policy 注入 → policy_body 文件 + launcher.sh 含 append-system-prompt ---
echo "--- Case 6: policy 注入 ---"
N="${TEST_PREFIX}-e"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" policy aggressive >/dev/null
# CREW_LAUNCHER_KEEP=1:默认 launcher 首行 self-unlink(fg exec 跑起来立即删自己),
# 读 /tmp launcher 文件必空 → 本 case 需保留文件才能 grep 内容。
CREW_LAUNCHER_KEEP=1 "$CL" spawn --name "$N" --mode fg >/dev/null 2>&1
[ -f "$CREW_STATE/$N.policy_body" ] && _ok "policy_body 文件生成" || _ng "policy_body 未生成" ""
[ -s "$CREW_STATE/$N.policy_body" ] && _ok "policy_body 非空" || _ng "policy_body 应有内容" ""
launcher="/tmp/crew-launch-$N.sh"
grep -q "append-system-prompt" "$launcher" && _ok "launcher.sh 含 --append-system-prompt" || _ng "launcher.sh 缺 --append-system-prompt" ""
grep -qE 'cat.*'"$N"'\.policy_body' "$launcher" && _ok "launcher.sh 用 \$(cat FILE) 展开 policy" || _ng "launcher.sh 展开方式不对" ""

# --- Case 7: launcher.sh 命令行短(A1 精神,不含长 policy body 原文)---
echo "--- Case 7: launcher.sh 短(policy 走 cat)---"
N="${TEST_PREFIX}-f"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" policy aggressive >/dev/null
CREW_LAUNCHER_KEEP=1 "$CL" spawn --name "$N" --mode fg >/dev/null 2>&1
launcher="/tmp/crew-launch-$N.sh"
sz=$(wc -c < "$launcher")
# 阈值放宽到 1200:新增 --settings + comm-protocol 注入(均走 $(cat FILE) 或路径,不含长原文)
# 后 launcher 略长,但仍远小于把 policy/comm 原文塞进命令行的体量。核心不变:长文本走 cat。
[ "$sz" -lt 1200 ] && _ok "launcher.sh 短($sz 字节 < 1200)" || _ng "launcher.sh 太长 $sz 字节" ""

# --- Case 8: unknown backend conf 报错 ---
echo "--- Case 8: 未知 backend conf ---"
N="${TEST_PREFIX}-g"
"$CS" set "$N" backend "nonexistent-backend" >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1) || true
echo "$out" | grep -q "not found" && _ok "未知 backend conf 报 not found" || _ng "未知 backend 应报,实际:$out" ""

# --- Case 9: mode 参数校验 ---
echo "--- Case 9: mode 参数校验 ---"
N="${TEST_PREFIX}-h"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode bogus 2>&1) || true
echo "$out" | grep -qE "mode.*必须|fg 或 tmux" && _ok "非法 mode 报错" || _ng "非法 mode 应报错,实际:$out" ""

# --- Case 10: tmux mode(真起 tmux,claude=/bin/echo 立退)---
echo "--- Case 10: tmux mode 起 tmux ---"
N="${TEST_PREFIX}-i"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode tmux 2>&1) || true
# 期望 crew-tmux ensure 后 send-keys 灌 launcher,tmux session 存在
resolved=$("$CT" resolve "$N")
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qFx "$resolved" && _ok "tmux mode 起 session '$resolved'" || _ng "tmux mode 未起 session,resolved=$resolved out=$out" ""
[ "$("$CS" get "$N" notmux)" = "0" ] && _ok "tmux mode notmux=0" || _ng "tmux mode notmux 应=0" ""

# --- Case 11: tmux mode + --task 灌初始任务(仅测流程不测 REPL)---
echo "--- Case 11: tmux mode --task ---"
N="${TEST_PREFIX}-j"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode tmux --task "hello world" 2>&1) || true
echo "$out" | grep -qE "ready" && _ok "tmux mode --task 完成 log 'ready'" || _ng "tmux mode --task 应 ready,实际:$out" ""

# ---- Case 12: sid_alive 4 场景(2026-09-01 §F 死 sid 自愈)---
echo "--- Case 12: sid_alive 4 场景 ---"
# source 出 sid_alive(纯 bash 函数,无副作用可直接引入)
source <(sed -n '/^sid_alive()/,/^}/p' "$CL")
JT="$(mktemp -d /tmp/sidalive.XXXXXX)"
ALIVE="$JT/a.jsonl"
printf '{"type":"mode","mode":"normal","sessionId":"alive-sid-1"}\n' > "$ALIVE"
sid_alive "$ALIVE" "alive-sid-1" && _ok "真 sid+首行匹配 → alive" || _ng "真 sid 应 alive" ""
sid_alive "$ALIVE" "wrong-sid" && _ng "首行 sessionId 不匹配应 dead" "" || _ok "sessionId 不匹配 → dead"
EMPTYF="$JT/empty.jsonl"; : > "$EMPTYF"
sid_alive "$EMPTYF" "any" && _ng "空文件应 dead" "" || _ok "空文件 → dead"
BADF="$JT/bad.jsonl"; echo "not-json-line" > "$BADF"
sid_alive "$BADF" "any" && _ng "坏 JSON 应 dead" "" || _ok "首行坏 JSON → dead"
rm -rf "$JT"

# ---- Case 13: build_claude_argv 死 sid 自愈(文件在但 sessionId 不对 → 归档+新 sid)---
echo "--- Case 13: 死 sid + 文件在 → 自愈 归档+新 sid ---"
N="${TEST_PREFIX}-dead"
DEAD_SID="deadbeef-0000-1111-2222-333344445555"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" sid "$DEAD_SID" >/dev/null
"$CS" del "$N" prev_sid >/dev/null 2>&1 || true
# cwd 目录里放一个"文件在但 sessionId 不匹配"的 jsonl
CWD="$PWD"
PROJDIR="$HOME/.claude/projects/$(printf '%s' "$CWD" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$PROJDIR"
printf '{"type":"mode","mode":"normal","sessionId":"someone-else-sid"}\n' > "$PROJDIR/$DEAD_SID.jsonl"
# source build_claude_argv 相关(gen_uuid/sid_alive/load_backend_conf 也带上)
source <(sed -n '/^gen_uuid()/,/^}/p; /^sid_alive()/,/^}/p; /^load_backend_conf()/,/^}/p; /^build_claude_argv()/,/^}/p' "$CL")
load_backend_conf "$N" >/dev/null 2>&1
argv_out=$(build_claude_argv "$N" 0 "$CWD" 2>/dev/null)
# 断言:1) argv 不含 --resume $DEAD_SID  2) prev_sid=$DEAD_SID  3) 新 sid 已生成 4) --session-id 新 sid
echo "$argv_out" | grep -qE "^--resume$" && next=$(echo "$argv_out" | grep -A1 "^--resume$" | tail -1) && [ "$next" = "$DEAD_SID" ] \
  && _ng "自愈失败:argv 仍 --resume $DEAD_SID" "" || _ok "argv 不再 --resume 死 sid"
prev=$("$CS" get "$N" prev_sid 2>/dev/null || echo "")
[ "$prev" = "$DEAD_SID" ] && _ok "prev_sid=死 sid 归档成功" || _ng "prev_sid=$prev(期望 $DEAD_SID)" ""
newsid=$("$CS" get "$N" sid 2>/dev/null || echo "")
[ -n "$newsid" ] && [ "$newsid" != "$DEAD_SID" ] && _ok "新 sid=$newsid(≠ 死 sid)" || _ng "新 sid 未生成或未换" ""
echo "$argv_out" | grep -qE "^--session-id$" \
  && next=$(echo "$argv_out" | grep -A1 "^--session-id$" | tail -1) \
  && [ "$next" = "$newsid" ] && _ok "argv 含 --session-id 新 sid" || _ng "argv 缺 --session-id 新 sid,实际:$argv_out" ""
rm -rf "$PROJDIR/$DEAD_SID.jsonl"

# ---- Case 14: 活 sid + 文件在且首行匹配 → --resume(自愈不误伤)---
echo "--- Case 14: 活 sid → --resume 不误伤 ---"
N="${TEST_PREFIX}-live"
LIVE_SID="livesid1-2222-3333-4444-555566667777"
"$CS" set "$N" backend mock >/dev/null
"$CS" set "$N" sid "$LIVE_SID" >/dev/null
printf '{"type":"mode","mode":"normal","sessionId":"%s"}\n' "$LIVE_SID" > "$PROJDIR/$LIVE_SID.jsonl"
argv_out=$(build_claude_argv "$N" 0 "$CWD" 2>/dev/null)
echo "$argv_out" | grep -qE "^--resume$" && next=$(echo "$argv_out" | grep -A1 "^--resume$" | tail -1) && [ "$next" = "$LIVE_SID" ] \
  && _ok "活 sid → --resume $LIVE_SID" || _ng "活 sid 应 --resume,实际:$argv_out" ""
# prev_sid 不该被改动(没触发自愈)
prev=$("$CS" get "$N" prev_sid 2>/dev/null || echo "")
[ -z "$prev" ] && _ok "活 sid 未触发自愈:prev_sid 未写" || _ng "活 sid 误触发自愈:prev_sid=$prev" ""

# ---- Case 15-18: _fallback_backend_key 众数 fallback(2026-09-02 P1)---
echo "--- Case 15: _fallback_backend_key 空 state → 空返回 ---"
FB_STATE="$CREW_STATE/fbstate15"; mkdir -p "$FB_STATE"
result=$(CREW_STATE="$FB_STATE" bash -c "source <(sed -n '/^_fallback_backend_key()/,/^}/p' '$CL'); _fallback_backend_key")
[ -z "$result" ] && _ok "空 state 返空(无候选)" || _ng "空 state 应返空,实际='$result'" ""

echo "--- Case 16: 众数统计 ---"
FB_STATE="$CREW_STATE/fbstate16"; mkdir -p "$FB_STATE"
# 3 个 newkey + 1 个 joycode
for n in a b c; do echo -n "newkey-4.7,Claude-Opus-4.7-joybuilder" > "$FB_STATE/$n.backend"; echo -n "newkey" > "$FB_STATE/$n.key"; done
echo -n "joycode-oai,GLM-5.3" > "$FB_STATE/d.backend"; echo -n "joycode" > "$FB_STATE/d.key"
result=$(CREW_STATE="$FB_STATE" bash -c "source <(sed -n '/^_fallback_backend_key()/,/^}/p' '$CL'); _fallback_backend_key")
[[ "$result" == *"newkey-4.7,Claude-Opus-4.7-joybuilder"* ]] && _ok "众数返 newkey 系(3:1)" || _ng "众数错: '$result'" ""
[[ "$result" == *newkey* ]] && _ok "key 众数返 newkey" || _ng "key 众数错" ""

echo "--- Case 17: env override 优先于众数 ---"
result=$(CREW_STATE="$FB_STATE" CREW_FALLBACK_MODEL="joycode-oai,GLM-5.3" CREW_FALLBACK_KEY="joycode" \
  bash -c "source <(sed -n '/^_fallback_backend_key()/,/^}/p' '$CL'); _fallback_backend_key")
[[ "$result" == "joycode-oai,GLM-5.3"$'\t'"joycode" ]] && _ok "env override 生效" || _ng "override 失败: '$result'" ""

echo "--- Case 18: load_backend_conf 空 backend 走 fallback + 写 state ---"
FB_STATE="$CREW_STATE/fbstate18"; mkdir -p "$FB_STATE"
# 造点众数数据
echo -n "newkey-4.7,Claude-Opus-4.7-joybuilder" > "$FB_STATE/existing.backend"
echo -n "newkey" > "$FB_STATE/existing.key"
# 目标 orphan 无 backend/key state
# source 出所有必要函数
result=$(CREW_STATE="$FB_STATE" CREW_HOME="$CREW_HOME" bash -c "
  source <(sed -n '/^_fallback_backend_key()/,/^}/p; /^load_backend_conf()/,/^}/p' '$CL')
  CS='$CS'
  load_backend_conf orphan 2>&1
  echo '---STATE---'
  cat '$FB_STATE/orphan.backend' 2>/dev/null
  echo ''
  cat '$FB_STATE/orphan.key' 2>/dev/null
")
echo "$result" | grep -q "fallback 众数" && _ok "load_backend_conf 空 backend 走 fallback 分支" || _ng "fallback 未触发" ""
echo "$result" | grep -q "newkey-4.7,Claude-Opus-4.7-joybuilder" && _ok "orphan.backend 被写入众数值" || _ng "state 未写: $result" ""
# ============================================================================
# 2026-09-03 官方 SendMessage 通信机制:settings.json 生成 + comm 注入 + --settings;
# gen_uuid mac fallback 修复(单 uuid)。fg 模式下 CREW_CLAUDE_BIN=/bin/echo 会把 launcher
# 里 exec 的 argv(含 --settings 等)打印到 stdout,与既有 Case 3 同套路用 out=$(...) 断言;
# --append-system-prompt "$(cat FILE)" 会被 shell 展开为文件内容,故用文件里的独特串断言注入。
# ============================================================================
HOOK_SH="$SCRIPT_DIR/../bin/crew-sendmsg-hook.sh"
STATUSLINE_SH="$SCRIPT_DIR/../bin/crew-statusline.sh"
COMM_MD="$SCRIPT_DIR/../templates/comm-protocol.md"

# ---- Case 19: settings.json 生成(合法 JSON + hooks + status line)----
echo "--- Case 19: settings.json 生成 ---"
N="${TEST_PREFIX}-set"
"$CS" set "$N" backend mock >/dev/null
"$CL" spawn --name "$N" --mode fg >/dev/null 2>&1
SF="$CREW_STATE/$N.settings"
if [ -x "$HOOK_SH" ] && command -v node >/dev/null 2>&1; then
  [ -f "$SF" ] && _ok "settings 文件生成" || _ng "settings 未生成" ""
  node -e "const s=JSON.parse(require('fs').readFileSync('$SF'));const h=s.hooks.PostToolUse[0];process.exit(h.matcher==='SendMessage'&&h.hooks[0].command.endsWith('crew-sendmsg-hook.sh')?0:1)" \
    && _ok "settings 合法 JSON:matcher=SendMessage + hook 指向 crew-sendmsg-hook.sh" || _ng "settings 内容不对:$(cat $SF 2>/dev/null)" ""
  node -e "const fs=require('fs'),path=require('path'),s=JSON.parse(fs.readFileSync('$SF'));process.exit(s.statusLine&&s.statusLine.type==='command'&&path.resolve(s.statusLine.command)===path.resolve('$STATUSLINE_SH')?0:1)" \
    && _ok "settings 注册 crew statusLine（显示实际模型/key）" || _ng "settings 缺 statusLine:$(cat $SF 2>/dev/null)" ""
else
  _ok "(跳过:无 node 或 hook 不可执行)"
  _ok "(跳过 settings 内容检查)"
  _ok "(跳过 statusLine 内容检查)"
fi

# ---- Case 19b: CCR session 只写入所需的 ANTHROPIC_AUTH_TOKEN ----
echo "--- Case 19b: CCR auth 环境最小化 ---"
N="${TEST_PREFIX}-auth"
"$CS" set "$N" backend mock >/dev/null
CREW_LAUNCHER_KEEP=1 "$CL" spawn --name "$N" --mode fg >/dev/null 2>&1
launcher="/tmp/crew-launch-$N.sh"
grep -qF 'ANTHROPIC_AUTH_TOKEN=mocktoken' "$launcher" \
  && _ok "CCR launcher 只写入所需的 ANTHROPIC_AUTH_TOKEN" \
  || _ng "launcher 缺 ANTHROPIC_AUTH_TOKEN" ""
grep -qF 'ANTHROPIC_API_KEY' "$launcher" \
  && _ng "launcher 不应再写入 ANTHROPIC_API_KEY" "" \
  || _ok "launcher 未写入 ANTHROPIC_API_KEY"

# ---- Case 20: launcher argv 含 --settings 指向该文件 ----
echo "--- Case 20: --settings 拼进 argv ---"
N="${TEST_PREFIX}-set2"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1)
SF="$CREW_STATE/$N.settings"
if [ -f "$SF" ]; then
  echo "$out" | grep -qF -- "--settings" && echo "$out" | grep -qF -- "$SF" \
    && _ok "argv 含 --settings 指向 $N.settings" || _ng "argv 缺 --settings:$out" ""
else
  _ok "(跳过:无 settings 文件)"
fi

# ---- Case 21: comm-protocol 注入(argv 里出现 comm 文件的独特串)----
echo "--- Case 21: comm-protocol 注入 ---"
N="${TEST_PREFIX}-comm"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1)
if [ -f "$COMM_MD" ]; then
  # comm-protocol.md 里有独特串 "同机会话间通信";--append-system-prompt "$(cat)" 展开后 echo 打印
  echo "$out" | grep -q '同机会话间通信' && _ok "argv 注入了 comm-protocol 内容" || _ng "未注入 comm(argv 无独特串)" ""
else
  _ok "(跳过:comm-protocol.md 不存在)"
fi

# ---- Case 22: gen_uuid 单 uuid(直接调 source 进来的函数)----
echo "--- Case 22: gen_uuid 单个小写 uuid ---"
u=$(gen_uuid)
lines=$(printf '%s' "$u" | grep -c '' )
echo "$u" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
  && _ok "gen_uuid → 单个小写标准 uuid:$u" || _ng "gen_uuid 格式不对(可能双 uuid):$u" ""
# 再验 fresh spawn 的 argv 里 --session-id 只出现一次
N="${TEST_PREFIX}-uuid"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode fg --fresh 2>&1)
sid_cnt=$(echo "$out" | grep -oc -- '--session-id' || echo 0)
[ "$sid_cnt" = 1 ] && _ok "fresh spawn argv --session-id 只 1 次" || _ng "--session-id 出现 $sid_cnt 次:$out" ""

# ---- Case 23: 无 node 降级(不生成 settings、不加 --settings、不崩)----
echo "--- Case 23: 无 node 降级 ---"
N="${TEST_PREFIX}-nonode"
"$CS" set "$N" backend mock >/dev/null
# 造不含 node 的临时 PATH(只放 /bin /usr/bin;若这些里也有 node 则退化,只验不崩)
rc=0
out=$(PATH="/usr/bin:/bin" "$CL" spawn --name "$N" --mode fg 2>&1) || rc=$?
SF="$CREW_STATE/$N.settings"
if ! PATH="/usr/bin:/bin" command -v node >/dev/null 2>&1; then
  [ ! -f "$SF" ] && _ok "无 node:未生成 settings" || _ng "无 node 却生成了 settings" ""
  echo "$out" | grep -qF -- "--settings" && _ng "无 node 却加了 --settings" "" || _ok "无 node:argv 不含 --settings"
else
  _ok "(环境标准路径有 node,降级 case 退化)"
  _ok "(退化:只验不崩)"
fi
echo "$out" | grep -q "session-id" && _ok "无 node:spawn 仍正常起(argv 有 session-id)" || _ng "无 node spawn 异常:$out rc=$rc" ""

# ---- Case 24: --name <会话名>(让 claude agentName = crew 会话名,SendMessage 寻址对齐)----
echo "--- Case 24: --name 注入 ---"
N="${TEST_PREFIX}-named"
"$CS" set "$N" backend mock >/dev/null
out=$("$CL" spawn --name "$N" --mode fg 2>&1)
echo "$out" | grep -qF -- "--name $N" && _ok "argv 含 --name $N(agentName=会话名)" || _ng "argv 缺 --name $N:$out" ""

# ---- Case 25: v8 P4 · launcher-argv.log dump 备排查身份错位坑(Agent-C 复审补) ----
echo "--- Case 25: launcher-argv.log 生成 ---"
N="${TEST_PREFIX}-arglog"
"$CS" set "$N" backend mock >/dev/null
rm -f "$CREW_STATE/launcher-argv.log"
"$CL" spawn --name "$N" --mode fg >/dev/null 2>&1 || true
if [ -f "$CREW_STATE/launcher-argv.log" ]; then
  # 断言含关键 argv:name= 匹配 + --session-id 关键字
  grep -q "name=$N " "$CREW_STATE/launcher-argv.log" && _ok "launcher-argv.log 存在 · 含 name=$N" || _ng "argv-log 缺 name=$N" ""
  grep -q -- "--session-id" "$CREW_STATE/launcher-argv.log" && _ok "argv-log 含 --session-id 关键 argv" || _ng "argv-log 缺 --session-id" ""
else
  _ng "launcher-argv.log 未生成" ""
fi

echo
echo "=== crew-launcher.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
