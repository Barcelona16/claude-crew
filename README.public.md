# claude-crew

<p align="right"><a href="./README.md">中文</a> · <a href="./README.en.md">English</a></p>

给 [Claude Code](https://claude.com/claude-code) 的**命名、可 attach、可持久化的 tmux 会话管理器**,后端可插拔。

一个 *crew 会话* = 一个跑着 `claude` 的具名 tmux 会话,绑定一个**名字**、一个**后端**(base URL + 模型 + token + 环境变量)和一个**固定的 session-id**。于是你能:

- **按名字指挥长活 agent** —— `crew api "加限流"`、`crew docs "更新 changelog"`
- **随时 attach 观察它干活** —— `crew attach api` 直接进到活会话里看
- **持久** —— 会话用 `--resume` 接回同一段对话,跨 tmux/宿主机重启不丢
- **每会话可切模型 + key** —— `--model` / `--key` 两个旋钮(经 CCR),一个会话跑 Opus、另一个跑别的模型
- **懒得记 flag?`--pick` 弹菜单选** —— `crew <名> --pick` 依次交互选 model → key → tmux(有 fzf 用 fzf,否则数字菜单);已有会话默认沿用上次配置,回车即可
- **多 key 自动降级** —— 可给一个模型配一串按优先级排的 key,最高优先级的连续失败(401/403/429/5xx)时,本地 `crew-proxy` 自动透明切到下一把,对 claude 无感知

它是一个依赖极少的 bash 脚本(只要 tmux + Claude Code)。无守护进程、无配置服务、**不依赖任何具体项目**。

## 安装

```bash
git clone <this repo> && cd claude-crew
bash install.sh          # 把 `crew` 软链到 ~/.local/bin
crew --help
```

## 一键 `setup.sh`(mac / Linux 通用)

`install.sh` 只装 `crew` 工具本身(会话管理,配合你现成的 Claude 就能用)。要拿到「多模型切换 + key 降级」这套,跑 `setup.sh` 一键配依赖:

```bash
git clone <repo> && cd claude-crew
GATEWAY_TOKEN=<你的API token> bash setup.sh    # 或直接 bash setup.sh 交互输入 token
```

它会:装 crew + claude-code-router(`npm i -g`)→ 用你的 token **生成/合并** CCR provider 配置(不动你已有的 provider)→ 铺模型预设 + `keys.conf` + `key-policy.conf` → 装 `crew-proxy` → **macOS 用 launchd / Linux 用 systemd --user** 把 CCR(`:3456`)和 crew-proxy(`:8788`)起成常驻服务 → 设默认模型。

**前提(各人自备)**:Node.js、tmux、Claude Code CLI、python3(crew-proxy 用);**自己的模型 API token**。装完编辑 `~/.claude-code-router/config.json` 把 `__BASE_URL__` / `__MODEL__` 换成你各家官方 API(Anthropic / OpenAI / 等),再把 `~/.config/claude-crew/backends/*.conf` 的预设名对上。

完事:`crew models` 看模型 · `crew up` 确保依赖在跑 · `crew <名> --model <你的模型>` 开跑。**密钥只落本机**(`~/.claude-code-router/config.json`、`~/.config/claude-crew/keys.conf`),不进 git。

## 用法

```bash
crew mysess "读 src/app.ts 列出它的导出"   # 起/续一个具名会话并(可选)喂任务
crew                      # 对当前目录的会话:ensure + attach
crew mysess --model <模型>   # 切模型(切完自动 attach);--key 切 key
crew mysess --pick           # 弹菜单交互选 model → key → tmux(不用记 flag)
crew ls                   # 列出会话(名字 / 状态 / 模型 / key)
crew models               # 列出模型预设
crew keys                 # 列出 API key 别名(掩码)
crew up                   # 确保依赖服务(CCR / crew-proxy)在跑
crew attach mysess        # attach 观察
crew kill mysess          # 关掉
crew send bob "看下这段"  # 给另一个会话的信箱投消息(见下「会话间通信」)
crew inbox                # 读自己的信箱
```

会话名缺省=当前目录名(重名自动加数字)。目录↔名字映射、每个会话的 session-id 存在
`~/.local/share/claude-crew/`,所以在同一目录再敲 `crew` 会接回同一段对话。

**Flags:** `--model <名>` 选模型预设(`--backend` 是隐藏别名)· `--key <别名>` 切 API key(`--key -` 清除)· `--pick`(`-p`)**交互式菜单依次选 model → key → tmux**(装了 fzf 用 fzf 模糊搜索,否则数字菜单;命令行已给的那项自动跳过;当前目录已有会话时默认高亮它上次的配置,回车即沿用)· `--fresh` 开全新对话(不 `--resume`)· `--safe` 不加 bypass(**bypass 现已默认开**;`CREW_YOLO=0` 全局关)。切 `--model`/`--key` 后在交互终端会**自动 attach**。

## 模型预设(走 CCR)

预设是 `~/.config/claude-crew/backends/<名>.conf`(bash source)。`crew models` 列出全部。
每个预设定义走哪条路(`BASE_URL` / `MODEL` / `TOKEN`)以及 `KEY_MODE`(决定 `--key` 如何落地),
见 [`backends/default.conf.example`](backends/default.conf.example):

| 键 | 含义 |
|-----|---------|
| `BASE_URL` | `ANTHROPIC_BASE_URL`(默认指向 crew-proxy `:8788`,它再转 CCR `:3456`) |
| `MODEL` | `claude --model <MODEL>`;`ccr` 模式写成 `provider,realmodel` |
| `TOKEN` / `TOKEN_CMD` / `TOKEN_ENV` | 入站 auth token(字面量 / 命令 stdout / 环境变量名) |
| `KEY_MODE` | `token`(默认)/ `ccr` —— 见下表 |
| `ENV_EXTRA` | 注入会话的额外 `K=V`(如 `MAX_THINKING_TOKENS=0`) |
| `DANGEROUS` | `1` → 强制 `--dangerously-skip-permissions`(bypass 现已全局默认开) |

**两个旋钮:`--model`(选预设)+ `--key`(选 key)**。`--key` 如何落地由预设的 `KEY_MODE` 决定:

| KEY_MODE | 走法 | `--key <别名>` 效果 |
|---|---|---|
| `token`(默认) | 直连网关,入站 token 即网关凭证 | 把 `ANTHROPIC_AUTH_TOKEN` 换成 `keys.conf` 里那把 |
| `ccr` | 走 [claude-code-router](https://github.com/musistudio/claude-code-router)`:3456`(默认经 crew-proxy),`MODEL=provider,realmodel` | 换成"服务该模型且 api_key==该 key"的 CCR provider(从 CCR config 动态查) |

**推荐 `ccr`** —— CCR 的 Anthropic↔OpenAI 流式翻译正确,key 也集中在 CCR config 一处管。
`--key` 别名在 `~/.config/claude-crew/keys.conf`(`别名=key`),`crew keys` 掩码列出。
要让"任意模型 × 任意 key"都能切,就在 CCR 里给每个模型都备好每把 key 的 provider。

```bash
crew mysess --model default                 # 你的默认模型(经 CCR)
crew mysess --model default --key k2         # 换另一把 key(切到对应 CCR provider)
crew keys                                    # 看 key 别名
```

## 依赖服务(CCR + crew-proxy)

`ccr` 预设依赖两个本地服务在跑:

- **CCR(claude-code-router)`:3456`** —— 统一入口,把 Claude Code 的 Anthropic 请求翻译/转发到各网关,
  并**按 provider 选上游 key**。所有 `ccr` 预设都经它。
- **crew-proxy `:8788`** —— 坐在 claude 与 CCR 之间的薄代理,负责 **key 优先级 + 失败自动降级**。
  某个模型在 `key-policy.conf` 里没配优先级时,它就是**透明转发**,单 key 用户完全无感。

预设的 `BASE_URL` 默认指向 crew-proxy;它再转发给 CCR。二者建议挂 **launchd 常驻**(后台 +
崩溃自拉起 + 开机自启)。crew 会在起 `ccr` 会话时自动 ensure 依赖,也可手动 `crew up`:

```bash
crew up                                  # 确保 CCR:3456 + crew-proxy:8788 都在(按需 kickstart launchd)
```

### 多 key 自动降级

给一个模型配一串按优先级(高→低)排列的 key,`crew-proxy` 会用最高优先级的 healthy key 转发;
它连续失败到阈值(默认 3 次,状态码 401/403/429/5xx 或连接错误)就**熔断**该 key、冷却一段时间
(默认 60s),并**在同一次请求里**透明切到下一把——claude 侧无感知。全部 key 都熔断时,用最高优先级
那把硬转发,把上游真实错误透传出来(不假装成功)。

在 `~/.config/claude-crew/key-policy.conf` 配置:

```
# <模型> = <别名1> <别名2> ...   (高优先级在前)
default = k1 k2 k3
```

前提:每个别名都(a)在 `keys.conf` 里、(b)在 CCR config 里有一个"服务该模型且用这把 key"的 provider。
可用环境变量调:`CREW_PROXY_FAILS`(熔断阈值)、`CREW_PROXY_COOLDOWN`(冷却秒数)、`CREW_PROXY_PORT`、
`CREW_PROXY_DISABLE=1`(整体关掉、直连 CCR)。

装 launchd agent(macOS;plist 由 setup 生成在 `~/.claude-code-router/`):

```bash
cp ~/.claude-code-router/com.claudecrew.ccr.plist   ~/Library/LaunchAgents/
cp ~/.claude-code-router/com.claudecrew.proxy.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.ccr.plist
launchctl load -w ~/Library/LaunchAgents/com.claudecrew.proxy.plist
# 改完 CCR config 后重启(不占终端):
launchctl kickstart -k gui/$(id -u)/com.claudecrew.ccr
```

> **别再前台 `ccr start`** —— 它是前台进程,交给 launchd 托管。端口/label 可用 `CREW_CCR_PORT` /
> `CREW_CCR_LABEL` / `CREW_PROXY_PORT` / `CREW_PROXY_LABEL` 覆盖(便于云端等其它环境适配)。

## 程序化一次性委派

`crew delegate` 起一个 `claude -p --model X` 子进程干活、只把**结果**打到 stdout ——
没有 tmux、没有会话、不 `--resume`。适合脚本里"让某个模型跑个一次性任务、拿结果回来":

```bash
crew delegate --model default "把这50个文件改成 X"   # 一次性委派,结果回 stdout
```

它复用 crew 的模型预设 + `--key` 逻辑,不依赖任何外部工具。核心会话管理不依赖任何具体项目。
需要更复杂的多 agent 编排,可自己写 `ext/*.sh` 扩展(crew 启动时从 `$CREW_HOME/ext/` 加载,有就加载)。

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
