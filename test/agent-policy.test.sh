#!/usr/bin/env bash
# test/agent-policy.test.sh — AGENT_POLICY 分层派发单元测试(2026-08-30)
# 覆盖 6 个场景:
#   1) 缺省 none/未设置 → 无 --append-system-prompt(向后兼容 21 crew)
#   2) AGENT_POLICY=balanced → 有 --append-system-prompt 且内容匹配 balanced 模板
#   3) AGENT_POLICY=aggressive → 内容包含'主脑档'关键字
#   4) AGENT_POLICY=xxx(未知)→ 告警回落 none,无注入
#   5) CREW_POLICY_DISABLE=1 → 强制跳过即使 conf 声明了 policy
#   6) 模板缺失 → 告警但不 fail(其余流程继续)
#
# 用法:bash /work/claude-crew/test/agent-policy.test.sh
# 不跑 tmux/claude(mock 掉),只测 bin/crew 里的 resolve_policy_template + extract_policy_body 两个函数。
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin/crew"
TEMPLATES="$REPO/templates"

pass=0; fail=0; total=0
_ok(){ total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng(){ total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; echo "    $2"; }

# 引入 bin/crew 里的两个函数(source 而非跑主流程)。
# bin/crew 顶部有 set 和主 case,我们只 source 到函数定义结束,靠 sub-shell + return 兜底。
# 实现方式:抠出 resolve_policy_template 和 extract_policy_body 到临时文件 source。
tmp_funcs=$(mktemp)
# 抠函数:awk 匹配 'function_name(){' 到下一个空行前的 '}'(bash 函数结尾)
awk '/^resolve_policy_template\(\)\{$/,/^\}$/' "$BIN" > "$tmp_funcs"
awk '/^extract_policy_body\(\)\{$/,/^\}$/' "$BIN" >> "$tmp_funcs"
# 依赖变量
cat >> "$tmp_funcs" <<EOF
POLICY_DIR_USER="/tmp/nonexistent-crew-test-user-\$\$"
POLICY_DIR_REPO="$TEMPLATES"
log(){ echo "[log] \$*" >&2; }
EOF

# shellcheck disable=SC1090
. "$tmp_funcs"

echo "=== AGENT_POLICY test suite ==="

# --- Case 1: 缺省 none / 空 → 空输出 ---
echo "--- Case 1: default/empty → no injection ---"
out=$(resolve_policy_template "")
[ -z "$out" ] && _ok "empty AGENT_POLICY returns empty" || _ng "empty AGENT_POLICY" "expected empty, got: $out"

out=$(resolve_policy_template "none")
[ -z "$out" ] && _ok "AGENT_POLICY=none returns empty" || _ng "AGENT_POLICY=none" "expected empty, got: $out"

# --- Case 2: balanced → 模板文件路径且内容含关键字 ---
echo "--- Case 2: balanced → template resolved and body extracted ---"
out=$(resolve_policy_template "balanced")
if [ -n "$out" ] && [ -f "$out" ]; then
  _ok "balanced resolves to file: $out"
  body=$(extract_policy_body "$out")
  case "$body" in
    *"标准档"*) _ok "balanced body contains '标准档'";;
    *) _ng "balanced body missing '标准档'" "body head: $(echo "$body" | head -3)";;
  esac
  case "$body" in
    *"grep/find/rg 扫描 3+"*) _ok "balanced body contains 'grep 3+ 判据'";;
    *) _ng "balanced body missing 'grep 3+ 判据'" "";;
  esac
else
  _ng "balanced did not resolve" "out=$out"
fi

# --- Case 3: aggressive → 主脑档关键字 ---
echo "--- Case 3: aggressive → 主脑档 keywords ---"
out=$(resolve_policy_template "aggressive")
body=$(extract_policy_body "$out")
case "$body" in
  *"主脑档"*) _ok "aggressive body contains '主脑档'";;
  *) _ng "aggressive body missing '主脑档'" "body head: $(echo "$body" | head -3)";;
esac
case "$body" in
  *"deploy-panel.sh"*) _ok "aggressive body contains 'deploy-panel.sh'";;
  *) _ng "aggressive body missing 'deploy-panel.sh'" "";;
esac
case "$body" in
  *"TaskCreate"*) _ok "aggressive body contains 'TaskCreate' 台账规则";;
  *) _ng "aggressive body missing 'TaskCreate' 台账规则" "";;
esac

# --- Case 4: unknown value → 告警回落 none ---
echo "--- Case 4: unknown AGENT_POLICY → fallback none ---"
warn_out=$(resolve_policy_template "definitely-invalid-xxx" 2>&1 >/dev/null)
case "$warn_out" in
  *"WARN: unknown AGENT_POLICY"*) _ok "unknown value triggers WARN log";;
  *) _ng "unknown value missing WARN" "log: $warn_out";;
esac
out=$(resolve_policy_template "definitely-invalid-xxx" 2>/dev/null)
[ -z "$out" ] && _ok "unknown value returns empty (fallback none)" || _ng "unknown value did not fallback" "out=$out"

# --- Case 5: CREW_POLICY_DISABLE=1 → 全禁 ---
echo "--- Case 5: CREW_POLICY_DISABLE=1 → force skip ---"
out=$(CREW_POLICY_DISABLE=1 resolve_policy_template "balanced")
[ -z "$out" ] && _ok "CREW_POLICY_DISABLE=1 skips even with balanced" || _ng "DISABLE=1 did not skip" "out=$out"

out=$(CREW_POLICY_DISABLE=1 resolve_policy_template "aggressive")
[ -z "$out" ] && _ok "CREW_POLICY_DISABLE=1 skips aggressive too" || _ng "DISABLE=1 did not skip aggressive" "out=$out"

# --- Case 6: 模板缺失 → WARN 但不 fail ---
echo "--- Case 6: template file missing → WARN, empty output ---"
# 模拟:临时把 balanced 挪走
mv "$TEMPLATES/policy-balanced.md" "$TEMPLATES/policy-balanced.md.bak"
warn_out=$(resolve_policy_template "balanced" 2>&1 >/dev/null)
case "$warn_out" in
  *"no template found"*) _ok "missing template triggers WARN";;
  *) _ng "missing template missing WARN" "log: $warn_out";;
esac
out=$(resolve_policy_template "balanced" 2>/dev/null)
[ -z "$out" ] && _ok "missing template returns empty (not fail)" || _ng "missing template returned non-empty" "out=$out"
mv "$TEMPLATES/policy-balanced.md.bak" "$TEMPLATES/policy-balanced.md"

# --- Case 7: 反 crew 爆炸铁律 关键字必须存在(2026-08-30 用户拍板) ---
echo "--- Case 7: anti-crew-explosion rule keywords in templates ---"
body=$(extract_policy_body "$TEMPLATES/policy-balanced.md")
case "$body" in
  *"防 crew 循环创建"*|*"防止 crew"*|*"crew 爆炸"*) _ok "balanced contains anti-crew-explosion keyword";;
  *) _ng "balanced missing anti-crew-explosion rule" "body: $(echo "$body" | grep -i 'crew' | head -5)";;
esac
case "$body" in
  *"无权直接"*"crew"*) _ok "balanced denies direct crew create";;
  *) _ng "balanced missing 'no direct crew create' rule" "";;
esac

body=$(extract_policy_body "$TEMPLATES/policy-aggressive.md")
case "$body" in
  *"crew 创建授权"*|*"唯一有 crew create 授权"*) _ok "aggressive contains crew create authority rule";;
  *) _ng "aggressive missing crew create authority rule" "";;
esac

body=$(extract_policy_body "$TEMPLATES/policy-conservative.md")
case "$body" in
  *"无权直接"*"crew"*|*"防止 crew 循环创建"*) _ok "conservative denies direct crew create";;
  *) _ng "conservative missing 'no direct crew create' rule" "";;
esac

# --- Case 8: extract_policy_body 只输出 --- 之后的内容,不输出 frontmatter ---
echo "--- Case 8: extract_policy_body strips frontmatter ---"
body=$(extract_policy_body "$TEMPLATES/policy-balanced.md")
case "$body" in
  *"crew 启动时拼进"*) _ng "body still contains pre-'---' frontmatter" "首行:$(echo "$body" | head -1)";;
  *) _ok "body strips pre-'---' frontmatter" ;;
esac

# --- Case 9: A3 policy body 通过文件传递(agent-bridge workflow-code 2026-08-30 加) ---
# 目的:crew bin 里 policy 注入应写文件 + flags 里 --append-system-prompt "$(cat FILE)",
# 规避 tmux send-keys 传超长 markdown 的 quoting bug(D2/坑① 根因)。
# 断言 crew bin 里有 $CREW_STATE/<name>.policy_body 相关逻辑。
echo "--- Case 9: A3 body-file policy 注入(规避 send-keys quoting bug)---"
crew_src=$(cat "$(dirname "$0")/../bin/crew")
case "$crew_src" in
  *".policy_body"*) _ok "crew bin 有 .policy_body 文件传递逻辑";;
  *) _ng "crew bin 缺 .policy_body(A3 修复未落地)" "";;
esac
case "$crew_src" in
  *'--append-system-prompt \"\$(cat '*) _ok "flags 用 --append-system-prompt \"\$(cat FILE)\" 让 shell 展开";;
  *) _ng "flags 未用 shell 展开文件(仍是长命令行,坑① 未修)" "";;
esac
case "$crew_src" in
  *".policy_body\""*)
    # kill --purge 时也清 policy_body
    grep -q 'nm\.policy_body' "$(dirname "$0")/../bin/crew" && _ok "kill --purge 清 .policy_body 文件" || _ng "kill --purge 未清 .policy_body(悬挂文件)" "" ;;
  *) : ;;
esac

# --- Case 10: A1 start_cmd 也走文件传递(agent-bridge workflow-code 2026-08-30 加)---
# 目的:tmux send-keys 只传短命令 "bash /tmp/crew-launch-<name>.sh"(几十字节),彻底
# 规避 send-keys 传长命令 quoting bug。即使未来 flags 又变长(其他机制加),也不再怕。
echo "--- Case 10: A1 start_cmd 走 /tmp/crew-launch-<name>.sh 文件 ---"
case "$crew_src" in
  *"/tmp/crew-launch-\$name.sh"*|*'/tmp/crew-launch-$name.sh'*) _ok "crew bin 有 /tmp/crew-launch-<name>.sh launcher 文件路径";;
  *) _ng "crew bin 缺 launcher 文件路径" "";;
esac
case "$crew_src" in
  *'tmux send-keys -t "$tmux_s" -l "bash $_launcher_file"'*) _ok "tmux send-keys 只传短命令 bash <launcher>";;
  *) _ng "tmux send-keys 仍在传 start_cmd 长命令(A1 未落地)" "";;
esac
case "$crew_src" in
  *"chmod +x \"\$_launcher_file\""*) _ok "launcher 文件 chmod +x";;
  *) _ng "launcher 未 chmod +x" "";;
esac

# --- Case 11: B2 crew stop/kill 防自杀检测(agent-bridge workflow-code 2026-08-30 加)---
# 目的:crew stop/kill 前判 $TMUX 是否属目标 session,匹配就拒,避免 kill 掉自己的 host pane
# 导致命令终止、死循环(用户 09:07 事故根源之一)。
echo "--- Case 11: B2 crew stop/kill 防自杀 ---"
case "$crew_src" in
  *"B2 防自杀检测"*) _ok "crew bin 有 B2 防自杀检测注释(可追溯)";;
  *) _ng "crew bin 缺 B2 检测(未落地)" "";;
esac
# stop 分支应该有 TMUX 检测
grep -A 10 "^\s*stop)" "$(dirname "$0")/../bin/crew" | grep -q "CREW_STOP_ALLOW_SELF_KILL" && _ok "stop 分支有 CREW_STOP_ALLOW_SELF_KILL 逃生阀" || _ng "stop 分支缺 CREW_STOP_ALLOW_SELF_KILL 逃生阀" ""
# kill 分支应该有 TMUX 检测
grep -A 10 "^\s*kill)" "$(dirname "$0")/../bin/crew" | grep -q "CREW_KILL_ALLOW_SELF" && _ok "kill 分支有 CREW_KILL_ALLOW_SELF 逃生阀" || _ng "kill 分支缺 CREW_KILL_ALLOW_SELF 逃生阀" ""
# 匹配 refuse 消息
case "$crew_src" in
  *"refuse to stop"*) _ok "stop 拒消息含 'refuse to stop'";;
  *) _ng "stop 拒消息缺 refuse 关键字" "";;
esac
case "$crew_src" in
  *"refuse to kill"*) _ok "kill 拒消息含 'refuse to kill'";;
  *) _ng "kill 拒消息缺 refuse 关键字" "";;
esac

# --- Case 12: bug ③ 修 tmux 已存在时不 new-session,直接 send-keys(agent-bridge 11:42 派)---
# 场景:bootstrap 外层已建 tmux work → 内层 crew --no-tmux + pinned 判据走 tmux 分支 →
# 原来 tmux new-session 撞已存在失败,send-keys 打到空 pane,claude 不起 → 空 pane bug ③。
# 修:pinned+tmux 分支加 tmux has-session 检测,已存在就跳过 new-session,直接 send-keys。
echo "--- Case 12: bug ③ 修 tmux 已存在时跳过 new-session ---"
case "$crew_src" in
  *"tmux has-session -t \"\$tmux_s\""*) _ok "crew bin pinned tmux 分支加 has-session 检测";;
  *) _ng "crew bin pinned tmux 分支未加 has-session 检测(bug ③ 未修)" "";;
esac
grep -A 4 'if tmux has-session -t "\$tmux_s"' "$(dirname "$0")/../bin/crew" | grep -q "跳过 new-session" && _ok "已存在分支明确 log '跳过 new-session'" || _ng "无 log 跳过 new-session" ""
grep -A 6 'if tmux has-session -t "\$tmux_s"' "$(dirname "$0")/../bin/crew" | grep -q "tmux -u new-session -d -s" && _ok "不存在分支保留 new-session" || _ng "缺 else 分支(不存在时该起 new-session)" ""

# --- 结果汇总 ---
echo ""
echo "=== Total: $total | Pass: $pass | Fail: $fail ==="
rm -f "$tmp_funcs"

[ "$fail" -eq 0 ]
