# crew.d/commands.sh — 会话与消息命令:ls/attach/menu/stop/kill/pin/adopt/register/wake/send/notify/status/heartbeat/web/inbox/log
cmd_ls() {
  local json_out=0 a
  for a in "$@"; do [ "$a" = "--json" ] && json_out=1; done
  local live_sessions
  live_sessions=$("$CT" list 2>/dev/null || echo "")
  local kr="$SCRIPT_DIR/crew-keyresolve.js"
  [ "$json_out" -eq 0 ] && printf '  %-20s %-9s %-56s %-10s %-30s\n' "NAME" "STATUS" "MODEL" "KEY" "DIR"

  # 2026-08-31 perf:两遍式 —— 第一遍纯 bash/proc 收集每会话 name/sid/backend(真模型)/dir/tmuxname
  # 到数组;然后【一次】node --batch 解析所有会话的 model/key(原来每会话 spawn 一次 node ≈占 ls
  # 耗时一半);第二遍打印。用 `< <(...)` 让循环在主 shell 跑(避免 `list | while` 的 subshell 吞数组)。
  local -a NAMES=() SIDS=() BACKENDS=() DIRS=() TMUXNS=()
  local name rest
  while IFS=$'\t' read -r name rest; do
    [ -z "$name" ] && continue
    local sid backend tmuxname dir claude_pid=""
    sid=$("$CS" get "$name" sid 2>/dev/null || echo "")
    backend=$("$CS" get "$name" backend 2>/dev/null || echo "?")
    # 内联 resolve(见前注):adopted(.tmux)> .tmuxname > live_sessions 查 name/crew-name
    tmuxname=""
    if [ -f "$CREW_STATE/$name.tmux" ]; then tmuxname=$(cat "$CREW_STATE/$name.tmux" 2>/dev/null)
    elif [ -f "$CREW_STATE/$name.tmuxname" ]; then tmuxname=$(cat "$CREW_STATE/$name.tmuxname" 2>/dev/null)
    elif echo "$live_sessions" | grep -qFx "$name"; then tmuxname="$name"
    elif echo "$live_sessions" | grep -qFx "crew-$name"; then tmuxname="crew-$name"
    fi
    dir=""
    # tmux live 时从 /proc 抠真 --model + 真 cwd(见前注)
    if [ -n "$tmuxname" ] && echo "$live_sessions" | grep -qFx "$tmuxname"; then
      local pane_pid
      pane_pid=$(tmux list-panes -t "$tmuxname" -F '#{pane_pid}' 2>/dev/null | head -1)
      if [ -n "$pane_pid" ]; then
        claude_pid=$(claude_pid_of "$pane_pid")
      fi
      if [ -n "$claude_pid" ]; then
        # bash 3.2 + set -u 坑:local 多变量声明不赋值 = unbound(macOS 分支不赋 real_cwd
        # → 249 行 [ -n "$real_cwd" ] 直接崩 "unbound variable",crew ls --json 全挂)。
        # 声明即赋空。
        local real_model="" real_cwd=""
        # 2026-10-20:macOS 无 /proc,用 ps 抠 cmdline(空格分隔,--model 在 argv 里);
        # Linux 保留 /proc 原路径(cmdline \0 分隔更稳,ps 也行但保旧路径不动)。
        if [ -r "/proc/$claude_pid/cmdline" ]; then
          real_model=$(cat "/proc/$claude_pid/cmdline" 2>/dev/null | tr '\0' '\n' | awk '/^--model$/{getline; print; exit}')
          real_cwd=$(readlink "/proc/$claude_pid/cwd" 2>/dev/null)
        else
          local _clcmd=""
          _clcmd=$(ps -o command= -p "$claude_pid" 2>/dev/null || true)
          real_model=$(printf '%s\n' "$_clcmd" | awk '{for(i=1;i<NF;i++) if($i=="--model"){print $(i+1); exit}}')
          # cwd:macOS 无 readlink /proc;lsof -p 太重(每次 ls 都跑),registry 兜底已够,
          # 不再为 dir 增损。real_cwd 留空 → 走下面 registry 反查。
        fi
        [ -n "$real_model" ] && backend="$real_model"
        [ -n "$real_cwd" ] && dir="$real_cwd"
      fi
    fi
    # DIR 兜底:/proc 抠不到 → registry 反查
    if [ -z "$dir" ] || [ "$dir" = "-" ]; then
      dir="-"
      if [ -f "$CREW_STATE/registry" ]; then
        local reg_dir
        reg_dir=$(awk -F'\t' -v n="$name" '$2==n{print $1; exit}' "$CREW_STATE/registry" 2>/dev/null)
        [ -n "$reg_dir" ] && dir="$reg_dir"
      fi
    fi
    NAMES+=("$name"); SIDS+=("$sid"); BACKENDS+=("$backend"); DIRS+=("$dir"); TMUXNS+=("$tmuxname")
  done < <("$CS" list 2>/dev/null)

  # 一次批量 keyresolve:喂 name<TAB>backend,拿回 name<TAB>model<TAB>key。存进两个"并行数组"式查表。
  # 2026-10-16:去关联数组 —— macOS 自带 bash 3.2 不支持 local -A(报 "local: -A: invalid option"
  # 导致 ls 输出空)。改用换行分隔的查表字符串(名字不含换行,validate_name 已限定)。
  local KR_MODEL="" KR_KEY=""
  if [ -f "$kr" ] && command -v node >/dev/null 2>&1 && [ "${#NAMES[@]}" -gt 0 ]; then
    local batch_in="" i
    for i in "${!NAMES[@]}"; do batch_in+="${NAMES[$i]}"$'\t'"${BACKENDS[$i]}"$'\n'; done
    local batch_out
    batch_out=$(printf '%s' "$batch_in" | env -i HOME="$HOME" PATH="$PATH" CREW_STATE="$CREW_STATE" CREW_HOME="$CREW_HOME" CREW_CCR_CONFIG="$CCR_PROVIDER_MAP" node "$kr" --batch 2>/dev/null)
    local bn bm bk
    while IFS=$'\t' read -r bn bm bk; do
      [ -z "$bn" ] && continue
      KR_MODEL="$KR_MODEL$bn"$'\t'"$bm"$'\n'; KR_KEY="$KR_KEY$bn"$'\t'"$bk"$'\n'
    done <<< "$batch_out"
  fi

  # 第二遍:打印(查批量表;缺则回落 state)
  local i
  local json_first=1
  [ "$json_out" -eq 1 ] && printf '['
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    local sid="${SIDS[$i]}" backend="${BACKENDS[$i]}" dir="${DIRS[$i]}" tmuxname="${TMUXNS[$i]}" key=""
    # 查表字符串(换行分隔 name<TAB>value);awk 精确匹配 name 列取第二列
    local m_kr k_kr
    m_kr=$(printf '%s' "$KR_MODEL" | awk -F'\t' -v n="$name" '$1==n{print $2; exit}')
    k_kr=$(printf '%s' "$KR_KEY" | awk -F'\t' -v n="$name" '$1==n{print $2; exit}')
    [ "$backend" = "?" ] && [ -n "$m_kr" ] && [ "$m_kr" != "?" ] && backend="$m_kr"
    [ -n "$k_kr" ] && [ "$k_kr" != "?" ] && key="$k_kr"
    [ -z "$key" ] && key=$("$CS" get "$name" key 2>/dev/null || echo "-")
    local status="new"
    if echo "$live_sessions" | grep -qFx "$tmuxname"; then
      status="live"
      "$CS" has "$name" pintmux 2>/dev/null && status="live 📌"
    elif [ -n "$sid" ]; then
      status="resumable"
    fi
    if [ "$json_out" -eq 1 ]; then
      # 逐字段 JSON 转义(反斜杠与双引号),输出 {name,status,model,key,dir} 数组
      _crew_json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
      [ "$json_first" -eq 1 ] && json_first=0 || printf ','
      printf '{"name":"%s","status":"%s","model":"%s","key":"%s","dir":"%s"}' \
        "$(_crew_json_esc "$name")" "$(_crew_json_esc "$status")" "$(_crew_json_esc "$backend")" \
        "$(_crew_json_esc "$key")" "$(_crew_json_esc "$dir")"
    else
      printf '  %-20s %-9s %-56s %-10s %-30s\n' "$name" "$status" "$backend" "$key" "$dir"
    fi
  done
  [ "$json_out" -eq 1 ] && printf ']\n'
}

cmd_attach() {
  local name="$1"
  [ -z "$name" ] && die "usage: crew attach <name>"
  # 远程路由(2026-10-19):本地 registry/state 没有这个会话 → 查远程;命中则透传 attach
  # (live 直连;resumable 先 crew 唤醒重建 tmux 再 attach)。远程无匹配回落本地原逻辑(会报不存在)。
  if ! "$CS" has "$name" sid 2>/dev/null && ! "$CS" list 2>/dev/null | cut -f1 | grep -qFx "$name"; then
    local rhit; rhit=$(_find_remote_session "$name" 2>/dev/null) || rhit=""
    if [ -n "$rhit" ]; then
      local rn="${rhit%%$'\t'*}" rsn=$(printf '%s' "$rhit" | cut -f2)
      log "远程会话 [remote:$rn] $rsn —— 透传 attach"
      # tmux 活着 → 直 attach;死着(resumable)→ 先 crew 唤醒(重建 tmux 恢复历史),轮询至 20s。
      if ! _rex "$rn" "tmux has-session -t crew-$rsn 2>/dev/null" >/dev/null 2>&1 \
         && ! _rex "$rn" "tmux has-session -t $rsn 2>/dev/null" >/dev/null 2>&1; then
        log "tmux 未运行,先唤醒 resumable 会话…"
        _rex_tty "$rn" "/work/claude-crew-v2/bin/crew $rsn true" </dev/tty >/dev/null 2>&1 \
          || _rex "$rn" "/work/claude-crew-v2/bin/crew-session set $rsn notmux 0" >/dev/null 2>&1
        local ok=0 i
        for i in 1 2 3 4 5 6 7 8 9 10; do
          if _rex "$rn" "tmux has-session -t crew-$rsn 2>/dev/null" >/dev/null 2>&1 \
             || _rex "$rn" "tmux has-session -t $rsn 2>/dev/null" >/dev/null 2>&1; then ok=1; break; fi
          sleep 2
        done
        [ "$ok" = "1" ] || die "唤醒超时:容器里手动排查 docker exec … crew $rsn"
      fi
      # iTerm2 控制模式(-CC)改为显式 opt-in:CREW_TMUX_CC=1。原因:实测容器 tmux 3.0a 与
      # 新 iTerm2 的 -CC 协议不完整兼容(巨量 list-keys 原始报文刷屏 + parse error 直接崩),
      # 且嵌套 tmux 场景(用户在本机 crew 会话里再 attach 远程)检测不可靠。普通 attach 在
      # iTerm2 里同样完全可用(就是普通终端窗口形态);要原生窗口映射再显式开。
      if [ "${CREW_TMUX_CC:-0}" = "1" ]; then
        _rex_tty "$rn" "tmux -CC attach -t crew-$rsn 2>/dev/null || tmux -CC attach -t $rsn"
      else
        _rex_tty "$rn" "tmux attach -t crew-$rsn 2>/dev/null || tmux attach -t $rsn"
      fi
    fi
  fi
  "$CT" attach "$name"
}

# crew(空参)交互菜单:列已有会话选一个 attach,或选"+ 新建会话"进创建流程(问名 → spawn,
# 新起会走 cmd_spawn 里"没输入就弹菜单选模型")。需交互终端(入口已保证)。
cmd_menu() {
  [ -t 0 ] || { cmd_ls; return 0; }   # 无 tty:回落 ls,不去读 /dev/tty(会崩)
  local live_sessions; live_sessions=$("$CT" list 2>/dev/null || echo "")
  # 会话选项:每行 "会话名   (状态·模型)",带一个新建项。用 tab 后缀藏真实会话名便于回取。
  local opts="+ 新建会话" nm st be tn
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    tn=""
    if [ -f "$CREW_STATE/$nm.tmux" ]; then tn=$(cat "$CREW_STATE/$nm.tmux" 2>/dev/null)
    elif [ -f "$CREW_STATE/$nm.tmuxname" ]; then tn=$(cat "$CREW_STATE/$nm.tmuxname" 2>/dev/null)
    elif echo "$live_sessions" | grep -qFx "$nm"; then tn="$nm"
    elif echo "$live_sessions" | grep -qFx "crew-$nm"; then tn="crew-$nm"; fi
    st="resumable"; echo "$live_sessions" | grep -qFx "$tn" && st="live"
    be=$("$CS" get "$nm" backend 2>/dev/null || echo "?")
    opts+=$'\n'"$nm   ($st · $be)"
  done < <("$CS" list 2>/dev/null | cut -f1 | sort -u)

  local chosen; chosen=$(printf '%s\n' "$opts" | _pick_one "crew 会话(选一个 attach,或新建)" "+ 新建会话")
  [ -z "$chosen" ] && return 0
  if [ "$chosen" = "+ 新建会话" ]; then
    local newname=""; printf '新会话名 > ' >&2; read -r newname </dev/tty 2>/dev/null || true
    [ -z "$newname" ] && { log "取消"; return 0; }
    # 2026-09-02:让用户选启动模式(默认 tmux 后台常驻;no-tmux 前台占当前终端)
    local _mode; _mode=$(printf 'tmux (后台常驻,推荐)\nno-tmux (前台,占当前终端)\n' | _pick_one "启动模式 ($newname)" "tmux (后台常驻,推荐)")
    case "$_mode" in no-tmux*) NO_TMUX=1 ;; esac
    cmd_spawn "$newname"   # 新起:cmd_spawn 里没传 --model 会自动弹选模型
  else
    # 取回真实会话名(截 "名   (..." 前段)
    local pick_name; pick_name="${chosen%%   (*}"
    cmd_spawn "$pick_name"  # 已有 live → attach;resumable → 重起
  fi
}

cmd_stop() {
  local name="$1"
  [ -z "$name" ] && die "usage: crew stop <name>"
  if [ -z "${CREW_STOP_ALLOW_SELF_KILL:-}" ] && "$CT" is-inside "$name" 2>/dev/null; then
    die "B2: refuse to stop '$name' — you are running inside its tmux session. Run 'crew stop $name' from OUTSIDE, or set CREW_STOP_ALLOW_SELF_KILL=1 to override."
  fi
  "$CT" kill "$name"
  log "stopped $name (state kept; resume with: crew $name)"
}

cmd_kill() {
  # 2026-08-31 修 flag 顺序 bug:原实现 `local name=$1; shift; [ $1 = --purge ]`
  # 假定 `kill <name> --purge` 严格顺序。用户跑 `crew kill --purge <name>` 时
  # name 被赋值成 "--purge",然后拿字符串 "--purge" 当会话名去 tmux/state clean,
  # 真会话不被杀。改成全程扫描 flag,与主脚本 line 67-73 同哲学(flag 位置无关)。
  local name="" purge=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      --) shift; [ -z "$name" ] && name="${1:-}" && shift; break ;;
      -*) die "unknown flag for kill: $1 (usage: crew kill <name> [--purge])" ;;
      *) [ -z "$name" ] && name="$1"; shift ;;
    esac
  done
  [ -z "$name" ] && die "usage: crew kill <name> [--purge]"
  if [ -z "${CREW_KILL_ALLOW_SELF:-}" ] && "$CT" is-inside "$name" 2>/dev/null; then
    die "B2: refuse to kill '$name' — you are running inside its tmux session. Run 'crew kill $name' from OUTSIDE, or set CREW_KILL_ALLOW_SELF=1 to override."
  fi
  "$CT" kill "$name"
  if [ "$purge" = 1 ]; then
    "$CS" clean "$name" --purge-transcript
    # 2026-09-03 v8 P0(Agent-A3 复审):--purge 时同步清 project.json sessions[] 残留
    # crew-register.js --remove 反向删,支持已有;不阻塞 kill 主流程,失败仅 warn。
    if command -v node >/dev/null 2>&1 && [ -f "$CR" ]; then
      node "$CR" --name "$name" --remove 2>&1 | sed 's/^/  [registry] /' || \
        echo "[crew kill --purge] warn: registry remove '$name' failed (project.json 可能仍有残留)" >&2
    fi
  else
    "$CS" clean "$name"
  fi
  log "deleted session '$name'"
}

cmd_pin() {
  local name="$1"
  [ -z "$name" ] && die "usage: crew pin <name>"
  "$CS" set "$name" pintmux 1
  log "'$name' pinned to tmux — --no-tmux will be refused. Un-pin: crew unpin $name"
}
cmd_unpin() {
  local name="$1"
  [ -z "$name" ] && die "usage: crew unpin <name>"
  "$CS" del "$name" pintmux
  log "'$name' un-pinned — --no-tmux (foreground) is allowed again"
}

cmd_adopt() {
  local a_name="$1" a_tmux="$2"; shift 2
  local a_sid="" a_model=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sid) a_sid="$2"; shift 2 ;;
      --dir) shift 2 ;;
      --model) a_model="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -z "$a_name" ] || [ -z "$a_tmux" ] && die "usage: crew adopt <name> <tmux-session>"
  if ! "$CT" list 2>/dev/null | grep -qFx "$a_tmux"; then
    log "warn: tmux session '$a_tmux' not live right now (adopting anyway)"
  fi
  "$CS" set "$a_name" tmux "$a_tmux"
  [ -n "$a_sid" ] && "$CS" set "$a_name" sid "$a_sid"
  [ -n "$a_model" ] && "$CS" set "$a_name" backend "$a_model"
  # 2026-08-30 audit-crew A5(P0):adopt 也对称写 registry(clean 会删,起就得补)
  local reg="$CREW_STATE/registry"
  mkdir -p "$CREW_STATE"
  if ! [ -f "$reg" ] || ! awk -F'\t' -v m="$a_name" '$2==m{ok=1}END{exit !ok}' "$reg" 2>/dev/null; then
    printf '%s\t%s\n' "$DIR" "$a_name" >> "$reg"
  fi
  log "adopted '$a_name' -> tmux '$a_tmux' (sid ${a_sid:-<none>}); now in crew ls / attach. stop/kill/prune will refuse it. Un-adopt: rm $CREW_STATE/$a_name.tmux"
}

cmd_register() {
  # 注:--dir 被 crew 顶层全局 flag 解析吃进 $DIR(见文件头 74-91 while 循环),这里直接读全局。
  # register 专属 flag(--role/--kind/--bucket/--description/--remove)在本函数解析。
  local name="" role="" kind="" bucket="" desc="" remove=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --role)        role="$2"; shift 2 ;;
      --kind)        kind="$2"; shift 2 ;;
      --bucket)      bucket="$2"; shift 2 ;;
      --description) desc="$2"; shift 2 ;;
      --remove)      remove=1; shift ;;
      -*)            die "crew register: unknown flag $1" ;;
      *)             [ -z "$name" ] && name="$1"; shift ;;
    esac
  done
  [ -z "$name" ] && die "usage: crew register <name> [--dir P] [--role R] [--kind K] [--bucket B] [--description D] [--remove]"
  command -v node >/dev/null 2>&1 || die "crew register 需要 node"
  local args=(--name "$name")
  [ -n "$DIR" ] && args+=(--dir "$DIR")
  [ -n "$role" ] && args+=(--role "$role")
  [ -n "$kind" ] && args+=(--kind "$kind")
  [ -n "$bucket" ] && args+=(--bucket "$bucket")
  [ -n "$desc" ] && args+=(--description "$desc")
  [ "$remove" = 1 ] && args+=(--remove)
  node "$CR" "${args[@]}"  # exit code 透传(0=成功/幂等/remove, 5=无归属 project)
}

cmd_wake() {
  # crew wake <name> [--note "文本"] [--no-queue]
  # exit 透传 crew-wake.js:0=已唤醒 1=会话不存在 2=非 idle 已入 pending 3=tmux 不可用
  local name="" note="" noqueue=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --note)     note="$2"; shift 2 ;;
      --no-queue) noqueue=1; shift ;;
      -*)         die "crew wake: unknown flag $1" ;;
      *)          [ -z "$name" ] && name="$1"; shift ;;
    esac
  done
  [ -z "$name" ] && die "usage: crew wake <name> [--note \"文本\"] [--no-queue]"
  command -v node >/dev/null 2>&1 || die "crew wake 需要 node"
  local args=("$name")
  [ -n "$note" ] && args+=(--note "$note")
  [ "$noqueue" = 1 ] && args+=(--no-queue)
  node "$CW" "${args[@]}"
}

cmd_send() {
  # crew send <name> "msg" [--no-wake] —— 落 JSON 信封到 inbox + 唤醒会话(默认)。
  # 2026-09-02 根治老协议漏 wake 坑(proj-sfw1k 事故):crew send 内部行为改为 send+wake,
  # 与 crew notify 语义合流。原"只落信封不 wake"行为通过 --no-wake 保留(供批量广播用)。
  # 派单代码调 crew send 也自动 wake,不用再单独跟 wake 步骤。
  local no_wake=0 name="" msg_parts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-wake) no_wake=1; shift ;;
      *) if [ -z "$name" ]; then name="$1"; else msg_parts+=("$1"); fi; shift ;;
    esac
  done
  [ -z "$name" ] && die "usage: crew send <name> \"msg\" [--no-wake]"
  [ "${#msg_parts[@]}" -eq 0 ] && die "crew send: 消息不能为空"
  # 远程路由(2026-10-19):本地无此会话 → 远程 send-keys 直接打字进远程 tmux(不经 inbox:
  # 远程会话的 inbox/唤醒机制跑在容器里,本地碰不到;send-keys 语义最接近"给会话发消息")。
  if ! "$CS" has "$name" sid 2>/dev/null && ! "$CS" list 2>/dev/null | cut -f1 | grep -qFx "$name"; then
    local rhit; rhit=$(_find_remote_session "$name" 2>/dev/null) || rhit=""
    if [ -n "$rhit" ]; then
      local rn="${rhit%%$'\t'*}" rsn=$(printf '%s' "$rhit" | cut -f2) rmsg="${msg_parts[*]}"
      _rex "$rn" "tmux send-keys -t crew-$rsn $(printf '%q' "$rmsg") Enter 2>/dev/null || tmux send-keys -t $rsn $(printf '%q' "$rmsg") Enter" >/dev/null 2>&1 \
        && log "✅ 已发送给远程会话 [remote:$rn] $rsn(send-keys;tmux 未运行时先 crew attach 唤醒)" && return 0
      log "远程发送失败(tmux 未运行?)——先 crew attach $rsn 唤醒再 send"
      return 1
    fi
  fi
  local msg="${msg_parts[*]}"
  local sender="${CREW_SESSION_NAME:-crew-send}"
  command -v node >/dev/null 2>&1 || die "crew send 需要 node"
  # 1) 写信封(拿到路径 → id 反查)
  local fpath env_id
  fpath=$(node "$CN" write --to "$name" --from "session:$sender" --note "$msg") || die "crew send: envelope 写失败"
  env_id=$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1])).id)" "$fpath" 2>/dev/null)
  log "queued -> inbox of '$name' (from $sender, id=$env_id)"
  # 2) 默认 wake(--no-wake 保留旧行为供批量广播)
  # 2026-09-02 修 A:wake nudge 里嵌信封原文头 120 字,让会话消费瞬间就看到任务内容,
  # 不会因 crew inbox 忙别的忘读原文(backend proj-sfw1k 事故根因层)。
  [ "$no_wake" = 1 ] && return 0
  local _preview="$(printf '%s' "$msg" | head -c 120 | tr '\n' ' ')"
  local _nudge="收到 @$name 反馈 from $sender(id=$env_id):$_preview … 【必读】跑 crew inbox $name 拿全文;完事按信封「完事汇报 X」要求做汇报"
  node "$CW" "$name" --note "$_nudge"
  local rc=$?
  # 3) wake 成功回写 delivery.wokeAt=now(与 crew notify 语义一致)
  if [ "$rc" = 0 ] && [ -n "$env_id" ]; then
    node "$CN" mark-woke --to "$name" --id "$env_id" >/dev/null 2>&1 || true
  fi
  return $rc
}

cmd_status() {
  # 远程路由(2026-10-19):本地无此会话 → 远程 registry/tmux 命中 → capture-pane 出健康摘要。
  if [ $# -ge 1 ] && ! "$CS" has "$1" sid 2>/dev/null && ! "$CS" list 2>/dev/null | cut -f1 | grep -qFx "$1"; then
    local rhit; rhit=$(_find_remote_session "$1" 2>/dev/null) || rhit=""
    if [ -n "$rhit" ]; then
      local rn="${rhit%%$'\t'*}" rsn=$(printf '%s' "$rhit" | cut -f2)
      echo "[remote:$rn] $rsn(tmux capture 尾部 12 行;空 = 未运行)"
      _rex "$rn" "tmux capture-pane -p -t crew-$rsn -S -12 2>/dev/null || tmux capture-pane -p -t $rsn -S -12 2>/dev/null" | tail -12
      return 0
    fi
  fi
  # crew status <name> [--json]  → 单会话健康摘要(心跳/inbox/pending)
  # exit 契约:0=返健康态 / 4=未注册
  local name="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) [ -z "$name" ] && name="$1"; shift ;;
    esac
  done
  [ -z "$name" ] && die "usage: crew status <name> [--json]"
  command -v node >/dev/null 2>&1 || die "crew status 需要 node"
  # 链路健康(2026-10-28):proxy(:8788)/CCR(:3456)/joycode(:8765) TCP 探测一行摘要。
  # 仅人类模式显示(--json 保持纯 JSON 输出契约);nc 缺失整段跳过。
  if [ "$json" = 0 ] && command -v nc >/dev/null 2>&1; then
    local hl=""
    for _hp in 8788:proxy 3456:ccr 8765:joycode; do
      local _port="${_hp%%:*}" _nm="${_hp#*:}"
      if nc -z -w 1 127.0.0.1 "$_port" >/dev/null 2>&1; then hl="$hl ${_nm}✓"; else hl="$hl ${_nm}✗"; fi
    done
    echo "链路:${hl# }"
  fi
  if [ "$json" = 1 ]; then
    node "$CST" "$name" --json
  else
    node "$CST" "$name"
  fi
}

cmd_heartbeat() {
  # crew heartbeat [--once] [--interval N] [--status]
  # 起心跳采样守护(单例,PID 文件反查);--once 采一次退,--status 查看当前进程
  command -v node >/dev/null 2>&1 || die "crew heartbeat 需要 node"
  node "$CH" "$@"
}

cmd_web() {
  # crew web [--port 18060]  → 起独立前端(单文件 node http,零依赖)
  # 需要心跳:未跑 crew heartbeat 时 ctxPct/tmux 状态是 null(前端仍能显示,只是空)
  command -v node >/dev/null 2>&1 || die "crew web 需要 node"
  node "$CWEB" "$@"
}

cmd_notify() {
  # crew notify <name> "msg" [--no-wake]  = send + wake 复合。
  # send 成功后自动 wake,wake 成功回写 delivery.wokeAt(mark-woke)。
  # exit 契约:0=send+wake 都成 / 2=send 成但目标非 idle(nudge 已入 pending) / 1=目标不存在 / 3=tmux 挂
  local no_wake=0 name="" msg_parts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-wake) no_wake=1; shift ;;
      *) if [ -z "$name" ]; then name="$1"; else msg_parts+=("$1"); fi; shift ;;
    esac
  done
  [ -z "$name" ] && die "usage: crew notify <name> \"msg\" [--no-wake]"
  [ "${#msg_parts[@]}" -eq 0 ] && die "crew notify: 消息不能为空"
  local msg="${msg_parts[*]}"
  local sender="${CREW_SESSION_NAME:-crew-notify}"
  command -v node >/dev/null 2>&1 || die "crew notify 需要 node"
  # 1) 写信封(拿到路径 → id 反查)
  local fpath env_id
  fpath=$(node "$CN" write --to "$name" --from "session:$sender" --note "$msg") || die "crew notify: envelope 写失败"
  env_id=$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1])).id)" "$fpath" 2>/dev/null)
  log "queued -> $name (id=$env_id): $fpath"
  # 2) wake(除非 --no-wake)
  # 修 A:wake nudge 里嵌信封原文头 120 字(见 cmd_send 同款注释)
  [ "$no_wake" = 1 ] && return 0
  local _preview="$(printf '%s' "$msg" | head -c 120 | tr '\n' ' ')"
  local _nudge="收到 @$name 反馈 from $sender(id=$env_id):$_preview … 【必读】跑 crew inbox $name 拿全文;完事按信封「完事汇报 X」要求做汇报"
  node "$CW" "$name" --note "$_nudge"
  local rc=$?
  # 3) wake 成功回写 delivery.wokeAt=now
  if [ "$rc" = 0 ] && [ -n "$env_id" ]; then
    node "$CN" mark-woke --to "$name" --id "$env_id" >/dev/null 2>&1 || true
  fi
  return $rc
}

cmd_inbox() {
  # crew inbox <name> [--peek] [--as <caller>]
  # 默认消费:走 crew-notify.js ack —— 回写 delivery.state=acked + 移到 consumed/ + 镜像 ack 到 feedback.jsonl。
  # --peek 只看不消费(直接 dump JSON/msg 文件,不改状态,不归档)。
  # 身份校验(v8 P0 · Agent-A1 复审加固 2026-09-03):
  #   - $CREW_SESSION **非空**:身份 = CREW_SESSION · --as **被忽略**(不允许 override · 防绕过)
  #     · CREW_SESSION ≠ name → exit 1 拒绝 · stderr 不 hint bypass 命令(防教攻击者)
  #   - $CREW_SESSION **为空**(本地手跑/CI):允许 --as 指定 caller · 无 --as 则不校验(兼容)
  # 兼容:目录里既可能是新 .json 信封,也可能是老 .msg 纯文本(逐步淘汰,消费 rm 无 ack)。
  # audit(v8 P1):写 $CREW_STATE/audit.log 记 caller + name + 结果(--as 使用/拒绝都记)
  local name="$1"; shift
  local peek=0
  local as=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --peek) peek=1; shift ;;
      --as) as="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -z "$name" ] && die "usage: crew inbox <name> [--peek] [--as <caller>]"
  # v8 身份校验:CREW_SESSION 非空 = 会话内(harness runtime)· 强制 caller = CREW_SESSION · --as 被忽略
  # CREW_SESSION 空 = 本地脚本/CI(harness 外)· --as 才生效(兜底)
  local caller
  local audit_note=""
  if [ -n "${CREW_SESSION:-}" ]; then
    caller="$CREW_SESSION"
    if [ -n "$as" ] && [ "$as" != "$caller" ]; then
      audit_note="ignored --as=$as (CREW_SESSION overrides)"
    fi
  else
    caller="$as"
    [ -n "$as" ] && audit_note="via --as (no CREW_SESSION)"
  fi
  # audit log(尽力,不阻塞主流程)
  local _audit="$CREW_STATE/audit.log"
  [ -d "$CREW_STATE" ] && printf '%s inbox target=%s caller=%s peek=%s %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" "${caller:-<none>}" "$peek" "$audit_note" \
    >> "$_audit" 2>/dev/null
  if [ -n "$caller" ] && [ "$caller" != "$name" ]; then
    echo "[crew inbox] denied: caller='$caller' cannot drain inbox of '$name'" >&2
    return 1
  fi
  local dir="$CREW_STATE/inbox/$name"
  [ -d "$dir" ] || { echo "(no messages)"; return 0; }
  if [ "$peek" = 1 ]; then
    local n=0
    for f in "$dir"/*.json "$dir"/*.msg; do
      [ -f "$f" ] || continue
      n=$((n+1))
      echo "── #$n  $(basename "$f") ──"
      if [[ "$f" == *.json ]]; then
        node -e '
          const e=JSON.parse(require("fs").readFileSync(process.argv[1]));
          const d=new Date(e.ts||0);
          const pad=n=>String(n).padStart(2,"0");
          const now=new Date();
          const sameDay=d.getFullYear()===now.getFullYear()&&d.getMonth()===now.getMonth()&&d.getDate()===now.getDate();
          const ts=isNaN(d.getTime())?"":(sameDay?pad(d.getHours())+":"+pad(d.getMinutes())+":"+pad(d.getSeconds()):(d.getMonth()+1)+"-"+pad(d.getDate())+" "+pad(d.getHours())+":"+pad(d.getMinutes()));
          console.log("["+ts+" "+e.from.kind+":"+e.from.id+"] "+e.note+"\n(id="+e.id+" state="+e.delivery.state+")");
        ' "$f"
      else
        # 老 .msg 从文件名解析 ts(命名格式 NNNN-YYYY-MM-DDTHH-MM-SS-...json/msg)
        local basen ts_display
        basen=$(basename "$f")
        ts_display=$(echo "$basen" | sed -nE 's/^[0-9]+-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}).*/\1/p' | sed 's/T/ /; s/-/:/3; s/-/:/3')
        [ -n "$ts_display" ] && echo "[$ts_display legacy]"
        cat "$f"
      fi
      echo
    done
    [ "$n" = 0 ] && echo "(no messages)"
    return 0
  fi
  # 消费:走 crew-notify.js ack,拿到一行一 JSON 信封的输出,打印可读格式。
  command -v node >/dev/null 2>&1 || die "crew inbox 需要 node"
  local n=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=$((n+1))
    printf -- "── #%d ──\n" "$n"
    printf '%s\n' "$line" | node -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        const e=JSON.parse(d);
        const dt=new Date(e.ts||0);
        const pad=n=>String(n).padStart(2,"0");
        const now=new Date();
        const sameDay=dt.getFullYear()===now.getFullYear()&&dt.getMonth()===now.getMonth()&&dt.getDate()===now.getDate();
        const ts=isNaN(dt.getTime())?"":(sameDay?pad(dt.getHours())+":"+pad(dt.getMinutes())+":"+pad(dt.getSeconds()):(dt.getMonth()+1)+"-"+pad(dt.getDate())+" "+pad(dt.getHours())+":"+pad(dt.getMinutes()));
        const src=e.from&&e.from.id?"["+ts+" "+e.from.kind+":"+e.from.id+"] ":(ts?"["+ts+"] ":"");
        console.log(src+e.note);
      })'
    echo
  done < <(node "$CN" ack --to "$name")
  if [ "$n" = 0 ]; then echo "(no messages)"; else echo "(consumed $n message(s), archived to inbox/$name/consumed/)"; fi
}

cmd_log() {
  local name="$1"
  [ -z "$name" ] && die "usage: crew log <name>"
  local sid
  sid=$("$CS" get "$name" sid 2>/dev/null) || die "no sid for '$name'"
  for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  die "transcript for sid '$sid' not found"
}
