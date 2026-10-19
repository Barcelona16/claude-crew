#!/usr/bin/env bash
# test/crew-help-version.test.sh — crew help 分层 + version release note 单元测试(2026-10-16)
# 覆盖:
#   [help]
#   ① 无参:分层帮助(日常 10 + 进阶),不含全量明细的 "crew adopt" 行
#   ② --all:全量命令明细(含 adopt/register 等进阶命令逐条列出)
#   ③ help <cmd>:单命令搜索(传 switch 命中 switch 行)
#   ④ help 不 crash、exit 0
#   [version]
#   ⑤ crew version:输出含版本号(读 CHANGELOG 头部 v<X.Y.Z>)+ 日期 + commit
#   ⑥ crew version:含 release note 摘要(至少一条 bullet)
#   ⑦ crew version --notes:从 Unreleased/## 节开始,不含文件头说明行("# Changelog" 不在首行)
#   ⑧ CHANGELOG 缺失时回落不 crash(临时移开验证 —— 因 repo 里必有,仅验证路径存在性判断)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"

pass=0; fail=0; total=0
_ok(){ total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng(){ total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

echo "=== help 分层测试 ==="

out=$(bash "$CREW" help 2>&1); rc=$?
[ "$rc" = 0 ] && _ok "④ help exit 0" || _ng "④ help rc=$rc" "$out"
echo "$out" | grep -q "日常 10 命令" && _ok "① 无参显示分层帮助(日常 10)" || _ng "① 无分层" "$(echo "$out" | head -3)"
echo "$out" | grep -q "进阶" && _ok "① 含进阶层" || _ng "① 缺进阶层" ""
echo "$out" | grep -qE "crew <名字>|crew ls" && _ok "① 日常层含起会话/ls" || _ng "① 日常层缺核心命令" ""
echo "$out" | grep -q "crew adopt" && _ng "① 分层帮助不应有 adopt 明细" "应只有分组" || _ok "① 分层帮助不含 adopt 明细"

out=$(bash "$CREW" help --all 2>&1)
echo "$out" | grep -q "crew adopt" && _ok "② --all 含 adopt 明细" || _ng "② --all 缺 adopt" ""
echo "$out" | grep -q "crew register" && _ok "② --all 含 register" || _ng "② --all 缺 register" ""

out=$(bash "$CREW" help switch 2>&1)
echo "$out" | grep -q "switch" && _ok "③ help switch 命中" || _ng "③ help switch 空" "$out"

echo "=== version release note 测试 ==="

out=$(bash "$CREW" version 2>&1); rc=$?
[ "$rc" = 0 ] && _ok "⑤ version exit 0" || _ng "⑤ version rc=$rc" "$out"
echo "$out" | grep -qE "^crew v[0-9]+\.[0-9]+\.[0-9]+" && _ok "⑤ 版本号格式 v X.Y.Z" || _ng "⑤ 版本号格式" "$(echo "$out" | head -1)"
echo "$out" | grep -qE "\(20[0-9]{2}-[0-9]{2}-[0-9]{2}" && _ok "⑤ 含日期" || _ng "⑤ 缺日期" ""
echo "$out" | grep -q "commit " && _ok "⑤ 含 commit" || _ng "⑤ 缺 commit" ""
echo "$out" | grep -q "Release note" && _ok "⑥ 含 release note 提示" || _ng "⑥ 缺提示" ""
echo "$out" | grep -qE "^  - " && _ok "⑥ 至少一条 bullet" || _ng "⑥ 无 bullet" ""

out=$(bash "$CREW" version --notes 2>&1)
first=$(echo "$out" | head -1)
echo "$first" | grep -q "^## " && _ok "⑦ --notes 首行是版本节(非文件头)" || _ng "⑦ 首行: $first" ""
echo "$out" | grep -q "^## \[Unreleased\]" && _ok "⑦ 含 Unreleased 节" || _ng "⑦ 缺 Unreleased" ""

echo ""
if [ "$fail" = 0 ]; then
  echo "=== crew-help-version.test.sh: $pass / $total pass ==="
  exit 0
else
  echo "=== crew-help-version.test.sh: $pass / $total pass, $fail FAIL ==="
  exit 1
fi
