# claude-crew

<p align="right"><a href="./README.md">中文</a> · <a href="./README.en.md">English</a></p>

给 [Claude Code](https://claude.com/claude-code) 的**命名、可 attach、可持久化的 tmux 会话管理器**,后端可插拔。

一个 *crew 会话* = 一个跑着 `claude` 的具名 tmux 会话,绑定一个**名字**、一个**后端**(base URL + 模型 + token + 环境变量)和一个**固定的 session-id**。于是你能:

- **按名字指挥长活 agent** —— `crew api "加限流"`、`crew docs "更新 changelog"`
- **随时 attach 观察它干活** —— `crew attach api` 直接进到活会话里看
- **持久** —— 会话用 `--resume` 接回同一段对话,跨 tmux/宿主机重启不丢
- **每会话独立后端** —— 一个会话跑 Claude、另一个跑便宜模型,并排开

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
crew ls                   # 列出运行中的会话
crew attach mysess        # attach 观察
crew kill mysess          # 关掉
crew backends             # 列出后端预设
crew send bob "看下这段"  # 给另一个会话的信箱投消息(见下「会话间通信」)
crew inbox                # 读自己的信箱
```

会话名缺省=当前目录名(重名自动加数字)。目录↔名字映射、每个会话的 session-id 存在
`~/.local/share/claude-crew/`,所以在同一目录再敲 `crew` 会接回同一段对话。

**Flags:** `--backend <名>` 选后端 · `--fresh` 开全新对话(不 `--resume`)· `--yolo` 加 `--dangerously-skip-permissions`。

## 后端

后端是 `~/.config/claude-crew/backends/<名>.conf` 里的预设(按 bash 源码 source)。内置的
`default` 后端就是原生 Claude(用你环境里现成的配置)。所有键都可选,见
[`backends/default.conf.example`](backends/default.conf.example):

| 键 | 含义 |
|-----|---------|
| `BASE_URL` | 覆盖 `ANTHROPIC_BASE_URL`(指向某个代理/网关) |
| `MODEL` | `claude --model <MODEL>` |
| `TOKEN` / `TOKEN_CMD` | auth token,字面量或某条命令的 stdout |
| `ENSURE_CMD` | 起会话前跑的幂等命令(如拉起一个代理) |
| `ENV_EXTRA` | 注入会话的额外 `K=V` 环境变量 |
| `DANGEROUS` | `1` → 加 `--dangerously-skip-permissions` |
| `CLAUDE_FLAGS` | 完全覆盖传给 `claude` 的 flags |

### 例子:把非 Anthropic 模型当会用工具的 agent

[`examples/glm-litellm/`](examples/glm-litellm/) 配了个 `glm` 后端,用
[LiteLLM](https://github.com/BerriAI/litellm) 把 Anthropic `/v1/messages`(带 tool-calling)
翻成 OpenAI 兼容上游 —— 于是一个便宜模型就能当**真正会调工具**的 Claude Code agent,
`crew` 还会按需把代理拉起来。

```bash
bash examples/glm-litellm/setup.sh
export GLM_GATEWAY_TOKEN=...            # 你的上游 token
crew --backend glm worker "跑个快速冒烟测试并汇报"
```

## 与 GKD 配合:交互会话 + 程序化委派

`crew` 管的是**交互式、可观察、长活**的 tmux 会话。而 [GKD](https://github.com/alvis-HaoH/gkd)(搞快点)是**程序化一次性委派**:起一个 `claude -p --model X`
子进程去干活、只把**结果**回传。两者天然互补,crew 直接把 GKD 接了进来:

- **crew 是后端的唯一真源,GKD 借用。** `crew gkd-sync` 把 crew 的 `backends/*.conf`
  投影进 GKD 的 `config/models.json`(一处定义、两处用)。
- **`crew delegate --backend B "任务"`** —— 一次性程序化委派:确保后端起来 → 同步后端到 GKD →
  调 GKD 的 runtime → 把结果打到 stdout。

```bash
crew mysess "长期迭代这个模块"          # 交互:可 attach 盯着看的 tmux 会话
crew delegate --backend glm "把这50个文件改成 X"   # 程序化:GKD 换脑委派,拿结果回来
crew gkd-sync                            # 手动把 crew 后端同步进 GKD models.json
```

**GKD 是可选依赖**:`delegate`/`gkd-sync` 需要 GKD —— 把 `GKD_DIR` 指向你的 GKD checkout
([安装 GKD](https://github.com/alvis-HaoH/gkd));其余功能(会话管理)不装 GKD 也照常用。
crew **不依赖 GKD 也不依赖任何具体项目**。

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

## 说明与坑

- **会话隔离。** 具名会话是持久的(`--resume`),且**继承所在目录的 `CLAUDE.md`**。
  干净的一次性活请用新会话名 + 中性目录(或 `--fresh`)—— 否则旧对话历史或项目的
  `CLAUDE.md` 会把 agent 带偏。
- **容器友好。** "后端起没起"的探测用 bash 内建 `/dev/tcp`(退化到 `nc`/`lsof`/`ss`),
  在没装 `lsof` 的极简容器里也能用 —— 用 `lsof` 判会静默失效、进而重复拉起后端。
- **可移植 UUID**:`uuidgen` / `/proc` / `python3` / `node` / `openssl` 逐个兜底。

## License

MIT —— 见 [LICENSE](LICENSE)。
