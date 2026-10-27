# crew.d/common.sh — 共享原语:日志/退出/pane→claude pid 探测/远程会话路由层
log() { echo "[crew] $*" >&2; }
die() { log "$*"; exit 1; }

# claude_pid_of <ppid> — 找 pane shell 的 bin/claude 子进程 pid(空 = 空壳/REPL 已退)。
# 2026-10-20 根修:原 `ps --no-headers -o pid,cmd --ppid` 是 Linux-only 语法,macOS BSD ps
# 报 illegal option rc=1 → claude_pid 恒空 → 每次启动误判"空壳"kill 活会话 + heartbeat
# 把 live 记成 dead-repl → watcher autoheal 连环重起(resume 混乱根因)。
# Linux 保留 --ppid 快路径(一次 syscall);macOS(BSD ps)用 -axo pid,ppid 全表 + awk 过滤,
# 兼容路径也兜底 Linux 老机型(探测 --ppid 是否被支持)。
claude_pid_of() {
  [ -n "${1:-}" ] || return 0
  local _pids
  if _pids=$(ps --no-headers -o pid,cmd --ppid "$1" 2>/dev/null); then
    printf '%s\n' "$_pids" | awk '/bin\/claude/{print $1; exit}'
    return 0
  fi
  ps -axo pid,ppid,command 2>/dev/null | awk -v p="$1" '$2==p && /bin\/claude/{print $1; exit}'
}

# ── 远程会话层(2026-10-19 三档合一:发现 / 路由 / 配置)────────────────────────
# 配置文件 ~/.config/claude-crew/remotes(每行: <名> ssh://<host>/<容器> [#注释]),
# 例:jimdb ssh://11.91.165.248/jimdb
# 语义:crew 在本机 registry 找不到会话时,按远程 registry 透明路由——attach/send/status/peek
#       走 ssh 透传(live 优先,tmux 死了先 crew 唤醒)。远程不可达时静默降级,行为与单机一致。

_remote_names() { [ -f "$CREW_REMOTES_FILE" ] && awk '/^[a-zA-Z0-9._-]+[[:space:]]+ssh:\/\//{print $1}' "$CREW_REMOTES_FILE"; }
# _remote_conf <名> → "host container"(无配置返 1)
_remote_conf() {
  [ -f "$CREW_REMOTES_FILE" ] || return 1
  local line
  line=$(awk -v n="$1" '$1==n && $2 ~ /^ssh:\/\//{print $2; exit}' "$CREW_REMOTES_FILE")
  [ -z "$line" ] && return 1
  local spec="${line#ssh://}"
  echo "${spec%%/*} ${spec#*/}"
}
# _rex <远程名> <命令…> → ssh 透传进容器 bash(2s 连接超时;失败静默,由调用方降级)
_rex() {
  local rn="$1"; shift
  local conf; conf=$(_remote_conf "$rn") || return 1
  local host="${conf%% *}" cont="${conf#* }"
  ssh -o BatchMode=yes -o ConnectTimeout=3 "$host" "docker exec $cont bash -c $(printf '%q' "$*")" 2>/dev/null
}
# _rex_tty <远程名> <命令…> → 同上但分配 tty(attach 专用)
_rex_tty() {
  local rn="$1"; shift
  local conf; conf=$(_remote_conf "$rn") || return 1
  local host="${conf%% *}" cont="${conf#* }"
  exec ssh -t -o BatchMode=yes "$host" "docker exec -it $cont bash -c $(printf '%q' "$*")"
}
# _remote_sessions → 全部远程会话清单 "远程名<TAB>会话名<TAB>状态(live|resumable)"。
# 远程全挂 → 空串(不报错:单机用户体验不变)。
_remote_sessions() {
  # 输出 "远程<TAB>会话名<TAB>状态"。registry 名单为底(resumable 全量);
  # live tmux 只把同名条目升级为 live + 补充 registry 之外的裸 tmux 会话(adopted 之类)。
  # 同名不产双行(下游 find/ls 的唯一性判定依赖它)。
  local rn sess live merged
  while IFS= read -r rn; do
    [ -z "$rn" ] && continue
    merged=$(
      { _rex "$rn" "cat ~/.local/share/claude-crew/registry 2>/dev/null" | awk '{print $2}'
        _rex "$rn" "tmux list-sessions -F '#{session_name}' 2>/dev/null" | sed 's/^crew-//'
      } | awk 'NR==FNR{ names[$0]=1; next } { tmon[$0]=1 } END{ for(n in names) print n"\t"(tmon[n]?"live":"resumable"); for(t in tmon) if(!(t in names)) print t"\tlive" }' - <(
          _rex "$rn" "tmux list-sessions -F '#{session_name}' 2>/dev/null" | sed 's/^crew-//')
    )
    while IFS=$'\t' read -r sess live; do
      [ -z "$sess" ] && continue
      printf '%s\t%s\t%s\n' "$rn" "$sess" "$live"
    done < <(printf '%s\n' "$merged")
  done < <(_remote_names)
}
# _find_remote_session <会话名或前缀> → "远程名<TAB>会话名"(唯一匹配;0 或多个都返 1,多个时提示到 stderr)
_find_remote_session() {
  # pat 支持两种匹配:首字符 @ 强制子串匹配(find 用);默认前缀匹配(attach/send 用,防误路由)。
  local pat="$1" hits rn sn mode="prefix"
  case "$pat" in @*) pat="${pat#@}"; mode="substr";; esac
  # 匹配:子串即可(远程流水线会话名是 cc-PIPE-<date>-<pid>-<role> 长名,用户记尾段)。
  # 去重:同远程同名会话 registry(resumable)与 tmux(live)各产一行 → 只留一行(live 优先)。
  hits=$(_remote_sessions | awk -F'\t' -v p="$pat" 'index($2, p)>0')
  [ -z "$hits" ] && return 1
  local n; n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
  if [ "$n" -gt 1 ]; then
    log "会话 '$pat' 在远程匹配到 $n 个,请用更长的前缀:"
    printf '%s\n' "$hits" | awk -F'\t' '{ printf "  [remote:%s] %s\n", $1, $2 }' >&2
    return 1
  fi
  printf '%s' "$hits"
}
