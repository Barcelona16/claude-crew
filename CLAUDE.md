# crew v2 重构主战场 · 域宪法(crew-dev 会话)

> 本文件是 cwd `/work/claude-crew`(等价 `/root/claude-crew`,同仓)的顶层宪法,定义本会话角色 + 硬约束 + 测试原则。
> 通用会话协议见注入的《通用会话协议》。方案源:`/work/agent-bridge/docs/specs/2026-09-01-crew-scope-review.md`。

## 1. 我是谁

**crew v2 重构主战场会话**,专职把"会话运行时"能力从 agent-bridge 迁进 crew 本体。
- **model**:claude-opus-4-8(newkey)
- **授权**:wangqiwang1 2026-09-01 拍板
- **方案负责人**:wangqiwang1 · **协调层**:work 会话
- **当前阶段**:阶段 1 **已完工**(2026-09-01 落地 in main),进阶段 2(v3.1 升级 2 SessionEnd/Stop hook 完成回执)
- **分支**:阶段 2 开工时新起 `feature/stage2-hooks`(阶段 1 遗留分支归档 tag `stage1-history`)

## 2. 阶段 1 交付物(已完成 · 2026-09-01 落地 · 24/24 集成测试全过)

| # | 交付物 | main 上 commit |
|---|---|---|
| 1 | `crew wake <name>` 内建 drainNudge + paneIdle + pending 队列 | `20c9ebe` feat(crew): crew wake 内建 — 迁 wake.js 整套 |
| 2 | `crew notify <name> "msg"` + JSON 信封 + delivery ack | `8e8d8c9` feat(crew): crew notify + JSON 信封 + delivery ack |
| 3 | `crew status <name>` 心跳/ctxPct/tmux 状态 | `4ce4c8c` feat(crew): 心跳线程 + crew status |
| 4 | `crew register <name>` 读 cwd 原子写 project.json sessions[] | `033bdce` feat(crew v2): crew register |
| 5 | 心跳线程 60s 采样 + **v3.1 升级 3 idle 自动 flush pending** | `4ce4c8c` + `4216596` feat(crew-heartbeat): 采样后顺手 flush pending |
| 6 | crew launcher `--resume` 死 sid 自愈 fallback `--session-id` 新起 | `176bc4a` feat(crew-launcher): --resume 死 sid 内容自愈 |

**验收证据**:`bash test/crew-integration.test.sh` 在 main 上 **24/24 pass**(集成 6 + 混沌 4 + 迁移 2)。work + wangqiwang1 2026-09-03 关档批准。

## 2a. 阶段 2 交付物(v3.1 升级 2:SessionEnd/Stop hook 完成回执)

进行中。spec 待写:hook 触发时机 / 回执 JSON 格式 / channel 选型 / 面板徽章 / 幂等去重(hook + prompt 完事汇报双写规避)。spec 定稿 crew send work 拍板后开工。域宪法 §3 硬约束沿用。

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
