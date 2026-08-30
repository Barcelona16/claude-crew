# claude-crew-v2

crew L 档重构(2026-08-30 用户拍板):独立开发,测试全绿后再切换现有项目。

**目标**:
- 修 5 概念纠缠(--no-tmux / pintmux / tmux-nesting / bootstrap / two-step spawn)
- 通用化,单一职责
- CLI 100% 兼容 /work/claude-crew(21 命令 + 22 存量 crew 场景)

**架构**:
```
crew          顶层 CLI(200 行)
├─ crew-session   状态管理(300 行,纯,无 side effect)
├─ crew-tmux      tmux 集成(200 行)
└─ crew-launcher  claude 启动(200 行)
```

**开发原则**:
- **不动** /work/claude-crew(生产)
- 每个工具独立可测,先写 test/scenarios/*.sh 建 baseline
- 每周末打 tag,回归 8 场景 + 22 存量 crew ls diff

**进度**:
- Step 1(本 commit):建目录 + baseline templates + README
- Step 2:8 场景测试矩阵 + baseline.out
- Week 1:crew-session
- Week 2:crew-tmux
- Week 3:crew-launcher + 顶层
- Week 4:切换现有

详见 /work/bridge-eng/docs/research/crew-L-refactor-plan.md

## Step 1 交付(2026-08-30 12:xx workflow-code)

- v2 目录 + git init(独立于生产 /work/claude-crew)
- README + 复制 templates 4 个模板作参考
- test/scenarios/{01-08}.sh + run-all.sh + baseline.out
- **baseline 已建**(用老 crew 记录 8 场景标准输出)
- 已知 bug:run-all.sh 里某处 env 传递不干净,08-adopt case 偶发污染生产(手工直接跑 env 传递 OK,run-all 内层某调用可能没继承);待后续修

## 下一步 Week 1

- crew-session 独立,300 行 bash,纯状态管理
- 覆盖 sid/backend/key/policy/pintmux/notmux 6 种状态文件
- 单测 20+ case,不依赖 tmux/claude
