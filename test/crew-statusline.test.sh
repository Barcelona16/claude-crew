#!/usr/bin/env bash
# crew-statusline.test.sh — statusline 渲染单元测试(2026-10-16)
# 覆盖 401 事故后恢复的上下文段 + 核心段渲染:
#   ① context_window 正常数据 → ctx<N>% (<K> left),绿(<75)
#   ② 高占用 95% → 红色档(>=90)
#   ③ 黄档 80%(75-89)
#   ④ usage 全 0(网关没回传,GLM-Local 老问题)→ 暗色 ctx?,不显骗人的 0%
#   ⑤ 无 context_window 字段 → 整段省略,其余段正常
#   ⑥ json 缺失/空 stdin → 不崩,有输出(铁律:绝不空白)
#   ⑦ 非零 usage 但无 window → 只显 ctx<N>%,无 (K left)
#   ⑧ ◧ 旧符号不再出现(终端字体不渲染的字符,2026-10-16 用户反馈弃用)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SL="$SCRIPT_DIR/../bin/crew-statusline.sh"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

render() { printf '%s' "$1" | CREW_SESSION=testsl bash "$SL" 2>/dev/null; }

J_OK='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":22,"context_window_size":200000,"total_input_tokens":44705}}'
J_HIGH='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":95,"context_window_size":200000,"total_input_tokens":190000}}'
J_MID='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":80,"context_window_size":200000,"total_input_tokens":160000}}'
J_ZERO='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":0,"context_window_size":200000,"total_input_tokens":0}}'
J_NOCTX='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"}}'
J_NOWIN='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42,"total_input_tokens":84000}}'

# ① 正常:ctx22% (155k left),绿色(32)
out=$(render "$J_OK")
echo "$out" | grep -qF 'ctx22%' && echo "$out" | grep -qF '(155k left)' \
  && _ok "正常数据显 ctx22% + (155k left)" || _ng "正常数据渲染: $out"
printf '%s' "$out" | grep -qF $'\033[32m' && _ok "22% 用绿色" || _ng "22% 未用绿色"

# ② 高占用:红(31)
out=$(render "$J_HIGH")
echo "$out" | grep -qF 'ctx95%' && echo "$out" | grep -qF '(10k left)' \
  && _ok "95% 显 ctx95% + (10k left)" || _ng "95% 渲染: $out"
printf '%s' "$out" | grep -qF $'\033[31m' && _ok "95% 用红色" || _ng "95% 未用红色"

# ③ 黄档
out=$(render "$J_MID")
echo "$out" | grep -qF 'ctx80%' && echo "$out" | grep -qF '(40k left)' \
  && _ok "80% 显 ctx80% + (40k left)" || _ng "80% 渲染: $out"
printf '%s' "$out" | grep -qF $'\033[33m' && _ok "80% 用黄色" || _ng "80% 未用黄色"

# ④ usage=0:ctx? 不显 0%
out=$(render "$J_ZERO")
echo "$out" | grep -q 'ctx?' && ! echo "$out" | grep -q 'ctx0%' \
  && _ok "usage=0 显 ctx? 而非骗人的 ctx0%" || _ng "usage=0 渲染: $out"

# ⑤ 无字段:整段省略
out=$(render "$J_NOCTX")
echo "$out" | grep -q 'ctx' && _ng "无 context_window 仍显 ctx: $out" || _ok "无字段时 ctx 段省略"

# ⑥ 空 stdin 不崩、有输出
out=$(printf '' | CREW_SESSION=testsl bash "$SL" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -n "$out" ] && _ok "空 stdin: rc=0 且非空输出" || _ng "空 stdin: rc=$rc out='$out'"

# ⑦ 有 usage 无 window:只显百分比
out=$(render "$J_NOWIN")
echo "$out" | grep -q 'ctx42%' && ! echo "$out" | grep -q 'left' \
  && _ok "无 window 时只显 ctx42%(无 left)" || _ng "无 window 渲染: $out"

# ⑧ 旧符号 ◧ 不再出现
out=$(render "$J_OK")
echo "$out" | grep -q '◧' && _ng "旧符号 ◧ 仍出现: $out" || _ok "旧符号 ◧ 已弃用"

echo ""
if [ "$fail" = 0 ]; then
  echo "=== crew-statusline.test.sh: $pass / $total pass ==="
  exit 0
else
  echo "=== crew-statusline.test.sh: $pass / $total pass, $fail FAIL ==="
  exit 1
fi
