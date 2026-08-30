#!/usr/bin/env bash
# 02-spawn-notmux.sh — crew --no-tmux 起会话(mock claude 是 /bin/echo,立即退)
# 期望:crew 拼装 claude 命令 exec,echo 打印参数后 crew 记状态文件
"$CREW_BIN" --no-tmux mock-test1 2>&1 | head -20
echo "---exit=$?---"
echo "---state files---"
ls -1 "$CREW_STATE/" 2>&1 | sort
