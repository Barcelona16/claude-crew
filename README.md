# claude-crew

给 [Claude Code](https://claude.com/claude-code) 的具名、可 attach、可持久化的 tmux 会话管理器，支持 CCR 3 模型路由与跨会话官方通信。

当前主线是 **v3**：会话间消息走 Claude Code 的 `SendMessage` / `ListAgents`，CCR 3 负责模型路由；`bin/crew` 是唯一的 CLI 入口。

## 安装

```bash
git clone <repo> && cd claude-crew
bash install.sh
crew --help
```

完整的中文使用说明见 [README.public.md](README.public.md)，英文说明见 [README.en.md](README.en.md)。

## 版本分支

- `legacy/v1`：旧单体实现，仅用于回溯。
- `release/v2`：多工具重构的最后一个 v2.5 版本，仅用于维护旧部署。
- `main`：当前 v3/CCR 3 实现；不包含旧版本可执行代码或回滚脚本。
