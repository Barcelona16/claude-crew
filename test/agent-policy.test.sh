#!/usr/bin/env bash
# test/agent-policy.test.sh — policy 模板注入测试(2026-10-16 重写)
# 旧版(2026-08-30)测 bin/crew 里的 resolve_policy_template/extract_policy_body 两个
# 函数 —— Week 3 重构(2ce8812)后该逻辑移进 bin/crew-launcher 的 spawn 流程(模板解析
# 内联、body 提取用 awk、经 <name>.policy_body 文件传给 --append-system-prompt)。
# 本版直接测【现行为】:各 policy 档 → policy_body 文件生成 + 正文内容正确 + 注入 argv。
# 覆盖 6 场景(对齐旧版意图):
#   1) policy=aggressive → body 含档位关键词(主脑档 / deploy-panel.sh / TaskCreate 台账)
#   2) policy=balanced   → body 非空且与 balanced 模板正文一致
#   3) policy=conservative → body 非空(模板存在即解析)
#   4) policy=none / 无  → 无 policy_body 文件(向后兼容,不注入)
#   5) policy=xxx(未知)→ 模板缺失 → 不注入 body、流程不挂(优雅降级)
#   6) 模板 frontmatter(--- 以上)不进 body(只注入正文)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CS="$REPO/bin/crew-session"
CL="$REPO/bin/crew-launcher"
TEMPLATES="$REPO/templates"

pass=0; fail=0; total=0
_ok(){ total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng(){ total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

export CREW_STATE="$(mktemp -d /tmp/agent-policy-test.XXXXXX)"
export CREW_HOME="$(mktemp -d /tmp/agent-policy-home.XXXXXX)"
mkdir -p "$CREW_HOME/backends" "$CREW_HOME/templates"
cp "$TEMPLATES"/*.md "$CREW_HOME/templates/" 2>/dev/null || true
# launcher backend 校验②:backends/mock.conf 必须存在,否则 spawn 拒起 → policy_body 不生成
printf 'BASE_URL=http://mock-gw\nMODEL=mock-model\nTOKEN=test\n' > "$CREW_HOME/backends/mock.conf"
export CREW_CLAUDE_BIN="/bin/echo"
trap 'rm -rf "$CREW_STATE" "$CREW_HOME"' EXIT

echo "=== agent-policy test suite(launcher 现行为)==="

# spawn 一次并返回 policy_body 文件路径(不存在则空)
gen_body() {
  local n="$1" pol="$2"
  CREW_SESSION_SKIP_VALIDATE=1 "$CS" set "$n" backend "mock" >/dev/null
  [ -n "$pol" ] && "$CS" set "$n" policy "$pol" >/dev/null
  CREW_LAUNCHER_KEEP=1 "$CL" spawn --name "$n" --mode fg >/dev/null 2>&1
  [ -f "$CREW_STATE/$n.policy_body" ] && echo "$CREW_STATE/$n.policy_body" || echo ""
}

# --- Case 1: aggressive 关键词 ---
echo "--- Case 1: aggressive → 主脑档关键词 ---"
body=$(gen_body "pol-aggr" "aggressive")
[ -n "$body" ] && _ok "aggressive body 生成" || { _ng "aggressive body 未生成" "spawn 后无文件"; body="/dev/null"; }
grep -q "主脑档" "$body" && _ok "aggressive 含 '主脑档'" || _ng "aggressive 缺 '主脑档'" "$body"
grep -q "deploy-panel.sh" "$body" && _ok "aggressive 含 'deploy-panel.sh'" || _ng "aggressive 缺 'deploy-panel.sh'" "$body"
grep -q "TaskCreate" "$body" && _ok "aggressive 含 'TaskCreate' 台账规则" || _ng "aggressive 缺 'TaskCreate'" "$body"

# --- Case 2: balanced 正文一致 ---
echo "--- Case 2: balanced 正文一致 ---"
body=$(gen_body "pol-bal" "balanced")
[ -n "$body" ] && _ok "balanced body 生成" || _ng "balanced body 未生成" "spawn 后无文件"
# 期望正文:模板 --- 之后的全部(与 launcher awk 逻辑一致)
want=$(awk '/^---$/{flag=1; next} flag' "$TEMPLATES/policy-balanced.md")
got=$(cat "$body" 2>/dev/null)
[ "$got" = "$want" ] && _ok "balanced 正文与模板 --- 后一致" || _ng "balanced 正文不一致" "$(echo "$got" | head -2)"

# --- Case 3: conservative ---
echo "--- Case 3: conservative ---"
body=$(gen_body "pol-cons" "conservative")
[ -n "$body" ] && [ -s "$body" ] && _ok "conservative body 非空" || _ng "conservative body 空" "无文件或空"

# --- Case 4: 无 policy → 不注入 ---
echo "--- Case 4: 无 policy → 无 policy_body ---"
body=$(gen_body "pol-none" "")
[ -z "$body" ] && _ok "无 policy 不生成 policy_body" || _ng "无 policy 仍生成 body" "$body"
body=$(gen_body "pol-none2" "none")
[ -z "$body" ] && _ok "policy=none 不生成 policy_body" || _ng "policy=none 仍生成 body" "$body"

# --- Case 5: 未知档 → 优雅降级 ---
echo "--- Case 5: 未知档 xxx ---"
body=$(gen_body "pol-xxx" "xxx")
[ -z "$body" ] && _ok "未知档无 body(模板缺失不注入,流程不挂)" || _ng "未知档生成了 body?" "$body"

# --- Case 6: frontmatter 不进 body ---
echo "--- Case 6: frontmatter 不进 body ---"
body=$(gen_body "pol-fm" "aggressive")
head -1 "$body" 2>/dev/null | grep -q "^# " \
  && _ng "body 首行是标题(frontmatter 泄入)" "$(head -1 "$body")" \
  || _ok "body 首行非模板标题(frontmatter 已剥)"

echo ""
if [ "$fail" = 0 ]; then
  echo "=== agent-policy.test.sh: $pass / $total pass ==="
  exit 0
else
  echo "=== agent-policy.test.sh: $pass / $total pass, $fail FAIL ==="
  exit 1
fi
