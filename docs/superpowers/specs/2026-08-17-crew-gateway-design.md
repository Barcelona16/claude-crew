# claude-crew spec:crew-gateway 对外共享 key 网关

日期:2026-08-17
状态:待 review

## 背景与动机

把 claude-crew 部署成一个**对外 API 中转网关**,跑在开发机 `11.91.165.248` 上。别人把这台机器地址配成自己的 Anthropic/OpenAI-兼容 API endpoint,请求带 key 过来,网关按策略做**共享 key 池 + 熔断恢复 + 亲和转发 + 门禁**,让一小圈人共享同一批真实 key 的额度。

核心诉求:
- 共享 key 池:N 个真实 key,某个限额就摘掉,一段时间后自动恢复。
- 每模型独立池(限额各不同)。
- 客户端传进来的 key 优先复用一模一样的真实 key(亲和)。
- 前端可视化 + 修改(登录表、模型)。
- 已知 key 标记 erp(谁贡献的额度)。
- 门票机制:如 `jimdbtest` 映射到 `personal` 额度、仅限 GLM-5.2。

## 指导原则:增强 crew-proxy(进主线),网关薄薄消费

`setup/crew_proxy.py`(监听 `127.0.0.1:8788`)已实现共享 key 池核心:读 `keys.conf` + `key-policy.conf` 按 model 选健康 key、熔断跳闸+冷却恢复、改写 model 转发 CCR、`/dashboard` 面板,并支持 joycode 等多种后端。

本次两个新需求——**亲和**(读客户端 key 优先复用)和**分级冷却**(按失败原因定冷却时长)——crew-proxy 源码目前无扩展点,非增强不可。

**关键决策(用户定):不做私改,而是把这两个需求抽象成 crew-proxy 的通用、可进主线的扩展能力**,让 crew-proxy 本身支持更丰富的策略定制;网关只是这套新能力的**第一个消费者**。好处:
- crew-proxy 增强是正式特性、进主线(仓库 `coding.jd.com:olsd/claude-crew`),上游演进无冲突,不是维护负担。
- 网关薄,复用 crew-proxy 全部后端(joycode 等)+ 新策略能力;以后想接新后端/新策略,增强 crew-proxy 即可,网关继续复用。

**默认无害原则(用户确认)**:新能力默认关闭/无副作用——不传亲和头、不给冷却配置文件时,crew-proxy 行为与现在**完全一致**。本机现有用法和上游演进零影响。

## crew-proxy 的两处能力增强(进主线,默认无害)

### 能力 A:亲和信号(affinity via header)

crew-proxy 的 `_route`(crew_proxy.py:797)选 key 时,允许请求携带一个"优先用哪个 alias"的提示头 `X-Crew-Prefer-Key`。若该头存在且其值在当前 model 的 policy 列表里,就把它提到 policy 最前(其余顺序、failover、熔断逻辑全不变)。

- 默认无害:无此头 → 行为与现在完全一致。
- 实现量:约 5 行。`_fwd_headers()`(541 行)已透传未知头,只需在 `_route` 里读一次并前置 alias。

### 能力 B:分级冷却(tiered cooldown)

crew-proxy 现在冷却是单一常量 `COOLDOWN`(env `CREW_PROXY_COOLDOWN`,默认 60s,crew_proxy.py:58、181)。增强为**按失败原因决定冷却时长**:

- 若配置目录存在 `cooldown.conf`,读它;否则回退到现有单一 `COOLDOWN`(默认无害)。
- `cooldown.conf` 格式(`key=秒数`,每次跳闸现读,支持热改):
  ```
  daily_quota      = 86400   # 429 且 retry-after 大/无 → 额度耗尽,摘一天
  transient        = 300     # 401/403/5xx/连接错 → 瞬时错误短冷却
  retryafter_max   = 300     # retry-after ≤ 此值 → 用其原值退避;> 此值 → 归 daily_quota
  ```
- 分流规则(在 `_route` 遇失败处,crew_proxy.py:862 附近):
  - 非 429 → `transient`。
  - 429 且 `retry-after` 存在且 ≤ `retryafter_max` → **用 retry-after 原值**(上游让等多久就等多久)。
  - 429 且 retry-after > `retryafter_max` 或缺失 → `daily_quota`(摘一天)。
- `Breaker.record_fail(alias, now, cooldown_secs)` 接收算好的秒数,`_tripped[alias]=now+cooldown_secs`;`healthy()` 自动恢复不变。dashboard `cooldown_left` 自然显示对应档。
- 实现量:约 15 行。

> 这两个增强做成小而内聚的 commit,直接进 crew-proxy 主线,成为其正式的"策略扩展面"。

## 架构与数据流

```
别人的 claude / 客户端
   │  带 key(x-api-key 或 Authorization: Bearer)
   ▼
gateway.py            0.0.0.0:8790   ← 新增(新仓库 crew-gateway),对外,薄
   │  ① 查登录表:key 不在 → 401
   │  ② 查 allow_models:model 不允许 → 403
   │  ③ 加头 X-Crew-Prefer-Key: <maps_to 的真实 alias>
   │  ④ 只放行 /v1/messages 和 /v1/chat/completions
   ▼
crew-proxy            127.0.0.1:8788 ← 增强后(亲和+分级冷却,进主线),仅本机
   │  读 X-Crew-Prefer-Key 把 alias 提到 model 池最前
   │  → 选健康 key → 熔断/分级冷却/failover → 改写 model
   │  (joycode 等后端天然复用)
   ▼
CCR                   127.0.0.1:3456 ← model → 上游 base_url + transformer
   ▼
上游 http://llm-gw.jd.local(内网 LLM 网关,开发机已验证可达)
```

安全边界:**crew-proxy 保持只听 `127.0.0.1`,永不对外**。有人扫到开发机只能碰到网关门禁,碰不到无鉴权的 crew-proxy。

## 决策记录

| 决策 | 选定 |
|---|---|
| 转发链路 | 经 crew-proxy → CCR(复用其全部后端能力) |
| crew-proxy 改动 | 增强为通用扩展(亲和头 + 分级冷却),进主线,默认无害;非私改 |
| 亲和信号 | 网关算好 `maps_to` 真实 alias,`X-Crew-Prefer-Key` 头传给 crew-proxy |
| 客户端校验 | 严格白名单:登录表没有 → 401 |
| 监听暴露 | 网关直接监听 `0.0.0.0`;无 TLS(内网);仅放行推理路径 |
| 恢复策略 | 分级:429 看 retry-after(原值退避 vs 摘一天);其他短冷却;读 cooldown.conf 热改 |
| 登录模型 | 统一登录表(真实 key 与门票同表) |
| 载体 | Docker 容器(Ubuntu + 离线 node20),照用户已验证离线路径 |

## 组件一:统一登录表(网关配置)

网关配置本体。JSON,开发机 `~/.config/claude-crew/gateway-auth.json`,权限 0600:

```json
{
  "personal":  { "maps_to": "personal", "allow_models": [],          "erp": "wangqiwang1" },
  "jimdbtest": { "maps_to": "personal", "allow_models": ["GLM-5.2"],  "erp": "wangqiwang1" }
}
```

- **表的键**:客户端登录字符串。可是真实 key 本身(`personal`),也可是纯门票(`jimdbtest`)。
- **`maps_to`**:映射到 `keys.conf` 哪个真实 alias(用谁额度)。网关据此算 `X-Crew-Prefer-Key`。
- **`allow_models`**:允许模型列表;**空 = 全部允许**。
- **`erp`**:贡献者标记。

erp 放登录表、不改 keys.conf:keys.conf 是 crew 既有格式,改它牵动 crew CLI;"谁贡献"是登录属性,放登录表更合适。dashboard 展示时 join 显示。

## 本地接入(用 crew 一键接开发机网关)

crew 的"后端"就是 `~/.config/claude-crew/backends/*.conf` 一个文件(格式 `BASE_URL/MODEL/TOKEN/ENV_EXTRA/KEY_MODE`,同 joycode/ccr 后端)。因此本地接入开发机网关**不用改 crew CLI**——装一个 backend conf 即可(像装 joycode 那样):

```
# backends/gateway.conf — 远程共享池,走开发机 11.91.165.248:8790
BASE_URL=http://11.91.165.248:8790
MODEL=GLM-5.2
TOKEN=<门票或真实 key,如 jimdbtest / personal>
ENV_EXTRA=MAX_THINKING_TOKENS=0
KEY_MODE=token
```

- `TOKEN` = 登录表里的登录 key。`jimdbtest` 仅 GLM-5.2;`personal` 全模型。
- `KEY_MODE=token`:token 随请求带给网关做门禁,网关据登录表算亲和(与 ccr 后端同理,本地不再 --key 选池)。
- 本地 `crew <name> --backend gateway` 即用共享池。切模型 `crew --model <model> <name>`(需在该门票 allow_models 内)。

新仓库 `crew-gateway` 带 `backends/gateway.conf.example` + 一个安装脚本(拷贝到 `~/.config/claude-crew/backends/` 并填 TOKEN),达到"装插件即接入"的体验。

## 组件二:gateway.py(新仓库,单文件 stdlib,薄)

stdlib `http.server` + `urllib`,零依赖,兼容 Python 3.6+(用容器内 python3)。每请求:
1. 取 key:先 `x-api-key`,再 `Authorization: Bearer`。
2. 读 `gateway-auth.json`(每请求现读,热改),查 key。无 → **401**(笼统,防探测)。
3. 解析 body `model`;查 `allow_models`(空则放行)。不允许 → **403**。
4. 取 `maps_to` 真实 alias,转发给 crew-proxy(`127.0.0.1:8788`),加头 `X-Crew-Prefer-Key`。
5. 响应(含流式 SSE)原样透传。

路径策略:只转发 `/v1/messages` 和 `/v1/chat/completions`;屏蔽 `/dashboard`、`/api/*`(不对外);其他 → 404。

配置(env):`GATEWAY_PORT`(默认 8790)、`GATEWAY_DOWNSTREAM`(默认 `http://127.0.0.1:8788`)、`GATEWAY_AUTH`(默认 `~/.config/claude-crew/gateway-auth.json`)。

## 组件三:前端(dashboard 扩展,可视化 + 修改)

在 crew-proxy 现有 `/dashboard`(仅本机)基础上扩展——**这也做成 crew-proxy 主线增强**(与它的 dashboard 一体,默认无害:无 gateway-auth.json 则该区块空):
- Keys 区块加 **erp 列**(join 登录表)。
- 新增**登录表区块**:每个登录 key → `maps_to` → `allow_models` → erp。
- 新增**编辑登录表**:增/删/改登录 key、改 maps_to/allow_models/erp,写回 `gateway-auth.json`(写前备份)。
- 校验:key 名/alias 白名单正则 `^[A-Za-z0-9._-]+$`;maps_to 必须是 keys.conf 已有 alias;allow_models 每项白名单校验。
- 编辑接口挂 crew-proxy dashboard(仅本机可达,天然安全);网关保持极薄。crew-proxy 与网关同读 `gateway-auth.json`,单一数据源。

## 部署形态(开发机 11.91.165.248)

现状(已探测):CentOS7、x86_64、Python3.6.8、**无 node/npm**、**无外网**;但上游 `llm-gw.jd.local`(172.29.24.167)可达、内网 npm 镜像 `registry.m.jd.com` 200、内网 Harbor `jcloudhub.jcloudcs.com` 可用、有 systemctl。

**载体:Docker 容器**(照用户跑通的离线路径),容器内 Ubuntu + node20:

```
开发机 CentOS7
├─ docker(yum 装,配 jcloudhub Harbor insecure-registry)
└─ 容器 "crew"(Ubuntu, --network host, --restart unless-stopped)
     ├─ node20(离线 tarball:本机下→scp→解压)
     ├─ CCR(内网 npm 源装)                    :3456
     ├─ crew CLI(装上,用不用得上再说)
     ├─ crew_proxy.py(增强版,进主线)          :8788 仅本机
     └─ gateway.py(新仓库)                     :8790 对外(host 网络)
```

步骤:
1. yum 装 docker + 配 Harbor 源 + pull Ubuntu 镜像。
2. 本机下 node20 linux-x64 tarball → scp → 解压。
3. 起常驻容器(host 网络、restart、挂载工作目录)。
4. 容器内 `npm config set registry http://registry.m.jd.com` → 装 CCR + crew CLI。
5. **搬凭证(仅 personal)**:本机 CCR config(服务 personal 的 provider)+ keys.conf(仅 personal 行)+ key-policy.conf + cooldown.conf → scp 到容器配置目录。
6. 写 `gateway-auth.json`:personal(自己/全模型)+ jimdbtest(personal/仅 GLM-5.2)。
7. 起 CCR → crew-proxy → gateway;放通开发机 8790 对外端口。
8. 保活:容器 `--restart unless-stopped`;容器内守护三服务。

## 新仓库结构 crew-gateway

```
crew-gateway/
  gateway.py                对外网关(门禁+allow_models+亲和头+路径白名单)
  gateway-auth.json.example 登录表样例
  backends/
    gateway.conf.example    本地 crew 接入用的 backend 样例(指向远程网关)
  install-backend.sh        本地一键装:拷 gateway.conf 到 ~/.config/claude-crew/backends/ 并填 TOKEN
  deploy/                   开发机 docker 部署脚本
  README.md
```

crew-proxy 的两处能力增强 + dashboard 扩展落在 **claude-crew 主仓库**(它们是 crew-proxy 的正式特性)。

## 单 key 限制(已接受)

开发机初期只搬 personal 一个真实 key,GLM-5.2 池里只有它。personal 跳闸时该 model 无备选,直接返回上游错误。以后往 keys.conf/policy 加更多真实 key 即自动获得 failover。

## 错误处理

- 网关 401:key 不在登录表(笼统)。403:model 不在 allow_models。502:crew-proxy 不可达。
- crew-proxy 熔断/分级冷却/failover:复用增强后逻辑,冷却后自动恢复。
- 登录表/CCR 写入:写前备份,失败回滚。

## 测试与验证

- crew-proxy 增强默认无害:不传 `X-Crew-Prefer-Key`、无 cooldown.conf 时,行为与增强前逐字节一致(回归)。
- 亲和:传 X-Crew-Prefer-Key=personal,日志显示优先 personal;人为跳闸后 failover(多 key)或返回上游错误(单 key)。
- 分级冷却:429 带小 retry-after → 原值;不带 → 摘一天;改 cooldown.conf 后新跳闸生效(热改)。
- 网关鉴权:personal → 通;非法/空 → 401;jimdbtest 请 GLM-5.2 → 通,请其他 → 403。
- 前端:改登录表增删门票、改 allow_models 写回正确;erp 列正确;非法 alias/元字符被拒。
- 端到端:外部机器配 `11.91.165.248:8790` + personal,发 GLM-5.2 请求,经网关→proxy→CCR→llm-gw 返回。

## 风险

- **凭证外泄面**:真实 key personal 在开发机容器;门票 jimdbtest 分发 = 分发 personal 额度;无 TLS,明文过内网。仅限可信内网圈子。root 明文密码已在会话暴露,部署后应 passwd 改密 + 优先密钥登录。
- **单 key 无备选**:初期 GLM-5.2 池只 personal,limit 即无 failover(已接受)。
- **命令注入**:exec 用参数数组 + 白名单,绝不拼 shell(沿用现有防护)。
- **对外暴露**:网关仅放行推理路径,屏蔽 dashboard/管理;crew-proxy 只听回环。
- **Python 版本**:用容器内 python3,确认 ≥3.6;crew_proxy 若有 3.7+ 语法需下修(增强时留意)。
- **上游合并**:两处增强设计成小而内聚 commit,进主线;若上游先动了 `_route`/`Breaker`,合并时以主线为准、增强重贴到新结构上(因默认无害,冲突面小)。

## 实现顺序

1. 增强 crew_proxy.py:亲和头 + 分级冷却(小而内聚,进主线,回归测默认无害)。
2. dashboard 扩展:erp 列 + 登录表区块 + 编辑接口(进主线)。
3. 写 gateway.py(门禁 + allow_models + 亲和头 + 路径白名单)。
4. 开发机部署:docker → node20 → CCR → 搬 personal 凭证 → crew_proxy → gateway → 放通端口 → 保活。
5. 本地接入:crew-gateway 带 backends/gateway.conf.example + install-backend.sh,本地装插件即用共享池。
6. 端到端验证 + README。
