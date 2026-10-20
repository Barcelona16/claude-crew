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

# 2026-10-20:隔离 CREW_HOME —— statusline 现在读 <CREW_HOME>/model-windows.conf 覆盖
# 真实窗口(与 launcher 注入同源)。不隔离的话真机 ~/.config 的 GLM-5.3=1M 会把
# 200k-based 期望值(155k left)全打挂。测试 conf 不写 glm → 走旧硬编码兜底,期望值不变。
# 同时清 TMUX + 隔离 CREW_STATE:否则真机 tmux 反查会把模型解析成当前 crew 会话的
# backend(如 GLM-5.3),display_name 里的测试模型名(Kimi/Qwen)永远测不到。
T="$(mktemp -d /tmp/crew-sl-test.XXXXXX)"
mkdir -p "$T/state"
trap 'rm -rf "$T"' EXIT
render() { printf '%s' "$1" | env -u TMUX -u CREW_MODEL -u CREW_BACKEND -u CREW_KEY CREW_SESSION=testsl CREW_HOME="$T" CREW_STATE="$T/state" CREW_STATUSLINE_MODEL="${SLM:-}" CREW_STATUSLINE_KEY="${SLK:-}" bash "$SL" 2>/dev/null; }

J_OK='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":22,"context_window_size":200000,"total_input_tokens":44705}}'
J_HIGH='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":95,"context_window_size":200000,"total_input_tokens":190000}}'
J_MID='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":80,"context_window_size":200000,"total_input_tokens":160000}}'
J_ZERO='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":0,"context_window_size":200000,"total_input_tokens":0}}'
J_NOCTX='{"session_id":"t","model":{"display_name":"GLM-5.3"},"workspace":{"current_dir":"/tmp"}}'
J_NOWIN='{"session_id":"t","model":{"display_name":"Qwen-Test"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42,"total_input_tokens":84000}}'

# ① 正常:ctx22%。GLM-5.3 在兜底表/conf 都命 1M → (955k left)(2026-10-20 对齐 d0fd695)
# 模型经 CREW_STATUSLINE_MODEL 注入(keyresolve 读真机 CCR,测试环境隔离不了它)
SLM="GLM-5.3-Local-joybuilder" SLM_KEY="personal"
out=$(render "$J_OK")
echo "$out" | grep -qF 'ctx22%' && echo "$out" | grep -qF '(955k left)' \
  && _ok "正常数据显 ctx22% + (955k left;GLM-5.3=1M)" || _ng "正常数据渲染: $out"
printf '%s' "$out" | grep -qF $'\033[32m' && _ok "22% 用绿色" || _ng "22% 未用绿色"

# ② 高占用:红(31)
out=$(render "$J_HIGH")
echo "$out" | grep -qF 'ctx95%' && echo "$out" | grep -qF '(810k left)' \
  && _ok "95% 显 ctx95% + (810k left;1M 窗口)" || _ng "95% 渲染: $out"
printf '%s' "$out" | grep -qF $'\033[31m' && _ok "95% 用红色" || _ng "95% 未用红色"

# ③ 黄档
out=$(render "$J_MID")
echo "$out" | grep -qF 'ctx80%' && echo "$out" | grep -qF '(840k left)' \
  && _ok "80% 显 ctx80% + (840k left;1M 窗口)" || _ng "80% 渲染: $out"
printf '%s' "$out" | grep -qF $'\033[33m' && _ok "80% 用黄色" || _ng "80% 未用黄色"

# ④ usage=0:ctx? 不显 0%
out=$(render "$J_ZERO")
echo "$out" | grep -q 'ctx?' && ! echo "$out" | grep -q 'ctx0%' \
  && _ok "usage=0 显 ctx? 而非骗人的 ctx0%" || _ng "usage=0 渲染: $out"

# ⑤ 无字段:整段省略
out=$(render "$J_NOCTX")
echo "$out" | grep -q 'ctx' && _ng "无 context_window 仍显 ctx: $out" || _ok "无字段时 ctx 段省略"

# ⑥ 空 stdin 不崩、有输出
out=$(printf '' | env -u TMUX -u CREW_MODEL -u CREW_BACKEND -u CREW_KEY CREW_SESSION=testsl CREW_HOME="$T" CREW_STATE="$T/state" bash "$SL" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -n "$out" ] && _ok "空 stdin: rc=0 且非空输出" || _ng "空 stdin: rc=$rc out='$out'"

# ⑦ 非零 usage 但无 window + 窗口表外模型 → 窗口真未知,只显 ctx42%
SLM="Qwen-Test" SLM_KEY=""
out=$(render "$J_NOWIN")
echo "$out" | grep -q 'ctx42%' && ! echo "$out" | grep -q 'left' \
  && _ok "无 window(表外模型)时只显 ctx42%(无 left)" || _ng "无 window 渲染: $out"

# ⑧ 旧符号 ◧ 不再出现
SLM="GLM-5.3-Local-joybuilder" SLM_KEY="personal"
out=$(render "$J_OK")
echo "$out" | grep -q '◧' && _ng "旧符号 ◧ 仍出现: $out" || _ok "旧符号 ◧ 已弃用"

# ⑨ model-windows.conf 生效(2026-10-20):conf 声明 glm-5.3=1000000 → left 按 1M 算
printf 'glm-5.3=1000000\n' > "$T/model-windows.conf"
out=$(render "$J_OK")
echo "$out" | grep -qF 'ctx22%' && echo "$out" | grep -qF '(955k left)' \
  && _ok "conf 窗口表生效:GLM-5.3 按 1M 算 (955k left)" || _ng "conf 窗口表未生效: $out"
# conf 改窗口(500k)→ 覆盖 CC 传的 200k(真实场景:上游窗口与假定不符)
printf 'glm-5.3=500000\n' > "$T/model-windows.conf"
out=$(render "$J_OK")
echo "$out" | grep -qF '(455k left)' \
  && _ok "conf 可改窗口:glm-5.3=500k → (455k left)" || _ng "conf 改窗口未生效: $out"
# conf 删掉 + 表外模型 → 用 CC 传的 window(Qwen 不在硬编码表,CC 传 200k 就信 200k)
rm -f "$T/model-windows.conf"
SLM="Kimi" SLM_KEY=""
printf '{"session_id":"t","model":{"display_name":"Kimi"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":22,"context_window_size":200000,"total_input_tokens":44705}}' \
  | env -u TMUX -u CREW_MODEL -u CREW_BACKEND -u CREW_KEY CREW_SESSION=testsl CREW_HOME="$T" CREW_STATE="$T/state" CREW_STATUSLINE_MODEL=Kimi bash "$SL" 2>/dev/null | grep -qF '(155k left)' \
  && _ok "conf 缺失回落:kimi 按 CC 传值 200k (155k left)" || _ng "conf 缺失回落失败"

echo ""
if [ "$fail" = 0 ]; then
  echo "=== crew-statusline.test.sh: $pass / $total pass ==="
  exit 0
else
  echo "=== crew-statusline.test.sh: $pass / $total pass, $fail FAIL ==="
  exit 1
fi
