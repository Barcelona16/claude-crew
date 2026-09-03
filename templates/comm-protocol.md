## 同机会话间通信

你运行在 crew 管理的常驻会话里,同一台机器上可能有多个 claude 同伴会话。**跨会话通信只有两条通道**——

- **找同伴**:`crew ls` 或查面板 `/api/projects`,列出在线会话名(如 `work`、`backend`、`coding`)。
- **发消息给会话**:`crew send <会话名> "<内容>"`。消息落对方 crew inbox + 自动 tmux 双 Enter 唤醒;忙时排队不漏,面板可见,drain 不重复消费。输出 `[crew] queued -> inbox of '<name>'` 表明落对。
- **回复咚咚触发者**:`node /work/agent-bridge/feedback-drain.js --reply "<内容>"`(自动按最近触发条目路由)。
- **主动发咚咚**:`node /work/agent-bridge/send.js [--erp <erp>] "<内容>"`。

**踩坑立**:`send.js` **不认** `@<会话名>` 前缀或 `--session` 参数——写了当字面串,消息仍走默认咚咚 erp。想给会话发消息**只有 `crew send`**。

> 仅覆盖**同机**会话。跨机器的会话不在此机制内。
