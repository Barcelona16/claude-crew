# Changelog

本文件记录 claude-crew 每个版本的显著变化。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/),
版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。日期为提交日。

`crew version` 读取本文件头部渲染版本摘要;新版本发布 = 在本文件顶部加一节 + 提交。

## [Unreleased]

## [4.0.2] - 2026-10-28

### 剥离对外共享层(proxy 回归个人使用)
- **删除面向外部用户的整套注册/门票机制**:登录页(快速接入文案/hero 图/注册表单)、
  `/api/register`(自助注册,实测 key→入池+CCR provider+policy+登录条目)、`/api/gateway/auth`
  (门票增删改)与 `/api/register-allow`(新注册者默认模型)全部移除;登录页精简为单行
  key 输入条,鉴权(gateway-auth.json admin 判定)与 Key 池/模型策略/应急会话保留。
- **删除宣传与静态资源**:#intro crew 宣传页(仓库链接/CCR 接入说明)与两张静态图路由
  (/crew-demo.gif、/crew-proxy-hero.png)移除;`_crew_config` 的 CREW_DEMO_GIF/
  CREW_HERO_PNG/REGISTER_*/register_allow_list/_raw_gateway_auth 常量与函数清理。
- **净减代码**:_crew_handler.py -296 行、crew_proxy.py 门面 -297 行、_crew_config.py 清理;
  双写 USAGE_HTML 与 Handler 仍逐字节一致;test_crew_proxy.py 同步删注册/门票测试块。
- 实测:/dashboard 精简页 0 残留、/usage 302、被删端点 404、/v1/messages 转发与
  /api/usage 延迟统计正常。

## [4.0.1] - 2026-10-28

### 监控页统一
- **单一入口 /dashboard**:以 /usage(功能超集)为基底合成综合 dashboard,补入原 /dashboard 独有的
  Sessions 表(/api/sessions,含 copy/edit/kill 会话操作)、Recent requests 日志表(/api/logs?n=100)
  与 proxy status meta(/api/status:端口/ccr_url/trip/cooldown);保留登录/注册、token 序列图、
  延迟分布 24h、健康状态、应急会话、Key 池/模型策略/登录表管理。深色 UI 风格与既有页一致。
- **路由**:/dashboard(/dashboard/) 返回综合页;/usage 与 /usage/ 302 → /dashboard(旧链接兼容)。
- **快速接入文案地址修正**:3 处硬编码 11.91.165.248:8790(旧网关)改为占位符 __CREW_ADDR__,
  服务端按请求 Host 动态填充(回退 server_address/127.0.0.1:8788)——纯 .replace 注入,HTML 常量
  保持普通字符串,无 f-string 转义风险。
- backends/crew-gateway.conf.example 的 BASE_URL 与注释同步 8788(注:dsh/common 的 11.91.165.248:3200
  是 JimDB 远端开发机默认值,非网关文案,未动)。

## [4.0.0] - 2026-10-28

### 重构(全面检查重构,保功能只改内部)
- **bin/crew 2314 行 bash 单体 → 薄入口 + bin/crew.d/{common,models,session,commands,ops,dsh}.sh 六模块**:
  命令分发/模型管理/会话管理/launcher 各归其位;拆前先列 62 函数对外能力清单,拆后逐项核对零丢失;
  `bash -n` + 全量测试 + 链路实测(:8788→CCR→上游 text_delta)通过。未提交的 resolve_picked_model
  兜底改动(反查 provider 改按模型名兜底,CREW_HOME 显式传参)整合进 models.sh 保留。
- **setup/crew_proxy.py 2946 行 py 单体 → 门面 + _crew_{config,windows,breaker,stats,server,handler} 六模块**:
  配置加载/窗口校准/熔断/统计/HTTP 转发各归其位;未提交的 BrokenPipe/ConnectionResetError 加固保留。
  Handler 类与 HTML 常量在门面与 _crew_handler.py 双写,逐字节一致(测试依赖门面副本)。
- 小文件审计:crew-launcher/crew-heartbeat.js/crew-watcher.js/joycode_proxy.py/_responses_compat.py 无冗余,不动。

### 测试(慢测试根治 + 统一入口,只改执行方式不砍断言)
- **test/run-all.sh 统一入口**:一条命令跑完 22 bash + 5 python + crew-proxy-boot + scenarios,
  PASS/FAIL + 耗时汇总;看门狗 SIGKILL(180s);`--only <名>` 单测、`--with-scenarios` 场景。
  全量 29/29 绿,墙钟 ~502s。
- 慢测试根治:claude-pid sleep 300 → sleep 5 + 轮询探测(10s→1s);autodiscover fake_gw 端口等待
  90s 看门狗 → 15s kill -9 + 端口轮询;scenarios BSD sed 归一;GNU timeout 可移植 shim;bash 3.2
  空数组坑用 homebrew bash 5 前置 PATH;本环境 SIGTERM 屏蔽 → 所有 kill 改 kill -9。
- 修复:claude-pid T3 OUTSIDE 提取 awk 写坏(恒误报)改为只取函数外非注释行 4/4;
  crew-tmux Case 7 固定 sleep 改 30×0.2s 轮询(全量负载下再扩至 15s)19/19;
  scenarios 基线刷新(07-kill-purge 过期纪元 + 05-doctor 随应急通道删除重录)。

### 部署 / 运行时
- **bin/crew-deploy.sh**:repo setup/*.py → ~/.config/claude-crew/ 幂等同步(md5 跳过 + py_compile 门禁),
  `--check` 只读预览,变更集重启对应 launchd 服务 + 4s 验证,消灭手工同步。
- joycode launchd plist 与 setup/launchd 模板对齐(修复 5 类漂移)。
- **Sol 流式打通**:根因 = 上游 GPT-6.1-Sol-A 从不发 `data: [DONE]`,流尾正常 `response.completed`、
  截断 `response.incomplete`,而 CCR 包内 next-ai-gateway.js 的 $rt 只认 completed+delta;
  最小 patch 纯新增两分支(备份 .bak-20261028-005929),三路真实验证(正常/截断/回归)全过。
  ⚠️ npm -g 升级会覆盖,幂等 postinstall 补丁脚本未做(已披露)。
- **窗口校准准确性**:GLM-5.3 = 1M(1,048,576)确证(官方文档 + 上游自报),非 200k;
  修真实算法 bug:maybe_calibrate_from_error 上下界方向用反(被拒估算 R 被优先写入会写大窗口致死锁),
  改优先 proven-safe 成功最大输入 + 10% margin。

### 监控 / 可诊断性
- **/usage 服务健康**:/api/usage 纯新增 `health{proxy,ccr}`(:3456 1s TCP 探测),页面顶部
  「proxy ✓ / CCR ✓|✗」状态行,30s 轮询刷新。
- **模型延迟分布(近 24h)**:CCR 转发链路全部 STATS.record 补 latency(根因:alias 路径从没传)
  + 流式 TTFT;LatencySeries(小时桶 + Reservoir,成功样本才进分位)持久化 latency.json(0600/20s 节流/重启不丢);
  /api/usage 纯新增 latency 字段 + /usage 页延迟分布卡片(P50/P90/P99/avg/请求数/成功率)。
- **一键应急会话**:admin-gated POST /api/emergency-session(key+模型白名单校验,argv 列表防注入,
  会话名服务端生成,PATH 注入);/usage 页表单(key→联动模型→一键起),实测 launchd 上下文 detached tmux 可起。
- **报错分层定位**:统一 classify_error → `[layer][fault] + 建议 + 详情` 进 error body 与代理日志;
  覆盖 ccr-down/joycode-down/no-key/no-provider/upstream-401/400/5xx/breaker-open/all-failed/stream-broken;
  statusline 新增链路健康段(proxy/ccr/joycode 并行探测),`crew status` 人类模式前置链路行。
- **模型切换顺畅路径**:`crew model-switch <model> [key]` 统一入口(校验存在→写 provider map→apply→
  重启 CCR→冒烟最小请求→失败自动回滚+http 码分类根因+重试命令);修 sync-models 跳过带空格模型名 bug(4 处);
  保留 resolve 三层防线与 launcher 守卫。

### 清理 / 安全
- 删除 .tmpdbg/(600 权限调试 keys.conf 疑似密钥)、bin/crew.bak-resolve-*、scenarios *.norm-base 残留。
- .gitignore 补 acp/node_modules/(crew-dsh/acp 运行依赖,可复现)与 *.norm-base。
- scenarios 基线 05-doctor 随应急通道删除重录,顺带移除基线内明文 token。

## [Unreleased]

### 新增
- **statusline tot 段:会话累计消耗 token**(2026-10-26 用户需求:判断「会话是不是
  跑太久、烧太多额度」;ctx 是当前窗口占用,压缩后归零,回答不了这个问题)。
  形态:`⬡ 会话 · 模型 · 🔑key · ctx48% (98k left) · tot665k · 分支 · 目录`。
  口径:Σ transcript 每条 assistant message.usage 的 input+output —— **cache_read/
  cache_creation 不计入**(缓存价约 1/10,混入会虚高一个数量级,失去参考价值;
  本会话实测:in+out 665k vs 含 cache 19.6M)。数据源:stdin transcript_path 优先,
  缺失按 session_id + cwd 拼 projects 路径。性能:mtime+size 缓存(变更才重扫,
  6.5MB 全扫实测 ~75ms)。分级变色:<1M 绿 / ≥1M 黄 / ≥3M 红 / ≥10M 深红。
  M 级一位小数(1.6M);<1000 显原值;0/无 transcript 整段静默省略。

### 修复
- **GPT-6 系模型切过去即 400(2026-10-26 事故)**:用户洞察 —— 从选模型菜单选中
  `GPT-6.1-Sol-A-joybuilder` 后每次对话 400("Function tools with reasoning_effort
  are not supported … use /v1/responses")。根因两层:
  ① llm-gw 的 GPT-6 系(gpt-6-sol/gpt-6.1-sol 实测;GPT-5.x 不受影响)在
  /v1/chat/completions 拒绝 function tools 与 reasoning_effort 共存,而 CCR 网关
  在 thinking 开启时会自动注入 reasoning_effort —— Claude Code 会话必带 tools,
  所以必撞;错误提示的两个出路也都是死路(该模型 reasoning_effort 不支持
  'none',唯一活路 /v1/responses)。
  ② `ensure_model_in_ccr`/sync-models 落地新模型时硬编码 `/v1/chat/completions`,
  这就是坏 provider 的出生地。修复:GPT-6 系落地改为 `type=openai_responses` +
  base 不带 chat/completions 后缀(CCR 3.1.3 的 Responses adapter 自动做双向
  转换;注意显式 type 字段优先于 URL 推断,router-plugin 对 legacy provider
  不认 /responses URL 后缀 —— 只改 URL 没用,2026-10-26 实测)。
  防复发:`ccr_v3.py validate` 加守卫 —— GPT-6 系模型若以 chat/completions 形态
  出现(非本地 joycode 代理豁免)直接 rc=1 拦下,手改 map 也能在 validate 阶段
  发现,而不是等会话 400。端到端验证:CCR 直打 tools+reasoning_effort+流式
  全通(function_call 正确返回)。
- **statusline ctx 段加已消耗 token 数**:用户要求 —— `ctx48% (951k left)` 升级为
  `ctx48% (951k/951k left)` 形态(累计消耗/剩余),一眼看出这个会话烧了多少;
  M 级消耗显示一位小数(1.2M)。

### 修复
- **上下文窗口自动校准(报错即修)**:用户洞察 —— 报错那一刻上游就告诉我们真实窗口。
  实测 llm-gw 溢出错误自带数字(GLM-5.3-Local:`context length (1048576 tokens)`;
  kimi-k3:`exceeded model token limit: 1048576`);GLM-5.2(code 1261 "Prompt 超长")
  不带 → 统计兜底:被拒请求估算 tokens(下界)+ 该模型历史最大成功 input(新增
  `max_in` 追踪,上界)夹逼,取保守下界(向下取 10k)。校准器在 translate
  prompt-too-long 命中时同步写 model-windows.conf(幂等/线程安全/异常静默),
  launcher 下次起会话即用真实窗口。端到端实测:conf 错值 200000 → 一次报错后
  自动纠正 1048576。
- **两种溢出措辞漏匹配致 CC 压缩恢复不触发**:实测 `longer than the model's context
  length`(GLM-5.3-Local)和 `exceeded model token limit`(kimi)都不在原
  _PTL_SOURCE_PATTERNS 里 → 这些模型的溢出错误不翻译 → CC 当普通 400 重试到死。
  补两种模式 + 中文 "Prompt 超长"(上游中英文措辞会切换,全收);hay 构造改多层
  展开(CCR 的 cause 字段是字符串化 JSON,中文以 \uXXXX 转义藏在内层,单层
  dumps 匹配不到 —— GLM-5.2 中文措辞漏匹配的根因)。
- **窗口表实测值修正**:GLM-5.3 全系 = 1048576(1M,非 1000000 假设值);
  kimi-k3 = 1048576(原表 200k 错误)。阶梯探测法:50k..800k words 多样化文本
  逐档打,直到逼出带数字的 400。


### 修复
- **每次启动误判"空壳"kill 活会话 + resume 混乱(macOS 根因)**:空壳检测/`crew ls`/
  heartbeat 用的 `ps --no-headers --ppid` 是 Linux-only 语法,macOS BSD ps 直接
  illegal option → claude_pid 恒空 → 每次 `crew <name>` 都把活会话当空壳 kill 重起,
  heartbeat 把所有 live 会话记 dead-repl → watcher autoheal 连环重起(resume 分叉)。
  新增 `claude_pid_of()`:Linux 保留 --ppid 快路径,macOS 走 `ps -axo pid,ppid` 全表
  过滤;heartbeat.js 同步加 BSD 回退。实测 crew_up pane(95199)→ claude(95366)
  正确识别,空壳场景(子进程退出)正确返回空。
- **`crew ls --json` macOS 崩溃(unbound variable)**:cmd_ls 的 /proc 增强在 macOS
  分支不赋 real_cwd,而 `local real_model real_cwd` 不带值声明在 bash 3.2 + set -u
  下是 unbound → 249 行直接崩。声明即赋空值修掉(这也是 dashboard Sessions 表
  空的一环:proxy 调 ls --json 拿到的是崩溃输出)。
- **dashboard Sessions 表永远空(crew exec failed: 'crew')**:launchd 起 proxy 时
  PATH 只有 /usr/bin:/bin,shutil.which("crew") 落空 → 裸名 "crew" → FileNotFoundError。
  CREW_BIN 解析加显式兜底链:which > ~/.local/bin/crew > repo bin/crew > 裸名;
  crew CLI 不可用时 _api_sessions 降级直读 state 文件(24 会话照常显示,标 degraded)。
- **dashboard Recent requests 表看不到错误信息和时间**:失败请求记 err 摘要
  (上游 400 body 里的 message,如 "prompt is too long",hover 看全文);时间列从
  相对秒(1029.5s)改墙钟 HH:MM:SS。
- **ctx 窗口失真 / 自动压缩失效(会话只能重开)**:oxygen(llm-gw)的 /v1/models
  不提供 context window 元数据,CC 对未知模型按 ~200k 假定,与上游真实窗口不符
  (假窗口 > 真窗口 → 压缩不触发 → compact 请求被 400 "prompt is too long" 拒 →
  会话卡死)。新增 `model-windows.conf`(backends/model-windows.conf.example 模板):
  launcher 起会话按模型注入 CLAUDE_CODE_MAX_CONTEXT_TOKENS(真实窗口)+
  AUTO_COMPACT_WINDOW(90% 提前压缩);statusline 同源读 conf 算剩余量
  (原硬编码表迁出,conf 缺失回落硬编码)。
- **proxy 偶发崩不自愈**:serve_forever 意外崩(非 KeyboardInterrupt)原样退出,
  launchd KeepAlive 重拉有 5s 空窗(期间所有会话请求全挂)。改为崩后关旧 socket
  重建重听(1s 退避防疯狂重建),端口被占才放退出交 launchd/doctor;请求线程异常
  装 threading.excepthook 结构化记录(此前 ConnectionResetError 只打裸 traceback)。

### 新增
- **crew doctor --fix 进程自愈**:crew-proxy 未监听 → launchd kickstart(或 nohup)
  自动拉起并复核;CCR 未监听 → ccr start + 等端口。配置类问题(base_url 指错/drift)
  仍只报告不自动改(改 key 必人工 apply 的宪法不动)。
- **doctor 结尾打印应急直连命令**:链路修不好时,直接给出绕过 crew-proxy/CCR 连
  oxygen 的 claude 命令(ANTHROPIC_BASE_URL=llm-gw/anthropic + AUTH_TOKEN + 模型),
  链路正常时也打(标"仅备用")。


## [3.13.2] - 2026-10-20

### 修复
- **左树仍指家目录的真正根因(toad click 缺陷)**:`toad acp` 的 PATH 位置参数与
  `-d` option 在 click 定义里**同名 project_dir**(argument 覆盖 option)——
  我们传 `-d <镜像>` 但 PATH 未传(default None),把 -d 顶掉 → Toad 落回 ~。
  修:镜像路径改为 COMMAND 之后的 PATH 位置参数(click 解析实测收到正确路径;
  真实进程命令行验证 ✓)。此前两次"修复"(latest 重试/兜底)治标未治本,
  误判致歉——日志显示 -d 传对,但被 click 吞掉,盯 -d 当然查不出来。

## [3.13.1] - 2026-10-20

### 修复
- **latest 解析偶发失败致左树落兜底目录**(用户连续两次实测不行):
  `--resolve latest` 需 ssh 拉远程成员表,偶发超时静默失败 → proj_dir 落
  ~/.crew/dsh-work 根(只有流水线文件夹名,无工作区内容)。
  ① 解析重试 3 次(间隔 1s);② 兜底改为本地最新镜像(目录名日期排序,
  离线可用)。连跑 4 次 PTY + headless 视觉截图验证 -d 与树内容全部正确。

## [3.13.0] - 2026-10-20

### 修复
- **裸 `crew dsh` 左树指向家目录**(用户实测):无流水线参数时 target 为空 →
  proj_dir 落 $PWD(用户在 ~ 跑,左树即家目录)。修复:无参自动解析「最新流水线」
  (`--resolve latest`,与 acpd 自动绑 lead 同规则),镜像跟随;镜像不可用兜底
  ~/.crew/dsh-work(绝不落 $PWD)。latest 支持角色参数(--resolve latest coder)。

## [3.12.0] - 2026-10-20

### 修复/优化
- **消息两侧区分**:历史回放/首条注入中,用户行用 `user_message_chunk`、角色行用
  `agent_message_chunk` —— Toad 分左右气泡渲染,对话一眼可辨(此前全是 agent 侧)。
- **工作区镜像真实化**:去掉 2M 文件上限(此前镜像 34M vs 远程 58M,大文件缺失
  导致目录「不真实」);排除 .git/node_modules/target/dist。温镜像后台增量刷新
  不阻塞启动(首次全量前台,约 1 分钟;二次起秒进)。

## [3.11.0] - 2026-10-20

### 新增
- **Toad UI 优化(Claude Code 观感 + JIMDB Agent 品牌)**:
  - 标题/状态栏:JIMDB Agent · by wangqiwang1;acpd 会话名与横幅同署名。
  - 观感预置(acp/toad-settings.json,crew dsh 自动应用,仅补缺省键):
    gruvbox 暖底暗色 + 紧凑输入 + 中文 placeholder(「给 dsh 角色发消息…」);
    footer 键位栏保留(新手友好);thoughts 折叠。
  - **工作区镜像**:crew dsh 启动时 rsync 远程流水线工作目录(容器
    /work/jimdb/.dsh/jimdb-work/PIPE-<pid>/ = 宿主 /root/claude-work/…)
    → 本地 ~/.crew/dsh-work/<pid>/,Toad 左侧 project 树即远程真实文件
    (排除 node_modules/.git/target,≤2M;CREW_DSH_SYNC=0 跳过;2.6s/wand3)。

## [3.10.0] - 2026-10-20

### 变更
- **移除 Martty 集成**(用户拍板):v3.6 引入,因不渲染绑定前 update(历史体验受限)v3.10 移除。
  `crew dsh` 默认路由 TTY → Toad(原 --toad 语义);Martty 主题插件目录、默认路由代码清零;
  `--toad` flag 兼容保留。本机 martty npm 包与 ~/.oma 已卸载清理。

## [3.9.0] - 2026-10-20

### 新增
- **Toad 客户端集成(`crew dsh --toad`)**:Toad(batrachianai/toad,Will McGugan/Textual 作者)
  富 UI——Markdown 流式渲染、语法高亮 diff、ctrl+r 会话恢复、集成 shell。
  **绑定即显历史**(首屏直接看到会话名+最近对话,无需发消息;Martty 做不到)。
  依赖:`uv tool install -U batrachian-toad`;`CREW_DSH_UI=toad` 同效。
- acpd `session/load` + `loadSession:true`(Toad ctrl+r resume 通道);绑定回放
  `CREW_DSH_BIND_REPLAY`(默认关,Martty 兼容;Toad 通道自动开)+ 延迟/原始推送诊断开关。
- 重大踩坑记录:`toad acp` 的 COMMAND 是**完整命令字符串**(引号包 `node /path/acpd.mjs`),
  PATH 是项目目录——此前误传两个参数导致 toad 起了裸 node,所有「Toad 不渲染」结论作废。

## [3.8.0] - 2026-10-20

### 新增
- **会话名常驻(session_info_update.title)**:acpd 绑定(session/new / resume)即推
  `<role> · <流水线>`——Martty 界面显示当前会话名(实测渲染 ✓)。
- **首条 prompt 注入历史前缀**:绑定后首次 prompt 的回复流开头注入「最近 N 条历史」
  (`user ›`/`<role> ›` 对话框格式,CREW_DSH_REPLAY_N=12 默认,0 关闭)。
  crew dsh --repl / Zed 实测渲染 ✓;Martty 实测不渲染首块前的内容(其内部策略,见下)。
- 修复语义角色:rec.role 从 member 名取(`<role>-pipe-<pid>`)——平台 sessions[].role
  恒 'teammate' 无语义,此前会错标。
- 诊断设施:CREW_ACPD_TRACE(收到的 JSON-RPC 时间线)/ CREW_ACPD_LOG(文件日志镜像)。

### 已知限制(实测结论)
- Martty 对「首条 prompt 前的主动 update」不渲染(会话未 started 即静默丢弃);
  对「prompt 响应流中真实回复前的块」也不渲染(内部策略)。历史在 Martty 里需靠
  角色自述(发"总结当前进展")或等上游支持 session/resume replay(RFD 在推进)。

## [3.7.0] - 2026-10-20

### 新增
- **Martty 主题插件「Claude Code」**(JIMDB Agent 专用,作者 wangqiwang1):把 crew dsh
  默认 Martty 富 UI 调成 Claude Code 观感——橙棕 brand #D97757 + 暖底深色 + 琥珀高亮,
  含 light 模式。`acp/martty-plugins/claude-code-theme/plugin.json`(kind: theme),
  装进 `~/.oma/plugins` 后 Martty 内 `/theme` → Claude Code 切换。
  部署:`bash acp/martty-plugins/install.sh`(幂等,支持任意机器)。
  踩坑记录:code.client 须经 applyClientHalf(Function 体普通 JS)——不支持 ESM export,
  须 `return {name, inject, apply}` 对象字面量;离线全链路验证(发现→挂载→注册→激活)通过。
  默认激活:插件只注册不激活,开机主题由 `~/.oma/settings.json` 的 `theme` 键决定——
  install.sh 现同步写入该键(theme → claude-code),新装机器开箱即 Claude Code 配色。

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
