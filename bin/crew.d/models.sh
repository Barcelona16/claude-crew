# crew.d/models.sh — CCR 模型/key 管理(自动发现、resolve、ensure、apply;models/keys/sync 命令)
# 某 key(别名)能路由的模型:CCR 里凡 api_key 匹配该别名【真值】的 provider,union 其 models[]。
# (v1 ccr_models_for_key 补回 —— v2 重构丢了)。别名→真值查 keys.conf;provider.api_key 存的
# 是真 token(joycode 的真值恰好也叫 joycode)。joycode 系还可从 :8765 /v1/models 实时拉(更全),
# 但 CCR models[] 已够用且不依赖代理在线,优先用它。
ccr_models_for_key() {
  local alias="$1" cfg="$CCR_PROVIDER_MAP"
  [ -f "$cfg" ] || return 0; command -v node >/dev/null 2>&1 || return 0
  # 别名 → 真值(keys.conf: alias=token);查不到就用别名本身当值(joycode 那种)
  local kv=""
  if [ -f "$CREW_HOME/keys.conf" ]; then
    kv=$(awk -F= -v a="$alias" '/^[[:space:]]*#/{next} {k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if(k==a){v=substr($0,index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}}' "$CREW_HOME/keys.conf")
  fi
  [ -z "$kv" ] && kv="$alias"
  KEY="$kv" node -e '
    const fs=require("fs");
    const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const ps=c.Providers||c.providers||[];
    const out=[];
    for(const p of ps){ if((p.api_key||p.apiKey)===process.env.KEY) for(const m of (p.models||[])) if(out.indexOf(m)<0) out.push(m); }
    process.stdout.write(out.join("\n"));
  ' "$cfg" 2>/dev/null
}

# 同上,但返回 CCR 3 的 "provider/model" selector(可直接当 backend / --model 用)。
# switch/pick 菜单用这个 —— 选中即得可用的 backend 值,无需再拼 provider。
ccr_models_for_key_full() {
  local alias="$1" cfg="$CCR_PROVIDER_MAP"
  [ -f "$cfg" ] || return 0; command -v node >/dev/null 2>&1 || return 0
  local kv=""
  if [ -f "$CREW_HOME/keys.conf" ]; then
    kv=$(awk -F= -v a="$alias" '/^[[:space:]]*#/{next} {k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if(k==a){v=substr($0,index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit}}' "$CREW_HOME/keys.conf")
  fi
  [ -z "$kv" ] && kv="$alias"
  KEY="$kv" node -e '
    const fs=require("fs");
    const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const ps=c.Providers||c.providers||[];
    const out=[];
    for(const p of ps){ if((p.api_key||p.apiKey)===process.env.KEY) for(const m of (p.models||[])){ var full=p.name+"/"+m; if(out.indexOf(full)<0) out.push(full); } }
    process.stdout.write(out.join("\n"));
  ' "$cfg" 2>/dev/null
}

# _autodisc_cache_path <alias>:自动发现的模型列表缓存(5min TTL,选模型菜单前静默拉上游用)
_autodisc_cache_path() { printf '%s/autodisc-%s.txt' "${TMPDIR:-/tmp}" "$1"; }

# auto_discover_models <alias> —— 选模型菜单的自动发现(2026-10-16,替代手动 crew sync-models):
# 只做「发现 + 合并显示」,【绝不写 map】:
#   返回 = CCR 静态表(provider/model 全名,可直接选)+ 上游有而 CCR 没有的新模型
#   (纯模型名,不带前缀 —— 选中后由 ensure_model_in_ccr 落地)。
# 数据源:该 key 上游的 /v1/models(joycode 本地 :8765,其余 provider 的 gateway origin),
# 缓存 5min(${TMPDIR}/autodisc-<alias>.txt);上游挂/空/CREW_AUTO_SYNC=0 → 只回静态表(fail-open)。
# 铁律:绝不因它报错/卡住选模型 —— 一切失败静默回落。
auto_discover_models() {
  local alias="$1"
  local static; static=$(ccr_models_for_key_full "$alias")
  [ "${CREW_AUTO_SYNC:-1}" = "0" ] && { printf '%s\n' "$static"; return 0; }
  local cache hit_ts now
  cache=$(_autodisc_cache_path "$alias")
  now=$(date +%s 2>/dev/null || echo 0)
  local remote=""
  if [ -f "$cache" ]; then
    hit_ts=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0)
    case "$hit_ts" in ''|*[!0-9]*) hit_ts=0;; esac
    if [ "$now" != 0 ] && [ $(( now - hit_ts )) -lt 300 ]; then
      remote=$(cat "$cache" 2>/dev/null)
    fi
  fi
  if [ -z "$remote" ]; then
    local kv is_jc=0 base
    kv=$(lookup_key "$alias")
    [ "$kv" = joycode ] && is_jc=1
    if [ "$is_jc" = 1 ]; then
      remote=$(fetch_models_url "http://127.0.0.1:${JOYCODE_PORT:-8765}/v1/models" "")
    else
      base=$(ccr_origin_for_key "$kv")
      [ -n "$base" ] && remote=$(fetch_models_url "${base%/}/v1/models" "$kv")
    fi
    [ -n "$remote" ] && printf '%s\n' "$remote" > "$cache" 2>/dev/null || true
  fi
  [ -z "$remote" ] && { printf '%s\n' "$static"; return 0; }
  # 合并:静态全名表 + 上游新模型(CCR 没有的裸名 —— 选中后 ensure_model_in_ccr 落地)
  local have new
  have=$(ccr_models_for_key "$alias")
  new=$(HAVE="$have" awk -F'\t' '
    BEGIN{ n=split(ENVIRON["HAVE"],h,"\n"); for(i=1;i<=n;i++) if(h[i]!="") seen[h[i]]=1 }
    NF{ id=$2; if(id!="" && !(id in seen) && !(id in done)){ done[id]=1; print id } }
  ' <<EOF
$remote
EOF
)
  printf '%s\n' "$static"
  [ -n "$new" ] && printf '%s\n' "$new"
}

# ensure_model_in_ccr <alias> <model> —— 用户从菜单选中【新模型】后落地(2026-10-16):
# 把这一个模型写进 provider map(与 sync-models 同规则)+ ccr_apply_provider_map。
# 幂等:CCR 已有该模型(或选的是 provider/model 全名)→ 零写入零 apply。
# 2026-10-27(400 事故根修):失败【不再静默】—— 写不进 map 或模型名非法时回非零,
# 调用方(resolve_picked_model / 菜单流程)据此提示,不再让"模型没进 CCR 但会话照起"
# 的带病状态发生(事故:dsh_word 选 JD-DeepSeek-V4.1-Flash-1017 后 400 All target
# providers failed)。joycode 分支把模型塞进【已有 joycode/joycode-oai provider】,
# 普通分支新建 <model>-<alias> provider —— 两种 selector 拼法不同,由
# resolve_picked_model 统一归一,不再由调用点各拼各的。
ensure_model_in_ccr() {
  local alias="$1" model="$2"
  [ -n "$alias" ] && [ -n "$model" ] || return 0
  case "$model" in */*) return 0 ;; esac   # 带 provider/ 前缀 = CCR 已有
  local have; have=$(ccr_models_for_key "$alias")
  printf '%s\n' "$have" | grep -qxF "$model" && return 0   # 已在(幂等)
  local kv is_jc=0 base ccrcfg="$CCR_PROVIDER_MAP" added
  kv=$(lookup_key "$alias")
  [ "$kv" = joycode ] && is_jc=1
  [ "$is_jc" = 1 ] || base=$(ccr_origin_for_key "$kv")
  [ -f "$ccrcfg" ] || return 0
  # 2026-10-27:set -u 下 joycode 分支 base 永不赋值 → 传空串而不是裸 $base
  # (此前 `BASE="$base"` 在 set -u 直接 unbound variable 崩,node 永远跑不到,
  #  模型从未写进 map → 会话 400。这就是 10-27 事故里 ensure 静默失败的根因)
  added=$(CCR_CFG="$ccrcfg" ALIAS="$alias" KV="$kv" ISJC="$is_jc" BASE="${base:-}" \
    PICK="$model" node -e '
    const fs=require("fs");
    const cfg=JSON.parse(fs.readFileSync(process.env.CCR_CFG,"utf8"));
    cfg.Providers=cfg.Providers||[];
    const pick=(process.env.PICK||"").split("\n").map(s=>s.trim()).filter(Boolean);
    const isjc=process.env.ISJC==="1", alias=process.env.ALIAS, kv=process.env.KV,
          base=(process.env.BASE||"").replace(/\/$/,"");
    // 无 owner 信息(REMOTE 空):claude 系名判 anthropic,其余 openai(与上游 owned_by 对齐的经验规则)
    const isAnthropic=m=> isjc ? /claude/i.test(m) : /claude/i.test(m);
    // GPT-6 系(llm-gw 2026-10-26 实测)在 /v1/chat/completions 拒绝 tools+reasoning_effort 组合
    // (gpt-6-sol/gpt-6.1-sol 全中;gpt-5.x 不受影响),必须走 /v1/responses。
    // CCR 判定 adapter 时显式 type 字段优先于 URL 推断(router-plugin jc()),URL 后缀它不认 —— 只改 URL 没用。
    const needsResponses=m=>/^gpt-6/i.test(m)&&!/gpt-6\.1-sol-pro-fast/i.test(m);
    const mkProvider=(m,anth)=>{
      const p={ name:m+"-"+alias,
        api_base_url: base + (anth?"/anthropic/v1/messages":needsResponses(m)?"/v1":"/v1/chat/completions"),
        api_key: kv, models:[m], transformer:{ use:[anth?"Anthropic":"OpenAI"] } };
      if(!anth&&needsResponses(m)) p.type="openai_responses";
      return p;
    };
    let added=0;
    if(isjc){
      const pj=cfg.Providers.find(p=>p.name==="joycode"), po=cfg.Providers.find(p=>p.name==="joycode-oai");
      for(const m of pick){
        const tgt=isAnthropic(m)?pj:po;
        if(!tgt) continue;
        tgt.models=tgt.models||[]; if(!tgt.models.includes(m)){ tgt.models.push(m); added++; }
      }
    } else {
      for(const m of pick){
        const anth=isAnthropic(m); const pname=m+"-"+alias;
        if(cfg.Providers.some(p=>p.name===pname)) continue;
        cfg.Providers.push(mkProvider(m,anth));
        added++;
      }
    }
    if(added===0) process.exit(1);   // 全 skip → 调用方不 apply
    const tmp=process.env.CCR_CFG+".tmp";
    fs.writeFileSync(tmp, JSON.stringify(cfg,null,2)); fs.renameSync(tmp, process.env.CCR_CFG);
    process.stdout.write(String(added));
  ' 2>/dev/null) || added=0
  if [ "${added:-0}" -gt 0 ] 2>/dev/null; then
    ccr_apply_provider_map >/dev/null 2>&1 || { log "ensure: apply 失败(模型已写 map 但未生效,跑 crew sync-models --key $alias)"; return 1; }
    log "auto-sync: '$model' 已写进 CCR 并 apply"
  fi
  # 2026-10-27:落地后校验模型确在 map(防 node 写坏/半写)。fail-loud,不静默。
  local verify
  verify=$(ccr_models_for_key "$alias")
  if ! printf '%s\n' "$verify" | grep -qxF "$model"; then
    log "ensure: '$model' 落地校验失败(map 里没有;跑 crew sync-models --key $alias)"
    return 1
  fi
  return 0
}

# resolve_picked_model <alias> <picked> —— 菜单选中值 → 可路由 CCR 3 selector(2026-10-27)。
# 选中裸名新模型时:先 ensure_model_in_ccr 落地,再按【该模型实际落在哪个 provider】拼 selector:
#   joycode key:模型塞进已有 joycode(Claude 系)/ joycode-oai(其余)→ selector=joycode[-oai]/<model>
#   其他 key  :新建 <model>-<alias> provider              → selector=<model>-<alias>/<model>
# 返回 selector 到 stdout;ensure 失败 → 回非零(调用方提示,不吞错)。
# 全名(provider/model)选中 → 原样输出,零副作用。
# 背景:此前调用点统一拼 "$model-$key/$model",对 joycode 分支拼出不存在的 provider
# → CCR 400 "All target providers failed"(2026-10-27 dsh_word 事故)。
resolve_picked_model() {
  local alias="$1" picked="$2"
  case "$picked" in
    */*) printf '%s\n' "$picked"; return 0 ;;
  esac
  [ -n "$picked" ] || return 1
  local before after added
  before=$(ccr_models_for_key "$alias")
  ensure_model_in_ccr "$alias" "$picked" || return 1
  after=$(ccr_models_for_key "$alias")
  # 落地后反查 provider:找出现在 models 里含它的(优先这次新增的)
  local sel=""
  # 2026-10-27(二修):必须显式传 CREW_HOME —— 此前只传 KEY/PICK/CCR_PROVIDER_MAP,
  # node 里 process.env.CREW_HOME 为 undefined → keys.conf 读不到 → kv 回落成模型名
  # → 反查 api_key===模型名 永不命中 → 恒报"落地后仍找不到 provider"、会话起不来。
  # (ensure 里写 provider 用的是 shell 侧 lookup_key,所以模型确实进了 map,只是反查瞎了)
  sel=$(KEY="$alias" PICK="$picked" CREW_HOME="$CREW_HOME" CCR_PROVIDER_MAP="$CCR_PROVIDER_MAP" node -e '
    const fs=require("fs");
    const c=JSON.parse(fs.readFileSync(process.env.CCR_PROVIDER_MAP,"utf8"));
    const pick=process.env.PICK, ps=c.Providers||c.providers||[];
    // keys.conf 真值(ensure 写 provider 用的 api_key;joycode 真值恰好是 joycode)
    let kv=pick; try{ const kc=fs.readFileSync(process.env.CREW_HOME+"/keys.conf","utf8");
      for(const ln of kc.split("\n")){ const i=ln.indexOf("=");
        if(i>0 && ln.slice(0,i).trim()===process.env.KEY){ kv=ln.slice(i+1).trim(); break; } } }catch(_){}
    let sel="";
    // 1) 优先:api_key===该 key 真值且含模型的 provider(用户自己的)
    for(const p of ps){ if((p.api_key||p.apiKey)===kv && (p.models||[]).indexOf(pick)>=0){ sel=p.name; break; } }
    // 2) 兜底:按模型名找所有含它的 provider——唯一则选它(模型可能落在别的 key 的池,
    //    如 DeepSeek-V4-Pro 在 joycode-oai 而用户用 personal key 选,2026-10-27 实测)。
    if(!sel){ const all=ps.filter(p=>(p.models||[]).indexOf(pick)>=0);
      if(all.length===1) sel=all[0].name;
      else if(all.length>1) sel=all[0].name; }   // 多个取第一个(能路由即可)
    if(sel) process.stdout.write(sel);
  ' 2>/dev/null)
  [ -n "$sel" ] || { log "resolve: '$picked' 落地后仍找不到 provider(异常,查 map)"; return 1; }
  printf '%s/%s\n' "$sel" "$picked"
}


# 别名 → 真值(keys.conf: alias=token)。查不到回显别名本身。sync-models / 反查共用。
lookup_key() {
  local alias="$1"
  [ -f "$CREW_HOME/keys.conf" ] || { echo "$alias"; return; }
  local v
  v=$(awk -F= -v a="$alias" '/^[[:space:]]*#/{next} {k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",k); if(k==a){vv=substr($0,index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",vv); print vv; exit}}' "$CREW_HOME/keys.conf")
  [ -n "$v" ] && echo "$v" || echo "$alias"
}

# GET 一个 OpenAI 风格 /v1/models,输出 "owned_by<TAB>id" 每行。curl→python3→静默空。(移植 v1)
fetch_models_url() {
  local url="$1" tok="${2:-}" raw=""
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$tok" ]; then raw=$(curl -fsS -m 12 -H "Authorization: Bearer $tok" "$url" 2>/dev/null)
    else raw=$(curl -fsS -m 12 "$url" 2>/dev/null); fi
  elif command -v python3 >/dev/null 2>&1; then
    raw=$(URL="$url" TOK="$tok" python3 -c '
import os,sys,urllib.request
r=urllib.request.Request(os.environ["URL"])
if os.environ.get("TOK"): r.add_header("Authorization","Bearer "+os.environ["TOK"])
sys.stdout.write(urllib.request.urlopen(r,timeout=12).read().decode())' 2>/dev/null)
  fi
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      let d; try{ d=JSON.parse(s); }catch(e){ return; }
      for(const m of (d.data||d.models||[])){
        const id=m.id||m.name||m.chatApiModel||m.label; if(!id) continue;
        process.stdout.write((m.owned_by||"")+"\t"+id+"\n");
      }
    });
  ' 2>/dev/null
}

# 某 key 的 gateway origin(scheme://host):取 CCR 里该 key 某 provider 的 api_base_url。(移植 v1)
ccr_origin_for_key() {
  local kv="$1" cfg="$CCR_PROVIDER_MAP"
  [ -f "$cfg" ] || return 0; command -v node >/dev/null 2>&1 || return 0
  KEY="$kv" node -e '
    const fs=require("fs");
    const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const p=(c.Providers||c.providers||[]).find(p=>(p.api_key||p.apiKey)===process.env.KEY && (p.api_base_url||p.apiBaseUrl));
    if(p){ try{ const u=new URL(p.api_base_url||p.apiBaseUrl); process.stdout.write(u.protocol+"//"+u.host); }catch(e){} }
  ' "$cfg" 2>/dev/null
}

# 多选(stdin 选项每行一个)→ 选中行到 stdout。fzf -m 优先,否则编号菜单接受 "1,3 5"/"all"/空取消。(移植 v1)
_pick_multi() {
  local title="$1"
  local opts=() line
  while IFS= read -r line; do [ -n "$line" ] && opts+=("$line"); done
  [ "${#opts[@]}" -eq 0 ] && return 0
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "${opts[@]}" | fzf --multi --height=50% --reverse --prompt="$title > " \
          --header="Tab=标记  Enter=确认  Esc=取消" 2>/dev/tty || true
  else
    local i
    printf '\n== %s ==  (编号如 "1,3 5"、"all"、或 Enter 取消)\n' "$title" >&2
    i=1; for line in "${opts[@]}"; do printf '  %2d) %s\n' "$i" "$line" >&2; i=$((i+1)); done
    local reply; printf '  选 > ' >&2; read -r reply </dev/tty 2>/dev/null || true
    [ -z "${reply:-}" ] && return 0
    if [ "$reply" = all ]; then printf '%s\n' "${opts[@]}"; return 0; fi
    local tok; for tok in $(printf '%s' "$reply" | tr ',' ' '); do
      [ "$tok" -ge 1 ] 2>/dev/null && [ "$tok" -le "${#opts[@]}" ] 2>/dev/null && printf '%s\n' "${opts[$((tok-1))]}"
    done
  fi
}

# CCR 3 的 provider 修改通过管理 RPC 原子保存，由 CCR 决定是否重启网关。
ccr_apply_provider_map() {
  local adapter="${CREW_CCR_V3_ADAPTER:-$SCRIPT_DIR/../setup/ccr_v3.py}"
  command -v python3 >/dev/null 2>&1 || die "CCR 3 provider 同步需要 python3"
  [ -f "$adapter" ] || die "CCR 3 adapter 不存在: $adapter"
  # setup.sh stores this local management credential mode 0600.  Interactive
  # `crew sync-models` is launched from a fresh shell, not from the service,
  # so recover it here instead of requiring users to export a secret manually.
  if [ -z "${CREW_CCR_WEB_TOKEN:-}" ] && [ -r "$CREW_HOME/ccr-web-token" ]; then
    export CREW_CCR_WEB_TOKEN="$(cat "$CREW_HOME/ccr-web-token")"
  fi
  python3 "$adapter" apply --provider-map "$CCR_PROVIDER_MAP"
}

cmd_models() {
  local key="${1:-}"
  if [ -n "$key" ]; then
    # crew models <key别名>:列该 key 在 CCR 里能路由的模型(joycode/newkey/... 通用)
    local ms; ms=$(ccr_models_for_key "$key")
    if [ -z "$ms" ]; then
      echo "== '$key' 支持的模型 =="
      echo "  (CCR 里没有 api_key 匹配 '$key' 的 provider;或未装 CCR/node)"
      return 0
    fi
    echo "== '$key' 支持的模型 =="
    printf '%s\n' "$ms" | sed 's/^/  /'
    return 0
  fi
  # 2026-09-01:无参 crew models 按 key 分组列【真实模型】(不再列 backend conf 文件名——那套是
  # 内部实现,用户面只见 key+模型)。想看内部 backend conf 用 `crew backends`。
  local k any=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    local ms; ms=$(ccr_models_for_key "$k")
    echo "== $k =="
    if [ -n "$ms" ]; then
      printf '%s\n' "$ms" | sed 's/^/  /'; any=1
    else
      echo "  (无可路由模型;crew addkey / crew sync-models --key $k 补充)"
    fi
  done < <(_list_keys)
  [ "$any" = 0 ] && echo "(keys.conf 里没有 key,或都没对应 CCR provider)"
  return 0
}

# crew backends —— 列内部 backend conf 文件名(实现细节;一般用户看 crew models 即可)
cmd_backends() {
  echo "== backends (内部实现,选模型请用 crew models) =="
  for f in "$CREW_HOME"/backends/*.conf; do
    [ -f "$f" ] || continue
    basename "$f" .conf | sed 's/^/  /'
  done
}

# crew keys —— 列 key 别名(值脱敏)
# crew sync-models [--key A] [--base-url URL] —— 从某 key 的上游发现新模型,多选加进 CCR,重启生效。
# joycode 从代理 :8765 /v1/models 拉(刷新 joycode/joycode-oai);其他 key 打其 gateway /v1/models,
# 每个新 model 建一个 <model>-<alias> provider。(移植自 v1)
cmd_sync_models() {
  local sm_key="$KEY" sm_base=""
  while [ $# -gt 0 ]; do case "$1" in
    --base-url) sm_base="${2:-}"; shift 2;;
    --base-url=*) sm_base="${1#*=}"; shift;;
    *) shift;;
  esac; done
  command -v node >/dev/null 2>&1 || die "crew sync-models 需要 node"
  # 1) 选 key
  if [ -z "$sm_key" ] || [ "$sm_key" = "-" ]; then
    [ -t 0 ] || die "crew sync-models 需 --key <别名> 或交互终端"
    sm_key=$(_list_keys | _pick_one "选要同步的 key" "")
    [ -n "$sm_key" ] || die "没选 key"
  fi
  local sm_kv; sm_kv=$(lookup_key "$sm_key")
  local ccrcfg="$CCR_PROVIDER_MAP"
  [ -f "$ccrcfg" ] || die "CCR config 不存在 ($ccrcfg)"
  # 2) 拉上游模型
  local is_joycode=0 sm_remote=""
  [ "$sm_kv" = joycode ] && is_joycode=1
  if [ "$is_joycode" = 1 ]; then
    local jport="${JOYCODE_PORT:-8765}"
    sm_remote=$(fetch_models_url "http://127.0.0.1:$jport/v1/models" "")
    [ -n "$sm_remote" ] || die "joycode 代理(:$jport)没返回模型 —— 起了吗(crew up)?VS Code 登录了 JoyCode 吗?"
  else
    [ -n "$sm_base" ] || sm_base=$(ccr_origin_for_key "$sm_kv")
    [ -n "$sm_base" ] || die "查不到 key '$sm_key' 的 gateway URL(CCR 里还没 provider 用它);传 --base-url <origin>"
    sm_base="${sm_base%/}"
    sm_remote=$(fetch_models_url "$sm_base/v1/models" "$sm_kv")
    [ -n "$sm_remote" ] || die "gateway $sm_base/v1/models 没返回模型(鉴权/URL 问题?)"
  fi
  # 3) diff 出本地没有的
  local sm_have sm_new
  sm_have=$(ccr_models_for_key "$sm_key")
  sm_new=$(HAVE="$sm_have" awk -F'\t' '
    BEGIN{ n=split(ENVIRON["HAVE"],h,"\n"); for(i=1;i<=n;i++) if(h[i]!="") seen[h[i]]=1 }
    NF{ id=$2; if(id!="" && !(id in seen) && !(id in done)){ done[id]=1; print id } }
  ' <<EOF
$sm_remote
EOF
)
  if [ -z "$sm_new" ]; then echo "== sync-models: '$sm_key' 已有全部上游模型 =="; return 0; fi
  echo "== sync-models: '$sm_key' — 上游有 $(printf '%s\n' "$sm_new" | grep -c .) 个新模型 ==" >&2
  # 4) 多选
  local sm_pick; sm_pick=$(printf '%s\n' "$sm_new" | _pick_multi "加到 key '$sm_key'")
  sm_pick=$(printf '%s\n' "$sm_pick" | awk 'NF')
  [ -n "$sm_pick" ] || { echo "没选 — 不改动"; return 0; }
  # 5) 写 CCR(备份 + 原子写 + 失败 restore)
  local sm_bak="$ccrcfg.bak.$(date +%s 2>/dev/null || echo manual)"
  cp "$ccrcfg" "$sm_bak" || die "备份失败"
  local sm_added
  sm_added=$(CCR_CFG="$ccrcfg" ALIAS="$sm_key" KV="$sm_kv" ISJC="$is_joycode" BASE="$sm_base" \
    REMOTE="$sm_remote" PICK="$sm_pick" node -e '
    const fs=require("fs");
    const cfg=JSON.parse(fs.readFileSync(process.env.CCR_CFG,"utf8"));
    cfg.Providers=cfg.Providers||[];
    const owner={}; for(const ln of (process.env.REMOTE||"").split("\n")){ const i=ln.indexOf("\t"); if(i<0)continue; owner[ln.slice(i+1)]=ln.slice(0,i); }
    const pick=(process.env.PICK||"").split("\n").map(s=>s.trim()).filter(Boolean);
    const isjc=process.env.ISJC==="1", alias=process.env.ALIAS, kv=process.env.KV, base=(process.env.BASE||"").replace(/\/$/,"");
    const isAnthropic=m=> isjc ? /claude/i.test(m) : (owner[m]||"").toLowerCase()==="anthropic";
    // GPT-6 系必须走 /v1/responses(同 ensure_model_in_ccr;llm-gw 拒绝 chat/completions+tools,2026-10-26)
    const needsResponses=m=>/^gpt-6/i.test(m)&&!/gpt-6\.1-sol-pro-fast/i.test(m);
    const mkProvider=(m,anth)=>{
      const p={ name:m+"-"+alias,
        api_base_url: base + (anth?"/anthropic/v1/messages":needsResponses(m)?"/v1":"/v1/chat/completions"),
        api_key: kv, models:[m], transformer:{ use:[anth?"Anthropic":"OpenAI"] } };
      if(!anth&&needsResponses(m)) p.type="openai_responses";
      return p;
    };
    let added=0, skipped=[];
    if(isjc){
      const pj=cfg.Providers.find(p=>p.name==="joycode"), po=cfg.Providers.find(p=>p.name==="joycode-oai");
      for(const m of pick){
        const tgt=isAnthropic(m)?pj:po;
        if(!tgt){ skipped.push(m+"(无 joycode provider)"); continue; }
        tgt.models=tgt.models||[]; if(!tgt.models.includes(m)){ tgt.models.push(m); added++; }
      }
    } else {
      for(const m of pick){
        const anth=isAnthropic(m); const pname=m+"-"+alias;
        if(cfg.Providers.some(p=>p.name===pname)){ skipped.push(m+"(已存在)"); continue; }
        cfg.Providers.push(mkProvider(m,anth));
        added++;
      }
    }
    const tmp=process.env.CCR_CFG+".tmp";
    fs.writeFileSync(tmp, JSON.stringify(cfg,null,2)); fs.renameSync(tmp, process.env.CCR_CFG);
    process.stderr.write("added "+added+(skipped.length?("; 跳过: "+skipped.join(", ")):"")+"\n");
    process.stdout.write(String(added));
  ') || { echo "写入失败;已从 $sm_bak 恢复"; cp "$sm_bak" "$ccrcfg"; return 1; }
  echo "== sync-models: 给 key '$sm_key' 加了 $sm_added 个 provider/model (备份: $sm_bak) =="
  # 6) 有变更才通过 CCR 3 RPC 应用 provider map
  if [ "${sm_added:-0}" -gt 0 ] 2>/dev/null; then
    ccr_apply_provider_map
    echo "  已同步 CCR 3 — 新模型生效(crew models $sm_key 查看)"
  fi
}

cmd_keys() {
  local kf="$CREW_HOME/keys.conf"
  echo "== keys =="
  [ -f "$kf" ] || { echo "  (无 keys.conf)"; return 0; }
  awk -F= '
    /^[[:space:]]*#/ {next} /=/ {
      a=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",a); if(a=="") next;
      v=substr($0, index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);
      m = (length(v)>10) ? substr(v,1,4) "…" substr(v,length(v)-2) : "****";
      printf "  %-14s %s\n", a, m;
    }' "$kf"
}

# crew addkey <key> [别名] —— 简化加 key:写进 keys.conf。别名不给则从 key 派生。
# 只做"写别名=key",不拉 /v1/models、不建 backend(那是 v1 add-key 的重活;此处按用户要的极简)。
cmd_addkey() {
  local key="$1" alias="${2:-}"
  [ -z "$key" ] && die "usage: crew addkey <key> [别名]"
  # 别名默认:key- + key 的 sha256 前 6(稳定、不含明文)
  if [ -z "$alias" ]; then
    local h
    h=$(printf '%s' "$key" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -c1-6)
    alias="key-$h"
  fi
  # 别名校验(与 crew-session 名规则一致:字母数字._-)
  case "$alias" in *[!A-Za-z0-9._-]*) die "别名 '$alias' 含非法字符(仅允许 A-Za-z0-9._-)";; esac
  local kf="$CREW_HOME/keys.conf"
  mkdir -p "$CREW_HOME"
  [ -f "$kf" ] || : > "$kf"
  # 已存在同别名?覆盖其行(保留其余),否则追加。
  if grep -qE "^[[:space:]]*$alias[[:space:]]*=" "$kf" 2>/dev/null; then
    awk -v a="$alias" -v k="$key" '
      { line=$0; t=$0; sub(/^[[:space:]]+/,"",t);
        if (index(t, a "=")==1 || index(t, a " =")==1) { print a "=" k } else { print line } }
    ' "$kf" > "$kf.tmp" && mv "$kf.tmp" "$kf"
    log "更新 key 别名 '$alias'(覆盖旧值)"
  else
    printf '%s=%s\n' "$alias" "$key" >> "$kf"
    log "加了 key 别名 '$alias'"
  fi
  chmod 600 "$kf" 2>/dev/null || true
  echo "现有 key 别名:"; cmd_keys | grep -v '== keys =='
}

# crew model-switch <model> [key别名] —— 模型切换统一入口(2026-10-28,#14)。
# 顺畅路径:校验模型存在 → 写 provider map(原子+备份)→ apply(hot)→ 冒烟探测(:8788 最小请求)
# → 失败自动回滚(恢复 map + re-apply)+ 精确根因 + 一键重试命令。
# 与既有能力的关系:resolve_picked_model 三层防线 / launcher 守卫 / ensure_model_in_ccr /
# ccr_apply_provider_map 全部保留并复用;本入口保证"模型先落 map 再冒烟",launcher 守卫自然放行。
# 已知失败根因逐个 fail-loud:resolve 找不到 provider / sync 跳过带空格名(已修)/ apply 后未热加载
# (v3 adapter 为 hot-apply,冒烟兜底)/ launcher 守卫(模型落 map 后不触发)/ key 别名不匹配。
cmd_model_switch() {
  local model="${1:-}" alias="${2:-}"
  [ -z "$model" ] && die "usage: crew model-switch <model> [key别名]"
  # 1) key 解析:显式给必须存在于 keys.conf;没给 → 有 tty 交互选,否则全 key 找唯一可路由的
  local kf="$CREW_HOME/keys.conf"
  [ -f "$kf" ] || die "keys.conf 不存在: $kf(先 crew addkey <key> [别名])"
  if [ -z "$alias" ]; then
    if [ -t 0 ]; then
      alias=$(_list_keys | _pick_one "选要切换的 key" "")
      [ -n "$alias" ] || die "没选 key"
    else
      local hit="" k
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        if printf '%s\n' "$(ccr_models_for_key "$k")" | grep -qxF "$model"; then
          [ -n "$hit" ] && die "model-switch: '$model' 多个 key 可路由($hit/$k),请显式传 key 别名"
          hit="$k"
        fi
      done < <(_list_keys)
      [ -n "$hit" ] || die "model-switch: '$model' 现有 key 都不可路由;显式传 key 或先 crew sync-models"
      alias="$hit"
    fi
  fi
  grep -qE "^[[:space:]]*$alias[[:space:]]*=" "$kf" || die "key 别名 '$alias' 不在 keys.conf(crew keys 查看;crew addkey <key> <别名>)"
  # 2) 模型存在性 + 写 map(不在路由池才写;写前备份以便失败回滚)
  local before wrote=0 bak=""
  before=$(ccr_models_for_key "$alias")
  if printf '%s\n' "$before" | grep -qxF "$model"; then
    echo "== model-switch: '$model' 已在 '$alias' 路由池,零写入 =="
  else
    [ -f "$CCR_PROVIDER_MAP" ] || die "CCR provider map 不存在: $CCR_PROVIDER_MAP"
    bak="$CCR_PROVIDER_MAP.bak.ms.$(date +%s 2>/dev/null || echo manual)"
    cp "$CCR_PROVIDER_MAP" "$bak" || die "model-switch: 备份 provider map 失败"
    if ! ensure_model_in_ccr "$alias" "$model"; then
      echo "✗ model-switch: '$model' 写进 CCR 失败。"
      echo "  原因: ensure 落地失败(node 写坏 map / 模型非法 / map 缺 joycode provider)。"
      echo "  下一步: crew sync-models --key $alias 手动同步;修好后再跑本命令。"
      echo "  重试: crew model-switch $model $alias"
      return 1
    fi
    wrote=1
  fi
  # 3) resolve 三层防线 → 可路由 CCR 3 selector
  local selector
  selector=$(resolve_picked_model "$alias" "$model") || {
    echo "✗ model-switch: resolve 失败(三层防线未通过)。"
    echo "  原因: '$model' 落地后反查不到 provider(异常状态,查 $CCR_PROVIDER_MAP)。"
    echo "  下一步: crew sync-models --key $alias 重建 provider;然后重跑本命令。"
    echo "  重试: crew model-switch $model $alias"
    return 1
  }
  # 4) apply(v3 adapter hot-apply,幂等;有写入才调)
  if [ "$wrote" = 1 ]; then
    if ! ccr_apply_provider_map; then
      echo "✗ model-switch: apply 失败(CCR 管理 RPC 不通)。"
      echo "  原因: [ccr-down] CCR web 接口不可达(adapter 连不上;token 失效同理)。"
      echo "  下一步: crew doctor;重启 com.claudecrew.ccr 后再跑。"
      echo "  重试: crew model-switch $model $alias"
      _ms_rollback "$bak"
      return 1
    fi
    echo "== model-switch: 已写 provider map 并 apply(hot) =="
  fi
  # 5) 冒烟探测:经 :8788 全链路最小请求(max_tokens=5);3 次尝试留 CCR 热加载窗口
  echo "== model-switch: 冒烟探测 '$selector'(经 :8788,最长 ~30s)=="
  local kv code body i
  kv=$(lookup_key "$alias"); code=""; body=""
  if ! command -v curl >/dev/null 2>&1; then
    echo "  (无 curl,跳过冒烟;切换已生效,链路验证建议起一次真实会话)"
    echo "✓ model-switch: '$model' 切换成功。使用: crew <会话> --model $selector"
    return 0
  fi
  for i in 1 2 3; do
    body=$(curl -sS -m 30 -w '\n%{http_code}' -X POST "http://127.0.0.1:8788/v1/messages" \
      -H "Content-Type: application/json" -H "x-api-key: $kv" \
      -d "{\"model\":\"$selector\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null)
    code=$(printf '%s' "$body" | tail -1)
    body=$(printf '%s' "$body" | sed '$d')
    [ "$code" = 200 ] && break
    [ "$i" -lt 3 ] && { echo "  (第 $i 次 http=$code,2s 后重试——CCR 热加载窗口)"; sleep 2; }
  done
  if [ "$code" = 200 ]; then
    echo "✓ model-switch: '$model' 冒烟 200,全链路通。使用: crew <会话> --model $selector"
    return 0
  fi
  # 6) 失败 → 精确根因 + 回滚 + 重试命令
  echo "✗ model-switch: 冒烟失败(http=$code)。"
  case "$code" in
    401|403) echo "  原因: [upstream-401] 该 key 失效或上游鉴权拒绝。下一步: crew addkey <新key> 换 key。" ;;
    000)     echo "  原因: [proxy-down] :8788 无响应(连接被拒)。下一步: 重启 com.claudecrew.proxy 后重试。" ;;
    502|503) echo "  原因: [ccr/joycode-down] :8788 上游链路 5xx。下一步: crew doctor;重启 com.claudecrew.ccr 与 com.claudecrew.joycode。" ;;
    400)     echo "  原因: [routing-400] CCR 路由拒绝(selector 或 provider 状态问题)。下一步: crew sync-models --key $alias 后重试。" ;;
    *)       echo "  原因: 未知错误。响应片段: $(printf '%s' "$body" | head -c 200)" ;;
  esac
  if [ -n "$bak" ]; then
    _ms_rollback "$bak"
    echo "  已自动回滚: provider map 恢复备份并 re-apply。"
  fi
  echo "  重试: crew model-switch $model $alias"
  return 1
}

# model-switch 失败回滚:恢复 provider map 备份 + re-apply(hot);备份不在则无操作。
_ms_rollback() {
  local bak="$1"
  [ -f "$bak" ] || return 0
  cp "$bak" "$CCR_PROVIDER_MAP" 2>/dev/null || return 0
  ccr_apply_provider_map >/dev/null 2>&1 || true
  rm -f "$bak" 2>/dev/null || true
}
