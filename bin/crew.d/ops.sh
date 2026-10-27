# crew.d/ops.sh — 运维命令:install-hooks/doctor/version/version-notes/help
cmd_install_hooks() {
  # crew install-hooks [--force]  把仓 hooks/ 装到当前 git 仓的 .git/hooks/
  # 已存在同名 hook 不覆盖(除非 --force)。装完后每次 commit 自动跑 post-commit hook
  # 读 commit message 的 Notify-Session trailer / [TO:xxx] 头,自动 crew notify 相关会话。
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  local src_dir="$SCRIPT_DIR/../hooks"
  [ -d "$src_dir" ] || die "hooks 目录不存在: $src_dir"
  # 当前 git 仓位置(cwd 或 crew 仓)
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "当前不在 git 仓里,请 cd 到仓根后跑"
  local dst_dir="$repo_root/.git/hooks"
  mkdir -p "$dst_dir"
  local installed=0 skipped=0
  for src in "$src_dir"/*; do
    [ -f "$src" ] || continue
    local name; name=$(basename "$src")
    local dst="$dst_dir/$name"
    if [ -f "$dst" ] && [ "$force" != 1 ]; then
      # 已存在:比较内容是否一致
      if cmp -s "$src" "$dst"; then
        log "$name 已装(内容一致)"; skipped=$((skipped+1))
      else
        log "$name 已存在但内容不同(未覆盖;要覆盖加 --force)"; skipped=$((skipped+1))
      fi
      continue
    fi
    cp "$src" "$dst" && chmod +x "$dst" && { log "装 $name → $dst"; installed=$((installed+1)); }
  done
  log "install-hooks: 装了 $installed 个,跳过 $skipped 个(仓根: $repo_root)"
}

cmd_doctor() {
  local fix=0
  [ "${1:-}" = "--fix" ] && fix=1
  # 2026-10-20:doctor 修复力升级 —— 链路问题分两类:
  #   进程类(proxy/CCR 挂了、双起抢端口):--fix 自动拉起/去重,零人工;
  #   配置类(base_url 指错、drift):仍只报告 —— 改 key 必人工 apply 的宪法不动。
  DOCTOR_FIXED=""
  echo "== doctor =="
  echo "CREW_STATE: $CREW_STATE $([ -d "$CREW_STATE" ] && echo ✓ || echo ✗)"
  echo "CREW_HOME:  $CREW_HOME $([ -d "$CREW_HOME" ] && echo ✓ || echo ✗)"
  echo "CS bin:     $CS $([ -x "$CS" ] && echo ✓ || echo ✗)"
  echo "CT bin:     $CT $([ -x "$CT" ] && echo ✓ || echo ✗)"
  echo "CL bin:     $CL $([ -x "$CL" ] && echo ✓ || echo ✗)"
  echo "tmux:       $(command -v tmux || echo '(not found)')"
  echo "sessions:   $("$CS" list 2>/dev/null | wc -l)"

  # 2026-10-16 401 事故防复发:proxy/CCR 联动自检(只报告,不自动改 —— 改 key 必须人工 apply)。
  # 事故两层根因,各对应一个检查:
  #   ① settings.json 的 ANTHROPIC_*_BASE_URL 被指到 :3456 直连 CCR(绕过 crew-proxy)+ apiKeyHelper
  #      与 ANTHROPIC_AUTH_TOKEN 冲突 → 直连 CCR 带 "test" → 401。检查:base_url 必须 :8788、apiKeyHelper 必须不存在。
  #   ② ccr-providers.json 的 gateway.api_key 与 CCR 3 live 配置分叉(改了没 apply)。检查:ccr_v3.py drift。
  if [ -n "${CREW_DOCTOR_SKIP_LINK:-}" ]; then
    :  # 测试/CI 注入跳过(不依赖真实 settings.json/CCR)
  else
    echo "== proxy/CCR 链路(2026-10-16 401 防复发)=="
    local link_bad=0
    local proxy_port="${CREW_PROXY_PORT:-8788}" ccr_port="${CREW_CCR_PORT:-3456}"
    # ① ~/.claude/settings.json 的三个 base_url 必须指 crew-proxy(:8788),不得直连 CCR(:3456)。
    #    用 python 精确解析(settings.json 是缩进多行 JSON,key/value 常分行,纯 grep 会把
    #    key 行误当 bad_url → 假阳性)。检查对象:env 里 *BASE_URL + 顶层 apiKeyHelper。
    local settings_json="$HOME/.claude/settings.json"
    if [ -f "$settings_json" ] && command -v python3 >/dev/null 2>&1; then
      local bad_urls
      bad_urls=$(python3 - "$settings_json" "$proxy_port" <<'PYEOF' 2>/dev/null || true
import json, sys
path, port = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception as e:
    print(f"parse-error: {e}"); sys.exit(0)
env = d.get("env", {}) or {}
for k, v in sorted(env.items()):
    if "BASE_URL" in k and f":{port}" not in str(v):
        print(f"{k} = {v}")
PYEOF
)
      if [ -n "$bad_urls" ]; then
        echo "  ✗ settings.json 有 BASE_URL 不指 crew-proxy :$proxy_port(直连 CCR → 带错 token → 401):"
        printf '    %s\n' "$bad_urls"
        echo "    修:改回 http://127.0.0.1:$proxy_port 并确认无 apiKeyHelper(见 2026-10-16 修复记录)"
        link_bad=1
      else
        echo "  ✓ settings.json BASE_URL 全部指向 crew-proxy(:$proxy_port)"
      fi
      if command -v python3 >/dev/null 2>&1 && python3 -c "
import json,sys
d=json.load(open('$settings_json'))
sys.exit(0 if 'apiKeyHelper' in d else 1)" 2>/dev/null; then
        echo "  ✗ settings.json 有 apiKeyHelper(与 ANTHROPIC_AUTH_TOKEN 冲突 → 实发 token 错 → 401)"
        echo "    修:删掉 apiKeyHelper 字段"
        link_bad=1
      fi
    else
      echo "  - settings.json 不存在或缺 python3(跳过 base_url 检查)"
    fi
    # ② crew-proxy(:8788)与 CCR(:3456)进程存活 —— --fix 时自动拉起(2026-10-20)
    if command -v nc >/dev/null 2>&1; then
      if nc -z 127.0.0.1 "$proxy_port" 2>/dev/null; then
        echo "  ✓ crew-proxy :$proxy_port 在听"
      else
        echo "  ✗ crew-proxy :$proxy_port 未监听(所有会话将无法路由)"
        link_bad=1
        if [ "$fix" = 1 ]; then
          # 优先 launchd(macOS 装机方式):kickstart -k 幂等重拉;无 launchd 条目则
          # nohup 直接起。拉起后 nc 复核。
          if [ -f "$HOME/Library/LaunchAgents/com.claudecrew.proxy.plist" ] && command -v launchctl >/dev/null 2>&1; then
            launchctl kickstart -k "gui/$(id -u)/com.claudecrew.proxy" 2>/dev/null && DOCTOR_FIXED="$DOCTOR_FIXED proxy(launchd kickstart)"
          elif [ -x "$CREW_HOME/crew_proxy.py" ]; then
            nohup python3 "$CREW_HOME/crew_proxy.py" >>"$CREW_STATE/crew-proxy.nohup.log" 2>&1 &
            DOCTOR_FIXED="$DOCTOR_FIXED proxy(nohup)"
          fi
          sleep 2
          if nc -z 127.0.0.1 "$proxy_port" 2>/dev/null; then
            echo "  ✓ --fix:crew-proxy 已拉起"
            link_bad=0
          else
            echo "  ✗ --fix:拉起失败(端口被占?跑 lsof -nP -iTCP:$proxy_port -sTCP:LISTEN 排查)"
          fi
        fi
      fi
      if nc -z 127.0.0.1 "$ccr_port" 2>/dev/null; then
        echo "  ✓ CCR :$ccr_port 在听"
      else
        echo "  ✗ CCR :$ccr_port 未监听"
        link_bad=1
        if [ "$fix" = 1 ]; then
          # CCR = claude-code-router daemon。有 ccr 命令就拉起,等端口,幂等。
          if command -v ccr >/dev/null 2>&1; then
            nohup ccr start >/dev/null 2>&1 &
            DOCTOR_FIXED="$DOCTOR_FIXED CCR(ccr start)"
            local _ccr_wait=0
            while [ "$_ccr_wait" -lt 15 ]; do
              nc -z 127.0.0.1 "$ccr_port" 2>/dev/null && break
              sleep 1; _ccr_wait=$((_ccr_wait+1))
            done
          fi
          if nc -z 127.0.0.1 "$ccr_port" 2>/dev/null; then
            echo "  ✓ --fix:CCR 已拉起"
          else
            echo "  ✗ --fix:CCR 拉起失败(ccr start 后仍无 :$ccr_port;查 ccr status / CCR 日志)"
          fi
        fi
      fi
    fi
    # ③ provider map vs live CCR 分叉(改 key 没 apply 就是这个)。
    #    token 来源:env(CREW_CCR_WEB_TOKEN)> launchd plist 的 proxy Label(com.claudecrew.proxy,
    #    setup.sh 装机时写入)> 放弃(报 skip)。不猜 token、不写死。
    local adapter="${CREW_CCR_V3_ADAPTER:-$CREW_HOME/ccr_v3.py}"
    if [ -f "$adapter" ] && [ -f "$CCR_PROVIDER_MAP" ] && command -v python3 >/dev/null 2>&1; then
      local drift_token="${CREW_CCR_WEB_TOKEN:-}"
      if [ -z "$drift_token" ] && [ -f "$HOME/Library/LaunchAgents/com.claudecrew.proxy.plist" ]; then
        drift_token=$(plutil -extract EnvironmentVariables.CREW_CCR_WEB_TOKEN raw \
          "$HOME/Library/LaunchAgents/com.claudecrew.proxy.plist" 2>/dev/null || true)
      fi
      if [ -n "$drift_token" ]; then
        if CREW_CCR_WEB_TOKEN="$drift_token" CREW_CCR_WEB_URL="${CREW_CCR_WEB_URL:-http://127.0.0.1:3458}" \
             python3 "$adapter" drift --provider-map "$CCR_PROVIDER_MAP" >/tmp/crew-drift.out 2>&1; then
          echo "  ✓ provider map 与 CCR live 配置一致(无 drift)"
        else
          rc_drift=$?
          if [ "$rc_drift" = "1" ]; then
            echo "  ✗ provider map 与 CCR live 配置分叉(gateway/provider key 不一致 → 401):"
            sed 's/^/    /' /tmp/crew-drift.out 2>/dev/null | head -8
            echo "    诊断:python3 $adapter drift --provider-map $CCR_PROVIDER_MAP"
            echo "    修:python3 $adapter apply --provider-map $CCR_PROVIDER_MAP 后重启 crew-proxy"
            link_bad=1
          else
            echo "  - drift 检查无法连上 CCR web RPC(rc=$rc_drift;CCR 未起或 token 未配,跳过)"
          fi
        fi
      else
        echo "  - 无 CREW_CCR_WEB_TOKEN(env/launchd plist 都没有,跳过 drift)"
      fi
    else
      echo "  - ccr_v3.py / provider map 缺失(非 CCR 3 部署,跳过 drift)"
    fi
    [ "$link_bad" = "0" ] && echo "  链路自检通过" || echo "  链路有问题(见上;进程类可 --fix 自动修,配置类需人工)"
  fi

  # 2026-08-30 audit-crew A5(P0):registry 脏行自愈
  # 脏行 = registry 里有 <cwd,name> 但 state 目录里无任何 <name>.<field> 文件
  # (crew clean 已删 state 但 registry 行残留;或试错留下的 owkr 等孤儿名)
  local reg="$CREW_STATE/registry"
  if [ -f "$reg" ]; then
    echo "== registry =="
    local dirty_lines=""
    while IFS=$'\t' read -r cwd name; do
      [ -z "$name" ] && continue
      # state 有任何 <name>.<field> 文件就算干净
      local has_state
      has_state=$(find "$CREW_STATE" -maxdepth 1 -name "$name.*" -not -name "*.pending" -not -name "*.tmp*" 2>/dev/null | head -1)
      if [ -z "$has_state" ]; then
        dirty_lines="$dirty_lines$cwd	$name"$'\n'
        echo "  ✗ 脏行 '$name' @ '$cwd'(state 无 $name.* 文件)"
      fi
    done < "$reg"
    if [ -n "$dirty_lines" ]; then
      if [ "$fix" = "1" ]; then
        # 用 awk 过滤保留干净行
        local tmp
        tmp=$(mktemp)
        while IFS=$'\t' read -r cwd name; do
          [ -z "$name" ] && continue
          local has_state
          has_state=$(find "$CREW_STATE" -maxdepth 1 -name "$name.*" -not -name "*.pending" -not -name "*.tmp*" 2>/dev/null | head -1)
          [ -n "$has_state" ] && printf '%s\t%s\n' "$cwd" "$name" >> "$tmp"
        done < "$reg"
        mv "$tmp" "$reg"
        echo "  ✓ --fix:已删脏行"
      else
        echo "  (跑 'crew doctor --fix' 清除脏行)"
      fi
    else
      echo "  ✓ registry 干净"
    fi
  fi

  [ -n "$DOCTOR_FIXED" ] && echo "本次 --fix 已自动修复: $DOCTOR_FIXED"
}

cmd_version() {
  local commit
  commit=$(cd "$SCRIPT_DIR/.." && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  # 2026-10-16:版本 + release note 从 CHANGELOG.md 读(权威源;发布 = CHANGELOG 顶部加一节)。
  # 格式:## [<ver>] - <date> 头 + 其下 bullet 列表。CHANGELOG 缺失/解析失败回落硬编码。
  local changelog="$SCRIPT_DIR/../CHANGELOG.md"
  if [ -f "$changelog" ]; then
    # 最新(非 Unreleased)版本头 + 该节全部 bullet
    local ver date
    ver=$(sed -n 's/^## \[\([^]]*\)\] - \([0-9-]*\).*/\1/p' "$changelog" | head -1)
    date=$(sed -n 's/^## \[\([^]]*\)\] - \([0-9-]*\).*/\2/p' "$changelog" | head -1)
    if [ -n "$ver" ]; then
      echo "crew v$ver ($date;commit $commit)"
      echo ""
      echo "Release notes(crew version --notes 看全文;CHANGELOG.md 权威):"
      # 当前版本节(从该版本头到下一个 ## 头)内的 bullet 行,去 - 前缀,截 60 字
      sed -n "/^## \[$ver\]/,/^## /p" "$changelog" | grep "^- \|^### " | head -8 | sed 's/^/  /'
      return 0
    fi
  fi
  echo "crew v3.1.0 (commit $commit;CHANGELOG.md 缺失,版本号可能滞后)"
}
cmd_version_notes() {
  local changelog="$SCRIPT_DIR/../CHANGELOG.md"
  [ -f "$changelog" ] || { echo "(CHANGELOG.md 不存在)"; return 0; }
  # 最近 3 个版本节的完整内容(含 Unreleased;跳过文件头部说明)
  awk 'BEGIN{s=0} /^## /{n++; s=1} s && n<=3' "$changelog"
}

# cmd_help —— 分层帮助(2026-10-16:26 个子命令对新人太重,分两栏)。
# 日常层:9 个高频命令,新人在这层就能完成 95% 操作。
# 进阶层:其余命令,各带一行"什么时候才需要"的定位说明。
# help --all 看全量 flag 细节(原头部注释);help <命令名> 同。
cmd_help() {
  # --all/-a:全量命令明细(原头部注释)。其他任何参数(如具体命令名):也回退全量搜索。
  case "${1:-}" in
    --all|-a) sed -n '9,42p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    -*|"") ;;   # 无参:显示分层帮助(下)
    *) sed -n '9,42p' "$0" | sed 's/^# \{0,1\}//' | grep -A3 -B1 -- "$1" || echo "(没找到 '$1';help --all 看全量)"; return 0 ;;
  esac
  cat <<'HEOF'
crew —— Claude Code 常驻会话管理器

日常 10 命令(新手从这里开始):
  crew <名字>              起/进入会话(不带 --model 会弹选模型菜单,菜单自动含上游最新模型)
  crew ls                  列出所有会话(状态/模型/key/目录)
  crew switch <名字>        交互换 key/model(选中即生效)
  crew send <名字> "消息"    给会话发消息(它忙则排队,闲则唤醒)
  crew dsh [流水线]         终端连远程 dsh:选流水线→连 lead,/switch 切子代理
  crew status <名字>        看会话健康(心跳/未读/挂起)
  crew doctor              自检(含 401 防复发链路检查)
  crew kill <名字>          删会话
  crew find <关键词>        搜历史会话(Top5 候选)
  crew version             版本(--notes 看 release note)

进阶(用到再看):
  acp                               ACP 三件套:stdio server(Zed 用)/ list / prompt 单发
  keys/addkey/models/sync-models/model-switch   key 与模型管理(选模型菜单已自动发现,sync-models 批量兜底,model-switch 一键切模型+冒烟验证)
  notify/wake/inbox                消息底层(send 的拆解形态;排查送达问题时用)
  attach/pin/stop                  tmux 细节控制(attach 兼远程透传:crew attach <远程会话前缀>)
  adopt/register/heartbeat/web     会话接管/注册/心跳/前端面板
  log/resume-prev/prune            历史/找回被覆盖的历史/清理陈旧会话
  backends/install-hooks           内部实现/hooks 安装

提示:crew 不带参数 = 交互菜单;任意命令加 --help 看 flag。
完整文档:help --all(或 README.md)
HEOF
}
