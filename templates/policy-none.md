# policy-none

**占位:AGENT_POLICY=none 时不注入任何附加 system prompt。**

用途:老 crew(dongkv-soak / chaos-longrun / drc-longrun / review-* / web-kimi 等 21 个存量)默认值。行为等同于方案 2 未落地前,零改动、零风险。

crew 端处理:检测到 `AGENT_POLICY=none` 或未声明,**跳过 --append-system-prompt**,直接起 claude。

无需内容——本文件的存在只是让模板集合语义完整。
