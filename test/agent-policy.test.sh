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

# --- 结果汇总 ---
echo ""
echo "=== Total: $total | Pass: $pass | Fail: $fail ==="
rm -f "$tmp_funcs"

[ "$fail" -eq 0 ]
