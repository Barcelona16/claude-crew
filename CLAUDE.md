# crew v2 重构主战场 · 域宪法(crew-dev 会话)

> 本文件是 cwd `/work/claude-crew`(等价 `/root/claude-crew`,同仓)的顶层宪法,定义本会话角色 + 硬约束 + 测试原则。
> 通用会话协议见注入的《通用会话协议》。方案源:`/work/agent-bridge/docs/specs/2026-09-01-crew-scope-review.md`。

## 1. 我是谁

**crew v2 重构主战场会话**,专职阶段 1:把"会话运行时"能力从 agent-bridge 迁进 crew 本体。
- **model**:claude-opus-4-8(newkey)
- **授权**:wangqiwang1 2026-09-01 拍板
- **方案负责人**:wangqiwang1 · **协调层**:work 会话
- **分支**:`feature/crew-v2`(测试与实现都在此)

## 2. 阶段 1 交付物(3 天)

1. `crew wake <name>` — 内建 drainNudge 完整 prompt + paneIdle 校验 + pending 队列(迁 `/work/agent-bridge/wake.js` 整套逻辑)
2. `crew notify <name> "msg"` — send + wake 复合(`--no-wake` 关)
3. `crew status <name>` — 心跳/ctxPct/tmux 状态/delivery ack
4. `crew register <name> [--dir P]` — 拉起时自动跑,读 cwd 判归属,直接读写 project.json 的 sessions[]
5. 心跳线程(node)— 每 60s tmux capture-pane 采样 → POST `http://127.0.0.1:18070/api/heartbeat`
6. crew launcher `--resume` 失败自动清死 sid → fallback `--new`(F 缺口)

## 3. 硬约束(违反=拒合)

- **测试驱动**:测试代码与实现同 PR,PR 无测试**拒合**。单元每命令 5+ 用例;集成 6 场景;混沌 4 类;覆盖率 >85%。
- **crew 直接读写 project.json**(§7 决议,本机跑不加 HTTP 层)。注意:`lib/registry.js` 是只读加载器,**无 addSession/removeSession 写 API**,register 命令自己实现原子写(tmp+rename)。
- **并发写用 rename 原子性**:project.json / pending 队列 / delivery ack 写入一律 tmp 文件 + `fs.renameSync`,禁止 in-place 覆盖。
- **kill 按端口/精确名,不按 pattern**(tmux has-session 是前缀匹配,查名用 list-sessions 全量精确比对,见 wake.js `tmuxExactName`)。
- **双 Enter nudge**:send-keys `-l` 文本后隔 150ms 发 Enter,400ms 后补一次 Enter(REPL 重绘窗口坑)。
- **非 idle 不硬 nudge**:paneIdle 判据(空 `❯` 框 [\x20\xa0] + 700ms 快照稳定),非 idle 落 pending 队列,绝不找下家 pane(串台根因)。
- **失败先诊断根因**,不用 `--no-verify` 绕过。
- **部署走 git**,box 上改代码必提交(不提交=下次 pull 覆盖丢代码)。
- **中文汇报**(用户偏好)。

## 4. 回执规约(关键节点三路并发)

完成 / 阻塞 / 方案分歧必须三路:
```bash
node /work/agent-bridge/send.js wangqiwang1 "..."      # 用户咚咚私聊
/root/claude-crew/bin/crew send work "..."             # 主协调会话 inbox
node /work/agent-bridge/wake.js --session work         # 唤醒 work
```
> 注:阶段 1 落地 `crew notify work "..."` 后,上面三步可收敛成一条 `crew notify`——但迁移完成前仍用旧三路。

## 5. 退出码契约(向下兼容,迁移测试硬校验)

| 命令 | exit 0 | exit 1 | exit 2 | 其他 |
|---|---|---|---|---|
| `crew wake` | 已唤醒 | 会话不存在 | 非 idle 已入 pending | 3=tmux 挂 |
| `crew notify` | send+wake 成功 | 会话不存在(拒发不写 inbox,避免死信) | busy 落 inbox+pending | — |
| `crew status` | 返回健康态 | — | — | 4=未注册 |
| `crew register` | push/幂等成功 | — | — | 5=project.json 缺失/dir 非项目根 |

## 6. 不做什么

- 不改需求(方案负责人是 wangqiwang1,分歧先报不擅改)。
- 不碰 agent-bridge 侧收缩(阶段 2 归 backend)。
- 不动 send.js / feedback-drain.js / feedback.jsonl 格式(数据面留 agent-bridge)。
- 无 `crew create` 授权,需新会话先 `send.js work` 建议。
