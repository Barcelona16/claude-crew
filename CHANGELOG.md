# Changelog

本文件记录 claude-crew 每个版本的显著变化。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/),
版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。日期为提交日。

`crew version` 读取本文件头部渲染版本摘要;新版本发布 = 在本文件顶部加一节 + 提交。

## [Unreleased]

## [3.7.0] - 2026-10-20

### 新增
- **Martty 主题插件「Claude Code」**(JIMDB Agent 专用,作者 wangqiwang1):把 crew dsh
  默认 Martty 富 UI 调成 Claude Code 观感——橙棕 brand #D97757 + 暖底深色 + 琥珀高亮,
  含 light 模式。`acp/martty-plugins/claude-code-theme/plugin.json`(kind: theme),
  装进 `~/.oma/plugins` 后 Martty 内 `/theme` → Claude Code 切换。
  部署:`bash acp/martty-plugins/install.sh`(幂等,支持任意机器)。
  踩坑记录:code.client 须经 applyClientHalf(Function 体普通 JS)——不支持 ESM export,
  须 `return {name, inject, apply}` 对象字面量;离线全链路验证(发现→挂载→注册→激活)通过。

## [3.6.0] - 2026-10-20

### 变更
- **`crew dsh` 默认 Martty 富 UI**(用户拍板):TTY 且装了 martty → 直接 exec Martty
  (DeepSeek Harness 官方 TUI,Rust/ratatui:主题/vim/消息队列/插件)包 crew-acpd;
  `--repl` 或 `CREW_DSH_UI=repl` 回退内置轻量 REPL;martty 未装/非 TTY 自动回退。
  目标选择经 `CREW_DSH_TARGET` 环境变量传 acpd(Martty 传不了 pipe:// cwd):
  `crew dsh wand3 designer` → 先 `--resolve` 解析 member 名再进 Martty。

### 新增
- `crew dsh --resolve <流水线> [角色]`:仅解析目标 member 名(内部通道,可独立用于脚本)。
- acpd `CREW_DSH_TARGET`:未绑定 cwd 会话按环境变量绑指定成员(优先于自动 lead)。

## [3.5.0] - 2026-10-20

### 变更
- **`crew chat` → `crew dsh` 更名 + 两级结构**(用户拍板):命令语义对齐连接对象(dsh 编排器);
  入口两级——先选流水线(默认进 lead 对话),`/switch <role>` 流水线内切子代理,`/roles` 看角色。
  `crew dsh <流水线> [角色]` 支持直连;`chat` 保留为兼容别名。对话框标准渲染:`你 › …` / `<role> › …`。
- acp/crew-chat.mjs → acp/crew-dsh.mjs;新增 groupPipelines(lead 排首 + 角色字母序)、renderTurn。

### 修复
- 角色回合前缀 `
` 覆写在管道/TTY 下不一致 → 改 `
` 换行。
- crew-acpd 支持 `CREW_ACPD_QUIET=1` 静音常规 stderr 日志(crew dsh 拉起时默认设,`CREW_DSH_DEBUG=1` 可开)——
  修日志泄漏进对话框。

## [3.4.0] - 2026-10-19

### 新增
- **`crew chat`——ACP 终端客户端(REPL)**:iTerm 里交互式连远程 dsh 进程内角色子代理。stdio 拉起 crew-acpd → 标准协议,替代 2427b7f 删掉的裸 HTTP 版。三形态:`crew chat`(菜单挑角色)/ `crew chat <前缀>`(直连,如 `designer-`)/ `crew chat --list`;REPL 内 `/list` `/switch <前缀>` `/quit`。agent_message_chunk 流式打印。(17 用例)
- **CLAUDE.md 重写为框架导览**:v3 宪法 → 仓库全景图(目录职责/三层连接体系/数据流/测试地形/维护约束),新会话不用读代码即可上手。

### 修复
- **crew-acpd `session/update` wire 格式**:原扁平形态 `{sessionId, sessionUpdate:{type,…}}` 被 SDK 客户端 zod 校验拒收(Invalid params)——角色回复从未真正流回任何标准 ACP 客户端;修正为嵌套形态 `{sessionId, update:{sessionUpdate:'agent_message_chunk', content:{…}}}`。集成测试 ⑯(SDK client ↔ crew-acpd 端到端往返)拦截并守护。
- **crew chat 非交互路径挂死**:`--list`/错误提前退出后 acpd 子进程 stdio 未关,node 永不退出(实测 timeout 124);所有提前退出路径显式 `acpd.kill() + process.exit`。

## [3.3.0] - 2026-10-16

### 新增
- **分层帮助**:`crew help` 两栏(日常 9 命令 + 进阶分组),`--all` 全量、`help <cmd>` 单命令搜索;不砍命令,兼容既有脚本。
- **release note 体系**:CHANGELOG.md(回填 1.x→3.2.0);`crew version` 读头部渲染版本+摘要,`--notes` 看最近 3 版全文。

## [3.2.0] - 2026-10-16

### 新增
- **选模型菜单自动发现上游模型**(`auto_discover_models`):三处选模型入口(新起自动菜单 / `--pick` / `switch`)弹菜单前静默拉该 key 上游 `/v1/models`,菜单永远最新;新模型选中才落地(`ensure_model_in_ccr` 单个写入 + apply),`sync-models` 降级为手动批量兜底。缓存 5 分钟,`CREW_AUTO_SYNC=0` 可关。(16 用例)
- **`ccr_v3.py apply` 强制关闭 CCR 原生 claudeCode 集成**(三层 profile 开关):根因是 CCR 该集成每次 apply 都会把 `~/.claude/settings.json` 写回 `:3456` 直连 + `apiKeyHelper`,导致所有非 crew 起的会话 401(2026-10-16 两次事故实锤)。

### 修复
- 二次 401 全链路:关闭集成本体(RPC)+ apply 永久免疫(merge_config 守卫)+ CLAUDE.md §3 三层防线。
- `crew-launcher`/`crew-kill` 存量失修测试对齐现行为(§F sid 自愈 / P1 众数 fallback)。

## [3.1.0] - 2026-10-15

### 新增
- **`ccr_v3.py drift`**:provider map 与 CCR 3 live 配置分叉检测(rc=0 一致 / 1 分叉 / 2 不可达),改 key 后必跑 apply → drift 复核。
- **`crew doctor` 链路自检**(401 防复发):settings.json BASE_URL 指向、apiKeyHelper、:8788/:3456 端口、drift 四项。
- **statusline 上下文段**:`ctx42% (116k left)` 分级变色(绿/黄/红);usage 不回传时显 `ctx?` 不显骗人的 0%。
- statusline git 分支 + 工作目录段。

### 修复
- **macOS 可移植性**(全仓测试 61 失败 → 0):`wc -l` 前导空格、写死 `/work/node20`、GNU `date -d`/`touch -d`、`/work/claude-crew` 路径、bash 3.2 无关联数组(`crew ls`/`crew-session` 去 assoc array)。
- 旧逗号 backend 串(`provider,model`)三处归一化(launcher/session/keyresolve)。
- `FEEDBACK_JSONL` 可移植 fallback(无 `/work` 时落 `$CREW_STATE`,修 Mac 上镜像 ENOENT)。
- `crew-session` audit 的 ppid/cmd macOS 兜底(ps 代 `/proc`)。

## [3.0.0] - 2026-10-14

### 变更(破坏性)
- **路由全面迁移到 CCR 3**(commit 2028139):provider map 独立于 CCR SQLite(`~/.config/claude-crew/ccr-providers.json`),经 CCR 3 认证 RPC apply;会话 backend 记 `provider/model` 斜杠 selector(旧逗号串自动兼容)。
- legacy v1/v2 代码从 `main` 拆到 `legacy/v1`、`release/v2` 分支,main 只保留 v3 生产代码。

### 修复
- key 同步时保全 CCR 配置(0447c20)。
- Crew 会话认证隔离(798eb71)。

## [2.5.x] - 2026-09-03 ~ 2026-09-05(v2 末期,见 release/v2)

- v8 通信协议:SendMessage 一等公民、Stop hook 完成回执、`--dedup-key` 防双发、inbox `--as` 身份校验。
- crew-web 前端排查增强;crew-watcher 告警刷屏根治;paneIdle REPL 忙态检测三轮加固。

## [2.0] - 2026-09-01(v2 重构,见 release/v2)

- 顶层 CLI 拆三个独立工具(crew-session / crew-tmux / crew-launcher),21 命令兼容层。
- `crew ls` 批量 keyresolve(单次 node 解析全部会话)。
- 阶段 1 交付 6 项(wake 内建 drainNudge / notify JSON 信封 / 心跳 / register / resume 死 sid 自愈),24/24 集成测试。

## [1.x] - 2026-08-05 ~ 2026-08-31(见 legacy/v1)

- 初版:命名/可 attach/常驻 tmux Claude Code 会话 + 插拔 backend。
- GKD 集成、双语文档。
