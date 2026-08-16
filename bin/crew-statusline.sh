#!/bin/bash
# crew-statusline.sh —— Claude Code statusLine:会话底部常显「会话名 · 模型 · 🔑key」。
#
# 为什么需要它:/model 和 stdin JSON 的 display_name 都只给通用档名("Opus 4.8"),
# 看不出实际路由到哪个后端 + 用哪把 key。覆盖 crew / `ccr code` 直起 / 直连三种起法。
#
# 关键设计:绝不显示含糊的 "default"。模型和 key 都解析成**具体真值**:
#   - 模型:CREW_MODEL / CREW_BACKEND / <sess>.backend;若是 "default"/"-"/空(ambient 明文
#     Claude)则用 CCR Router.default 的具体 model 名替掉;"provider,model" 形只显 model 段。
#   - key :显式别名(CREW_KEY / <sess>.key)优先;否则按会话实际 base_url 解析(base_url 优先——
#     它决定实际路由模式,才知道真 key):
#       * :8788 crew-proxy  -> key-policy.conf 里该 model 的主选别名(如 personal);ambient token 是入口令牌不算
#       * :3456 CCR 直连    -> Router.default 的 provider 的 api_key,反查 keys.conf 得别名(如 prod)
#       * 直连上游网关(llm-gw / api.anthropic.com / 未知)-> ambient ANTHROPIC_AUTH_TOKEN 本身就是真 key,映射别名
#     不同路由默认 key 不同,所以必须按 base_url 分别解析,别一律叫 "default"。
#
# 铁律:每次渲染调用 —— 必须快、绝不报错、绝不空白。解析用 node(读 CCR/keys/policy 三文件),
# node 缺失或失败则降级到纯 env 展示。node 实测 ~70ms,可接受。
set +e 2>/dev/null

# Claude Code 从 stdin 灌 session JSON(可能空);读掉但不阻塞(claude 会关 stdin)。
input="$(cat 2>/dev/null)"

STATE="${CREW_STATE:-$HOME/.local/share/claude-crew}"

# 从 stdin JSON 抠一个字符串字段(best-effort,不管嵌套;失败返回空)。
json_str(){ printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }

# ---------- 1) 会话名 ----------
sess="${CREW_SESSION:-}"
tname=""
if [ -z "$sess" ] && [ -n "$TMUX" ]; then
  # 反查:当前 tmux 会话名 -> 匹配某个 <sess>.tmux 文件内容(crew adopt 时写入)。
  # 必须 $TMUX 已设(确实在 tmux 内)才信 —— 否则 tmux display-message 会返回
  # 服务器上"最近活跃的别的会话",拿它当前缀是错的(踩过:返回了 crew-jimdb_bug_fix_2)。
  tname="$(tmux display-message -p '#S' 2>/dev/null)"
  if [ -n "$tname" ] && [ -d "$STATE" ]; then
    for f in "$STATE"/*.tmux; do
      [ -f "$f" ] || continue
      if [ "$(cat "$f" 2>/dev/null)" = "$tname" ]; then
        sess="$(basename "$f" .tmux)"; break
      fi
    done
  fi
fi
# 仍空:tmux 名(确在 tmux 内)> cwd basename;都没有就省略前缀(不塞含糊占位)。
if [ -z "$sess" ]; then
  if [ -n "$tname" ]; then
    sess="$tname"
  else
    cwd="$(json_str current_dir)"; [ -z "$cwd" ] && cwd="$(json_str cwd)"
    [ -n "$cwd" ] && sess="$(basename "$cwd")"
  fi
fi

# ---------- 2) 解析模型 + key(具体真值,绝不 "default")----------
# 用 node 一次性读 CCR config / keys.conf / key-policy.conf,按 env + base_url 解析。
model=""; key=""
if command -v node >/dev/null 2>&1; then
  res="$(SESS="$sess" node -e '
    var fs=require("fs"), HOME=process.env.HOME||"";
    var STATE=process.env.CREW_STATE||(HOME+"/.local/share/claude-crew");
    var sess=process.env.SESS||"";
    function rd(p){ try{ return fs.readFileSync(p,"utf8"); }catch(e){ return ""; } }
    // keys.conf: "<alias>=<token>"(实际格式,无空格);兼容 "<alias> <token>" 空白格式。-> token->alias
    var tok2alias={}, i, ln, parts, eqk, ka, kt;
    var kl=rd(HOME+"/.config/claude-crew/keys.conf").split("\n");
    for(i=0;i<kl.length;i++){
      ln=kl[i].trim(); if(!ln||ln[0]==="#")continue;
      eqk=ln.indexOf("=");
      if(eqk>=0){ ka=ln.slice(0,eqk).trim(); kt=ln.slice(eqk+1).trim(); if(ka&&kt) tok2alias[kt]=ka; }
      else { parts=ln.split(/\s+/); if(parts.length>=2) tok2alias[parts[1]]=parts[0]; }
    }
    // key-policy.conf: "<model> = <alias1> <alias2> ..."
    var policy={}, pl=rd(HOME+"/.config/claude-crew/key-policy.conf").split("\n"), eq, mk, al;
    for(i=0;i<pl.length;i++){ ln=pl[i].trim(); if(!ln||ln[0]==="#")continue; eq=ln.indexOf("="); if(eq<0)continue; mk=ln.slice(0,eq).trim(); al=ln.slice(eq+1).trim().split(/\s+/); policy[mk]=al; }
    // CCR config
    var ccr={}; try{ ccr=JSON.parse(rd(HOME+"/.claude-code-router/config.json")); }catch(e){}
    var provs=ccr.Providers||ccr.providers||[];
    function provKey(n){ for(var j=0;j<provs.length;j++){ if(provs[j]&&provs[j].name===n) return (provs[j].api_key||"")+""; } return ""; }
    var rdef=((ccr.Router&&ccr.Router.default)||"")+"", dprov=rdef, dmodel=rdef, ci=rdef.indexOf(",");
    if(ci>=0){ dprov=rdef.slice(0,ci); dmodel=rdef.slice(ci+1); }
    // ---- model ----
    var model=process.env.CREW_MODEL||process.env.CREW_BACKEND||"";
    if(!model && sess) model=rd(STATE+"/"+sess+".backend").trim();
    if(model===""||model==="-"||model==="default") model=dmodel;   // ambient 明文 -> 具体 model
    var mprov=""; var mi=model.indexOf(","); if(mi>=0){ mprov=model.slice(0,mi); model=model.slice(mi+1); }
    // ---- key(base_url 优先:决定实际路由模式,才知道真 key)----
    var base=process.env.ANTHROPIC_BASE_URL||"", isProxy=/:8788/.test(base), isCCR=/:3456/.test(base);
    var key=process.env.CREW_KEY||"";
    if((!key||key==="-") && sess) key=rd(STATE+"/"+sess+".key").trim();
    if(key==="-") key="";
    if(!key){
      if(isProxy){
        // crew-proxy(:8788):真 key 由 key-policy 决定,ambient token(=test)是入口令牌不算
        var mname=model||dmodel;
        var pol=policy[mname]||policy[process.env.CREW_BACKEND||""]||null;
        if(pol&&pol.length) key=pol[0];
      } else if(isCCR){
        // CCR 直连(:3456):真 key = Router.default 的 provider 的 api_key -> 别名;ambient token(=test)不算
        var prov=mprov||dprov, tok=provKey(prov)||provKey(dprov);
        if(tok) key=tok2alias[tok]||(tok.length>10?(tok.slice(0,4)+"…"+tok.slice(-3)):tok);
      } else {
        // 直连上游网关(llm-gw / api.anthropic.com / 未知):ambient token 本身就是真 key
        var at=process.env.ANTHROPIC_AUTH_TOKEN||process.env.ANTHROPIC_API_KEY||"";
        if(at) key=tok2alias[at]||(at.length>10?(at.slice(0,4)+"…"+at.slice(-3)):at);
      }
    }
    if(!model) model="?";
    if(!key) key="?";
    process.stdout.write(model+"\t"+key);
  ' 2>/dev/null)"
  if [ -n "$res" ]; then
    IFS=$'\t' read -r model key <<<"$res"
  fi
fi

# ---------- 2.5) node 缺失/失败的纯 env 降级(仍尽量避免裸 "default")----------
if [ -z "$model" ]; then
  model="${CREW_MODEL:-${CREW_BACKEND:-}}"
  [ -z "$model" ] && [ -n "$sess" ] && [ -f "$STATE/$sess.backend" ] && model="$(cat "$STATE/$sess.backend" 2>/dev/null)"
  [ -z "$model" ] && model="$(json_str display_name)"
  case "$model" in *,*) model="${model#*,}";; esac
  [ "$model" = "-" ] && model=""
  [ -z "$model" ] && model="?"
fi
if [ -z "$key" ]; then
  key="${CREW_KEY:-}"
  [ -z "$key" ] && [ -n "$sess" ] && [ -f "$STATE/$sess.key" ] && key="$(cat "$STATE/$sess.key" 2>/dev/null)"
  [ "$key" = "-" ] && key=""
  [ -z "$key" ] && key="?"
fi

# ---------- 3) 按模型档上色(一眼分清 Opus / GLM / kimi)----------
c_reset=$'\033[0m'; c_dim=$'\033[2m'
lc="$(printf '%s' "$model" | tr 'A-Z' 'a-z')"
case "$lc" in
  *opus*)   c_model=$'\033[36m' ;;   # cyan  = 真 Opus(贵/强)
  *sonnet*) c_model=$'\033[34m' ;;   # blue  = Sonnet
  *glm*)    c_model=$'\033[33m' ;;   # yellow= GLM(省钱替身)
  *kimi*)   c_model=$'\033[35m' ;;   # magenta= kimi
  *)        c_model=$'\033[37m' ;;   # 其它/未知
esac

# ---------- 4) 输出(单行,无尾换行)----------
# 组装:⬡ [<会话名> · ]<模型> · 🔑<key>
c_key=$'\033[35m'   # magenta 区分 key 段
key_seg="$(printf ' %s·%s %s🔑%s%s' "$c_dim" "$c_reset" "$c_key" "$key" "$c_reset")"

if [ -n "$sess" ]; then
  printf '%s⬡ %s ·%s %s%s%s%s' "$c_dim" "$sess" "$c_reset" "$c_model" "$model" "$c_reset" "$key_seg"
else
  printf '%s⬡%s %s%s%s%s' "$c_dim" "$c_reset" "$c_model" "$model" "$c_reset" "$key_seg"
fi
