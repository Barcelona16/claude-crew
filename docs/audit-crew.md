# crew 工具架构梳理汇总(audit-crew)

> 2026-08-30 20:09,主会话直派子 agent 产出(前两个 crew 会话干这活都卡死)
> 任务书来源:用户 16:33 拍板(架构被反复修补千疮百孔,梳理),范围 /work/claude-crew(v2 重构后的 crew-session/crew-tmux/crew-launcher+配置)
> 性质:只梳理不实施;参考 /work/bridge-eng/docs/audit-backend.md 结构

---

## 一句话总结

v2 三件套(crew-session 193 行/crew-tmux 183 行/crew-launcher 233 行/顶层 crew 348 行)的**分层本身是干净的**,但它是"半场切换":v1 的 1586 行还在同目录躺着(`crew.v1`)、v1 的 6 个命令面(up/keys/stats/delegate/sync-models/prune)静默丢失、v2 不再 source ext hooks 但 ext 脚本还留在配置目录里、registry 只有 v1 在写而 v2 只读不写——**每层职责清楚,但层与层之间、v1 与 v2 之间的契约没人管**,这就是"千疮百孔"的结构性根源。审计共发现 **18 条补丁债**、**6 个待拍板问题**,最重的一条是 v1 用血泪修掉的"/tmp 明文 token 泄露"在 v2 重构中丢失——crew-launcher 生成的启动脚本不脱敏直接落 /tmp,现场已堆积 10+ 个。

---

## 二、总体架构(v2 现状速写)

```
crew (348 行,顶层 CLI,兼容 21 命令)
├─ crew-session (193 行,纯状态:13 字段文件 $CREW_STATE/<name>.<field>)
├─ crew-tmux    (183 行,tmux 生命周期:精确名匹配/resolve 双前缀/防自杀)
└─ crew-launcher(233 行,组装 claude argv:backend conf/policy body/two-step spawn)
```

- 切换方式:`scripts/switch-to-v2.sh` 备份老 crew 为 `bin/crew.v1`,换 4 个 bin。rollback 脚本在。
- `crew-session list` 遍历 `*.field` 文件输出 tsv;顶层 `crew ls` 再叠加 /proc 真值反查(model/cwd/key)。
- 配置:`~/.config/claude-crew/`(backends/*.conf + keys.conf + ext/joycode.sh + joycode_proxy.py);状态:`~/.local/share/claude-crew/`。

## 三、补丁债清单(18 条,带文件行号证据)

### 主题 A:v1→v2 迁移遗留(7 条)

| # | 问题 | 证据 | 危害 |
|---|---|---|---|
| A1 | **v1 全量躺在 bin/crew.v1(1586 行)当"参考实现"** | `/work/claude-crew/bin/crew.v1`;d8ff983 commit "恢复 bin/crew.v1 备份" | 两份实现并存,v2 缺功能时读 v1 抄逻辑(crew-launcher:62-82 的 backend 合成就是照 v1:313 手抄的),抄完没有回归验证;README 里 v2 说的"CLI 100% 兼容 21 命令"与实际不符 |
| A2 | **6 个 v1 命令面丢失:up/keys/stats/delegate/sync-models/prune** | v1:1242 `up)`/1285 `keys)`/1357 `sync-models)`/1201 `prune)`/1147-1148 stats/delegate;v2:281 `prune` 是唯一 stub("not implemented in v2 skeleton"),其余 5 个**连 stub 都没有**——`crew keys` 会落进 `*) cmd_spawn` 分支被当会话名误起会话 | `crew up`(拉起 CCR:3456 + crew-proxy:8788 + joycode ext)没了,但 v2-laucher 合成 backend 时假设 :8788 在听——**依赖链断了但没人拉**;`crew sync-models`(注册新模型进 CCR,CLAUDE.md 明文要求 kimi 切换前跑)同样消失 |
| A3 | **v2 不 source ext hooks,v1 source** | v1:83 "Optional extensions live in $CREW_HOME/ext/*.sh (sourced if present)";v2 四个文件 grep 'crew_ext' 零命中;`/root/.config/claude-crew/ext/joycode.sh` 还在(定义 crew_ext_dep_up/crew_ext_cmd/crew_ext_help) | joycode 扩展(代理拉起 :8765/joycode_* 模型预设/joycode-export 子命令)对 v2 完全失效;ext 文件成了死配置 |
| A4 | **backend conf 丢失后靠"v1 兼容合成"续命** | crew-launcher:61-82:conf 缺失且 backend 带逗号→合成 `BASE_URL=crew-proxy:8788 TOKEN=test KEY_MODE=ccr`;现场 `/root/.config/claude-crew/backends/` 只有 joycode.conf+mock.conf 两份(joycode.conf 是刚手工补的) | KEY_MODE=ccr 是合成的假值(现场真 conf 用 KEY_MODE=joycode),keyresolve 走 conf 时行为分叉;依赖"恰好带逗号"的隐式约定 |
| A5 | **registry v1 写/v2 不写,v2 kill 误删全行** | v1:247 `printf '%s\t%s\n' "$cwd" "$name" >> "$REG"`(resolve_name_for_cwd/resolve_explicit_name/fresh_name_for_cwd 三处 append);v2 四文件 grep 写 registry 零命中,只有 crew-session:120-124 clean 删行、crew:125-127 ls 读行;现场 registry 内容 `/work⇥work` + `/work⇥owkr`(两行,`owkr` 是脏行/试错残留) | v2 起的会话永远不进 registry→`crew ls` DIR 列靠 /proc 兜底、crew-session-sync.js(agent-bridge)看不到该会话、ensure-daemons 548 行 `reg_dir` 反查返空回落 /work;`crew kill` 走 clean 删 `$2==name` 行——脏行删不掉也没人清 |
| A6 | **state 字段 13 个,v2 实际用 7 个,3 个死字段** | crew-session:40 VALID_FIELDS 13 个;notify/settings/nohup 三个字段 v2 全链路零写入零读取(只在 clean 里被删);v1 里 notify 有完整 Stop hook 体系(v1:821-838),v2 没实现 | `--notify` 任务完成回报功能整体丢失;字段表声明了不存在的语义,误导后续开发 |
| A7 | **测试基线漂移已发生** | `git status`:`test/scenarios/output/{03,04,05,06,08}.out` 5 个 baseline 未提交修改 | v2 的 8 场景回归"全绿"结论建立在被改过的 output 上,下次跑 run-all 会对不上;对比 v2 切换时"20+integ 全绿"的说法已不可复验 |

### 主题 B:五概念纠缠(4 条)——今天 work policy 加载 4 次失败的根因区

| # | 问题 | 证据 | 危害 |
|---|---|---|---|
| B1 | **--no-tmux 的三重语义:pin 优先/fg exec 替换/记忆模式** | crew:316-322(pintmux 时忽略 --no-tmux 静默转 tmux)+ crew-launcher:197-204(fg 模式 `exec bash "$launcher"` **替换当前 shell**+写 fgpid=$$)+ crew-session:19(notmux "0"/"1" mode 记忆) | 同一个 flag:对 pinned 会话是"被忽略"、对 fg 是"吃掉你的 shell"、对第三方调用方(start.sh/bootstrap.sh 用 `--no-tmux </dev/null &` 起后台)依赖"claude 拒 root 前台"这个副作用才不炸;bootstrap.sh:57-66 已为这个纠缠打了 B1 补丁(un-pin/re-pin 绕圈) |
| B2 | **fg 模式写 fgpid=$$ 但 fgpid 语义在 v1 是"claude 的 pid"** | crew-launcher:202 `"$CS" set "$name" fgpid "$$"`——$$ 是 crew-launcher 进程;v1:622-625 用 fgpid `kill -0` 判 fg 活。v2 无任何 fgpid 消费方 | 死状态字段+语义漂移:若未来有人按 v1 语义读 fgpid,判活必错 |
| B3 | **tmux-nesting 判据分裂** | v2 侧:crew-tmux:92 `env -u TMUX` 起 session、start.sh:119 `env -u TMUX` 包 crew;但 ensure-daemons.sh:304 `tmux has-session -t work` 仍是**前缀匹配**(CLAUDE.md 3c 铁律禁用写法,自己仓里还剩这一处) | nesting 的"真相"分散在调用方各自 env -u,crew 内部无统一判据;ensure-daemons 的 has-session 前缀坑(work 误中 workxxx)未清零 |
| B4 | **two-step spawn 的"等 shell 就绪"启发式脆弱** | crew-launcher:208-214:ensure 后循环 20 次 capture-pane grep '\$|#|❯' 判 shell 提示符;:218 task 灌入 `sleep 2` 后 send-keys | policy 加载 4 次失败的事故形态:prompt 正则误判 + sleep 2 不够 claude 起完 → task/policy 灌进空 pane 或被 shell 吃掉;无任何就绪回执机制 |

### 主题 C:重复实现/逻辑冲突(4 条)

| # | 问题 | 证据 | 危害 |
|---|---|---|---|
| C1 | **tmux 名解析:crew-tmux resolve(权威,4 级回落)与 ensure-daemons 手抄双前缀并存** | crew-tmux:42-64(resolve:adopted tmux→tmuxname→裸名→crew-前缀→默认返 crew- 且 exit 1);ensure-daemons:234-249 手写 `crew-$CS`/`$CS` 双前缀 grep,不认 adopted/tmuxname | 两套解析对"adopt 会话用外部名"的场景结论不同;ensure-daemons 12 段杀会话(278-281 kill-session)用的名字可能和 crew 自己 resolve 的不一致,杀错/杀漏 |
| C2 | **/proc 真值反查逻辑:crew ls 一份(348 行里 82-130,含 keyresolve 调用+registry 兜底)与 ensure-daemons 11 段手写 pane_pid/ps 一份** | crew:86-103 vs ensure-daemons:254-262 | 同"判 claude 活"逻辑两处维护,一处改了另一处漂移(ensure-daemons 已补过 pane_current_command 误报坑,crew ls 侧没有) |
| C3 | **inbox 消费协议无 ack:crew inbox 无参即删(crew:239 `rm -f *.msg`),与 agent-bridge feedback-drain 的 ack/回滚哲学冲突** | crew:223-242 vs agent-bridge watcher/feedback-drain 的 pending/ack 机制 | 会话侧用 crew inbox 收的任务,读完即焚无消费失败恢复;两套消息体系(crew inbox vs agent-bridge store)并存,语义不对称 |
| C4 | **crew-launcher 生成的 /tmp/crew-launch-*.sh 无清理+明文 token(v1 修了 v2 没跟)** | v1:869-870 落 /tmp 前 `sed 's/ANTHROPIC_AUTH_TOKEN=[^ ]*/ANTHROPIC_AUTH_TOKEN=***/g'` 脱敏;v2 crew-launcher:183-195 直接 printf env 前缀,**不脱敏**;现场 /tmp 有 10+ 个 crew-launch-*.sh(含 audit-* 测试残留) | v1 用血泪换来的 token 泄露修复(commit 9b48bc6)在 v2 重构中丢失;/tmp 644 明文 ANTHROPIC_AUTH_TOKEN,含真 key 的 conf 起的会话全裸奔 |

### 主题 D:死代码/杂项(3 条)

| # | 问题 | 证据 | 危害 |
|---|---|---|---|
| D1 | **crew-session `list` 顺序依赖 bash associative array 迭代+sort 兜底,输出字段截断 60 字符** | crew-session:162 `head -c 60` 截断 | backend 值如 `joycode-oai,Kimi-K3` 尚可,长 path/task 类字段截断;tsv 协议无文档,消费方(crew ls)只吃 name 列,其余字段实际白传 |
| D2 | **`crew help` 只 sed 3,22 行头注释,flag 表不全** | crew:346 `sed -n '3,22p' "$0"`;实际支持 --policy(crew:50)未列在 3-22 段外 | 用户 help 看不到 --policy/--pick 语义;与 CLAUDE.md "完整用法 crew --help"的预期不符 |
| D3 | **joycode.nohup.log 等状态目录垃圾** | `/root/.local/share/claude-crew/` 里 joycode.nohup.log + audit-back/audit-front 测试残留(notmux/sid/tmuxname/backend 多文件) | 测试污染生产 state(README Step1 已自知"run-all env 传递不干净,08-adopt 偶发污染生产",未修);state 目录无清理机制 |

## 四、待拍板问题(6 个,有行为权衡)

1. **v1(crew.v1)删还是留?** 留=参考实现+rollback 便利,但 A1/A4/A5 的漂移持续发生;删=丢失 up/keys/sync-models 等 6 命令的唯一样本。建议:先把 6 命令移植进 v2 再删,或明确 crew.v1 只读不跑。
2. **`crew up` 的服务拉起职责归谁?** v2 没实现,现状 :8788/:3456 靠 ensure-daemons cron + start.sh 拉起(ccr 进程在、crew_proxy.py 在)。若 crew 不再管服务,CLAUDE.md"crew 常用速查"和依赖链文档要改;若 crew 管,需把 crew_dep_up 移植。
3. **ext hooks 机制要不要在 v2 复活?** ext/joycode.sh 当前是死配置(A3)。复活=插件面回归;不复活=joycode 功能(预设/代理/export)永久丢失,当前靠手工 conf 兜底(A4)。
4. **registry 协议归谁?** v2 不写 registry(A5),但 agent-bridge 3 处消费(crew-session-sync.js/ensure-daemons/crew ls DIR 兜底)。选项:crew-session 加 registry 写入(单一写方)/全链路改用 /proc 真值淘汰 registry/维持现状(半瘫)。涉及跨仓契约,需与 agent-bridge 侧统一拍。
5. **fg(--no-tmux 前台)模式还留不留?** B1/B2 显示它语义破碎,且 root 环境下 claude 拒前台跑(CLAUDE.md 已有"新建 crew 会话不能带 --no-tmux"硬约束)。删掉可消掉 notmux/fgpid/fg 三纠缠;保留则需修 exec 替换语义+fgpid 语义。
6. **inbox 要不要并进 agent-bridge 消息体系?** C3。并=单一消息语义+ack 可恢复;不并=crew 自治,但两套哲学继续分叉。

## 五、重构建议(优先级+成本,只梳理不实施)

| 优先级 | 建议 | 成本 | 说明 |
|---|---|---|---|
| **P0** | **补 v2 的 token 脱敏+launcher 清理**(C4):crew-launcher 落 /tmp 前脱敏 ANTHROPIC_AUTH_TOKEN,spawn 成功后可留文件但权限 600;顺手清 /tmp 存量 | 0.5h | v1 已修过的安全坑在 v2 丢失,明文 token 落 /tmp 是活风险,无行为权衡不需拍板 |
| **P0** | **registry 写方收口到 crew-session**(A5):set tmuxname/sid 时同步写 registry 行(kill 已删行,对称补写入),并加一次 `crew doctor` registry 脏行自愈(删 owkr 这类) | 1h | 不做则 agent-bridge 侧 crew-session-sync 持续半瞎;做=恢复 v1 契约,v2 会话重新对面板可见 |
| **P1** | **tmux 名解析单源化**(B3+C1):ensure-daemons 11/12 段改调 `crew-tmux resolve`,删手抄双前缀;顺手清掉 ensure-daemons:304 的 has-session -t 前缀匹配 | 1.5h | 与 agent-bridge audit-backend"7 处手抄 tmux 解析"同病,根治前缀劫持类 bug 的复发路径 |
| **P1** | **命令面诚实化**(A2+D2):up/keys/stats/delegate/sync-models 在 v2 里要么实现要么显式 die 带迁移指引(现在 keys 等会被当会话名误 spawn);help 输出补 --policy;`crew prune` stub 明确丢弃 | 1h(显式 die)/1 天(up/keys/sync-models 移植) | 最小版本(显式 die)先止血"误起会话";移植版本待拍板问题 1/2 有结论再做 |
| **P2** | **就绪回执替代启发式**(B4):two-step spawn 后不 sleep 2+grep prompt,改为 launcher 脚本里起 claude 前后 touch 就绪标记文件(如 `$CREW_STATE/<name>.ready`),task 灌入等标记 | 1h | 直击今天 policy 加载 4 次失败的根因形态;需小规模验证 claude 起动时序 |
| **P2** | **死字段清理**(A6+B2+D3):VALID_FIELDS 砍掉 notify/settings/nohup(或实现 notify);fgpid 语义修正或随 fg 模式一起删(待拍板 5);state 目录测试残留清理+run-all 隔离修复(README 已知 bug) | 0.5h | 降低后续开发误用;notify 若要实现成本另计(约 1 天,含 Stop hook 注入) |
| **P3** | **测试基线复位**(A7):git checkout 恢复 5 个 output/*.out 或重新录制并 commit,恢复"8 场景全绿"可复验性 | 0.5h | 没有可信基线,以上任何重构都无法回归验证——实际应最先做 |

(排序说明:P3 的基线复位虽标 P3,但它是所有其他项的前置,动手时第一个做。)

## 六、现场快照(2026-08-30 20:09)

- 仓:main=origin/main(已同步),分支只有 main;最近 commit 170acef
- 进程:ccr(15:05 起)与 crew_proxy.py(Aug29 起)都在跑;:8788 在听(crew-proxy)
- state:work 会话带 pintmux+policy=aggressive+policy_body(5.6KB)+backend=`joycode-oai,GLM-3`+key=joycode,/tmp/crew-launch-work.sh 内容与之一致(现役主会话,健康)
- registry:仅 2 行(/work→work、/work→owkr),其中 owkr 为脏行
- 测试输出:5 个 baseline output 有未提交修改
