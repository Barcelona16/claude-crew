# crew.d/dsh.sh — dsh/acp 终端编排客户端(Toad/REPL 路由;ACP stdio/list/prompt)
# crew acp —— ACP 透传/列表(2026-10-19 集成;底层 acp/crew-acpd.mjs)。
#   crew acp                  stdio 拉起 ACP server(给 Zed 等 ACP 客户端当 command 用)
#   crew acp list             列平台角色子代理会话(dsh 进程内;ACP session/list 的人读版)
#   crew acp prompt <role>-pipe-<pid> "文本"   单发一条给该子代理,轮询回复打到 stdout
#   crew dsh [流水线 [角色]]  终端 REPL 连 dsh(两级:流水线→角色;对话框样式)

# crew dsh —— 连远程 dsh 编排器(2026-10-20,原 crew chat 更名升级;v3.10 起默认 Toad 富 UI)。
#   crew dsh                    交互:选流水线 → 默认连 lead 对话
#   crew dsh <流水线前缀>       直连(如 wand3;多命中列候选)
#   crew dsh <流水线> <角色>    直连指定角色(如 wand3 designer)
#   crew dsh --list             列流水线×角色
#   crew dsh --repl             内置轻量 REPL(管道/脚本场景)
# UI 路由:v3.10 起 TTY + toad 可执行 → exec toad acp 包 crew-acpd(绑定即显历史);
#   流水线/角色经 CREW_DSH_TARGET=<member> 传 acpd(客户端传不了 pipe:// cwd)。
#   CREW_DSH_UI=repl 同 --repl;CREW_DSH_UI=toad 显式 Toad;toad 未装/非 TTY 回退内置 REPL。
#   Toad = batrachianai/toad(Textual 作者 Will McGugan 的 ACP 客户端,富渲染)。
#   历史:Martty 集成于 v3.6,v3.10 移除(不渲染绑定前 update,历史体验受限)。

cmd_dsh() {
  [ -x "$(command -v node)" ] || die "crew dsh 需要 node"
  [ -f "$DSHMJS" ] || die "缺 $DSHMJS"
  # flag 解析(轻量:只认 --list/--repl/--)
  local ui="${CREW_DSH_UI:-}" args=() target_member=""
  local a
  while [ $# -gt 0 ]; do
    case "$1" in
      --repl) ui="repl" ;;
      --toad) ui="toad" ;;   # 兼容保留(现默认即 toad)
      --list|--) args+=("$1") ;;
      --resolve) ui="resolve"; shift; while [ $# -gt 0 ]; do args+=("$1"); shift; done; break ;;
      *)  [ -z "$target_member" ] && target_member="$1" || target_member="$target_member $1" ;;
    esac
    shift
  done
  # --resolve:仅解析目标 member 名(内部/Martty 通道用),直接转 crew-dsh.mjs
  if [ "$ui" = "resolve" ]; then
    exec node "$DSHMJS" --resolve ${args[@]+"${args[@]}"}
  fi
  # --list 或 repl 模式 → 内置 crew-dsh.mjs
  if [ "$ui" = "repl" ] || [ -n "$(printf '%s' "${args[*]:-}" | grep -F -- --list)" ]; then
    exec node "$DSHMJS" ${target_member:+"$target_member"} ${args[@]+"${args[@]}"}
  fi
  # 默认(CREW_DSH_UI=toad 或未指定):TTY + toad 可执行 → Toad 富 UI(绑定即显历史)
  if [ "$ui" = "toad" ] || [ "$ui" = "" ]; then
    local toad_bin=""
    command -v toad >/dev/null 2>&1 && toad_bin="toad"
    [ -z "$toad_bin" ] && [ -x "$HOME/.local/bin/toad" ] && toad_bin="$HOME/.local/bin/toad"
    if [ -n "$toad_bin" ] && [ -t 0 ]; then
      # 目标解析:有参 → 解析 member 名;无参 → 解析「最新流水线 lead」
      # (与 acpd 自动绑 lead 同规则;镜像跟随,左树永不落到 $PWD —— 2026-10-20 用户实测踩坑)
      # 解析(带重试:--resolve 要 ssh 拉远程成员表,偶发失败会让左树落到兜底目录)
      _resolve_member() {
        local spec="$1" try out
        for try in 1 2 3; do
          out=$(timeout 30 node "$DSHMJS" --resolve "$spec" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
          sleep 1
        done
        return 1
      }
      if [ -z "$target_member" ]; then
        target_member=$(_resolve_member latest) || target_member=""
      else
        target_member=$(_resolve_member "$target_member") || target_member=""
      fi
      # 工作区镜像:rsync 远程流水线工作目录 → 本地(~/.crew/dsh-work/<pid>/),
      # Toad 左侧 project 树 = 远程真实文件(只读镜像;每次启动刷新,CREW_DSH_SYNC=0 跳过)
      local proj_dir=""
      if [ "${CREW_DSH_SYNC:-1}" = "1" ] && [ -n "$target_member" ]; then
        local pid_raw="${target_member##*-pipe-}"   # <role>-pipe-<pid> → pid
        local mirror="$HOME/.crew/dsh-work/$pid_raw"
        mkdir -p "$mirror"
        _dsh_rsync() {
          rsync -az --quiet -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
            --exclude node_modules --exclude .git --exclude '*.log' --exclude target --exclude dist \
            "${CREW_DSH_RSYNC_SRC:-11.91.165.248:/root/claude-work/jimdb/.dsh/jimdb-work/PIPE-$pid_raw/}" "$mirror/"
        }
        if [ -d "$mirror" ] && [ -n "$(ls -A "$mirror" 2>/dev/null)" ]; then
          # 已有镜像:后台增量刷新,不阻塞 Toad 启动
          (_dsh_rsync >/dev/null 2>&1 &) 
          proj_dir="$mirror"
          log "工作区镜像 $mirror(后台增量刷新中)"
        elif _dsh_rsync 2>/dev/null; then
          # 首次:前台全量拉(约 1 分钟内;完成后即时可见完整树)
          proj_dir="$mirror"
          log "工作区镜像 ← 远程 PIPE-$pid_raw 全量 → $mirror"
        else
          log "warn: 工作区镜像 rsync 失败(左树将指向当前目录)"
        fi
      fi
      # 兜底:镜像不可用时也不用 $PWD(用户实测左树指到家目录的坑)——
      # 用 ~/.crew/dsh-work/latest 软链指向最新流水线镜像;再不行用 crew 仓库目录
      if [ -z "$proj_dir" ]; then
        # 解析/同步失败 → 本地已有镜像里挑最新的(目录名含日期,离线可用)
        local fallback
        fallback=$(ls -1 "$HOME/.crew/dsh-work" 2>/dev/null | sort -r | head -1)
        if [ -n "$fallback" ] && [ -d "$HOME/.crew/dsh-work/$fallback" ]; then
          proj_dir="$HOME/.crew/dsh-work/$fallback"
        else
          proj_dir="$HOME/.crew/dsh-work"
          mkdir -p "$proj_dir"
        fi
        log "warn: 镜像未就绪,左树回退 $proj_dir(网络恢复后重启 crew dsh 刷新)"
      fi
      # Claude Code 观感预置(gruvbox 暖底/极简/紧凑;仅补缺省键,不覆盖用户自定义)
      TOADCFG="${TOAD_CONFIG:-$HOME/.config/toad/toad.json}" TOADPRESET="$SCRIPT_DIR/../acp/toad-settings.json" python3 - <<'PYCFG' 2>/dev/null || true
import json, os
cfg_path, preset_path = os.environ['TOADCFG'], os.environ['TOADPRESET']
try:
    cfg = json.load(open(cfg_path))
except Exception:
    cfg = {}
preset = json.load(open(preset_path))
preset.pop('_comment', None)
changed = False
for k, v in preset.items():
    if k not in cfg:
        cfg[k] = v; changed = True
    elif isinstance(v, dict) and isinstance(cfg.get(k), dict):
        for k2, v2 in v.items():
            if k2 not in cfg[k]:
                cfg[k][k2] = v2; changed = True
if changed:
    os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
    tmp = cfg_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=4, ensure_ascii=False)
    os.replace(tmp, cfg_path)
PYCFG
      export CREW_DSH_TARGET="$target_member" CREW_DSH_BIND_REPLAY=1
      # 标题 = 状态栏常驻显示:JIMDB Agent + 作者署名(角色/流水线由 acpd session_info_update 补充)
      log "dsh → Toad 富 UI(绑定即显历史;--repl 回内置)"
      # 注意:toad acp 的 PATH 位置参数与 -d option 在 click 里同名(project_dir),
      # argument 优先 —— -d 会被未传的 PATH(default None)覆盖(实测踩坑:左树落 ~)。
      # 正确姿势:镜像路径作为 COMMAND 之后的 PATH 位置参数传入。
      exec "$toad_bin" acp -t "${CREW_DSH_TITLE:-JIMDB Agent · by wangqiwang1}" "node $ACPD" "$proj_dir"
    fi
    [ "$ui" = "toad" ] && [ -z "$toad_bin" ] && die "toad 未安装(uv tool install -U batrachian-toad)"
  fi
  # 回退:内置 REPL(非 TTY 或 toad 未装)
  exec node "$DSHMJS" ${target_member:+"$target_member"} ${args[@]+"${args[@]}"}
}

# chat 为 dsh 的兼容别名(2026-10-19 首版名,2026-10-20 更名 dsh)

cmd_acp() {
  case "${1:-}" in
    "")
      # stdio 透传:ACP 客户端的 command 配 crew acp 即可。
      exec node "$ACPD" ;;
    list)
      local base="${JIMDB_BASE:-http://11.91.165.248:3200}" erp="${JIMDB_ERP:-wangqiwang1}"
      curl -sS --max-time 10 -H "X-ERP: $erp" "$base/api/projects" \
        | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=[]
for p in d.get("projects") or []:
    if not p["name"].startswith("PIPE-"): continue
    for s in p.get("sessions") or []:
        role=s["name"].split("-pipe-")[0]
        rows.append((s["name"], "pipe://%s/%s"%(p["name"],role)))
for n,c in rows: print("  %-46s %s"%(n,c))
print("(%d 个角色会话;crew acp prompt <名> 发消息)"%len(rows))
' ;;
    prompt)
      shift
      local target="${1:?用法: crew acp prompt <role>-pipe-<pid> "文本"}"
      local text="${2:?缺文本}"
      local base="${JIMDB_BASE:-http://11.91.165.248:3200}" erp="${JIMDB_ERP:-wangqiwang1}"
      curl -sS --max-time 10 -X POST -H "X-ERP: $erp" -H "Content-Type: application/json" \
        -d "{\"session\": \"$target\", \"text\": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$text")}" \
        "$base/api/send" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("✅ 已投递" if d.get("ok") else f"❌ {d.get(chr(101)+chr(114)+chr(114))}")' ;;
    *)
      echo "用法: crew acp            # stdio ACP server(客户端 command)
      crew acp list          # 列平台角色子代理
      crew acp prompt <会话> "文本"   # 单发一条" >&2; return 1 ;;
  esac
}
