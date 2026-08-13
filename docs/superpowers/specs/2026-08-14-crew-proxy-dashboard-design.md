# claude-crew spec:crew-proxy 控制面板(dashboard)

日期:2026-08-14
状态:待 review

## 背景与动机

`crew-proxy`(`setup/crew_proxy.py`,`:8788`)已经是 claude 与 CCR 之间的薄代理,持有
key 优先级 + 熔断状态,是"唯一能看到 HTTP 流量、又不被 CCR 升级冲掉"的控制点。现在给它加一个
本地控制面板:可视化 key 健康/熔断、请求计数、近期日志、crew 会话列表,并能对会话做
kill / 改配置,以及(高风险)加 key/provider 同步进 CCR。

设计的**总原则**:保住 crew-proxy「零第三方依赖、单文件」的气质。面板是 stdlib 内嵌
(`/dashboard` 返回自包含 HTML,`/api/*` 返回 JSON,前端原生 JS 轮询),不引入 npm / 构建 /
框架。所有**修改状态**的操作统一通过 exec `crew` CLI 或写 crew 的状态文件,proxy 不重复
实现 crew 已有的逻辑,crew 保持为唯一的状态修改入口。

**明确不做(本版)**:token / 成本统计(不解析响应体,零解析风险)。只统计请求级粗粒度指标
(次数、成功/失败、熔断)。token 统计留作后续独立 spec。

## 范围与分阶段

面板一次性覆盖四层能力,但按**风险递增**分阶段实现,代码上隔离高风险写操作:

| 阶段 | 能力 | 风险 | 写入 |
|---|---|---|---|
| A | 只读面板:key 熔断状态、请求计数、日志、会话列表 | 零 | 无 |
| B | 点击 kill 会话 | 低(可逆性一般,面小) | exec `crew kill <name>` |
| C | 改会话 model/key | 中 | 写 `<name>.backend` / `<name>.key` |
| D | 加 key/provider 同步 CCR | 高(改全局配置) | 写 CCR config + keys.conf(先备份) |

实现顺序 A→B→C→D;每阶段可独立验证、独立提交。D 单独隔离,带确认 + 自动备份。

---

## 1. 架构与数据流

```
浏览器 ──HTTP──> crew-proxy :8788
  ├─ /                          现有:代理转发给 CCR(路由 + 熔断,不变)
  ├─ /dashboard                 新:返回自包含 HTML(单文件,原生 JS 轮询)
  ├─ /api/status      GET       key 熔断状态 + per-key/per-model 请求计数(JSON)
  ├─ /api/sessions    GET       crew 会话列表(exec `crew ls`,解析成 JSON)
  ├─ /api/logs        GET       proxy 近期请求日志(内存环形缓冲)
  ├─ /api/session/kill    POST  {name} → exec `crew kill <name>`
  ├─ /api/session/config  POST  {name, model?, key?} → 写 <name>.backend/.key
  └─ /api/ccr/provider    POST  {alias, key, model, base_url, transformer} →
                                备份并写 CCR config + keys.conf(阶段 D)
```

**数据源划分**:
- proxy 自有(内存 + 落盘):熔断状态 `Breaker._fails/_tripped`、请求计数、日志环形缓冲。
- crew 会话:通过 exec `crew ls` 拿(唯一状态入口),proxy 只解析其输出,不直接读一堆
  `.sid/.backend/.key` 文件重新实现 crew 的 status 判定逻辑。
- 写操作:kill 走 `crew kill`;改配置写 crew 的状态文件(格式简单、单值);CCR 写入是 proxy
  自己 merge(和 setup.sh 同风格的 node/python JSON merge),写前 `cp` 备份。

**前端形态**:一段静态 HTML 常量内嵌在 `crew_proxy.py`,`/dashboard` 直接返回。原生 JS:
`setInterval` 每 2–3s `fetch` 各 `/api/*`,渲染成表格/卡片。零构建、零依赖。

**安全**:proxy 只监听 `127.0.0.1`(现状不变),dashboard 同源。写操作前端弹 `confirm()`;
CCR 写入后端先备份(`config.json.bak.<ts>`)。不加登录(本机单用户,和 CCR/joycode 一致)。

## 2. proxy 侧新增数据采集(轻量,零响应体解析)

在现有 `_route` 里,不碰 body,只加计数:
- 全局:总请求数、成功数、失败数(沿用 `_is_fail` 判定)。
- per-key(alias):请求数、成功、失败、当前连续失败计数、熔断状态 + 冷却到期。
- per-model:请求数(可选)。
- 日志环形缓冲(内存,定长如 200 条):每条 `{ts_offset, model, alias, status, forced, failover}`。
  **不落盘**(避免磁盘增长 + 隐私);重启即清空,面板只看"近期"。

计数结构和 `Breaker` 一样加锁,`/api/status` 直接 dump。落盘沿用现有
`proxy-state.json`(只存熔断,不存计数/日志,保持文件小)。

> 时间戳:crew_proxy 是 stdlib,可用 `time.time()`(它不是 workflow 脚本,无 Date.now 限制)。

## 3. 各 API 契约(阶段 A)

- `GET /api/status` →
  ```json
  {
    "port": 8788, "ccr_url": "http://127.0.0.1:3456",
    "fail_n": 3, "cooldown": 60,
    "totals": {"requests": 120, "ok": 110, "fail": 10},
    "keys": [
      {"alias": "gw", "requests": 100, "ok": 98, "fail": 2,
       "consec_fails": 0, "state": "healthy", "cooldown_left": 0},
      {"alias": "gw2", "requests": 20, "ok": 12, "fail": 8,
       "consec_fails": 3, "state": "tripped", "cooldown_left": 42}
    ]
  }
  ```
- `GET /api/sessions` → exec `crew ls`,解析定宽表格为:
  ```json
  {"sessions": [
    {"name": "api", "status": "live", "model": "GLM-5.2", "key": "gw", "dir": "/path"},
    ...
  ]}
  ```
  (解析 crew ls 的定宽列;或给 crew 加一个 `crew ls --json` 更稳——见 §6 取舍。)
- `GET /api/logs?n=100` → `{"logs": [{...}, ...]}`(环形缓冲最近 n 条)。

## 4. 写操作 API(阶段 B/C/D)

- `POST /api/session/kill` `{name}` → 校验 name 合法(仅 `[A-Za-z0-9._-]`,防注入)→
  `exec crew kill <name>` → 返回 `{ok, output}`。**不支持 --purge**(删 transcript 太狠,
  面板不给这个按钮)。
- `POST /api/session/config` `{name, model?, key?}` → 校验 name/model 合法 → 写
  `$CREW_STATE/<name>.backend`(model)、`<name>.key`(key,空则删文件)→ 返回 `{ok}`。
  提示"下次 `crew <name>` 生效或需重开会话"。
- `POST /api/ccr/provider` `{alias, key, model, base_url, transformer}`(阶段 D)→
  1. 校验字段;2. `cp CCR_config CCR_config.bak.<ts>`;3. merge:keys.conf 加 `alias=key`,
  CCR Providers 加一个 `{name, api_base_url, api_key, models:[model], transformer}`
  (name 唯一化,如 `<model>-<alias>`);4. 返回 `{ok, backup_path}`。**不自动重启 CCR**——
  提示用户"改完 CCR config 需 `crew up` / kickstart 让 CCR 重载"。前端此操作二次确认。

所有写操作:name/alias/model 白名单校验(`^[A-Za-z0-9._,-]+$`),拒绝 shell 元字符;exec
crew 用**参数数组**(`subprocess.run([...], shell=False)`),绝不拼 shell 字符串。

## 5. 前端 UI(阶段 A 起)

单页,顶部标题 + 三块:
1. **Keys 状态卡**:每 key 一行,healthy 绿 / tripped 红 + 冷却倒计时;请求数、成功率。
2. **会话表**:name / status(live·resumable·new 上色)/ model / key / dir;每行按钮
   `kill`(阶段 B)、`edit`(阶段 C 弹小表单选 model/key)。
3. **日志流**:近期请求滚动列表(model · key · status · 是否 failover/forced)。
底部小按钮 `+ add key/provider`(阶段 D,弹表单)。原生 JS 轮询,无框架。

## 6. 关键取舍

- **exec `crew ls` 解析 vs `crew ls --json`**:解析定宽表格脆(列宽变了就崩)。**推荐给 crew 加
  `crew ls --json`**——小改动、稳、面板与 CLI 共用一份 status 逻辑。本 spec 纳入这个小改动。
- **写操作走 CLI vs proxy 直接改文件**:kill 必须走 `crew kill`(它还清 registry + tmux);
  改 model/key 是单值文件,proxy 直接写等价且更简单(避免 crew 无对应子命令)。CCR merge
  proxy 自己做(有备份)。
- **不做登录/token 统计**:保持薄;本机单用户;token 统计留后续。

## 7. 风险

- **命令注入**:所有 exec 用参数数组 + 白名单校验,绝不拼 shell。这是 D/B 阶段的头号风险。
- **CCR 写坏**:阶段 D 写前必备份;merge 逻辑复用 setup.sh 已验证的风格;失败回滚到备份。
- **crew ls 解析脆**:用 `crew ls --json` 规避(§6)。
- **dashboard 阻塞代理**:面板 API 不能拖慢转发主路径;exec crew 有超时;计数加锁但轻量。
- **HTML 内嵌膨胀**:单文件 HTML 别失控;控制在几百行内,复杂了再考虑拆(但拆就破坏零依赖,
  优先克制 UI 复杂度)。

## 8. 验证

- 阶段 A:起 proxy,访问 `/dashboard` 能看到 keys/sessions/logs;发几个请求(含故意失败),
  面板计数/熔断/日志正确刷新。
- 阶段 B:面板 kill 一个测试会话,`crew ls` 确认消失。
- 阶段 C:面板改会话 model/key,读 `<name>.backend/.key` 确认写对;`crew <name>` 生效。
- 阶段 D:加一个 key/provider,确认 CCR config 有新 provider + 备份文件存在 + keys.conf 有别名;
  故意传非法 alias/含元字符,确认被拒。
- 注入测试:name/alias 传 `; rm -rf` 之类,确认校验拦截、无命令执行。

## 实现顺序

1. crew 加 `crew ls --json`(小改动,面板依赖)
2. proxy:计数 + 日志环形缓冲 + `/api/status` `/api/logs` `/api/sessions` + `/dashboard` HTML(阶段 A)
3. 阶段 B:`/api/session/kill`
4. 阶段 C:`/api/session/config`
5. 阶段 D:`/api/ccr/provider`(备份 + merge + 注入防护)
6. 更新 README(内部 + 公开双版本)描述面板
