#!/usr/bin/env bash
# test/crew-ensure-selector.test.sh — 裸名新模型选中后的 selector 拼接(2026-10-27 400 事故根修)
#
# 事故:dsh_word 选中新发现的裸名模型 JD-DeepSeek-V4.1-Flash-1017(key=joycode),
# cmd_switch 拼出 "JD-DeepSeek-V4.1-Flash-1017-joycode/JD-DeepSeek-V4.1-Flash-1017"
# —— joycode 分支实际把模型塞进【已有 joycode-oai provider】,该拼法 provider 不存在
# → CCR ai-gateway 找不到 provider → 400 "All target providers failed"。
# 且 ensure_model_in_ccr 失败静默(模型也没进 map),launcher 对带 / 的 selector
# 无条件合成不校验,两层安全网全缺位。
#
# 本套测【selector 归一化函数 resolve_picked_model】+ ensure 失败可见 + launcher 守卫:
#   ① joycode key + 裸名新模型 → selector = joycode-oai/<model>(且模型已入 joycode-oai.models)
#   ② 普通 key(personal)+ 裸名新模型 → selector = <model>-<key>/<model>(新 provider)
#   ③ 全名 provider/model 原样透传,不 ensure
#   ④ joycode key + Claude 系模型 → joycode/<model>(anthropic provider),不是 joycode-oai
#   ⑤ ensure 失败(上游不可写)→ 调用方能拿到非零退出码,不再静默(防复发)
#   ⑥ ensure 成功后 selector 落地即可路由:provider 名存在于 map
#   ⑦ launcher 守卫:selector 的 provider 不在 map → 拒起(非无条件合成)
#   ⑧ launcher 守卫:provider 在 map → 正常合成
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW_BIN="$SCRIPT_DIR/../bin/crew"
LAUNCHER="$SCRIPT_DIR/../bin/crew-launcher"

pass=0; fail=0; total=0
_ok(){ total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng(){ total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

T="$(mktemp -d /tmp/crew-sel.XXXXXX)"
export CREW_HOME="$T/home"
export CREW_STATE="$T/state"
mkdir -p "$CREW_HOME" "$CREW_STATE"
trap 'rm -rf "$T"' EXIT

cat > "$CREW_HOME/keys.conf" <<EOF
personal=tok-8b04
joycode=joycode
EOF

# provider map:含 joycode/joycode-oai(与生产同形)
cat > "$T/providers.json" <<EOF
{
  "gateway": {"api_key": "sk-ccr-test"},
  "Providers": [
    {"name": "joycode", "api_base_url": "http://127.0.0.1:19999/v1/chat/completions",
     "api_key": "joycode", "models": ["Claude-Opus-4.8-hq"],
     "transformer": {"use": ["Anthropic"]}},
    {"name": "joycode-oai", "api_base_url": "http://127.0.0.1:19999/v1/chat/completions",
     "api_key": "joycode", "models": ["GLM-5.3"],
     "transformer": {"use": ["OpenAI"]}},
    {"name": "p-existing", "api_base_url": "http://127.0.0.1:19999/v1/chat/completions",
     "api_key": "tok-8b04", "models": ["model-A"],
     "transformer": {"use": ["OpenAI"]}}
  ]
}
EOF
export CCR_PROVIDER_MAP="$T/providers.json"

# 抠出被测函数(同 autodiscover 测试的提取法)
FUNCS="$T/funcs.sh"
awk '/^lookup_key\(\)|^ccr_models_for_key\(\)|^ensure_model_in_ccr\(\)|^resolve_picked_model\(\)|^ccr_apply_provider_map\(\)/{p=1} p{print} p&&/^}/{p=0}' "$CREW_BIN" > "$FUNCS"
if ! grep -q "resolve_picked_model" "$FUNCS"; then
  echo "FAIL: resolve_picked_model 未定义于 bin/crew(先实现再跑)"; exit 1
fi
# 桩
apply_calls="$T/apply.calls"; : > "$apply_calls"
cat >> "$FUNCS" <<EOF
ccr_apply_provider_map(){ echo "called" >> "$apply_calls"; }
log(){ :; }
die(){ echo "[die] \$*" >&2; exit 1; }
CREW_HOME="$CREW_HOME"
CCR_PROVIDER_MAP="$T/providers.json"
EOF

. "$FUNCS"

echo "=== resolve_picked_model 测试 ==="

# --- ① joycode + 裸名新模型 → joycode-oai/<model> ---
sel=$(resolve_picked_model joycode "JD-DeepSeek-V4.1-Flash-1017" 2>/dev/null)
[ "$sel" = "joycode-oai/JD-DeepSeek-V4.1-Flash-1017" ] \
  && _ok "① joycode+裸名 → joycode-oai/<model>" \
  || _ng "① joycode selector 错" "$sel"
inmap=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
print(any('JD-DeepSeek-V4.1-Flash-1017' in p.get('models',[]) for p in c['Providers'] if p['name']=='joycode-oai'))")
[ "$inmap" = "True" ] && _ok "① 模型已入 joycode-oai.models" || _ng "① 模型未入 map" "joycode-oai 缺该模型"

# --- ② personal + 裸名新模型 → <model>-<key>/<model> ---
sel2=$(resolve_picked_model personal "model-NEW-9" 2>/dev/null)
[ "$sel2" = "model-NEW-9-personal/model-NEW-9" ] \
  && _ok "② personal+裸名 → <model>-<key>/<model>" \
  || _ng "② personal selector 错" "$sel2"
inmap2=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
print(any(p.get('name')=='model-NEW-9-personal' for p in c['Providers']))")
[ "$inmap2" = "True" ] && _ok "② 新 provider 已建" || _ng "② provider 未建" "map 缺 model-NEW-9-personal"

# --- ③ 全名透传 ---
sel3=$(resolve_picked_model joycode "joycode-oai/GLM-5.3" 2>/dev/null)
[ "$sel3" = "joycode-oai/GLM-5.3" ] && _ok "③ 全名原样透传" || _ng "③ 全名被改" "$sel3"
ap=$(grep -c "called" "$apply_calls" 2>/dev/null | tr -d ' ')
[ "$ap" = "2" ] && _ok "③ 全名不触发额外 apply(2 次=①②)" || _ng "③ 多余 apply" "count=$ap"

# --- ④ joycode + Claude 系 → joycode/<model> ---
sel4=$(resolve_picked_model joycode "Claude-Opus-5-hq" 2>/dev/null)
[ "$sel4" = "joycode/Claude-Opus-5-hq" ] \
  && _ok "④ joycode+Claude 系 → joycode/<model>" \
  || _ng "④ Claude 系 selector 错" "$sel4"
inmap4=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
print(any('Claude-Opus-5-hq' in p.get('models',[]) for p in c['Providers'] if p['name']=='joycode'))")
[ "$inmap4" = "True" ] && _ok "④ Claude 模型入 joycode.models" || _ng "④ 未入 joycode" "缺模型"

# --- ⑤ ensure 失败可见(不静默)---
# 注入:providers.json 换成坏 JSON → node 解析崩 → ensure 返回非零
cp "$T/providers.json" "$T/providers.json.good"
printf 'not-json{' > "$T/providers.json"
sel5_rc=0
sel5=$(resolve_picked_model personal "model-UNWRITABLE" 2>/dev/null); sel5_rc=$?
cp "$T/providers.json.good" "$T/providers.json"
[ "$sel5_rc" -ne 0 ] && _ok "⑤ ensure 写失败 → 非零退出(可见)" || _ng "⑤ 失败仍静默 rc=0" "sel=$sel5 rc=$sel5_rc"

# --- ⑥ 落地 selector 的 provider 必在 map(1②④ 的 selector 反查)---
allin=$(python3 -c "
import json,sys
c=json.load(open('$T/providers.json'))
names={p['name'] for p in c['Providers']}
sels=['joycode-oai/JD-DeepSeek-V4.1-Flash-1017','model-NEW-9-personal/model-NEW-9','joycode/Claude-Opus-5-hq']
print(all(s.split('/',1)[0] in names for s in sels))")
[ "$allin" = "True" ] && _ok "⑥ 全部落地 selector 的 provider 都存在于 map" || _ng "⑥ 有 selector 指向不存在 provider" "查 map"

# --- ⑦⑧ launcher 守卫 ---
echo "=== launcher selector 守卫测试 ==="
# launcher 是可执行脚本(有主流程),不能整个 source —— 抠 load_backend_conf 函数体测。
# 函数内引用 $CS(crew-session),传桩路径;_fallback_backend_key 依赖 CREW_STATE(空,无影响)。
LFUNCS="$T/lfuncs.sh"
awk '/^load_backend_conf\(\)|^_fallback_backend_key\(\)/{p=1} p{print} p&&/^}/{p=0}' "$LAUNCHER" > "$LFUNCS"
grep -q "load_backend_conf" "$LFUNCS" || { echo "FAIL: load_backend_conf 未定义于 crew-launcher"; exit 1; }
CS_STUB="$T/cs-stub.sh"
# crew-session 桩:$1=子命令(get/set), $2=会话名, $3=字段;backend 由 STUB_BACKEND 环境变量给
cat > "$CS_STUB" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "get" ] && [ "$2" = "test-sess" ] && [ "$3" = "backend" ]; then
  echo "${STUB_BACKEND:-}"; exit 0
fi
echo ""; exit 0
EOF
chmod +x "$CS_STUB"

# ⑦ provider 不存在 → 拒起(退出非零,提示含修复指引)
# (CREW_STATE 指向空目录,让 _fallback_backend_key 读不到真实机器的 .backend 众数)
out7=$(CS="$CS_STUB" STUB_BACKEND="ghost-provider/some-model" CREW_HOME="$CREW_HOME" CREW_STATE="$CREW_STATE" CREW_CCR_CONFIG="$T/providers.json" \
  bash -c '. "'"$LFUNCS"'"; load_backend_conf "test-sess"' 2>&1); rc7=$?
[ "$rc7" -ne 0 ] && _ok "⑦ ghost provider selector → 拒起(rc=$rc7)" || _ng "⑦ 未拒起" "rc=$rc7 out=$out7"
echo "$out7" | grep -q "sync-models\|--model" && _ok "⑦ 拒起提示含可操作指引" || _ng "⑦ 提示缺指引" "$out7"

# ⑧ provider 存在 → 正常合成(via :8788)
out8=$(CS="$CS_STUB" STUB_BACKEND="joycode-oai/GLM-5.3" CREW_HOME="$CREW_HOME" CREW_STATE="$CREW_STATE" CREW_CCR_CONFIG="$T/providers.json" \
  bash -c '. "'"$LFUNCS"'"; load_backend_conf "test-sess"; echo "BK=$BK_MODEL|$BK_BASE_URL"' 2>&1)
echo "$out8" | grep -q "BK=joycode-oai/GLM-5.3|http://127.0.0.1:8788" \
  && _ok "⑧ 合法 selector 正常合成(:8788)" \
  || _ng "⑧ 合法 selector 被拦" "$out8"

echo
echo "== 结果: $pass/$total 通过, $fail 失败 =="
[ "$fail" -eq 0 ]
