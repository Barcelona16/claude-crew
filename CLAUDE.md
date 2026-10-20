# claude-crew · 框架导览(会话启动必读)

> 本文件是新会话(人或 agent)了解本仓库的**第一入口**:是什么、有什么、怎么跑测试、哪些坑不能踩。
> 维护约束(宪法)沉淀在本文末尾;通用会话协议由注入层提供,不重复。
> 方案源:`docs/specs/`(逐 spec 存档)。

## 1. 这是什么

**crew = Claude Code 常驻会话管理器 + 远程 agent 连接层**,三层能力:

| 层 | 入口 | 干什么 |
|---|---|---|
| 本地会话管理 | `crew <名字>` | 具名 tmux 会话起/attach/收发/换模型,CCR 3 路由 |
| 远程 CC 现场 | `crew attach <远程会话前缀>` | ssh → docker exec → tmux attach,接管远程容器里跑着的 CC |
| 远程角色 agent | `crew dsh [流水线 [角色]]` | 终端连 dsh:默认 Martty 富 UI(官方 TUI,主题/插件);`--repl` 回退内置两级 REPL;/switch 切子代理 |

## 2. 仓库地形(改哪里看哪里)

```
bin/crew              唯一 CLI 入口(bash;分发到 ↓)
bin/crew-session      状态管理(project.json / sessions)
bin/crew-tmux         tmux 集成(attach/pin/空壳检测)
bin/crew-launcher     claude 启动(sid 自愈 --resume fallback)
bin/crew-notify.js    inbox 信封 + wake(native messaging)
acp/
  crew-acpd.mjs       ACP server:把远程 dsh 角色(平台 HTTP 面)桥成标准 ACP(stdio);CREW_DSH_TARGET 定向
  crew-dsh.mjs        内置轻量 REPL(--repl/--list/--resolve);crew dsh 默认路由 Martty(bin/crew cmd_dsh)
  martty-plugins/     Martty 插件分发(claude-code-theme 主题;install.sh 装 ~/.oma/plugins)
  crew-mcp.mjs        MCP server:本地 CC 会话经 MCP 工具连远程角色
lib/                  registry 等只读加载器
setup/ccr_v3.py       CCR 3 配置管理(apply/drift;401 防复发核心)
test/*.test.sh        每命令一套;宪法:实现+测试同 PR
web/                  前端面板(:18060)
docs/specs/           方案存档(改架构先写 spec)
```

## 3. 远程连接体系(2026-10-19 定型)

远程机器 `11.91.165.248`,docker 容器 `jimdb` 内跑 dsh 编排器(PID 1):
29 个角色子代理是其**进程内 teammate**(非独立 tmux),平台 HTTP 面 `:3200`(web-forward 转容器 3100)。

三条连接路径,按场景选:

| 场景 | 命令 | 通道 |
|---|---|---|
| iTerm 富 UI 聊角色 | `crew dsh wand3`(默认 Martty)→ `/agent` 切换;`--repl` 回内置 | 本地 stdio ACP(crew-acpd ↔ :3200 HTTP;Martty 经 --agent 包 acpd) |
| 单发一条指令 | `crew acp prompt <成员名> "文本"` | HTTP 直连 |
| 本地 CC 会话里调用 | jimdb-remote MCP 工具(ask/send_role_agent) | MCP |
| 看远程 CC 干活现场 | `crew attach <前缀>` | ssh → docker exec → tmux |
| Zed 等编辑器 | ACP client command 配 `crew acp` | stdio ACP server |

**ACP wire 格式坑**(2026-10-19 实测):`session/update` params 必须是嵌套形态
`{sessionId, update:{sessionUpdate:'agent_message_chunk', content:{type:'text',…}}}`;
扁平形态会被 SDK zod 拒收(Invalid params),回复静默丢失。测试 ⑯ 守护此点。

**ACP SDK 方法常量**:`methods.agent.session.list` / `.new` / `.prompt`(不是 `.listSessions` /
`.newSession` —— 那些不存在,undefined 会让 method 字段消失、消息退化成 response,连接静默挂死)。

## 4. 测试

```bash
bash test/<某命令>.test.sh     # 单套
bash test/crew-integration.test.sh   # 集成+混沌+迁移
```

- 宪法:实现与测试同 PR,无测试拒合。
- 测试不依赖真远程(⑯ 用 fake HTTP 面);个别用例(⑬⑮)对真远程冒烟,不可达时判据放行。
- macOS bash 3.2:禁用关联数组;`stat -c`/`stat -f` 双试;`cat -A` 不存在(用 `cat -et`)。

## 5. 发版

CHANGELOG.md 是版本权威源:`crew version` 读头部渲染。发版 = 顶部加一节(SemVer)+ 提交;
`--notes` 看最近 3 版全文。

## 6. 维护约束(违反=拒合)

- **测试驱动**:单元每命令 5+ 用例;集成 6 场景;混沌 4 类;覆盖率 >85%。
- **并发写用 rename 原子性**:project.json / pending 队列 / delivery ack 一律 tmp + `fs.renameSync`。
- **kill 按端口/精确名**,不按 pattern(tmux has-session 前缀匹配坑)。
- **双 Enter nudge**:`-l` 文本后 150ms Enter,400ms 补一次;**非 idle 不硬 nudge**(串台根因)。
- **失败先诊断根因**,不用 `--no-verify` 绕过;**部署走 git**(容器内改代码必提交)。
- **改 key 必重跑 `ccr_v3.py apply`**,然后 `crew doctor` 复核(401 防复发三层防线见 §3 硬约束历史)。
- **settings.json 的 BASE_URL 只指 crew-proxy(:8788)**,不得直连 CCR(:3456)。
- **CCR 原生 claudeCode 集成保持关闭**(apply 会写回直连配置踩掉修复)。
- **中文汇报**(用户偏好)。

## 7. 不做什么

- 不改需求(分歧先报 wangqiwang1,不擅改)。
- 不动 send.js / feedback-drain.js / feedback.jsonl 格式(数据面归 agent-bridge)。
- 远程 dsh 侧零改动原则:crew 侧桥接(ACP/MCP)不要求平台改代码。
