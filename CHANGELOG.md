# Changelog

本文件记录 claude-crew 每个版本的显著变化。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/),
版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。日期为提交日。

`crew version` 读取本文件头部渲染版本摘要;新版本发布 = 在本文件顶部加一节 + 提交。

## [Unreleased]

- 命令分层帮助(日常 9 命令 + 进阶;`crew help` 两栏,新人只看第一栏)
- `crew version` 自动带最近版本 release note(读 CHANGELOG.md)

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
