# crew.d/session.sh — 会话维护:spawn/prune/autoprune/switch/resume-prev/find + 选择器/路径解析原语
# 会话最近活跃时间(epoch):transcript .jsonl mtime + state 文件 mtime 取 max。0=无从判定。
# _mtime 跨平台:Linux `stat -c %Y`,macOS/BSD `stat -f %m`。注意 Linux 上 `stat -f` 是"文件系统
# 信息"(不报错但输出多行文本!),故必须先试 -c、再试 -f,且校验结果是纯数字(不是就当 0)。
_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=""
  case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) || m="";; esac
  case "$m" in ''|*[!0-9]*) m=0;; esac
  echo "$m"
}
session_activity() {
  local nm="$1" last=0 s m f
  s=$("$CS" get "$nm" sid 2>/dev/null || echo "")
  if [ -n "$s" ]; then
    for f in "$HOME"/.claude/projects/*/"$s".jsonl; do
      [ -f "$f" ] || continue; m=$(_mtime "$f"); [ "$m" -gt "$last" ] 2>/dev/null && last=$m
    done
  fi
  for f in "$CREW_STATE/$nm.sid" "$CREW_STATE/$nm.backend" "$CREW_STATE/$nm.key"; do
    [ -f "$f" ] || continue; m=$(_mtime "$f"); [ "$m" -gt "$last" ] 2>/dev/null && last=$m
  done
  echo "$last"
}

# 自动清理陈旧会话(分级):transcript/state 最后活跃 > STATE_DAYS(默认7)天 → 删 crew 状态(留
# transcript,可 find/resume 找回);> PURGE_DAYS(默认30)天 → 连 transcript 一起删(彻底)。
# 铁律:live(tmux 在跑)/ pinned 会话【绝不删】。不碰 send/inbox/--model 等接口。
# crew <name> [--days N] [--purge-days M] [--dry-run]
cmd_prune() {
  local p_days="${CREW_PRUNE_DAYS:-7}" p_purge_days="${CREW_PURGE_DAYS:-30}" p_dry=0
  while [ $# -gt 0 ]; do case "$1" in
    --days) p_days="$2"; shift 2;;
    --days=*) p_days="${1#*=}"; shift;;
    --purge-days) p_purge_days="$2"; shift 2;;
    --purge-days=*) p_purge_days="${1#*=}"; shift;;
    --dry-run|-n) p_dry=1; shift;;
    *) shift;;
  esac; done
  local now; now=$(date +%s 2>/dev/null || echo 0); [ "$now" = 0 ] && return 0
  local cut_state=$(( now - p_days*86400 )) cut_purge=$(( now - p_purge_days*86400 ))
  local live_sessions; live_sessions=$("$CT" list 2>/dev/null || echo "")
  local reaped=0 purged=0 kept=0 nm
  # 每个会话打一行明细:空闲天数 + 动作/保留原因,一眼看清"为什么没删"。
  printf '  %-20s %-10s %s\n' "会话" "空闲" "结果" >&2
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    # live?(tmux 在跑)→ keep
    local tn=""
    if [ -f "$CREW_STATE/$nm.tmux" ]; then tn=$(cat "$CREW_STATE/$nm.tmux" 2>/dev/null)
    elif [ -f "$CREW_STATE/$nm.tmuxname" ]; then tn=$(cat "$CREW_STATE/$nm.tmuxname" 2>/dev/null)
    elif echo "$live_sessions" | grep -qFx "$nm"; then tn="$nm"
    elif echo "$live_sessions" | grep -qFx "crew-$nm"; then tn="crew-$nm"
    fi
    local last age_d age_s
    last=$(session_activity "$nm"); case "$last" in ''|*[!0-9]*) last=0;; esac
    if [ "$last" = 0 ]; then age_s="?"; else age_d=$(( (now-last)/86400 )); age_s="${age_d}d"; fi
    # live → keep
    if [ -n "$tn" ] && echo "$live_sessions" | grep -qFx "$tn"; then
      printf '  %-20s %-10s %s\n' "$nm" "$age_s" "保留(live)"; kept=$((kept+1)); continue
    fi
    # pinned → keep(常驻会话如 work)
    if "$CS" has "$nm" pintmux 2>/dev/null; then
      printf '  %-20s %-10s %s\n' "$nm" "$age_s" "保留(pinned)"; kept=$((kept+1)); continue
    fi
    # 判不出活跃时间 → 保守 keep
    [ "$last" = 0 ] && { printf '  %-20s %-10s %s\n' "$nm" "$age_s" "保留(无活跃时间)"; kept=$((kept+1)); continue; }
    if [ "$last" -lt "$cut_purge" ]; then
      # > purge_days:连 transcript 删
      if [ "$p_dry" = 1 ]; then printf '  %-20s %-10s %s\n' "$nm" "$age_s" "将连历史删(>${p_purge_days}d)"; purged=$((purged+1)); continue; fi
      "$CT" kill "$nm" 2>/dev/null || true
      "$CS" clean "$nm" --purge-transcript >/dev/null 2>&1 || true
      printf '  %-20s %-10s %s\n' "$nm" "$age_s" "已连历史删"; purged=$((purged+1))
    elif [ "$last" -lt "$cut_state" ]; then
      # state_days~purge_days:只删状态,留 transcript
      if [ "$p_dry" = 1 ]; then printf '  %-20s %-10s %s\n' "$nm" "$age_s" "将删状态(>${p_days}d,留历史)"; reaped=$((reaped+1)); continue; fi
      "$CT" kill "$nm" 2>/dev/null || true
      "$CS" clean "$nm" >/dev/null 2>&1 || true
      printf '  %-20s %-10s %s\n' "$nm" "$age_s" "已删状态(留历史)"; reaped=$((reaped+1))
    else
      printf '  %-20s %-10s %s\n' "$nm" "$age_s" "保留(未超 ${p_days}d)"; kept=$((kept+1))
    fi
  done < <("$CS" list 2>/dev/null | cut -f1 | sort -u)
  echo "== prune: 删状态 $reaped, 连历史删 $purged, 保留 $kept (状态>${p_days}d, 历史>${p_purge_days}d$( [ "$p_dry" = 1 ] && printf ', dry-run'))"
}

# 机会式节流自动清理:每 CREW_PRUNE_EVERY 秒(默认1天)最多一次,后台静默跑 prune。搭 spawn/ls 触发,
# 无需 cron。CREW_PRUNE_AUTO=0 关闭。绝不 delay 前台操作(后台 &)。
crew_autoprune() {
  [ "${CREW_PRUNE_AUTO:-1}" = 1 ] || return 0
  local every="${CREW_PRUNE_EVERY:-86400}" stamp="$CREW_STATE/.last-prune" last now
  last=$(cat "$stamp" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0;; esac
  now=$(date +%s 2>/dev/null || echo 0); [ "$now" = 0 ] && return 0
  [ $((now - last)) -ge "$every" ] || return 0
  printf '%s' "$now" > "$stamp" 2>/dev/null || true
  ( "$SCRIPT_DIR/crew" prune >/dev/null 2>&1 & ) 2>/dev/null || true
}

# crew switch <会话> —— 交互切 key→model(都默认当前值),选完走 live 换模型路径重启。
# 顺序:先选 key(默认会话现 key),再选 model(默认会话现 model)。等价 `crew <会话> --key K --model M`,
# 但交互、免背参数。非交互(无 tty)报错提示用带参形式。
# crew resume-prev <会话> —— 把 sid 换回上次被 --fresh 覆盖前归档的 prev_sid,找回老历史。
# 场景:误 --fresh 后想恢复之前的对话(老历史 jsonl 还在,只是 state.sid 指向了新空会话)。
cmd_resume_prev() {
  local name="$1"
  [ -z "$name" ] && die "usage: crew resume-prev <会话>"
  local prev; prev=$("$CS" get "$name" prev_sid 2>/dev/null || echo "")
  [ -z "$prev" ] && die "'$name' 没有 prev_sid(没被 --fresh 覆盖过,或已找回)"
  local cur; cur=$("$CS" get "$name" sid 2>/dev/null || echo "")
  # 交换:当前 sid 存回 prev_sid(可再换回),prev 设为当前 sid
  "$CS" set "$name" sid "$prev" >/dev/null
  [ -n "$cur" ] && "$CS" set "$name" prev_sid "$cur" >/dev/null
  log "'$name' sid 换回 prev_sid=$prev(原 sid $cur 存进 prev_sid,可再 resume-prev 换回)。crew $name 重起即 resume 老历史"
}

cmd_switch() {
  local name="$1"
  [ -z "$name" ] && die "usage: crew switch <会话>"
  [ -t 0 ] || die "crew switch 需交互终端;非交互请用: crew $name --key <K> --model <M>"
  local cur_key cur_be picked_key picked_be
  cur_key=$("$CS" get "$name" key 2>/dev/null || echo "")
  cur_be=$("$CS" get "$name" backend 2>/dev/null || echo "")
  picked_key=$(_list_keys | _pick_one "选 key ($name,当前: ${cur_key:-无})" "$cur_key")
  # model 菜单:列【该 key 支持的模型】(ccr_models_for_key_full,provider/model 全名,直接可用)。
  # 拿不到(该 key 无 CCR provider)→ 提示补 key,不再暴露 backend 文件名。
  local model_opts
  # 2026-10-16:菜单数据源换 auto_discover_models(拉上游 /v1/models 增量同步,失败回落静态表)
  model_opts=$(auto_discover_models "$picked_key")
  [ -z "$model_opts" ] && { log "key '$picked_key' 没有可路由模型(crew sync-models --key $picked_key 补充);保持原模型"; picked_be="$cur_be"; }
  [ -n "$model_opts" ] && picked_be=$(printf '%s\n' "$model_opts" | _pick_one "选模型 ($name,当前: ${cur_be:-无})" "$cur_be")
  # 选中裸名新模型(无 provider/ 前缀)→ ensure 落地 + 按 joycode/普通分支拼对 selector
  # (2026-10-27 根修:统一走 resolve_picked_model,不再各拼各的 $model-$key/$model)
  if [ -n "$picked_be" ]; then
    local _sel; _sel=$(resolve_picked_model "$picked_key" "$picked_be") \
      || { log "切换中止:模型 '$picked_be' 落地失败(上面有指引);保持原模型"; picked_be="$cur_be"; }
    [ -n "$_sel" ] && picked_be="$_sel"
  fi
  # 设全局 BACKEND/KEY,走 cmd_spawn 的 live 换模型逻辑(它会判与现值不同才重启)
  [ -n "$picked_key" ] && KEY="$picked_key"
  [ -n "$picked_be" ] && BACKEND="$picked_be"
  if [ "$BACKEND" = "$cur_be" ] && [ "$KEY" = "$cur_key" ]; then
    log "'$name' key/model 未变(key=$KEY model=$BACKEND),不重启"
    return 0
  fi
  log "switch '$name' → key=$KEY model=$BACKEND"
  cmd_spawn "$name"
}

# crew find <描述...> —— 快搜已有 crew 会话历史,返回 Top5 候选(会话名+概要+打开命令)。
# 重点是快:每会话只 tail transcript 最近片段(不读大 .jsonl 全文)grep 粗筛;按命中数+最近活跃
# 排序;概要取首个命中行的 user 文本(疑似密钥脱敏)。纯 grep 路径,零模型依赖。
# CREW_FIND_TAIL(默认 200000 字节)控制每会话读多少最近内容。

cmd_find() {
  [ $# -eq 0 ] && die "usage: crew find <描述...>"
  # 远程按会话名匹配(2026-10-19):远程 transcript 在容器里,本机 grep 不到,只匹配名字。
  local _rf; _rf=$(_find_remote_session "@$*" 2>/dev/null) || _rf=""
  if [ -n "$_rf" ]; then
    log "远程匹配(按名字;内容搜索请在远程跑 crew find):"
    printf '%s\n' "$_rf" | awk -F'\t' '{ printf "  [remote:%s] %s\n", $1, $2 }'
  fi
  local q="$*" tailb="${CREW_FIND_TAIL:-200000}"
  local live_sessions; live_sessions=$("$CT" list 2>/dev/null || echo "")
  # 收集 name→sid→transcript,grep 粗筛计分。结果行:"命中数<TAB>mtime<TAB>name<TAB>transcript"
  local scored="" name sid j hits mt words w
  # 拆词(空格分),任一命中计一分
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    sid=$("$CS" get "$name" sid 2>/dev/null || echo "")
    [ -z "$sid" ] && continue
    j=""
    for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do [ -f "$f" ] && { j="$f"; break; }; done
    [ -z "$j" ] && continue
    # 只读最近 tailb 字节(快)。多词累计命中(每词 grep -ic 计数)。
    local recent; recent=$(tail -c "$tailb" "$j" 2>/dev/null)
    hits=0
    for w in $q; do
      local c; c=$(printf '%s' "$recent" | grep -ic -- "$w" 2>/dev/null)
      case "$c" in ''|*[!0-9]*) c=0;; esac
      hits=$((hits + c))
    done
    [ "$hits" -eq 0 ] && continue
    mt=$(_mtime "$j")
    scored+="$hits"$'\t'"$mt"$'\t'"$name"$'\t'"$j"$'\n'
  done < <("$CS" list 2>/dev/null | cut -f1 | sort -u)

  if [ -z "$scored" ]; then
    echo "没找到匹配 '$q' 的会话。换个关键词?(find 只搜每个会话最近的对话片段)"
    return 0
  fi

  # 排序:命中数降序,再 mtime 降序;取 Top5
  local top; top=$(printf '%s' "$scored" | sort -t$'\t' -k1,1nr -k2,2nr | head -5)

  # 输出候选块
  local rank=0 c_dim=$'\033[2m' c_reset=$'\033[0m' c_name=$'\033[36m' c_cmd=$'\033[2m'
  while IFS=$'\t' read -r hits mt name j; do
    [ -n "$name" ] || continue
    rank=$((rank+1))
    # 状态/model/cwd
    local st="resumable" tn=""
    if [ -f "$CREW_STATE/$name.tmux" ]; then tn=$(cat "$CREW_STATE/$name.tmux" 2>/dev/null)
    elif [ -f "$CREW_STATE/$name.tmuxname" ]; then tn=$(cat "$CREW_STATE/$name.tmuxname" 2>/dev/null)
    elif echo "$live_sessions" | grep -qFx "$name"; then tn="$name"
    elif echo "$live_sessions" | grep -qFx "crew-$name"; then tn="crew-$name"; fi
    echo "$live_sessions" | grep -qFx "$tn" && st="live"
    local be; be=$("$CS" get "$name" backend 2>/dev/null || echo "?")
    local cwd; cwd=$(awk -F'\t' -v n="$name" '$2==n{print $1; exit}' "$CREW_STATE/registry" 2>/dev/null)
    local cwdb; cwdb=$(basename "${cwd:-?}")
    # 概要:node 直接读 transcript 末尾片段(不用 stdin 管道 —— 在 `while <<<` 循环里 node 会
    # 继承循环的 here-string stdin,读不到管道数据,故传文件路径让 node 自己 fs 读末尾 tailb 字节)。
    # 抠首个含【任一】查询词的文本(与计分一致,不只首词);疑似密钥脱敏;失败回落。
    local gist
    gist=$(node -e '
      var fs=require("fs"), file=process.argv[1], tailb=+process.argv[2]||200000;
      var words=process.argv.slice(3).map(function(w){return w.toLowerCase()});
      var buf="";
      try{ var fd=fs.openSync(file,"r"), sz=fs.fstatSync(fd).size, start=Math.max(0,sz-tailb), len=sz-start;
           var b=Buffer.alloc(len); fs.readSync(fd,b,0,len,start); fs.closeSync(fd); buf=b.toString("utf8"); }catch(e){}
      var lines=buf.split("\n"), found="";
      for(var i=0;i<lines.length && !found;i++){
        try{var m=JSON.parse(lines[i]); var c=m.message&&m.message.content;
          var t = typeof c==="string" ? c : (Array.isArray(c)? c.map(function(bl){return bl&&bl.text||""}).join(" ") : "");
          if(!t) continue; var lt=t.toLowerCase();
          for(var k=0;k<words.length;k++){ if(words[k] && lt.indexOf(words[k])>=0){ found=t.replace(/\s+/g," ").trim().slice(0,120); break; } }
        }catch(e){}
      }
      if(found) process.stdout.write(found);
    ' "$j" "$tailb" $q 2>/dev/null)
    # 脱敏:疑似 token(sk-/长 hex/长 base64)打码
    gist=$(printf '%s' "$gist" | sed -E 's/(sk-[A-Za-z0-9_-]{6})[A-Za-z0-9_-]+/\1…/g; s/[A-Za-z0-9]{32,}/<REDACTED>/g')
    if [ -z "$gist" ]; then
      # content 里没抠到(命中可能在工具输出/路径等非对话文本)→ 回落:抽首个命中词所在原始行的
      # 可读片段(去 JSON 转义噪音,截断),让用户仍能看到匹配上下文。
      local w1b; w1b=$(printf '%s' "$q" | awk '{print $1}')
      gist=$(tail -c "$tailb" "$j" 2>/dev/null | grep -i -m1 -- "$w1b" 2>/dev/null \
        | sed -E 's/\\[a-z]//g; s/[{}"]//g; s/\s+/ /g' | cut -c1-110)
      [ -n "$gist" ] && gist="~ $gist"
    fi
    [ -z "$gist" ] && gist="(命中 $hits 处)"
    printf '%s#%d%s  %s%s%s  %s(%s · %s · %s)%s\n' "$c_dim" "$rank" "$c_reset" "$c_name" "$name" "$c_reset" "$c_dim" "$st" "$be" "$cwdb" "$c_reset"
    printf '    概要: %s\n' "$gist"
    printf '    打开: %screw %s%s\n\n' "$c_cmd" "$name" "$c_reset"
  done <<< "$top"
}

# 2026-08-31:解析会话真实工作目录。优先级(对齐 v1 path_for_name + $PWD 回落):
#   显式 --dir($DIR 非空) > registry 里 <cwd>\t<name> 按 name 反查 > state.dir > $PWD。
# 换模型/重启 live 会话时不应丢工作目录 —— 会话早在 registry(首次 spawn 时写入),从那反查
# 回它原来的目录;claude 的 --resume 也依赖在正确 cwd 起(否则按错 project 目录找历史崩)。
# --- 交互选择器(移植自 v1 --pick)------------------------------------------
# _pick_one <title> <default>:选项从 stdin(每行一个),选中值到 stdout。fzf 优先,否则编号菜单
# (接受编号、选项原文、唯一前缀;Enter 保持默认)。所有提示走 stderr,只有选中值进 stdout。
_pick_one() {
  local title="$1" def="$2" chosen=""
  local opts=() line
  while IFS= read -r line; do [ -n "$line" ] && opts+=("$line"); done
  [ "${#opts[@]}" -eq 0 ] && { printf '%s' "$def"; return; }
  if command -v fzf >/dev/null 2>&1; then
    local ordered; ordered=$( { [ -n "$def" ] && printf '%s\n' "$def"; local o; for o in "${opts[@]}"; do [ "$o" = "$def" ] || printf '%s\n' "$o"; done; } )
    chosen=$(printf '%s\n' "$ordered" | fzf --height=40% --reverse --prompt="$title > " \
            --header="Enter=选中  Esc=保持默认 [$def]" 2>/dev/tty) || chosen=""
  else
    local i
    printf '\n== %s ==  (输编号,或 Enter 保持默认: %s)\n' "$title" "$def" >&2
    i=1; for line in "${opts[@]}"; do printf '  %2d) %s%s\n' "$i" "$line" "$([ "$line" = "$def" ] && printf '  (默认)')" >&2; i=$((i+1)); done
    local reply; printf '  选 > ' >&2; read -r reply </dev/tty
    if [ -z "$reply" ]; then chosen="$def"
    elif [ "$reply" -ge 1 ] 2>/dev/null && [ "$reply" -le "${#opts[@]}" ] 2>/dev/null; then chosen="${opts[$((reply-1))]}"
    else
      local o m="" hits=0 h="" rl; rl=$(printf '%s' "$reply" | tr 'A-Z' 'a-z')
      for o in "${opts[@]}"; do [ "$o" = "$reply" ] && { m="$o"; break; }; done
      if [ -z "$m" ]; then
        for o in "${opts[@]}"; do case "$(printf '%s' "$o" | tr 'A-Z' 'a-z')" in "$rl"*) hits=$((hits+1)); h="$o";; esac; done
        [ "$hits" = 1 ] && m="$h"
      fi
      if [ -n "$m" ]; then chosen="$m"; else printf '  无匹配 "%s" — 保持默认: %s\n' "$reply" "$def" >&2; chosen="$def"; fi
    fi
  fi
  [ -z "$chosen" ] && chosen="$def"
  printf '%s' "$chosen"
}
# backend 名列表(backends/*.conf 去 .conf),每行一个
_list_backends() {
  local f
  for f in "$CREW_HOME"/backends/*.conf; do
    [ -f "$f" ] || continue
    basename "$f" .conf
  done | sort -u
}
# key 别名列表(keys.conf 的 alias=... 左侧),每行一个
_list_keys() {
  [ -f "$CREW_HOME/keys.conf" ] || return 0
  awk -F= '/^[[:space:]]*#/{next} /=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); if($1)print $1}' "$CREW_HOME/keys.conf" | sort -u
}

# _trust_dir <dir>:给该目录在 ~/.claude.json 预写 hasTrustDialogAccepted=true,让 claude 起会话
# 时不弹"Quick safety check: trust this folder?"确认页(--dangerously-skip-permissions 不跳它,
# detached tmux 里没人回车会卡住 → 空壳循环。本地新目录起会话必踩)。幂等,原子写,只改该 dir 条目。
_trust_dir() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  [ "$dir" = "-" ] && return 0
  command -v node >/dev/null 2>&1 || return 0   # 无 node:降级,用户手动确认一次
  DIR_TO_TRUST="$dir" node -e '
    const fs=require("fs"), os=require("os"), path=require("path");
    const f=path.join(os.homedir(),".claude.json");
    let c={};
    try { c=JSON.parse(fs.readFileSync(f,"utf8")); } catch(e) { c={}; }
    if(typeof c!=="object"||!c) c={};
    c.projects=c.projects||{};
    const d=process.env.DIR_TO_TRUST;
    const p=c.projects[d]||{};
    if(p.hasTrustDialogAccepted===true) process.exit(0);  // 幂等:已信任不写
    p.hasTrustDialogAccepted=true;
    c.projects[d]=p;
    const tmp=f+".crewtmp";
    fs.writeFileSync(tmp, JSON.stringify(c));
    fs.renameSync(tmp, f);
  ' 2>/dev/null || true
}

resolve_session_dir() {
  local name="$1" d=""
  if [ -n "$DIR" ]; then echo "$DIR"; return; fi
  local reg="$CREW_STATE/registry"
  if [ -f "$reg" ]; then
    d=$(awk -F'\t' -v n="$name" '$2==n{print $1; exit}' "$reg" 2>/dev/null)
  fi
  [ -z "$d" ] && d=$("$CS" get "$name" dir 2>/dev/null || echo "")
  [ -z "$d" ] && d="$PWD"
  echo "$d"
}

cmd_spawn() {
  # 远程路由(2026-10-19):本机无此会话但远程有 → 交给 cmd_attach 走远程(唤醒+attach),
  # 防止"想接手远程 agent 却在本地建了同名空会话"。显式 --fresh/--model 时仍按本地新建(用户明确要新起)。
  if [ $# -ge 1 ] && [ -z "$BACKEND" ] && [ "$FRESH" -eq 0 ]; then
    local _sp="$1"
    if ! "$CS" list 2>/dev/null | cut -f1 | grep -qFx "$_sp"; then
      local _rhit; _rhit=$(_find_remote_session "$_sp" 2>/dev/null) || _rhit=""
      if [ -n "$_rhit" ]; then
        cmd_attach "$_sp"; exit $?
      fi
    fi
  fi
  local name="$1"; shift
  local task="$*"
  [ -z "$name" ] && die "no name"

  # 2026-09-01:--pick 强制交互选(换模型/新起入口)。顺序先 key 后模型(与 switch/新起一致):
  # 选 key(默认会话现值)→ 从该 key 支持的模型选(默认现值;拿不到回落全量 backend)。放在 attach
  # 判断【之前】跑,选完的 BACKEND/KEY 被下面 live 换模型逻辑识别。仅 --pick 触发,不误伤纯 attach。
  # 需交互终端;非交互即使传 --pick 也跳过。
  if [ "$PICK" = 1 ] && [ -t 0 ]; then
    local _def_key; _def_key=$("$CS" get "$name" key 2>/dev/null || echo "")
    local _picked_key; _picked_key=$(_list_keys | _pick_one "选 key ($name)" "$_def_key")
    [ -n "$_picked_key" ] && KEY="$_picked_key"
    local _def_be; _def_be=$("$CS" get "$name" backend 2>/dev/null || echo "")
    local _mo; [ -n "$KEY" ] && _mo=$(auto_discover_models "$KEY")  # 拉上游增量,回落静态
    if [ -z "$_mo" ]; then
      [ -n "$KEY" ] && log "key '$KEY' 没有可路由模型(crew sync-models --key $KEY 补充);可 --model 直接指定"
    else
      local _picked_be; _picked_be=$(printf '%s\n' "$_mo" | _pick_one "选模型 ($name${KEY:+, key=$KEY})" "$_def_be")
      # 选中裸名新模型 → ensure 落地 + 拼对 selector(2026-10-27 统一 resolve_picked_model)
      if [ -n "$_picked_be" ]; then
        local _sel; _sel=$(resolve_picked_model "$KEY" "$_picked_be") \
          || { log "选中模型 '$_picked_be' 落地失败(上面有指引),忽略该选择"; _picked_be=""; }
        [ -n "$_sel" ] && _picked_be="$_sel"
      fi
      [ -n "$_picked_be" ] && BACKEND="$_picked_be"
    fi
  fi

  # 2026-08-30 audit-crew A5(P0):registry 写方收口 —— spawn 起会话时把 <cwd,name>
  # 落 registry(v2 之前只 clean 删行、从不写入,导致 agent-bridge crew-session-sync 侧
  # 长期看不见 v2 会话,DIR 兜底靠 /proc)。
  # 2026-08-31:解析真实工作目录(显式--dir > registry反查 > state.dir > $PWD),供 registry
  # 写入与传给 launcher 共用。显式 --dir 且与 registry 现值不同时,更新该行(原逻辑只首次写,
  # 导致换模型重启时 --dir 被忽略、会话掉回 /work)。
  local reg="$CREW_STATE/registry"
  mkdir -p "$CREW_STATE"
  local session_dir; session_dir=$(resolve_session_dir "$name")
  if ! [ -f "$reg" ] || ! awk -F'\t' -v m="$name" '$2==m{ok=1}END{exit !ok}' "$reg" 2>/dev/null; then
    printf '%s\t%s\n' "$session_dir" "$name" >> "$reg"
  elif [ -n "$DIR" ]; then
    # 显式 --dir:若 registry 里该 name 的 cwd 与之不同,重写该行
    local cur_reg_dir
    cur_reg_dir=$(awk -F'\t' -v n="$name" '$2==n{print $1; exit}' "$reg" 2>/dev/null)
    if [ "$cur_reg_dir" != "$DIR" ]; then
      awk -F'\t' -v n="$name" -v d="$DIR" 'BEGIN{OFS="\t"} $2==n{$1=d} {print}' "$reg" > "$reg.tmp" 2>/dev/null \
        && mv "$reg.tmp" "$reg"
    fi
  fi

  # 2026-08-30 修:v1 语义——crew <name> 无 task 且 tmux 已 live 时,attach 而非新起
  # (踩坑:用户跑 crew work,v2 无脑 spawn 灌新 launcher → 新起 crew-work tmux,
  # 而真 work tmux 还活着,claude 被分叉;pinned adopt 会话尤其危险)
  # 有 --fresh / 有 task / --no-tmux 时不走 attach,按用户显式意图 spawn
  if [ -z "$task" ] && [ "$FRESH" = 0 ] && [ "$NO_TMUX" = 0 ]; then
    local existing
    existing=$("$CT" resolve "$name" 2>/dev/null || true)
    if [ -n "$existing" ] && "$CT" list 2>/dev/null | grep -qFx "$existing"; then
      # 2026-09-01:空壳检查 —— tmux 会话在,但 pane 里没有 claude 进程(claude 崩了/退了,只剩
      # tmux 壳)= 不算真 live。此时不该 attach 空壳(会 attach 到一个 bash shell,bootstrap 还会
      # 踩嵌套 attach rc=1),应 kill 空壳后往下 spawn 重起。复用 cmd_ls 的 pane_pid→claude_pid 查法。
      local _pane_pid _claude_pid=""
      _pane_pid=$(tmux list-panes -t "$existing" -F '#{pane_pid}' 2>/dev/null | head -1)
      if [ -n "$_pane_pid" ]; then
        _claude_pid=$(claude_pid_of "$_pane_pid")
      fi
      if [ -z "$_claude_pid" ]; then
        log "'$name' 的 tmux ($existing) 是空壳(无 claude 进程)→ kill 后重起(--resume 保历史)"
        "$CT" kill "$name" 2>/dev/null || true
        # 不 exec attach,不进换模型块 —— 直接落下面 spawn 重起
      else
      # 真 live:补回 v1 的"live 会话就地换 model/key"语义(v2 重构时丢了)。
      # 显式传了 --model/--key 且与 state 现值不同 → 停旧的、写新值、往下 spawn(sid 在→launcher
      # 自动 --resume,历史保留)。没传(纯 crew <name>)→ 仍 attach,不动。
      local _cur_backend _cur_key _want_restart=0
      _cur_backend=$("$CS" get "$name" backend 2>/dev/null || echo "")
      _cur_key=$("$CS" get "$name" key 2>/dev/null || echo "")
      if [ -n "$BACKEND" ] && [ "$BACKEND" != "$_cur_backend" ]; then
        log "切换 '$name' 模型: ${_cur_backend:-<无>} -> $BACKEND(重启,--resume 保历史)"; _want_restart=1
      fi
      if [ -n "$KEY" ] && [ "$KEY" != "$_cur_key" ]; then
        log "切换 '$name' key: ${_cur_key:-<无>} -> $KEY(重启,--resume 保历史)"; _want_restart=1
      fi
      if [ "$_want_restart" = 1 ]; then
        "$CT" kill "$name" 2>/dev/null || true   # 停旧的;sid/state 保留,下面 spawn 会 --resume
      else
        log "'$name' 已 live (tmux=$existing) → attach(换模型/key 加 --model/--key;要新起加 --fresh 或 crew kill 后再来)"
        exec "$CT" attach "$name"
      fi
      fi
    fi
  fi

  # 2026-09-01:走到这 = 确定要 spawn。没传 --model 且会话没记忆过 backend、又是交互终端 →
  # 交互选(新起会话"没输入就交互")。顺序:先选 key,再从【该 key 支持的模型】选(与 switch 一致,
  # 列真实模型名如 GLM-5.3/Claude-Opus-4.7,而非 backend 文件名)。拿不到该 key 的模型才回落全量
  # backend 名。已有记忆 backend 的(重起旧会话)不打扰。非交互(脚本)不弹。
  if [ -z "$BACKEND" ] && [ -t 0 ] && ! "$CS" has "$name" backend 2>/dev/null; then
    # 1) 先选 key
    if [ -z "$KEY" ] && ! "$CS" has "$name" key 2>/dev/null; then
      local _pk; _pk=$(_list_keys | _pick_one "选 key ($name)" "")
      [ -n "$_pk" ] && KEY="$_pk"
    fi
    # 2) 再选该 key 支持的模型(provider/model 全名,可直接用);拿不到 → 提示补 key,不暴露文件名
    local _mopts=""
    [ -n "$KEY" ] && _mopts=$(auto_discover_models "$KEY")  # 拉上游增量,回落静态
    if [ -z "$_mopts" ]; then
      [ -n "$KEY" ] && log "key '$KEY' 没有可路由模型(crew sync-models --key $KEY 补充);可 --model 直接指定"
    else
      local _pm; _pm=$(printf '%s\n' "$_mopts" | _pick_one "选模型 ($name${KEY:+, key=$KEY})" "")
      # 选中裸名新模型 → ensure 落地 + 拼对 selector(2026-10-27 统一 resolve_picked_model)
      if [ -n "$_pm" ]; then
        local _sel; _sel=$(resolve_picked_model "$KEY" "$_pm") \
          || { log "选中模型 '$_pm' 落地失败(上面有指引),忽略该选择"; _pm=""; }
        [ -n "$_sel" ] && _pm="$_sel"
      fi
      [ -n "$_pm" ] && BACKEND="$_pm"
    fi
  fi

  [ -n "$BACKEND" ] && "$CS" set "$name" backend "$BACKEND"
  [ -n "$KEY" ] && "$CS" set "$name" key "$KEY"
  # --policy X:设 per-session policy 文件(v2 修② 2026-08-30)
  if [ -n "$POLICY" ]; then
    if [ "$POLICY" = "-" ]; then
      "$CS" del "$name" policy
      log "AGENT_POLICY session pin cleared for '$name'"
    else
      "$CS" set "$name" policy "$POLICY"
      log "AGENT_POLICY pinned for '$name' -> $POLICY"
    fi
  fi

  # 2026-08-31 audit-crew P2-b:mode 决策(五概念解耦)
  #   --use-current-tmux 最高优先(用户显式意图 = 已在 tmux pane 里,别再 new-session)
  #   --no-tmux 次之:pinned 时忽略(pinned 语义 = "always on tmux"),否则 fg
  #   默认 tmux(new-session)
  local mode="tmux"
  if [ "$USE_CUR_TMUX" = 1 ]; then
    mode="use-current-tmux"
    log "'$name' 使用当前 tmux pane 起 claude(不 new-session,pinned 状态不动)"
  elif [ "$NO_TMUX" = 1 ]; then
    if "$CS" has "$name" pintmux 2>/dev/null; then
      log "'$name' is pinned to tmux (always-on); ignoring --no-tmux."
    else
      mode="fg"
    fi
  fi

  local -a extra_args=()
  [ "$FRESH" = 1 ] && extra_args+=(--fresh)
  [ -n "$task" ] && extra_args+=(--task "$task")

  # 2026-09-02:起会话前预信任 cwd,免 claude 弹 trust dialog 卡住(detached tmux 无人回车→空壳循环)
  _trust_dir "$session_dir"

  "$CL" spawn --name "$name" --mode "$mode" --dir "$session_dir" "${extra_args[@]}"
  local _spawn_rc=$?

  # 2026-09-03:tmux 模式首次新起后自动 attach 进会话(与"已 live 时 crew <name> attach"一致的
  # UX)。之前 spawn 完只打印 ready 停在 shell,用户还得手动 crew attach。仅在:spawn 成功 +
  # tmux 模式(fg/use-current-tmux 已 exec 进 claude,不到这)+ 交互终端(非脚本)时 attach。
  if [ "$_spawn_rc" = 0 ] && [ "$mode" = "tmux" ] && [ -t 0 ] && [ -t 1 ]; then
    exec "$CT" attach "$name"
  fi
  return "$_spawn_rc"
}

# 2026-09-01:机会式自动清理陈旧会话(节流每天一次,后台跑)。排除 prune 自身避免递归;
# 排除纯读命令无妨(它也只是后台触发一次)。live/pinned 绝不删,见 cmd_prune。
