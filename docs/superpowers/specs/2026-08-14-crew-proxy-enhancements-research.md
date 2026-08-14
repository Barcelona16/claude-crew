# crew-proxy 增强调研:成熟 LLM 代理/网关都做了什么 + 建议的功能清单

日期:2026-08-14
状态:调研 + 提案(待你验收)

你的要求:大胆探索成熟的这类管理工具怎么做(尤其 **token 消耗**),但**别太影响性能**;
先列一些我觉得有用的技能/功能,你明天验收。本文就是这份清单 + 取舍分析。

> 说明:本次环境无法联网搜索,以下是基于我对这些工具(LiteLLM、Helicone、Langfuse、
> OpenRouter、Portkey、Cloudflare AI Gateway、OpenWebUI)的既有认知整理。落地前对具体
> 字段/算法建议再对照各自最新文档核一遍。

## 一、成熟工具都做了什么(能力地图)

| 能力 | 谁做得好 | crew-proxy 现状 | 值不值得抄 |
|---|---|---|---|
| **按 key/模型统计 token & 成本** | LiteLLM、Helicone、Langfuse | 无(只统计请求次数) | ★★★ 你点名要的 |
| 请求日志 / trace(输入输出、延迟、状态) | Helicone、Langfuse | 有环形缓冲(内存,粗粒度) | ★★ 已够用,可增强 |
| 虚拟 key / 预算上限 / 限流(per-key rate limit + budget) | LiteLLM、Portkey | 无 | ★★ 有用但重 |
| 失败自动降级 / 重试 / fallback 链 | LiteLLM、OpenRouter、Portkey | **已做**(熔断+降级) | — 已完成 |
| 响应缓存(相同请求命中缓存省钱) | Helicone、Portkey、CF | 无 | ★ 对 coding 场景收益有限 |
| 负载均衡(多 key 轮询/加权,非仅故障切换) | LiteLLM、OpenRouter | 无(只按优先级) | ★ 可选 |
| 延迟 / 首 token 时间(TTFT)指标 | Helicone、Langfuse | 无 | ★★ 便宜且有用 |
| 成本预警 / 用尽告警 | LiteLLM、Helicone | 无 | ★ 依赖 token 统计先做 |
| 语义缓存 / 相似度去重 | Portkey、CF | 无 | ✗ 太重,不适合本项目气质 |
| 审计 / 合规日志落库 | 企业版们 | 无 | ✗ 超出定位 |

## 二、token 统计怎么做才「不影响性能」(核心)

这是你最关心的。难点:proxy 现在**刻意不解析响应体**(§ 前一个 spec 的决定),因为解析流式
SSE 有成本。要拿到 token 数,只有几条路,性能代价从低到高:

### 方案 1:读 usage 字段,但**只在非流式** + **流式只读最后一个 usage 事件**(推荐)
- 非流式:`_relay` 里 body 已经完整读进内存(现在就是 `resp.read()`),顺手 `json.loads`
  取 `usage.input_tokens/output_tokens`(Anthropic)或 `usage.prompt_tokens/completion_tokens`
  (OpenAI)。**几乎零额外成本**——body 本来就在手里。
- 流式(claude 交互几乎都是流式):**不要**逐块解析每个 SSE chunk(那会拖慢转发)。做法:
  转发时不解析,但**旁路累积**——把每个 chunk 追加到一个小 buffer(有上限),转发结束后
  **一次性**扫最后的 `message_delta`/`message_stop` 事件里的 usage。Anthropic 流式在
  `message_start` 给 input_tokens、`message_delta` 累计 output_tokens、末尾给最终值。
  **关键:解析发生在流已经全部转发给 claude 之后**,不占转发关键路径的延迟。
- 代价:每个响应多一次小 JSON 解析(µs 级)+ 流式多一个有上限的 buffer。**对转发延迟基本
  无感**(解析在 body 已送达客户端之后做)。这就是"不影响性能"的正确实现方式。

### 方案 2:估算(tiktoken/字符数近似)——不推荐
零解析响应体,但要引第三方库(破坏零依赖)或自己写 tokenizer(不准)。放弃。

### 方案 3:只统计字节数(现在能免费拿到)——保底
连响应体都不碰,只统计请求/响应字节。不是真 token,但零成本。**可作为方案 1 的降级兜底**
(某些上游不返 usage 时)。

**建议**:实现**方案 1**,落一份 per-key/per-model 的累计(input/output tokens、请求数、
按可配价目表算的估算成本),写进 `proxy-state.json` 旁边一个 `usage.json`(定期 flush,不是每
请求同步写盘——避免 IO 拖累)。dashboard 加一块"用量"卡。

### 性能护栏(务必)
- 解析只在 body 已转发完之后做,**绝不进转发关键路径**。
- 流式 buffer 设上限(如 256KB),超了就放弃该请求的 token 统计(极长响应罕见,宁可漏统计不
  拖慢)。
- usage 落盘用「攒 N 条或每 T 秒 flush 一次」,不是每请求写盘。
- 解析异常一律吞掉(统计是尽力而为,绝不能因统计报错影响转发)。

## 三、我建议做的功能清单(排序 = 我认为的性价比)

**第一梯队(建议做,契合项目、性能安全):**
1. **token & 成本统计**(方案 1)+ dashboard 用量卡。你点名要的,性能可控。
2. **延迟 / TTFT 指标**:转发时记 `t0`,首字节 / 结束各记一次,per-model 平均延迟。几乎免费
   (只加时间戳),dashboard 显示。
3. **usage 落盘 + 历史**:让面板能看"今日/本周 per-key token & 成本",不只是本次进程。

**第二梯队(有用,但更重或需你拍板):**
4. **per-key 预算上限 + 用尽告警**:某 key 超过配置的 token/成本上限就自动跳过(像熔断,但按
   预算而非失败)。依赖 #1。
5. **加权负载均衡**:key-policy 支持权重,不只是"故障才切",可主动分摊(省单 key 限流压力)。
6. **请求日志增强**:环形缓冲加 tokens/延迟/成本列;可选落盘最近 N 条到文件供事后查。

**第三梯队(观望,可能不做):**
7. 响应缓存 —— coding 场景重复请求少,收益低,且缓存正确性风险高。倾向不做。
8. 语义缓存 / 审计落库 —— 超出"薄代理"定位,破坏零依赖。明确不做。

## 四、我的推荐路线(若你明天点头)

按这个顺序,每步都能独立验证、独立提交,且都守住「不影响转发性能」:

1. **token 统计(方案 1)**——Stats 增加 usage 累计,`_relay` 旁路解析(非流式直读 / 流式尾部
   扫描),dashboard 加用量卡。这是主菜。
2. **延迟 / TTFT**——顺手加,几乎零成本。
3. **usage 落盘 + 面板历史视图**。
4.(可选,等你决定)**预算上限 + 告警**。

每步都配单测(mock 上游返回带 usage 的响应,断言累计正确;断言流式解析不阻塞转发)。

## 五、需要你明天定的取舍

- **成本估算要不要内置价目表?** token 数是客观的;换算成"钱"需要 per-model 单价表
  (会过时、且内部 llm-gw 计费口径可能和公开价不同)。建议:只统计 **token 数**,成本作为可选、
  价目表放配置文件由你填。
- **预算上限(#4)做不做?** 它会让 proxy 从"观测"走向"管控",是产品方向选择。
- **usage 落盘的隐私**:只存计数(token 数、次数),**绝不存 prompt/响应内容**。确认这个红线。

---

## 附:crew 本身可加的小技能(顺带想到的)

- `crew ls --json` 已加(dashboard 用)。可再加 `crew stats`(CLI 看用量,复用 proxy 的
  `/api/status`)。
- `crew doctor`:一键自检(CCR 通不通、proxy 通不通、keys.conf/policy 合法性、每个 policy 别名
  是否有对应 CCR provider)——排障利器,纯只读。
- dashboard 加"复制 crew 命令"按钮(选中会话 → 生成 `crew <name> --model ...` 命令)。
