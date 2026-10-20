#!/bin/bash
# crew-statusline.sh —— Claude Code statusLine:会话底部常显「会话名 · 模型 · 🔑key · 上下文 · git分支」。
#
# 为什么需要它:/model 和 stdin JSON 的 display_name 都只给通用档名("Opus 4.8"),
# 看不出实际路由到哪个后端 + 用哪把 key。覆盖 crew / `ccr code` 直起 / 直连三种起法。
# 2026-10-15 增段:上下文占比(自定义 statusline 会替换掉内置百分比显示,所以必须
# 自己从 stdin JSON 的 context_window 字段算出来补上)+ git 分支 + 输出风格。
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
# node 缺失或失败则降级到纯 env 展示。node 实测 ~70ms,可接受。jq 缺失时上下文段静默省略
# (脚本其余部分只用 sed/grep,不依赖 jq)。
set +e 2>/dev/null

# Claude Code 从 stdin 灌 session JSON(可能空);读掉但不阻塞(claude 会关 stdin)。
input="$(cat 2>/dev/null)"

STATE="${CREW_STATE:-$HOME/.local/share/claude-crew}"

# 从 stdin JSON 抠一个字符串字段(best-effort,不管嵌套;失败返回空)。
json_str(){ printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
# 从 stdin JSON 抠一个数字字段(整数部分;jq 缺失时 sed 兜底)。
json_num(){
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
  else
    printf '%s' "$input" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p" | head -1 | cut -d. -f1
  fi
}
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
# 交给共享解析器 crew-keyresolve.js(与 `crew ls` 同一份逻辑,单一真源):它读 CCR config /
# keys.conf / key-policy.conf,按本会话 live env(ANTHROPIC_BASE_URL / CREW_MODEL / CREW_KEY,
# 子进程自动继承)+ base_url 分路由解析。node 实测 ~70ms,可接受;缺 node/脚本则走下方纯 env 降级。
# CREW_STATUSLINE_MODEL/KEY:测试注入通道(2026-10-20)—— keyresolve 读真机 CCR config,
# 测试隔离环境无法控制其输出;显式 env 跳过解析,专测渲染逻辑本身。
model="${CREW_STATUSLINE_MODEL:-}"; key="${CREW_STATUSLINE_KEY:-}"
_kr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_kr="$_kr_dir/crew-keyresolve.js"
if [ -z "$model" ] && command -v node >/dev/null 2>&1 && [ -f "$_kr" ]; then
  res="$(CREW_STATE="$STATE" SESS="$sess" node "$_kr" "$sess" 2>/dev/null)"
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

# ---------- 3.5) 上下文段(2026-10-15 加,当晚因数据源不可靠 revert;2026-10-16 恢复)----------
# 恢复依据:revert 时 llm-gw 的 GLM-Local 链路流式 usage 几乎全 null(34407:17),
# CC 端 total_input_tokens 恒为 0;2026-10-16 实测(临时捕获 statusline stdin)该链路
# 已回传真实 usage(total_input_tokens=44705 / used_percentage=22 / 窗口 200k),数据源恢复。
# 数据源:stdin JSON 的 context_window(CC ≥2.1 提供 used_percentage/remaining_percentage/
# context_window_size/total_input_tokens)。分级变色:>90% 红(危险,即将自动压缩)、
# 75-90% 黄(注意)、其余绿(健康)。jq 缺失/字段缺失时整段静默省略,不影响其他段。
# 注意:usage=0(input_tokens 也为 0/缺失)说明网关没回传真实 usage,只显暗色 ctx?
# 而不是骗人的绿色 0%(2026-10-15 revert 留下的教训:数据不可靠时宁缺毋滥)。
ctx_seg=""
used="$(json_num '.context_window.used_percentage' 'used_percentage')"
in_tok="$(json_num '.context_window.total_input_tokens' 'total_input_tokens')"
if [ -n "$used" ] && [ "$used" != "null" ] 2>/dev/null && { [ -z "$in_tok" ] || [ "$in_tok" != "null" ] && [ "$in_tok" -gt 0 ] 2>/dev/null; }; then
  # 剩余 token 绝对值(千位简写,如 116k)——比纯百分比更有行动价值(还够聊几个回合)。
  win_tok="$(json_num '.context_window.context_window_size' 'context_window_size')"
  # 2026-10-20:按模型覆盖真实 window 改读配置 ~/.config/claude-crew/model-windows.conf
  # (与 crew-launcher 注入 CLAUDE_CODE_MAX_CONTEXT_TOKENS 同源,改一处两边一致)。
  # CC 传的 200k 是未知模型假定值,不是上游真实窗口。conf 缺失时回落旧硬编码表。
  # (顶层脚本无函数,不能用 local — bash 顶层 local 会静默失败连赋值一起丢)
  _mw="${CREW_HOME:-$HOME/.config/claude-crew}/model-windows.conf"
  _mw_win=""
  if [ -f "$_mw" ]; then
    _mw_win=$(awk -F= -v m="$lc" '$1!="" && index(m, tolower($1)) {print $2; exit}' "$_mw" 2>/dev/null)
  fi
  if [ -n "${_mw_win:-}" ]; then
    win_tok="$_mw_win"
  else
    # 旧硬编码兜底(conf 被删/未装)
    case "$lc" in
      glm-5.3*|glm5.3*) win_tok=1000000 ;;
      glm-5.2*|glm5.2*) win_tok=200000 ;;
      kimi*) win_tok=200000 ;;
      claude*|opus*) win_tok=200000 ;;
    esac
  fi
  left_k=""
  if [ -n "$in_tok" ] && [ -n "$win_tok" ] && [ "$in_tok" -ge 0 ] && [ "$win_tok" -gt 0 ] 2>/dev/null; then
    left_val=$(( win_tok - in_tok ))
    if [ "$left_val" -lt 0 ]; then
      left_k="超了"
    else
      left_k="$(( left_val / 1000 ))k"
    fi
  fi
  used="${used%.*}"  # 42.0 -> 42(有小数时)
  case "$used" in
    ''|*[!0-9]*) ;;                       # 非数字:整段跳过
    *) if [ "$used" -ge 90 ]; then c_ctx=$'\033[31m'    # red   >=90% 快压缩了
       elif [ "$used" -ge 75 ]; then c_ctx=$'\033[33m'  # yellow 75-89%
       else c_ctx=$'\033[32m'                           # green <75%
       fi
       if [ -n "$left_k" ] && [ "$used" -gt 0 ]; then
         ctx_seg="$(printf ' %s·%s %sctx%s%% %s(%s left)%s' "$c_dim" "$c_reset" "$c_ctx" "$used" "$c_ctx" "$left_k" "$c_reset")"
       else
         ctx_seg="$(printf ' %s·%s %sctx%s%%%s' "$c_dim" "$c_reset" "$c_ctx" "$used" "$c_reset")"
       fi ;;
  esac
elif [ -n "$used" ] && [ "$used" = "0" ] 2>/dev/null; then
  # usage=0 且 input_tokens 也是 0/缺失:网关没回传真实 usage(部分链路偶发),
  # 显暗色 ctx? 而不是骗人的绿色 0%。
  ctx_seg="$(printf ' %s·%s %sctx?%s' "$c_dim" "$c_reset" "$c_dim" "$c_reset")"
fi

# ---------- 3.6) git 分支段 + 工作目录段(2026-10-15)----------
# cwd:优先 stdin JSON 的 workspace.current_dir(会话可 cd,比启动目录准),降级 PWD。
# 显示 $HOME 缩写 + 只显尾部两级(路径长会挤掉模型段;两级足够定位)。
git_seg=""
cwd="$(json_str current_dir)"; [ -z "$cwd" ] && cwd="$(json_str cwd)"
[ -z "$cwd" ] && cwd="$PWD"
if [ -n "$cwd" ] && [ -f "$cwd/.git/HEAD" ]; then
  br="$(sed -n 's|^ref: refs/heads/||p' "$cwd/.git/HEAD" 2>/dev/null | head -1)"
  [ -n "$br" ] && git_seg="$(printf ' %s·%s %s%s%s%s' "$c_dim" "$c_reset" "$c_dim" "$br" "$c_reset" "")"
fi
dir_seg=""
if [ -n "$cwd" ] && [ "$cwd" != "/" ]; then
  d_show="${cwd/#$HOME/\~}"
  # 尾部两级(tilde 单独成段不算层级)
  case "$d_show" in
    "~"|"/tmp"|"/var/tmp") ;;        # 家目录本身/系统临时目录:整段显示
    */*)
      tail2="$(printf '%s' "$d_show" | awk -F/ '{ if (NF>=2) print $(NF-1)"/"$NF; else print $NF }')"
      [ -n "$tail2" ] && d_show="$tail2"
      ;;
  esac
  dir_seg="$(printf ' %s·%s %s%s%s' "$c_dim" "$c_reset" "$c_dim" "$d_show" "$c_reset")"
fi

# ---------- 4) 输出(单行,无尾换行)----------
# 组装:⬡ [<会话名> · ]<模型> · 🔑<key> · ctx上下文% (剩余) · 分支 · 目录
c_key=$'\033[35m'   # magenta 区分 key 段
key_seg="$(printf ' %s·%s %s🔑%s%s' "$c_dim" "$c_reset" "$c_key" "$key" "$c_reset")"

if [ -n "$sess" ]; then
  printf '%s⬡ %s ·%s %s%s%s%s%s%s%s' "$c_dim" "$sess" "$c_reset" "$c_model" "$model" "$c_reset" "$key_seg" "$ctx_seg" "$git_seg" "$dir_seg"
else
  printf '%s⬡%s %s%s%s%s%s%s%s' "$c_dim" "$c_reset" "$c_model" "$model" "$c_reset" "$key_seg" "$ctx_seg" "$git_seg" "$dir_seg"
fi
