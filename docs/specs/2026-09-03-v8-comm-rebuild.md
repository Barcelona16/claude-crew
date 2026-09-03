# crew v8 · 三层通信重构 · SendMessage 一等公民(2026-09-03)

> **拍板**:wangqiwang1 2026-09-03 04:03 · 批准 5 步执行方案 · β 批量重开老会话已完成 14/16 · 剩 crew-dev/work 归用户手动
>
> **背景**:v6/v7 test-sendmsg 实测 "跨 tmux SendMessage 不通" 是错判。真根因 = 老 launcher 无 `--name` + claude < v2.1.224 · cross-session messaging 未 GA。sendmsg-test-a/b 2026-09-03 03:34 实证:UDS 直传 · ListAgents 双向可见 · 全通。
>
> **本 spec 目的**:v7 → v8 精简版协议 · SendMessage 从被排除回到主通道 · 一并修 P0/P1 坑 · 重构 Stop hook dedup。

## 1. 三层通信定稿 · v8

**决策口诀**(先问"目标是谁 + 我是谁"):

| 场景 | 通道 | 命令 |
|---|---|---|
| **会话内 model → 同机在线 crew 会话** · 一等公民 | 层 1 SendMessage | `SendMessage(to="<agentName>", message, summary)` |
| **hook/cron/外部脚本 → 会话** OR 兜底(对方 kill 但要留言) | 层 2 crew send | `crew send <name> "<内容>"` |
| 会话 → 用户咚咚 / cron / 外部 → 用户 | 层 3 咚咚外呼 | `feedback-drain --reply` / `send.js` |

**关键性质**:
- 层 1 走同机 UDS(`/tmp/cc-socks/<pid>.sock`)/ 跨机走 Anthropic 服务器转发 · turn 结束消息直进对方 context · **异步投递**(消息到达时机在发送方 turn 结束**之后**)
- 层 2 crew inbox 权威副本 + tmux 双 Enter 唤醒 · 保留兜底价值(pending 队列 / 面板追溯 / 会话不在同 UDS 域 / hook 等外部脚本无法调 SendMessage)
- **v7 → v8 变**:v7 说"只两条通道",v8 加回 SendMessage 作层 1 主通道 · v7 的 crew send 保留为层 2

## 2. Stop hook 定位澄清(重要)

**发现**:Stop hook 是**外部 shell 脚本**,不在 claude harness 里 · **不能直接调 SendMessage 工具**(SendMessage 只能被 claude 会话内 model 主动调)。

**因此 v8 Stop hook 保持走 crew send 底层**(crew-notify.js write)· channel='crew-auto-done' 标签保留 · **只加 dedup-key = session_id 防 hook + prompt 完事汇报双发**。

**A2 方案里 "SendMessage 主 + crew send 兜底" 只适用于会话内 model 主动通信** · Stop hook 层 2 用 crew send 是正确定位。

## 3. SendMessage 异步性说明(P1 归档)

- 消息到达对方 context 的时机:发送方 turn **结束之后** · 对方**下一 turn 开始时** harness 拼进 context
- **发送方本 turn 内不能期望**对方即时读到并回复;要即时反馈请用 crew send + tmux 唤醒(层 2)
- 面板消费 SendMessage 记录:通过 crew-sendmsg-hook.sh 镜像 feedback.jsonl channel='crew-native' · drain 侧已过滤不重复消费

## 4. v7 → v8 变更清单

### 4.1 底层代码

| 文件 | 改动 |
|---|---|
| `bin/crew-notify.js` | write 加 `--dedup-key` · 相同 key 24h 内跳过写入 · $CREW_STATE/.dedup/<key>.stamp marker |
| `bin/crew-stop-hook.sh` | 传 `--dedup-key <session_id>` 给 crew-notify.js write · marker 老逻辑保留(内部 marker + dedup-key 双保险) |
| `bin/crew` cmd_inbox | 加 `--as <name>` 身份校验 · 默认取 $CREW_SESSION · 越权拒绝 |
| `bin/crew-watcher.js` | stale-inbox 告警前 `crew ls` 检查 target 是否 live · 已 kill 跳过 |
| `bin/crew-sendmsg-hook.sh` | 不动 · 继续 channel='crew-native' |
| `bin/crew-launcher` | 不动 · --name + --settings v3.0 已到位 |

### 4.2 上层文档

| 文件 | 改动 |
|---|---|
| `templates/comm-protocol.md` | v7 → v8 · 三通道决策树 · 加 SendMessage 主路径 |
| `docs/specs/2026-09-02-comm-stable-final.md` | 加 §10 v8 note · 归档 v6/v7 判决错的根因(老 launcher 无 --name + claude 版本 <2.1.224)|
| `/work/.crew-onboarding/CLAUDE.md` §2.0 + VERSION | 直接改本机(direct 部署 · 不在 git 仓)· 下轮 crew stop+resume 生效 |
| `CLAUDE.md`(域宪法) | §2a 阶段 2 交付更新为"v8 上线" |

**注**:`agent-bridge/CLAUDE.md` **不存在 §2.0** — 该仓库根 CLAUDE.md 是通用会话协议指向,通信协议权威在:
1. `/work/.crew-onboarding/CLAUDE.md §2.0`(launcher 注入所有新会话)
2. `/work/claude-crew/templates/comm-protocol.md`(launcher --append-system-prompt 每次注入)
3. `agent-bridge/docs/specs/2026-09-02-comm-stable-final.md §10`(v8 归档)

三处内容对齐,`agent-bridge/CLAUDE.md` 本身不重复通信协议段以避免多源分裂。

### 4.3 dedup 语义(Agent-B 复审 · Round 3 补)

Dedup 是 **hook 内部机制** · 不涉及跨通道自动合并:

1. **只拦 hook 内部重触发** — Stop hook 传 `--dedup-key <self>.<sid>` 防同 turn 二次触发写重复 turn-done
2. **cmd_send / cmd_notify 不自动注入 dedup-key** — 手动 crew send 的调用方按语义(比如"完事汇报")决定是否想合并,不代码强制
3. **跨通道靠语义** — 手动 crew send X "完事汇报" + 同 turn Stop hook crew send X "[auto-done] ..." 会各落一条 · dedup 不合并
4. **面板消费面** — messagesOf 遇 crew-native + crew-auto-done 同 turn 双展 · 不合并 · 用户凭 channel 徽章(💬 vs 🤖)识别

### 4.4 修坑清单

| 坑 | 修法 |
|---|---|
| **P0 crew inbox 无身份校验** | cmd_inbox 加 `--as <name>` · 默认 = $CREW_SESSION · 越权拒绝 + stderr 警告 · 无 CREW_SESSION 场景(本地跑)不校验(兼容) |
| **P1 argv 身份错位**(test-a argv 是 --name test-b) | 归 work 复现细节 · 我盘点未见 launcher 变量污染 · 可能是 spawn 命令行重复 --name 覆盖 · 加 sanity check(可选) |
| **P1 SendMessage 异步归档** | 本 spec §3 明确 · 消费者不应期望 turn 内即时读到 |
| **消息重复 dedup** | crew-notify.js --dedup-key · Stop hook 传 session_id · 24h TTL marker |
| **crew-watcher stale 骚扰** | 告警前 crew ls 检查 target · 已 kill 跳过 |

## 5. 测试增量

| ID | 用例 |
|---|---|
| U11 | crew-notify.js `--dedup-key X` 两次 · 第二次跳过不写 |
| U12 | `--dedup-key A/B/A` · 只有 A 第二次跳,B 独立 |
| U13 | dedup marker 25h 后过期 · 允许重发(用 touch -d 模拟) |
| U14 | crew inbox 身份校验 · CREW_SESSION=alice · crew inbox bob → exit 1 + stderr |
| U15 | crew inbox 身份校验兼容 · 无 CREW_SESSION → 不校验通过 |
| U16 | watcher stale 跳过 killed 会话 |
| I7 | Stop hook 触发两次(同 session_id)· 第二次 dedup 跳过 |

## 6. 老会话适配(已完成 04:07)

- **14/16 会话**已 stop+resume 拿到 --settings + hook · SendMessage 能力就绪
- **剩 crew-dev + work**:归用户手动
- 重开清单:backend/chaos-longrun/coding/coding-9znh2/dongkv-soak/drc-longrun/proj-9znh2/review-full/review-pr/web-kimi/workflow-code(11 个)+ review/proj-y32g7/coding-y32g7(3 个前置)

## 7. 落地顺序

1. spec 定稿(本文档)· wangqiwang1 review
2. 代码重构(90 min · 5 commit):
   - commit A:crew-notify.js --dedup-key
   - commit B:crew-stop-hook.sh 传 dedup-key
   - commit C:crew cmd_inbox --as 身份校验
   - commit D:crew-watcher.js stale 跳过 killed
   - commit E:comm-protocol.md v7 → v8 + spec §10 归档
3. 回归 + 覆盖率
4. MR 重推 feature/stage2-hooks
5. crew send work 请派 3 agent 并行复审

## 8. 跨域协调

- **agent-bridge**:CLAUDE.md §2.0 v7 → v8 VERSION → 8 · 归 coding 派单
- **面板前端**:🤖 auto-done 徽章 · 归 backend 派单
- **我不擅改跨域文档**,只发 crew send work 请派

---
**版本**:v8 提案 · 未定稿 · 归 wangqiwang1 拍板
**分支**:feature/stage2-hooks 追加
