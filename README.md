# claude-crew

<p align="right"><a href="./README.md">中文</a> · <a href="./README.en.md">English</a></p>

给 [Claude Code](https://claude.com/claude-code) 的**命名、可 attach、可持久化的 tmux 会话管理器**,后端可插拔。

一个 *crew 会话* = 一个跑着 `claude` 的具名 tmux 会话,绑定一个**名字**、一个**后端**(base URL + 模型 + token + 环境变量)和一个**固定的 session-id**。于是你能:

- **按名字指挥长活 agent** —— `crew api "加限流"`、`crew docs "更新 changelog"`
- **随时 attach 观察它干活** —— `crew attach api` 直接进到活会话里看
- **持久** —— 会话用 `--resume` 接回同一段对话,跨 tmux/宿主机重启不丢
- **每会话可切模型 + key** —— `--model` / `--key` 两个旋钮(经 CCR),一个会话跑 Opus、另一个跑 GLM/kimi

它是一个依赖极少的 bash 脚本(只要 tmux + Claude Code)。无守护进程、无配置服务、**不依赖任何具体项目**。

## 安装

```bash
git clone <this repo> && cd claude-crew
bash install.sh          # 把 `crew` 软链到 ~/.local/bin
crew --help
```

## 用法

```bash
crew mysess "读 src/app.ts 列出它的导出"   # 起/续一个具名会话并(可选)喂任务
crew                      # 对当前目录的会话:ensure + attach
crew mysess --model GLM-5.2  # 切模型(切完自动 attach);--key 切 key
crew ls                   # 列出会话(名字 / 状态 / 模型 / key)
crew models               # 列出模型预设
crew keys                 # 列出 API key 别名(掩码)
crew up                   # 确保依赖服务(CCR / joycode 代理)在跑
crew attach mysess        # attach 观察
crew kill mysess          # 关掉
crew send bob "看下这段"  # 给另一个会话的信箱投消息(见下「会话间通信」)
crew inbox                # 读自己的信箱
```

会话名缺省=当前目录名(重名自动加数字)。目录↔名字映射、每个会话的 session-id 存在
`~/.local/share/claude-crew/`,所以在同一目录再敲 `crew` 会接回同一段对话。

**Flags:** `--model <名>` 选模型预设(`--backend` 是隐藏别名)· `--key <别名>` 切 API key(`--key -` 清除)· `--fresh` 开全新对话(不 `--resume`)· `--safe` 不加 bypass(**bypass 现已默认开**;`CREW_YOLO=0` 全局关)。切 `--model`/`--key` 后在交互终端会**自动 attach**。

## 模型预设(走 CCR)

预设是 `~/.config/claude-crew/backends/<名>.conf`(bash source)。`crew models` 列出全部。
每个预设定义走哪条路(`BASE_URL` / `MODEL` / `TOKEN`)以及 `KEY_MODE`(决定 `--key` 如何落地),
见 [`backends/default.conf.example`](backends/default.conf.example):

| 键 | 含义 |
|-----|---------|
| `BASE_URL` | `ANTHROPIC_BASE_URL`(通常指向 CCR `:3456`) |
| `MODEL` | `claude --model <MODEL>`;`ccr` 模式写成 `provider,realmodel` |
| `TOKEN` / `TOKEN_CMD` / `TOKEN_ENV` | 入站 auth token(字面量 / 命令 stdout / 环境变量名) |
| `KEY_MODE` | `token`(默认)/ `ccr` / `litellm` —— 见下表 |
| `ENV_EXTRA` | 注入会话的额外 `K=V`(如 `MAX_THINKING_TOKENS=0`) |
| `DANGEROUS` | `1` → 强制 `--dangerously-skip-permissions`(bypass 现已全局默认开) |

**两个旋钮:`--model`(选预设)+ `--key`(选 key)**。`--key` 如何落地由预设的 `KEY_MODE` 决定:

| KEY_MODE | 走法 | `--key <别名>` 效果 |
|---|---|---|
| `token`(默认) | 直连网关,入站 token 即网关凭证 | 把 `ANTHROPIC_AUTH_TOKEN` 换成 `keys.conf` 里那把 |
| `ccr` | 走 [claude-code-router](https://github.com/musistudio/claude-code-router)`:3456`,`MODEL=provider,realmodel` | 换成"服务该模型且 api_key==该 key"的 CCR provider(从 CCR config 动态查) |
| `litellm` | 走本地 LiteLLM | 按 key 起对应上游端口(主要给 `claude -p` 委派) |

**推荐 `ccr`** —— CCR 的 Anthropic↔OpenAI 流式翻译正确(交互会话可用,LiteLLM 的流式会吐空 delta),
key 也集中在 CCR config 一处管。`--key` 别名在 `~/.config/claude-crew/keys.conf`(`别名=key`),`crew keys` 掩码列出。
要让"任意模型 × 任意 key"都能切,就在 CCR 里给每个模型都备好两把 key 的 provider。

预设名**就是 CCR 里的模型名**(`crew models` 列出);joycode 服务的模型用 `joycode_<模型>` 前缀区分。joycode 有**两条路**:Claude 系走 `joycode,`(CCR Anthropic transformer → 代理 anthropic 端点),kimi / glm / JoyAI-Code / MiniMax / DeepSeek 等非 Claude 走 `joycode-oai,`(CCR OpenAI transformer → 代理 OpenAI 端点)—— 预设已配好,你只管 `crew --model joycode_<名>`。

```bash
crew mysess --model Claude-Opus-4.8-joybuilder             # Opus-4.8(经 CCR)
crew mysess --model Claude-Opus-4.8-joybuilder --key k8b04 # 换另一把 key(切到对应 CCR provider)
crew mysess --model GLM-5.2 --key k19aa
crew mysess --model kimi-k3-joybuilder                     # kimi(经 CCR)
crew mysess --model joycode_Claude-Opus-4.7-hq            # joycode Claude 系(经 :8765)
crew mysess --model joycode_Kimi-K2.6                     # joycode 非 Claude 系(kimi/glm 等,同经 :8765)
crew keys                                                  # 看 key 别名
```

## 依赖服务(CCR + joycode 代理)

`ccr` 预设依赖本地代理在跑:

- **CCR(claude-code-router)`:3456`** —— 统一入口,把 Claude Code 的 Anthropic 请求翻译/转发到各网关,
  并**按 provider 选上游 key**。所有 `ccr` 预设都经它。
- **joycode 代理 `:8765`**(仅 `joycode_*` 模型需要)—— 读 VS Code 的 JoyCode 登录态、
  HMAC 签名后转发到 JoyCode SaaS 网关。因为这套鉴权是定制的,CCR 无法替代,所以它必须单独跑。

两者建议挂 **launchd 常驻**(后台 + 崩溃自拉起 + 开机自启)。crew 会在起 `ccr` 会话时自动 ensure 依赖,
也可手动 `crew up` 检查并按需拉起:

```bash
crew up                                  # 确保 CCR:3456 + joycode:8765 都在(按需 kickstart launchd)
```

装 launchd agent(macOS;plist 由 setup 生成在 `~/.claude-code-router/`):

```bash
cp ~/.claude-code-router/com.claudecrew.ccr.plist     ~/Library/LaunchAgents/
cp ~/.claude-code-router/com.claudecrew.joycode.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.ccr.plist
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.joycode.plist
# 改完 CCR config 后重启(不占终端):
launchctl kickstart -k gui/$(id -u)/com.claudecrew.ccr
```

> **别再前台 `ccr start`** —— 它是前台进程,交给 launchd 托管。端口/label 可用 `CREW_CCR_PORT` /
> `CREW_CCR_LABEL` / `CREW_JOYCODE_PORT` / `CREW_JOYCODE_LABEL` 覆盖(便于云端等其它环境适配)。
> joycode 代理脚本放在非 TCC 目录(如 `~/.config/claude-crew/`),否则 launchd 读 `~/Desktop` 会被 macOS 拒。

## 可选扩展:GKD 程序化委派

核心 crew = tmux + CCR 切模型/key。可选扩展放在 `ext/*.sh`,crew 启动时从 `$CREW_HOME/ext/` 加载
(有就加载,没有就是纯核心)。[GKD](https://github.com/alvis-HaoH/gkd)(搞快点)做**程序化一次性委派**:
起一个 `claude -p --model X` 子进程干活、只把**结果**回传。启用:

```bash
cp ext/gkd.sh ~/.config/claude-crew/ext/       # 装扩展
export GKD_DIR=/path/to/gkd                     # 指向你的 GKD checkout
crew delegate --model GLM-5.2 "把这50个文件改成 X"  # 程序化委派,拿结果回来
crew gkd-sync                                    # 把 crew 预设同步进 GKD models.json
```

没装扩展时,`delegate`/`gkd-sync` 会提示如何安装。核心会话管理不依赖 GKD,也不依赖任何具体项目。

## 会话间通信(异步信箱)

会话之间靠**信箱**通信:`crew send` 把消息投进对方信箱(文件),对方在方便时用 `crew inbox` 读。
因为 `crew` 在 PATH 上,**会话里的 agent 可以自己 `crew send 别的会话 "..."`**——这就是 agent 间协作。

```bash
crew send bob "帮我 review 限流分母那段"        # 投递(异步,不打断对方)
crew send --nudge bob "急,看下这个"            # 投递并往对方会话注入一行"你有新消息"提醒
crew send --all "都停一下,主干要改了"           # 广播给所有运行中的会话
crew inbox                                       # 读+清空自己的信箱(在会话内自动认领本会话)
crew inbox --peek bob                            # 只看不清空
```

每条消息带发信人(`--from`,缺省=`$CREW_SESSION` 或 `cli`)和时间。会话启动时 crew 会把
`CREW_SESSION=<名字>` 注入进去,所以会话内的 agent 知道"我是谁"、投递会自动署名。
信箱是**异步**的:默认不打断收件人,想立刻提醒用 `--nudge`。

## tmux:滚轮翻历史 + 选中即复制

`crew attach` 进去后,如果 tmux 鼠标是关的,滚轮会翻成 shell 的命令历史而不是 Claude 的输出,
选中也没法复制到系统剪贴板。`crew` 已经给它建的会话**自动开 `mouse on`**(仅作用于 crew 会话,
不动你全局配置),所以滚轮翻动开箱即用。但"选中即复制到系统剪贴板"是 tmux 键表绑定,得在你自己的
`~/.tmux.conf` 里加一段:

```tmux
set -g mouse on
set -g history-limit 50000
# 滚轮在普通 pane 里自动进 copy-mode 翻历史
bind-key -T root WheelUpPane if-shell -F "#{alternate_on}" "send-keys -M" "copy-mode -e"
# 选中即复制到系统剪贴板(macOS 用 pbcopy;Linux 换成 "xclip -selection clipboard")
setw -g mode-keys vi
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "pbcopy"
bind-key -T copy-mode-vi Enter            send-keys -X copy-pipe-and-cancel "pbcopy"
bind-key -T copy-mode-vi y                send-keys -X copy-pipe-and-cancel "pbcopy"
```

> Terminal.app 不支持按住 `Option` 绕过 tmux 鼠标(那是 iTerm2 的特性),所以走 copy-mode
> 的路子最稳:拖拽选中 → 松开即进剪贴板 → `Cmd+V` 粘贴。iTerm2/Ghostty 则两种方式都行。

## 说明与坑

- **会话隔离。** 具名会话是持久的(`--resume`),且**继承所在目录的 `CLAUDE.md`**。
  干净的一次性活请用新会话名 + 中性目录(或 `--fresh`)—— 否则旧对话历史或项目的
  `CLAUDE.md` 会把 agent 带偏。
- **容器友好。** "后端起没起"的探测用 bash 内建 `/dev/tcp`(退化到 `nc`/`lsof`/`ss`),
  在没装 `lsof` 的极简容器里也能用 —— 用 `lsof` 判会静默失效、进而重复拉起后端。
- **可移植 UUID**:`uuidgen` / `/proc` / `python3` / `node` / `openssl` 逐个兜底。

## License

MIT —— 见 [LICENSE](LICENSE)。
