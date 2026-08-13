# claude-crew 重构 spec:双版本发布 + joycode 插件化 + key 自动降级薄代理

日期:2026-08-13
状态:待 review

## 背景与动机

claude-crew 目前是单一仓库,内部把三件 JD 专有的东西和通用的会话管理耦合在一起:
(1) joycode 代理(读 VS Code JoyCode 登录态、转发 JD 内网网关);(2) CCR 模板里的
`llm-gw.jd.local` 内网地址;(3) delegate 依赖外部 GKD。要对外开源,这三样都得剥离;
同时想加一个"多 key 按优先级、失败自动降级"的能力。

经调研(见 spike 结论)确认:所有 `ccr` 预设的流量都经 claude-code-router(CCR,`:3456`)。
CCR 有隐藏的 fallback 配置但**单次请求内生效、不记忆、无熔断**,且 transformer 看不到错误
响应——因此 key 降级无法纯靠 CCR 配置实现,需要在 claude 与 CCR 之间加一层自己的薄代理。

**核心架构决定:在 Claude Code 与 CCR 之间引入一个薄代理层(下称 `crew-proxy`)作为可扩展的
流量控制点。** 第一版只实现 key 自动降级;它同时为未来的用量统计、限流、缓存、审计预留正确的
位置——这些若塞进 CCR 源码会被升级覆盖,塞进 crew 的 bash 又碰不到 HTTP 流量,独立薄代理是
唯一同时"能看到流量"又"不被上游冲掉"的位置。

## 范围

本 spec 覆盖(按建议实现顺序):

1. **hygiene**:移除 git 跟踪的 `.pyc`,补 `.gitignore`。
2. **delegate 去 GKD 依赖**:`crew delegate` 走 crew 自己的 `claude -p` 逻辑;GKD 降为纯可选扩展。
3. **litellm 死代码清理**:crew 里 `KEY_MODE=litellm` 分支已无预设触发,移除;`examples/glm-litellm/` 一并移除(见 §3)。
4. **joycode 插件化**:抽成 `ext/joycode.sh` + proxy + 独立 install.sh,源在独立内网仓。
5. **双版本发布体系**:coding 主仓=内部版(单一真相源),`make-public.sh` 生成开源版推 GitHub;开源版 CCR 模板用通用占位符。
6. **key 自动降级薄代理 `crew-proxy`(路径 Y)**:最重的一块,单独一章。

非目标(明确不做):熔断之外的扩展(统计/限流/缓存)第一版不写,仅在代理架构里留位置。

---

## 1. Hygiene

- `git rm --cached setup/__pycache__/joycode_proxy.cpython-314.pyc`(已被跟踪,是误提交)。
- `.gitignore` 追加 `__pycache__/` 和 `*.pyc`。

## 2. delegate 去 GKD 依赖

**现状**:`crew delegate --model X "task"` 经 `ext/gkd.sh` 的 `crew_delegate`,最终
`exec node "$gkd/scripts/gkd-runtime.mjs" "--$backend" "$task"`——本质只是起一个
`claude -p --model X` 一次性子 agent、结果打 stdout。

**改动**:把 delegate 变成 crew 核心自带、不依赖 GKD。

- 在 `bin/crew` 新增核心 `crew_delegate_core`:复用 `load_backend`(拿 model/base_url/token/env)、
  ensure 依赖(CCR 起没起)、拼环境变量(和 `ensure_session` 里那段一致),然后
  `exec $CLAUDE_BIN -p --model "$BK_MODEL" $flags "$task"`。
- `--key` 支持:走 `crew-proxy` / CCR 路由后,delegate 自动继承同一套 key 逻辑。
- `case` 分派:`delegate)` 优先调核心实现;GKD 的 `crew_delegate`(若装了 ext)仅在用户显式
  要 GKD 多 agent 编排时用(保留但不再是 delegate 的唯一实现)。
- `crew gkd-sync` 保持在 `ext/gkd.sh`(GKD 专属,核心不需要)。

**验证**:`crew delegate --model GLM-5.2 "echo hi"` 在**未装 GKD**时也能跑通,输出到 stdout。

## 3. litellm 死代码清理

- `bin/crew`:移除 `litellm_port_for_key`、`KEY_MODE=litellm` 分支(`ensure_session` 里
  那段 `elif [ "${BK_KEY_MODE:-token}" = "litellm" ]`)、相关注释。
- `KEY_MODE` 取值收敛为 `token` / `ccr`(README 表格同步)。
- `examples/glm-litellm/`:移除(litellm 路线已废弃)。
- 注意:清理后全量 `crew models` / `crew --model X` / `--key` 冒烟测试,确认无 `token`/`ccr`
  路径回归。

## 4. joycode 插件化

joycode 抽成一个与 `ext/gkd.sh` 同构的可选扩展,源码在**独立内网仓**(如
`claude-crew-joycode`),核心仓(及开源版)零 joycode 痕迹。

### 4.1 从核心仓移出的内容

| 离开核心 | 去向(joycode 插件仓) |
|---|---|
| `setup/joycode_proxy.py` | 插件仓 `joycode_proxy.py` |
| `ccr-config.template.json` 里 `joycode`/`joycode-oai` 两个 provider | 插件 install.sh 自行合并进用户 CCR config |
| `setup/launchd/*joycode*.tmpl`、`setup/systemd/*joycode*.tmpl` | 插件仓 `service/` |
| `setup.sh` 里 joycode 检测/拷贝/preset/服务启动 | 插件 `install.sh` |
| README joycode 章节 | 插件仓 README |

### 4.2 插件形态

- **运行时**:`ext/joycode.sh`,sourced 进 crew(和 gkd.sh 一样),定义 joycode 相关的依赖检查。
- **安装时**:插件仓带自己的 `install.sh`——用户先跑核心 `setup.sh`,再跑插件 `install.sh`:
  拷 proxy 到 `~/.config/claude-crew/`、自包含地 merge 两个 CCR provider(同核心 merge 风格的
  node 脚本,不依赖核心内部实现)、写 `joycode_*` 预设、装并起 service。
- **核心的扩展 hook**:核心 `crew up` 目前硬编码 joycode 依赖调用,需改为通用 seam——
  crew 在核心依赖检查后,调用扩展注册的 `crew_ext_dep_up`(约定函数名,无则 no-op)。joycode
  插件定义它;GKD 不受影响。这是对核心唯一的架构性新增,且是通用的(非 joycode 专属)。

### 4.3 边界校验

- 核心仓 `grep -ri joycode` 应为空(README/代码/模板/service 全无)。

## 5. 双版本发布体系

**单一真相源 = coding 主仓(内部版)**,含 `llm-gw.jd.local` 内网 URL。开源版由发布脚本派生,
永不手工维护,杜绝分叉。

### 5.1 `make-public.sh`(新增,放核心仓)

生成一个干净的开源版工作副本(或临时目录),然后推 GitHub。它做:

1. **剥 joycode**:确保工作副本无任何 joycode 文件/引用(插件本就不在核心仓,主要防残留)。
2. **换 CCR 模板**:`ccr-config.template.json` 换成通用占位符样例——provider 用
   `__BASE_URL__` / `__MODEL__` / `__API_KEY__` 占位 + 注释,教用户填各家官方 API
   (Anthropic / 智谱 / Moonshot 等),不含任何 `llm-gw.jd.local`。
3. **README**:开源版用不含内网信息的版本(见 §5.2)。
4. 推到 `origin`(GitHub);coding 保持内部版。

### 5.2 README 双版本

- 内部版 README:现状(含 joycode 章节由插件仓补充说明、含 llm-gw 说明)。
- 开源版 README:去 joycode、去 llm-gw,把 setup 讲成"填你自己的官方 API"。
- 实现方式:主仓维护内部版 README;`make-public.sh` 用 `README.public.md` /
  `README.public.en.md` 覆盖为开源版(两份并存,发布时替换)。

### 5.3 关键取舍

内部版模板仍用内网 URL(内部人开箱即用);开源版靠 `make-public.sh` 替换。发布脚本是唯一
需要"记得两个版本差异"的地方,集中一处。

---

## 6. key 自动降级薄代理 `crew-proxy`(路径 Y)

### 6.1 定位

一个本地 HTTP 反向代理,坐在 Claude Code 与 CCR 之间:

```
claude  →  crew-proxy (:NNNN)  →  CCR (:3456)  →  上游网关
```

crew 会话的 `ANTHROPIC_BASE_URL` 从指向 CCR 改为指向 crew-proxy。crew-proxy 自己维护 key
优先级 + 熔断状态,**自己决定这次请求用哪个 key**,带着选好的 key 转发给 CCR(路径 Y:代理
自己路由,CCR 不再管 fallback)。降级瞬时生效、不重启 CCR、状态在代理进程内存 + 落一份到磁盘。

### 6.2 key 优先级与熔断配置

- 配置文件:`~/.config/claude-crew/keys.conf` 扩展,或新增 `~/.config/claude-crew/key-policy.conf`。
  形如:每个"逻辑模型"对应一个有序的 key 列表(优先级)。
  ```
  # <逻辑模型> = <key别名1> <key别名2> ...   (按优先级从高到低)
  GLM-5.2 = gw_primary gw_backup gw_third
  ```
- 熔断参数(全局或 per-model):`连续失败阈值 N`(默认 3)、`冷却时间 T`(默认 60s)、
  `视为失败的状态码`(默认 401/403/429/5xx + 连接错误)。

### 6.3 降级状态机(per key)

- 每个 key 维护:`连续失败计数`、`状态(healthy / tripped)`、`熔断到期时间`。
- 请求到来 → 选当前优先级最高的 `healthy` key 转发。
- 响应是失败状态码 → 该 key 计数+1;达到 N → 置 `tripped`,设冷却到期 = now + T,**当次请求**
  立即用下一个 healthy key 重试(对 claude 透明)。
- 响应成功 → 该 key 计数清零。
- 冷却到期 → key 恢复 `healthy`,重新回到优先级序列(下次请求可能重新启用它)。
- 全部 key 都 tripped → 用优先级最高的那个硬转发(把上游真实错误透传给 claude,不假装成功)。

### 6.4 key 怎么带给 CCR

crew-proxy 选定 key 后,需让 CCR 用这把 key 请求上游。复用现有 `ccr_provider_for` 的思路:
CCR 里每个"模型 × key"是一个独立 provider(同 base_url、不同 api_key)。crew-proxy 把请求的
`model` 改写成对应 provider 的 `provider,realmodel`,CCR 就用那把 key。**所以 key 列表在
CCR config 里要有对应的 provider 条目**(setup 时按 keys.conf 生成)。

### 6.5 进程与生命周期

- 形态:一个独立脚本(python3,和 joycode_proxy 一致的技术栈,零第三方依赖用标准库
  `http.server`),监听 `127.0.0.1:${CREW_PROXY_PORT:-8788}`。
- 作为依赖服务纳入 `crew up` / launchd / systemd(和 CCR、joycode 同级)。
- crew 预设的 `BASE_URL` 默认指向 crew-proxy;`KEY_MODE=ccr` 的语义扩展为"经 crew-proxy 再到 CCR"。
- 落盘状态:`~/.local/share/claude-crew/proxy-state.json`(重启恢复熔断状态,可选)。

### 6.6 流式处理

Claude 是流式的。crew-proxy 必须正确透传 SSE:参考 joycode_proxy 的做法(`Connection: close`、
不加 chunked framing)。**难点**:失败降级要在"上游第一个字节返回前"判定——一旦开始流式转发就
不能中途换 key。策略:只在收到上游响应头(状态码)后、开始转 body 前决定是否降级重试;body 已开始
则透传。

### 6.7 未来扩展预留(不实现,仅架构留位)

crew-proxy 的请求/响应拦截点天然支持:用量/成本统计、per-key 限流、审计日志、缓存、影子流量。
第一版只写 §6.3 的降级;这些扩展各自是独立后续 spec。

### 6.8 验证

- 单测:构造 401/429/5xx 响应,断言计数、熔断、冷却、切下一个 key、全挂透传。
- 集成:配两把 key(一把故意填错),发请求,断言首选失败后自动切备用且 claude 无感知。
- 流式:确认 SSE 正常透传、降级只在头阶段发生。

---

## 实现顺序与依赖

1. Hygiene(独立,先做)
2. litellm 清理(独立)
3. delegate 去 GKD(独立)
4. joycode 插件化(依赖:核心加 `crew_ext_dep_up` hook)
5. crew-proxy key 降级(最重;依赖 CCR 里 per-key provider 已由 setup 生成)
6. 双版本发布 `make-public.sh`(最后;依赖 joycode 已插件化、模板可替换)

演示(`scripts/demo.sh` 及 GIF)在全部完成后单独做,更新展示新能力。

## 风险

- **crew-proxy 流式降级**:body 已开始就无法换 key(§6.6),需在测试里明确这条边界。
- **CCR restart 依赖**:路径 Y 避免了 restart,但 setup 生成 per-key provider 的逻辑要稳。
- **双版本漂移**:`make-public.sh` 是唯一防线,需有边界校验(§4.3 的 grep)纳入发布脚本。
- **litellm 清理回归**:清理后必须冒烟测试 `token`/`ccr` 两条路径。
