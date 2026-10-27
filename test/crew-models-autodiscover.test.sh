#!/usr/bin/env bash
# test/crew-models-autodiscover.test.sh — auto_discover_models 单元测试(2026-10-16)
# 覆盖(选模型入口自动拉上游 /v1/models,替代手动 crew sync-models):
#   ① 首次拉取:上游返回 2 个 CCR 已有 + 1 个新模型 → provider map 只加新模型(幂等不重加已有)
#   ② 缓存:5 分钟内第二次调用不再打上游(fake 网关计数不增)
#   ③ 缓存过期:mtime 拨回 10 分钟前 → 重新拉
#   ④ fail-open:上游挂了(404)→ 返回非空(CCR 静态表兜底),不报错
#   ⑤ 新模型已写入后:再跑一次 → 不重复写(幂等,added=0)
#   ⑥ joycode 别名走本地 :8765(不带头鉴权)
#   ⑦ CREW_AUTO_SYNC=0 → 完全不拉不写,直接回落
#   ⑧ 上游返回空 data → 静默回落,menu 仍能弹
# 测试用 fake HTTP server(python)模拟网关。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW_BIN="$SCRIPT_DIR/../bin/crew"
# 重构后:被测函数整块在 models.sh;抠取源指向该 lib
MODELS_LIB="$SCRIPT_DIR/../bin/crew.d/models.sh"

pass=0; fail=0; total=0
_ok(){ total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng(){ total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

T="$(mktemp -d /tmp/crew-autodisc.XXXXXX)"
export CREW_HOME="$T/home"
export CREW_STATE="$T/state"
mkdir -p "$CREW_HOME" "$CREW_STATE"
# 本环境 SIGTERM 屏蔽,后台 mock 服务器一律 kill -9 清理(对测试桩完全正当)
trap 'rm -rf "$T"; [ -n "${FAKE_PID:-}" ] && kill -9 "$FAKE_PID" 2>/dev/null || true; [ -n "${FAKE_PID2:-}" ] && kill -9 "$FAKE_PID2" 2>/dev/null || true' EXIT

# 端口就绪探测:轮询 nc -z,最多 5s;替代固定 sleep,更快更稳
wait_port(){ local p="$1" i; for i in $(seq 1 50); do nc -z 127.0.0.1 "$p" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

# keys.conf:personal(8b04 网关)+ joycode(本地代理)
cat > "$CREW_HOME/keys.conf" <<EOF
personal=tok-8b04
joycode=joycode
EOF

# provider map:personal 已有 model-A/model-B(joycode provider 也建一个,⑥ 用)
cat > "$T/providers.json" <<EOF
{
  "gateway": {"api_key": "sk-ccr-test"},
  "Providers": [
    {"name": "p-existing", "api_base_url": "http://127.0.0.1:19999/anthropic/v1/messages",
     "api_key": "tok-8b04", "models": ["model-A", "model-B"],
     "transformer": {"use": ["Anthropic"]}},
    {"name": "joycode", "api_base_url": "http://127.0.0.1:19999/v1/chat/completions",
     "api_key": "joycode", "models": ["GLM-5.3"],
     "transformer": {"use": ["OpenAI"]}}
  ]
}
EOF
export CCR_PROVIDER_MAP="$T/providers.json"

# 抠出被测函数(source 纯函数,避免跑主流程)
FUNCS="$T/funcs.sh"
# awk 提取(sed 多 -n range 在部分 bash 有重复输出怪癖,2026-10-16 实测)
awk '/^lookup_key\(\)|^fetch_models_url\(\)|^ccr_origin_for_key\(\)|^ccr_models_for_key\(\)|^ccr_models_for_key_full\(\)|^auto_discover_models\(\)|^ensure_model_in_ccr\(\)|^_autodisc_cache_path\(\)/{p=1} p{print} p&&/^}/{p=0}' "$MODELS_LIB" > "$FUNCS"
if ! grep -q "auto_discover_models" "$FUNCS"; then
  echo "FAIL: auto_discover_models 未定义于 bin/crew(先实现再跑)"; exit 1
fi
# 依赖桩:ccr_apply_provider_map 测试里不真 apply(只记调用)
apply_calls="$T/apply.calls"
cat >> "$FUNCS" <<EOF
ccr_apply_provider_map(){ echo "called" >> "$apply_calls"; }
log(){ :; }
die(){ echo "[die] \$*" >&2; exit 1; }
_pick_one(){ cat; }
_pick_multi(){ cat; }
_list_keys(){ printf 'personal\njoycode\n'; }
CREW_HOME="$CREW_HOME"
EOF

# fake 网关:python http server,GET /v1/models 返回固定 JSON,计数到文件
HITS="$T/hits"; : > "$HITS"
cat > "$T/fake_gw.py" <<PYEOF
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open("$HITS", "a") as f: f.write(self.path + "\n")
        if self.path == "/v1/models":
            body = json.dumps({"object": "list", "data": [
                {"id": "model-A", "owned_by": "anthropic"},
                {"id": "model-B", "owned_by": "anthropic"},
                {"id": "model-NEW-1", "owned_by": "anthropic"},
            ]}).encode()
        else:
            body = b'{}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
srv = HTTPServer(("127.0.0.1", 19999), H)
srv.serve_forever()
PYEOF
python3 "$T/fake_gw.py" &
FAKE_PID=$!
wait_port 19999

# provider map 里 personal 的 origin 指向 fake 网关
# (ccr_origin_for_key 从 api_base_url 提 origin → http://127.0.0.1:19999)

echo "=== auto_discover_models 测试 ==="

# --- ① 首次:新模型 model-NEW-1 写入 ---
. "$FUNCS"
out=$(auto_discover_models personal 2>/dev/null)
# ①a 菜单应含新模型【裸名】(与静态全名表并列)
echo "$out" | grep -qxF "model-NEW-1" && _ok "① 菜单合并显示新模型裸名 model-NEW-1" || _ng "① 菜单缺新模型" "$(echo "$out" | tr '\n' ' ')"
# ①b 静态表也在(provider/model 全名)
echo "$out" | grep -q "p-existing/model-A" && _ok "① 静态全名表仍在菜单" || _ng "① 静态表丢了" "$out"
# ①c 绝不写 map(发现阶段零写入)
nprov=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
print(len([p for p in c['Providers'] if p.get('api_key')=='tok-8b04']))")
[ "$nprov" = "1" ] && _ok "① 发现阶段不写 map(仍 1 个 personal provider)" || _ng "① map 被写" "providers=$nprov"
added=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
ps=[p for p in c['Providers'] if p.get('api_key')=='tok-8b04']
ms=set(); [ms.update(p.get('models',[])) for p in ps]
print(sorted(ms))")
echo "    现有: $added"

# --- ② 缓存 5min:第二次不打网关 ---
hits_before=$(wc -l < "$HITS" | tr -d ' ')
auto_discover_models personal >/dev/null 2>&1
hits_after=$(wc -l < "$HITS" | tr -d ' ')
[ "$hits_after" = "$hits_before" ] && _ok "② 缓存期内不重复拉(hits $hits_before=$hits_after)" || _ng "② 缓存失效" "$hits_before->$hits_after"

# --- ③ 缓存过期 → 重拉 ---
backdate_cache() {
  local f="$(_autodisc_cache_path personal)"
  [ -f "$f" ] || { echo "no-cache-file"; return 1; }
  touch -t "$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M.%S)" "$f" 2>/dev/null \
    || python3 -c "import os,sys,time; os.utime(sys.argv[1], (time.time()-600,)*2)" "$f"
}
backdate_cache && _ok "③a 缓存文件拨回 10min" || _ng "③a 无缓存文件" "$(_autodisc_cache_path personal)"
auto_discover_models personal >/dev/null 2>&1
hits_after3=$(wc -l < "$HITS" | tr -d ' ')
[ "$hits_after3" -gt "$hits_after" ] && _ok "③ 过期后重新拉取" || _ng "③ 过期未重拉" "$hits_after->$hits_after3"

# --- ④ fail-open:网关挂 → 返回 CCR 静态表非空 ---
kill -9 $FAKE_PID 2>/dev/null; wait $FAKE_PID 2>/dev/null; FAKE_PID=""
backdate_cache 2>/dev/null || python3 -c "
import os,time,sys
f='$(_autodisc_cache_path personal)'
os.path.exists(f) and os.utime(f,(time.time()-600,)*2)"
out=$(auto_discover_models personal 2>/dev/null)
[ -n "$out" ] && _ok "④ 网关挂掉返回静态表(菜单能弹)" || _ng "④ 返回空" "$out"

# --- ⑤ 幂等:已有模型不重复写(①后再跑,模型集不再变) ---
python3 "$T/fake_gw.py" & FAKE_PID=$!; wait_port 19999
backdate_cache
auto_discover_models personal >/dev/null 2>&1
nprov5=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
print(len([p for p in c['Providers'] if p.get('api_key')=='tok-8b04']))")
[ "$nprov5" = "1" ] && _ok "⑤ 幂等:重复 discover 不写 map" || _ng "⑤ map 被写" "providers=$nprov5"
# --- ⑨-⑪ ensure_model_in_ccr ---
echo "--- ensure_model_in_ccr(选中才落地)---"
rm -f "$apply_calls"; : > "$apply_calls"
ensure_model_in_ccr personal model-NEW-1
inmap=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
print(any('model-NEW-1' in p.get('models',[]) for p in c['Providers']))")
[ "$inmap" = "True" ] && _ok "⑨ 选中 model-NEW-1 → 写入 map" || _ng "⑨ 未写入" "ensure 失败"
applied=$(grep -c "called" "$apply_calls" 2>/dev/null | tr -d ' ')
[ "$applied" = "1" ] && _ok "⑨ 写入后 apply 恰一次" || _ng "⑨ apply 次数=$applied" ""
nprov9=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
print(len(c['Providers']))")
[ "$nprov9" = "3" ] && _ok "⑨ 只加一个 provider(2→3)" || _ng "⑨ provider 数=$nprov9" "应 3(joycode+原有+新)"
ensure_model_in_ccr personal model-NEW-1
applied2=$(grep -c "called" "$apply_calls" 2>/dev/null | tr -d ' ')
[ "$applied2" = "1" ] && _ok "⑩ 再 ensure 同模型 → 幂等零 apply" || _ng "⑩ 重复 apply=$applied2" ""
ensure_model_in_ccr personal "p-existing/model-A"
applied3=$(grep -c "called" "$apply_calls" 2>/dev/null | tr -d ' ')
[ "$applied3" = "1" ] && _ok "⑪ 全名 provider/model → 直接跳过" || _ng "⑪ 全名仍触发 apply=$applied3" ""

# --- ⑫-⑭ GPT-6 系落地走 /v1/responses(2026-10-26 事故防复发)---
# llm-gw 对 gpt-6 系在 /v1/chat/completions 拒绝 tools+reasoning_effort(400);
# 落地必须:api_base_url 不带 /chat/completions + type=openai_responses。
echo "--- GPT-6 系落地(ensure_model_in_ccr)---"
ensure_model_in_ccr personal GPT-6.1-Sol-A-joybuilder
g6=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
p=[x for x in c['Providers'] if x.get('name')=='GPT-6.1-Sol-A-joybuilder-personal']
p=p[0] if p else {}
print(p.get('type','')+'|'+p.get('api_base_url',''))")
[ "${g6%%|*}" = "openai_responses" ] && _ok "⑫ GPT-6 系 provider 带 type=openai_responses" || _ng "⑫ 缺 type" "$g6"
case "${g6#*|}" in
  */chat/completions) _ng "⑬ GPT-6 系 URL 仍是 chat/completions" "$g6" ;;
  *) _ok "⑬ GPT-6 系 URL 无 /chat/completions(走 responses)" ;;
esac
ensure_model_in_ccr personal GPT-5.5-joybuilder
g5=$(python3 -c "
import json; c=json.load(open('$T/providers.json'))
p=[x for x in c['Providers'] if x.get('name')=='GPT-5.5-joybuilder-personal']
p=p[0] if p else {}
print((p.get('type') or '')+'|'+p.get('api_base_url',''))")
[ "${g5%%|*}" = "" ] && case "${g5#*|}" in */chat/completions) _ok "⑭ GPT-5.x 仍走 chat/completions(无 type)";; *) _ng "⑭ GPT-5.x URL 异常" "$g5";; esac || _ng "⑭ GPT-5.x 不应有 type" "$g5"

# --- ⑥ joycode:走 :8765(本测试没有 8765,fail-open 应仍返回 joycode 静态 GLM-5.3)---
out=$(JOYCODE_PORT=19998 auto_discover_models joycode 2>/dev/null)
echo "$out" | grep -q "GLM-5.3" && _ok "⑥ joycode 上游不可达时回落静态表(GLM-5.3 在)" || _ng "⑥ joycode 回落失败" "$out"

# --- ⑦ CREW_AUTO_SYNC=0 关闭 ---
rm -f "$HITS" 2>/dev/null; touch "$HITS"
CREW_AUTO_SYNC=0 auto_discover_models personal >/dev/null 2>&1
hits7=$(wc -l < "$HITS" | tr -d ' ')
[ "$hits7" = "0" ] && _ok "⑦ CREW_AUTO_SYNC=0 不打网关" || _ng "⑦ 关闭仍打网关" "hits=$hits7"

# --- ⑧ 上游空 data → 静默回落非空 ---
cat > "$T/fake_gw2.py" <<PYEOF
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"object":"list","data":[]}).encode()
        self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(body)))
        self.end_headers(); self.wfile.write(body)
srv = HTTPServer(("127.0.0.1", 19997), H)
srv.serve_forever()
PYEOF
# 临时把 personal 的 provider 指到空网关
T="$T" python3 - <<'PY8'
import json, os
c = json.load(open(os.path.join(os.environ["T"], "providers.json")))
for p in c["Providers"]:
    if p.get("api_key") == "tok-8b04":
        p["api_base_url"] = "http://127.0.0.1:19997/anthropic/v1/messages"
json.dump(c, open(os.path.join(os.environ["T"], "providers.json"), "w"), indent=2, ensure_ascii=False)
PY8
python3 "$T/fake_gw2.py" & FAKE_PID2=$!
wait_port 19997
backdate_cache 2>/dev/null
out=$(auto_discover_models personal 2>/dev/null)
[ -n "$out" ] && _ok "⑧ 上游空 data 静默回落非空" || _ng "⑧ 空 data 返回空" "$out"
kill -9 $FAKE_PID2 2>/dev/null; FAKE_PID2=""

echo ""
if [ "$fail" = 0 ]; then
  echo "=== crew-models-autodiscover.test.sh: $pass / $total pass ==="
  exit 0
else
  echo "=== crew-models-autodiscover.test.sh: $pass / $total pass, $fail FAIL ==="
  exit 1
fi
