#!/usr/bin/env bash
# crew-stop-hook.sh — Claude Code Stop hook · v3.1 升级 2(2026-09-03)
#
# 用途:main agent 每 turn 结束时,crew 侧自动 crew send 触发者一条 turn-done 回执,
# 让父会话机制层收得到"我干完了",取代 prompt 层"完事汇报 X"约定。
#
# 挂载:crew-launcher 生成的 $CREW_STATE/<name>.settings 里
#   {hooks:{Stop:[{matcher:"*",hooks:[{type:"command",command:"<this>"}]}]}}
#
# 输入(stdin JSON,官方 schema · 见 plugin-dev/hook-development/SKILL.md):
#   { session_id, transcript_path, cwd, permission_mode, hook_event_name:"Stop", reason }
# 环境:CREW_SESSION(本会话名,launcher 注入)、CREW_STATE(状态目录)
#
# 核心逻辑:
#   1) 反查 triggerFrom:$CREW_STATE/inbox/<self>/consumed/*.json 最近一条的 from.name
#      · 若为 kind=session 且非 self → triggerFrom = 会话名
#      · 否则(空 inbox / from 是 erp / 是自己)→ triggerFrom=null 静默不发
#   2) 幂等去重:$CREW_STATE/<self>.turn-<session_id>.done 存在 → 跳过
#   3) 抠 transcript_path 最后一条 assistant text · 截 512B → transcript_snippet
#   4) 调 crew-notify.js write --channel crew-auto-done --kind turn-done
#   5) 写 marker(24h 后 crew-heartbeat 清扫)
#
# 铁律:**恒退 0**,全程容错(缺字段/坏 JSON/无 node/crew-notify 缺失 都静默退 0)。
#       Stop hook exit 2 = block Claude 继续,我们绝不用。

{
  self="${CREW_SESSION:-}"
  [ -z "$self" ] && exit 0
  command -v node >/dev/null 2>&1 || exit 0

  hook_json=$(cat 2>/dev/null)
  [ -n "$hook_json" ] || exit 0

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CN="$SCRIPT_DIR/crew-notify.js"
  [ -f "$CN" ] || exit 0

  CS="${CREW_STATE:-/tmp/claude-crew}"

  # node 里做全部脏活:JSON 解析 + inbox 反查 + transcript 抠取 + marker + spawn crew-notify
  # 参数经 env/stdin,不经 shell 分词,message 任意字符安全
  printf '%s' "$hook_json" | \
    CREW_SEND_SELF="$self" CREW_NOTIFY="$CN" CREW_STATE_DIR="$CS" \
    node -e '
      const fs = require("fs");
      const path = require("path");
      const cp = require("child_process");

      let s = "";
      process.stdin.on("data", (d) => (s += d)).on("end", () => {
        try {
          let j;
          try { j = JSON.parse(s); } catch (e) { process.exit(0); }
          const self = process.env.CREW_SEND_SELF;
          const CS = process.env.CREW_STATE_DIR;
          const CN = process.env.CREW_NOTIFY;
          const sid = j.session_id || "";
          const tp = j.transcript_path || "";
          const reason = j.reason || "";
          const cwd = j.cwd || "";
          if (!self) process.exit(0);

          // (1) 幂等 marker:$CREW_STATE/<self>.turn-<sid>.done 存在 → 跳过
          const marker = path.join(CS, self + ".turn-" + sid + ".done");
          try { if (sid && fs.existsSync(marker)) process.exit(0); } catch (_) {}

          // (2) triggerFrom 反查:inbox/consumed 下最近一条 .json 的 from
          //     (最新消费的信封 = 最可能是本 turn 触发者)
          let triggerFrom = null;
          try {
            const consumed = path.join(CS, "inbox", self, "consumed");
            const entries = fs.readdirSync(consumed)
              .filter((f) => f.endsWith(".json"))
              .sort()
              .reverse();  // 最新在前(文件名 pad4-ts,字典序=时序)
            for (const f of entries) {
              try {
                const env = JSON.parse(fs.readFileSync(path.join(consumed, f), "utf8"));
                const from = env && env.from;
                // 只认 session kind,非 self,非空 id
                if (from && from.kind === "session" && from.id && from.id !== self) {
                  triggerFrom = from.id;
                  break;
                }
              } catch (_) { /* 坏 JSON 跳过 */ }
            }
          } catch (_) { /* inbox 不存在等 */ }

          if (!triggerFrom) process.exit(0);  // 无触发者 = 用户手敲 or 全 erp,静默

          // (3) 抠 transcript 最后一条 assistant text · 512B 上限
          let snippet = "";
          try {
            if (tp && fs.existsSync(tp)) {
              // transcript 是 jsonl,倒序遍历找最后 assistant.content[0].text 或 text 字段
              const raw = fs.readFileSync(tp, "utf8");
              const lines = raw.split(/\n/).filter(Boolean);
              for (let i = lines.length - 1; i >= 0; i--) {
                try {
                  const r = JSON.parse(lines[i]);
                  const isAssistant = r && (r.type === "assistant" || (r.message && r.message.role === "assistant"));
                  if (!isAssistant) continue;
                  const msg = r.message || r;
                  const content = msg.content;
                  let text = "";
                  if (typeof content === "string") text = content;
                  else if (Array.isArray(content)) {
                    for (const c of content) {
                      if (c && c.type === "text" && typeof c.text === "string") { text = c.text; break; }
                    }
                  }
                  if (text) { snippet = text; break; }
                } catch (_) { /* 坏行跳过 */ }
              }
              if (snippet.length > 512) snippet = snippet.slice(0, 512) + "…";
            }
          } catch (_) { /* transcript 读失败不阻塞 */ }

          // (4) 组装 note(人类可读 + 结构化都在 note 里 · 单一权威副本原则,避免 envelope 层分裂字段)
          //     turn-done note 首行"[auto-done] "触发面板徽章展示,body 是 JSON structured payload
          const payload = {
            kind: "turn-done",
            self,
            session_id: sid,
            cwd,
            reason,
            transcript_snippet: snippet,
            ts: new Date().toISOString(),
          };
          const note = "[auto-done] " + self + " turn 完成 · reason=" + (reason || "n/a")
                     + (snippet ? "\n" + snippet : "")
                     + "\n<!-- payload:" + JSON.stringify(payload) + " -->";

          // (5) 调 crew-notify.js write · argv 传参 message 任意字符安全
          try {
            cp.spawnSync(process.execPath, [
              CN, "write",
              "--to", triggerFrom,
              "--from", "session:" + self,
              "--note", note,
              "--channel", "crew-auto-done",
              "--kind", "turn-done",
            ], { stdio: "ignore", timeout: 5000 });
          } catch (_) { /* 恒不抛 */ }

          // (6) 写 marker 幂等
          try {
            fs.mkdirSync(CS, { recursive: true });
            fs.writeFileSync(marker, new Date().toISOString() + "\n");
          } catch (_) {}
        } catch (e) { /* 顶层兜底 · 恒不抛 */ }
        process.exit(0);
      });
    ' 2>/dev/null || true
} 2>/dev/null

exit 0
