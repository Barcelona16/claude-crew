## 同机会话间通信

**一句话决策**:**会话内默认用 SendMessage · shell 脚本用 crew send · 外呼用户用 send.js**。

你运行在 crew 管理的常驻会话里,同一台机器上可能有多个 claude 同伴会话。**v8 三通道**(2026-09-03,SendMessage 通了后):

**决策口诀**(先问"我是谁 + 目标是谁"):

- **我是会话内 model,目标是同机在线会话** → 用 **`SendMessage`**(官方工具 · UDS 直传 · 一等公民)
  - `SendMessage(to="<agentName>", message="...", summary="...")` — agentName = crew 会话名
  - `ListAgents` 查在线会话
  - 语义:异步投递 · 消息进对方 message queue · 对方下一 turn 开始时进 context
  - 局限:无 read receipt(不知对方读没读)· 要即时对话得等对方回 SendMessage 才知道

- **我是 hook/cron/外部脚本 → 会话** 或 **兜底(会话已 kill/需 pending 排队/需面板追溯)** → 用 **`crew send`**
  - `crew send <会话名> "<内容>"` · 消息落对方 crew inbox + tmux 双 Enter 唤醒(paneIdle 判据 · 忙时排队)
  - hook 场景强制走这个 · shell 脚本没 SendMessage 工具

- **回复咚咚触发者 / 主动咚咚外呼** → 用 **`send.js` / `feedback-drain --reply`**
  - `node /work/agent-bridge/feedback-drain.js --reply "..."` — 按最近触发者自动路由
  - `node /work/agent-bridge/send.js [--erp <erp>] "..."` — 主动发咚咚

**踩坑立**:
- `send.js` **不认** `@<会话名>` 前缀或 `--session` 参数——写了当字面串,消息仍走默认咚咚 erp。想给会话发消息用 `SendMessage`(会话内)或 `crew send`(脚本)。
- **hook 里没 SendMessage 工具**:Stop hook / cron / 外部脚本是普通 bash,不是 claude 会话 —— **只能用 crew send**。
- **dedup 只拦 hook 内部重触发**:Stop hook 传 `--dedup-key <self>.<sid>` 防同 turn 二次触发;**手动 crew send + hook 若同 turn 内共存,会各落一条**(跨通道不自动合并),用户凭 channel 徽章(crew-native vs crew-auto-done)识别。
- **agentName == crew 会话名**(launcher `--name` 保证 · 2d167f4 后对齐)。ListAgents 列出即会话名,SendMessage `to=` 也是会话名。
- **跨机器降级**:同机走 UDS 直传(`/tmp/cc-socks/<pid>.sock`);跨机器 SendMessage 会经 Anthropic 服务器转发。**本 protocol 只保证同机场景**,跨机器的行为按 Claude Code CLI 官方能力兜底。

> 仅覆盖**同机**会话。跨机器的会话不在此机制内。
