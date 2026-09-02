#!/usr/bin/env bash
# crew-sendmsg-hook.sh — PostToolUse hook,会话调 SendMessage(官方跨会话通信工具)时,
# crew 侧把这条消息记一条日志(复用 crew-notify.js write → inbox + 镜像 feedback.jsonl)。
#
# 挂载:crew-launcher 生成的 $CREW_STATE/<name>.settings 里
#   {hooks:{PostToolUse:[{matcher:"SendMessage",hooks:[{type:"command",command:"<this>"}]}]}}
#
# 输入:hook JSON 从 stdin(claude PostToolUse 约定)。预期结构:
#   { tool_name, tool_input:{to, message}, ... }(兼容 toolName/toolInput 驼峰变体)
# 环境:CREW_SESSION(本会话名,launcher 注入)、CREW_STATE(状态目录)。
#   CREW_SENDMSG_TOOL 覆盖期望的工具名(默认 SendMessage,官方改名时的逃生阀)。
#
# 铁律:**恒退 0**,全程容错。hook 失败绝不阻塞会话(缺字段/坏 JSON/无 node 都静默退 0)。
#
# 实现说明:message 可能含换行/空格/引号/NUL 等任意字符,不经 shell 变量中转——
# 由 node 解析 stdin 后 spawn crew-notify.js 时用 argv 直接传(argv 不受 shell 分词影响)。

{
  self="${CREW_SESSION:-}"
  [ -z "$self" ] && exit 0
  command -v node >/dev/null 2>&1 || exit 0

  hook_json=$(cat 2>/dev/null)
  [ -n "$hook_json" ] || exit 0

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CN="$SCRIPT_DIR/crew-notify.js"
  [ -f "$CN" ] || exit 0

  # node 解析 tool_name / to / message(容错多种字段命名),命中目标工具且 to/message
  # 齐备 → 直接 spawnSync crew-notify.js(argv 传参,不经 shell,message 任意字符安全)。
  # tool_name 二次校验:非目标工具静默退 0。全程 try/catch,任何异常都退 0 不阻塞。
  printf '%s' "$hook_json" | \
    CREW_SEND_SELF="$self" CREW_NOTIFY="$CN" \
    CREW_SENDMSG_TOOL="${CREW_SENDMSG_TOOL:-SendMessage}" node -e '
      let s = "";
      process.stdin.on("data", (d) => (s += d)).on("end", () => {
        try {
          let j;
          try { j = JSON.parse(s); } catch (e) { process.exit(0); }
          const tn = j.tool_name || j.toolName || "";
          const ti = j.tool_input || j.toolInput || {};
          const to = ti.to || "";
          const msg = ti.message || "";
          const want = process.env.CREW_SENDMSG_TOOL || "SendMessage";
          if (tn && tn !== want) process.exit(0);   // 误匹配到别的工具 → 不记
          if (!to || !msg) process.exit(0);          // 缺 to/message → 不记
          const cp = require("child_process");
          cp.spawnSync(process.execPath, [
            process.env.CREW_NOTIFY, "write",
            "--to", String(to),
            "--from", process.env.CREW_SEND_SELF,   // 无冒号 → session:self
            "--note", String(msg),
          ], { stdio: "ignore" });
        } catch (e) { /* 恒不抛 */ }
        process.exit(0);
      });
    ' 2>/dev/null || true
} 2>/dev/null

exit 0
