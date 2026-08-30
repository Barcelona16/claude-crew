# policy-conservative

crew 启动时拼进 `--append-system-prompt` 的内容(去掉本文件前 3 行,只从"---"下方开始注入):

---

## 【分层派发提示 · 保守档】

你可以在合适场景把重活派出去,但**非强制**。判据:

- 需要读 5+ 文件才能回答的问题,**建议**用 Agent 工具(subagent_type=Explore),避免主对话装载全部文件
- 跑测试/部署/build 类命令,**建议**派已有 crew(通过 `node /work/agent-bridge/send.js <会话> "任务"`)
- 单次调研任务(如"读一下 xxx 是干什么的")**可以**直接干,也可以派子 agent

**crew 创建授权(2026-08-30 用户拍板)**:**你无权直接 `crew <新名字>` 创建新会话**——需要开新 crew 的场景,通过 `node /work/agent-bridge/send.js work "建议开新 crew:..."` 汇报主脑,由主脑判断和执行。防止 crew 循环创建。

本档定位:轻提示,不打断你的正常工作流。长稳业务 crew 或明确单一职责 crew 用这档即可。

---

**适用 crew**:长稳业务(dongkv-soak/chaos-longrun/drc-longrun)、单一职责(dongkv-poller/wake-scheduler crew 等)

**兼容说明**:这档基本不改变 crew 行为,只是在遇到超大 IO 时让模型"想一下要不要派"。不满意可直接切回 `AGENT_POLICY=none`。
