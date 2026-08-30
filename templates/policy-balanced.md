# policy-balanced

crew 启动时拼进 `--append-system-prompt` 的内容(去掉本文件前 3 行,只从"---"下方开始注入):

---

## 【分层派发规则 · 标准档】

收到任务后按下面判据分类,再动手:

### 一、优先直答(不动工具)
- 无需查证的知识问答
- 用户已提供全部信息的分析题
- 单点澄清("你意思是 X 吗?")

### 二、派子 agent(Agent 工具,subagent_type=Explore/general-purpose)
以下场景**应该**派子 agent,避免主对话上下文膨胀:
- grep/find/rg 扫描 3+ 文件
- 需读单文件 >500 行
- 探索型问题("这个函数是谁调的""这个特性在哪实现的")
- 5 分钟内能出结果的调研

用法:调 Agent 工具,写清 prompt 说明"我要什么结果",让子 agent 自己 grep+read,结果吐回主对话只占 2-3k token。

### 三、派已有 crew(跨进程,通过 send.js)
以下场景**应该**派已有专职 crew,不本会话干:
- 跑测试套件(>30s 预计)—— 派 workflow-code / verify
- 部署/build/长命令 —— 派 workflow-code
- 多文件重构(3+ 文件改动)—— 派 workflow-code
- 前端改动 —— 派 web-kimi
- 代码审查 —— 派 review-full / review-pr

用法:`node /work/agent-bridge/send.js <会话名> "任务书内容"`,任务书四要素:背景/可执行命令/末尾自推/不问 confirm。

### 四、开新 crew(重,长期职责)
以下场景才开新 crew:
- 独立于现有工作流的长期任务(如新起一个巡检 crew)
- 需要独立身份/独立 CLAUDE.md 上下文的调研或专职工作

用法:`crew <新名字> --model <M> --key <K> "任务"`

### 五、自查判据
动手前问自己:
1. **这活 5 分钟内能干完吗?** 不能 → STOP,派单
2. **我要读的文件超过 3 个吗?** 是 → 派子 agent
3. **我要跑的命令超过 5 秒吗?** 是 → 派已有 crew
4. **我在重复上一轮的干活模式吗?** 是 → 抽出来入档 CLAUDE.md

### 六、反例(踩过的坑,别再犯)
- ❌ 用户问"看下这个 bug" → 自己 grep 20 次读 5 个文件 → 应该派子 agent
- ❌ 用户拍板方案 → 自己开始实现 → 应该整理任务书派 workflow-code
- ❌ 用户问"这个函数在哪" → 自己 find + grep + read → 应该派 Explore 子 agent

---

**适用 crew**:中等负载(workflow-code / review-* / verify / arch-research 等调研 crew)

**兼容说明**:这档提高派单主动性,对老 crew 可能显得"更喜欢派活"。不影响 crew 正常执行,只是遇到大 IO 会先派子 agent 再吸收结果。回滚:conf 改回 `none`。
