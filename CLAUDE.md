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
  crew-dsh.mjs        内置轻量 REPL(--repl/--list/--resolve);crew dsh TTY 默认路由 Toad(bin/crew cmd_dsh)
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
| iTerm 富 UI 聊角色 | `crew dsh wand3`(默认 Toad:绑定即显历史+JIMDB Agent 品牌+工作区镜像;`--repl` 回内置) | 本地 stdio ACP(crew-acpd ↔ :3200 HTTP;rsync 镜像远程工作区) |
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

### 6.1 模型落地链(selector 唯一真相,2026-10-27 400 事故沉淀)

**事故**:dsh_word 选中新发现的裸名模型(key=joycode)→ 拼出 selector
`<model>-joycode/<model>` → provider 不存在 → CCR 400 "All target providers failed"。
三层防线全缺位:ensure 静默失败(set -u 崩在 `BASE="$base"` 未定义)+ launcher 无守卫
+ 错误文案难懂。**同一模型名,joycode 与普通 key 的落地方式不同,selector 拼法也不同**:

| key | ensure 落地动作 | 正确 selector |
|---|---|---|
| joycode | 塞进【已有】`joycode`(Claude 系)或 `joycode-oai`(其余)的 models[] | `joycode[-oai]/<model>` |
| 其他 | 新建 `<model>-<key>` provider | `<model>-<key>/<model>` |

**铁律(改 selector 逻辑必读)**:
1. **拼 selector 只准走 `resolve_picked_model`**(bin/crew)。它 ensure 落地后**反查
   provider map 得出真实 provider 名**,再拼 `provider/model` —— 不允许调用点自己拼
   `$model-$key/$model`(那是普通 key 分支的专属形态)。三个入口(switch / --pick /
   新起菜单)全走它;加第四个入口也走它。
2. **ensure_model_in_ccr 失败必须 fail-loud**:回非零让调用方提示,不静默。落地后
   校验模型确在 map(防半写)。修 set -u 坑:joycode 分支不赋值的变量传 `"${base:-}"`。
3. **launcher 对 `provider/model` selector 有守卫**:provider 不在 provider map → 拒起
   并给修复指引(crew switch 重选 / sync-models / --model 显式指定),绝不带病起会话。
4. **改 map 后必须 `ccr_v3.py --provider-map <map> apply`(带 token)→ drift → doctor**;
   **apply 只写 sqlite 配置,不热加载运行时 —— 必须重启 CCR(kill 老进程,launchd 拉新)
   才生效**。验证基准是 sqlite `app_config.default`(或带 `x-ccr-web-auth` 头的 getConfig
   RPC),**不是 `~/.claude-code-router/config.json`(CCR 2 尸体,别再读它)**。
5. **新模型冒烟**:apply+重启后,用 `client-key` 拿网关 key,curl 打 :8788 全链路
   (crew-proxy→CCR→joycode→上游)确认 200 + 模型真回复,才算落地完成。
6. 测试守护:`test/crew-ensure-selector.test.sh` 13 用例(①-⑧ 覆盖两分支 selector、
   幂等、失败可见、launcher 守卫)。改 ensure/resolve/launcher 守卫必须先跑它。

## 7. 不做什么

- 不改需求(分歧先报 wangqiwang1,不擅改)。
- 不动 send.js / feedback-drain.js / feedback.jsonl 格式(数据面归 agent-bridge)。
- 远程 dsh 侧零改动原则:crew 侧桥接(ACP/MCP)不要求平台改代码。
