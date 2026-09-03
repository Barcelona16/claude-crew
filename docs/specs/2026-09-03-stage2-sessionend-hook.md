# crew v3.1 阶段 2:Stop hook 完成回执(2026-09-03)

> **上下文**:v3.1 升级 2 —— 用户抱怨"派单出去不知道干没干完",完事汇报靠会话主动 crew send 触发者(prompt 层约定),漏做/格式错常见。用 **Claude Code CLI 内建 Stop hook**(机制层)自动 crew send 触发者,拿到结构化完成回执。
>
> **拍板**:work + wangqiwang1 2026-09-03 批准 v3.1 升级 2,归阶段 2 · **spec 归 crew-dev 主责**
> **spec 定稿后**:crew send work 报,拍板再开工。分支 `feature/stage2-hooks`,不直落 main,完工开 MR 走评审。

## 1. 事件选型:Stop(不是 SessionEnd)

依据 Claude Code CLI hooks 官方描述(hook-development/SKILL.md · 本地权威副本):

| 事件 | 触发 | 是否合适 |
|---|---|---|
| **Stop** | main agent turn 结束时(每 turn) | ✅ **就选这个** — 每次完事都触发 |
| SubagentStop | subagent turn 结束 | ❌ 我们要的是 crew 会话回 trigger,不是 fork subagent |
| SessionEnd | 整个 CLI session 终止 | ❌ 太晚,交互全结束才触发,失去实时性 |
| SessionStart | CLI session 启动 | ❌ 语义反了 |

**决策**:**Stop hook** · matcher `"*"` · type `"command"`(不用 prompt——机制层要快,不走 LLM)。

## 2. Hook stdin 输入 · 官方 schema

```json
{
  "session_id": "abc123",
  "transcript_path": "/root/.claude/projects/-work-.../SID.jsonl",
  "cwd": "/current/working/dir",
  "permission_mode": "ask|allow",
  "hook_event_name": "Stop",
  "reason": "<stop 原因>"
}
```

**关键字段**:
- `session_id`:claude harness 内部 UUID,**不是** crew 会话名(crew 侧要靠 `$CREW_SESSION` env 拿会话名,参考 crew-sendmsg-hook.sh 现有做法)
- `transcript_path`:本 turn transcript jsonl 完整路径 — 用于抠 turn 内容/耗时
- `reason`:Stop 事件专属字段,可能给出停止原因

**约束**:Exit code `0` = 成功;`2` = blocking(阻塞 Claude 继续,**我们不能用**);其他 = non-blocking error。**crew Stop hook 铁律恒退 0**(和 crew-sendmsg-hook.sh 一样),永不阻塞会话。

## 3. 完成回执 JSON 格式(crew turn-done rec)

Hook 触发时把这条 rec 写 target 会话 inbox(通过 `crew notify --no-wake` — 触发者会话可能正忙,不硬 nudge;或按 wake 策略自选)。

**下述 schema 是设计意图**;**实际实现**出于向后兼容(不改 envelope 层字段布局,避免破坏老 drain/面板消费者),把结构化字段全塞进 `note` 里的 `<!-- payload:<JSON> -->` HTML 注释——**单一权威副本原则**,消费者按正则抠出 payload 解析(见下 §3.1)。

```json
{
  "id": "<uuid>",
  "channel": "crew-auto-done",
  "kind": "turn-done",
  "from": {"kind": "session", "name": "<self crew name>"},
  "to": {"kind": "session", "name": "<triggerFrom>"},
  "trigger_id": "<触发本 turn 的信封 id 或 null>",
  "session_id": "<claude session_id>",
  "cwd": "<hook cwd>",
  "reason": "<Stop reason>",
  "transcript_snippet": "<可选:抠 transcript 尾部 N 行,含最终响应文字>",
  "turn_duration_ms": <可选:从 turn 开始到 stop 的 ms>,
  "ctx_pct": <可选:抠 pane 拿 % context used>,
  "ts": "<ISO 时间>"
}
```

**必填**:id / channel / kind / from / to / ts
**选填**:trigger_id / transcript_snippet / turn_duration_ms / ctx_pct(能拿就填,拿不到不阻塞)

**channel = `crew-auto-done`**(新枚举)——与 crew-native(SendMessage 镜像)、ding-outbound(咚咚外发)、external(外部写入)并列。feedback-drain 侧**跳过 crew-auto-done**(hook 触发的是通知,不是 drain 该消费的反馈),面板加徽章"🤖 auto-done"。

### 3.1 实现细节(self-review 2026-09-03 P1-1 判决:改 spec 对齐实现)

**Envelope 顶层字段**:实现里只写 `id / ts / from / note / delivery / channel / kind`(通过 `crew-notify.js write --channel crew-auto-done --kind turn-done` 落),**不写** trigger_id/session_id/cwd/reason/transcript_snippet 等结构化字段到顶层。

**Note 结构**:
```
[auto-done] <self> turn 完成 · reason=<reason>
<transcript_snippet 若有>
<!-- payload:{"kind":"turn-done","self":"...","session_id":"...","cwd":"...","reason":"...","trigger_id":"<env.id 或 null>","transcript_snippet":"...","ts":"..."} -->
```

**消费者读法**(面板/agent-bridge/其他会话):
```javascript
const m = envelope.note.match(/<!-- payload:(.+?) -->/);
const payload = m ? JSON.parse(m[1]) : null;
```

**为什么这样设计**:
- Envelope 层保持与老 crew send 完全兼容(老 drain/前端不认多字段就当无视)
- 结构化数据集中 payload 一处,避免"顶层字段 vs note 字符串"两份权威副本长期漂移
- HTML 注释包裹让 markdown 渲染器(面板)自动隐藏 payload,人类只看到 `[auto-done] ...` 首行 + snippet

**trade-off**:消费者要正则抠 payload · 但格式稳定(有 U10 单元测试保护),优于分裂两份字段的长期维护成本。

## 4. 触发者定位(triggerFrom · 关键难题)

Stop hook 只知道"我"是谁(`$CREW_SESSION` env)+ 本 turn 的 session_id/transcript,**不知道谁触发了本 turn**。触发者定位方案:

**方案 A · inbox tail 反查**(推荐):Hook 触发时读 `$CREW_INBOX_DIR/<self>/*.msg`(最近的 pending/consumed 信封),取 `.from.name` 作为 triggerFrom。缺点:如果 turn 是用户 attach tmux 手敲的,inbox 没条目,triggerFrom=null → hook 静默退不发。**这个 fallback 合理:没触发者就不通知,不是 bug**。

**方案 B · env 注入**:crew notify 时 send-keys 的 nudge 里塞 `CREW_LAST_TRIGGER=<from>` env——不可靠,tmux send-keys env 不是持久 shell state,turn 结束时 hook 拿不到。**否决**。

**方案 C · 独立 state 文件**:crew notify 落信封时同时写 `$CREW_STATE/<name>.last-trigger`,hook 读它。**次选**,比 A 有额外 IO,但 IPC 明确。

**首选 A**,退化时静默;C 备选(如果 A 因 inbox 归档时机不稳定不可行)。

## 5. 幂等去重(hook + prompt 完事汇报双写规避)

用户已有习惯:prompt 层"完事汇报 X"约定还会保留(通用协议 §1.1)。为避免同一 turn 被 hook 自动 crew send 一次 + 会话手动 crew send 一次:

**方案 · in-flight marker**:
1. Hook 触发前先检查 `$CREW_STATE/<self>.turn-<session_id>.done` 是否存在
2. 若存在(会话手动 crew send 前已在 crew-notify.js write 时写入 marker)→ hook 跳过,不重复通知
3. 若不存在 → hook 发 crew notify + 事后写 marker
4. Marker 24h 后 crew-heartbeat 清扫

**crew-notify.js `write` 增强**:检测 note 内含"完事汇报"或"回执"关键字 → 触发 turn-done marker 写入(触发者会话自己 crew send 时不产生双写)。**这条是可选优化**,不做也能靠 hook 自身冷启动状态判断(第一次跑就发,如果重复能容忍一次)。

## 6. 面板徽章展示

feedback.jsonl channel 枚举扩展:

| channel | 徽章 | drain 消费 |
|---|---|---|
| crew-native | 🔗 会话间 | 否(SendMessage 镜像) |
| ding-outbound | 📱 我发咚咚 | 否 |
| ding-inbound | (无徽章) | 是 |
| external | (无徽章) | 是 |
| **crew-auto-done** | 🤖 auto-done | **否**(hook 自动通知非用户反馈) |

Panel 前端 messagesOf 结果每条按 channel 加徽章;新增 crew-auto-done → 徽章 "🤖 auto-done"。

## 7. 落地代码清单

**新增**:
- `bin/crew-stop-hook.sh`(参考 crew-sendmsg-hook.sh):stdin 拿 hook JSON → node 解析 → inbox tail 反查 triggerFrom → 若命中调 `bin/crew-notify.js write` 落信封(channel=crew-auto-done,kind=turn-done)+ 写 marker
- `bin/crew turn-done`(可选子命令):手动触发同 hook 逻辑,便于 debug/回退

**改动**:
- `bin/crew-launcher`:extra_settings 生成的 `settings.json` 加 `Stop` hook(与现有 PostToolUse SendMessage hook 并列),command 指向 crew-stop-hook.sh
- `bin/crew-notify.js`:mirrorToFeedback 支持 channel=crew-auto-done 分支
- `agent-bridge/feedback-drain.js`:belongsToSession 增 `channel === 'crew-auto-done' → return false`(与 crew-native 同一逻辑并列)——**这条 agent-bridge 域**,需协调 coding 会话
- `web/panel` 前端:messagesOf 徽章展示扩展 —— **backend 域**,需协调 backend 会话

## 8. 测试要求(域宪法 §3 硬约束)

**单元(每命令 5+ 用例)**:
- U1 hook 收到合法 Stop JSON → 生成 crew-auto-done rec,写 inbox 成功
- U2 hook 收到缺 session_id/reason → 静默退 0,不 crash
- U3 hook triggerFrom 反查:inbox 最近条目命中 → 用其 from.name
- U4 hook triggerFrom 反查:inbox 空 → triggerFrom=null,静默退不发
- U5 hook 恒退 0:node 缺失/CN 缺失/marker 已存在都不 crash
- U6 marker 存在时跳过重复通知
- U7 crew turn-done 手动触发等价于 hook 自动触发

**集成 5+ 场景**:
- I1 A crew notify B → B turn 完 → hook 自动 crew send A 一条 turn-done
- I2 A 派 5 条给 B → B 每 turn 完自动回 A 一条 turn-done(5 条)
- I3 用户 attach tmux 手敲 B → hook 触发但 triggerFrom=null → 不发
- I4 B 会话手动 crew send A "完事汇报" → hook 检测到 marker 跳过重复
- I5 A 会话已 kill(tmux 无)→ hook crew send exit 1 不写 inbox 不 crash

**混沌 3+ 类**:
- C1 hook stdin 是坏 JSON → 恒退 0
- C2 crew-notify.js 缺失/不可执行 → 恒退 0
- C3 inbox tail 反查时 project.json 损坏 → 用 self session state 兜底,不 crash

**覆盖率 >85%**

## 9. 退出码契约(补充域宪法 §5)

| 命令 | exit 0 | exit 1 | 其他 |
|---|---|---|---|
| `crew-stop-hook.sh` | 恒 0(铁律) | — | — |
| `crew turn-done` | 成功发出 | triggerFrom 不可达/inbox 无线索 | 3=self session state 缺失 |

## 10. Open Questions(spec 讨论期待反馈)

1. **triggerFrom 反查方案 A vs C**:先试 A 简单,不稳再换 C(state 文件)?可以两阶段落地
2. **transcript_snippet 抠内容策略**:transcript jsonl 抠"最后一条 assistant message text"还是"整段 last-turn"?默认前者(短、够用),长度上限建议 512 字节
3. **turn_duration_ms 拿法**:hook 触发时无"turn 开始时间",能从 transcript_path 头部 timestamp 反推,但成本大且不精确。**建议先不做,后续按需加**
4. **crew turn-done 子命令是否必需**:如果 hook 稳定,子命令价值仅 debug。可先不实现,只做 hook 主路径

## 11. 与 v7 协议关系

v7 业务协议**不变**:crew send 命令行接口不变,业务侧只知道"crew send 跨会话 / send.js+drain 咚咚"两条通道。**Stop hook 是 crew 内部机制升级,业务用法无感知**——crew send 依然是"通知目标"的接口,只是 hook 自动帮触发者收到回执,不用会话自己 crew send 回。

---

**作者**:crew-dev(2026-09-03,基于本机权威 hook-development/SKILL.md 副本 + crew-sendmsg-hook.sh 先例)
**版本**:v1 提案(未定稿,归 work + wangqiwang1 拍板)
**分支**:`feature/stage2-hooks`(spec 定稿开工时创建,不直落 main,完工开 MR)
