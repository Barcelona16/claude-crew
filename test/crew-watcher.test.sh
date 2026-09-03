#!/usr/bin/env bash
# crew-watcher.test.sh — crew-watcher 告警 1 (Stale Inbox) 单元测试
# 覆盖:
#   ① scanStalePending 找 stale pending 信封
#   ② alertStale 首次告警 + 状态锁定(去重)
#   ③ 单条独立告警 vs 多条汇总(同一发送者)
#   ④ 自告警短路(CREW_SESSION_NAME==sender 时转发用户)
#   ⑤ CREW_WATCHER_ALERT_STALE=0 全关
#   ⑥ baseline 命令 —— 首次静默历史积压
#   ⑦ 阈值 CREW_WATCHER_STALE_MIN 生效
#   ⑧ 7 天清理 alerted 记录(NaN 时间戳不再误伤)

set -uo pipefail

# 2026-09-03 v8:清 CREW_SESSION 避免继承污染 cmd_inbox 身份校验(测试跑本身不代表任何会话)
unset CREW_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
WATCHER="$SCRIPT_DIR/../bin/crew-watcher.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

T="$(mktemp -d /tmp/crew-watcher.XXX)"
trap 'rm -rf "$T"' EXIT
export CREW_STATE="$T/state"
mkdir -p "$CREW_STATE/inbox" "$CREW_STATE/heartbeat"
# 2026-09-02 修 · 防测试污染生产咚咚:sendAlert 走 DRY 模式,只 log 不真发
export CREW_WATCHER_DRY_ALERT=1
export CREW_WATCHER_ALERT_LOG="$T/alerts.log"

# fake tmux(watcher 走 crew notify → 需要 fake 免 spawn 真 tmux)
FAKE_BIN="$T/fb"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tmux" <<'X'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  list-sessions) [ -n "${FAKE_TMUX_SESSIONS:-}" ] && printf '%s\n' "$FAKE_TMUX_SESSIONS" | tr ',' '\n' || echo ""; exit 0 ;;
  capture-pane) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
X
chmod +x "$FAKE_BIN/tmux"
export PATH="$FAKE_BIN:$PATH"
# 2026-09-03 v8:让 fake tmux 返测试用的全部 target 会话名(watcher stale 过滤 killed 会话
# 需要 target 出现在 tmux list-sessions,否则视为已 kill 跳过告警,测试全挂)
export FAKE_TMUX_SESSIONS="bob,alice,carol,dave,eric,charles,dan,eve,gina,hilda,ivy,jasmin"

# 造一个 15 分钟前的 stale 信封(from=alice 发给 bob)
OLD_TS=$(date -u -d "-15 minutes" '+%Y-%m-%dT%H:%M:%S.000Z')
mkdir -p "$CREW_STATE/inbox/bob"
cat > "$CREW_STATE/inbox/bob/0001-old.json" <<EOF
{ "id": "env-A-15min", "ts": "$OLD_TS",
  "from": { "kind": "session", "id": "alice" },
  "note": "hey bob please read",
  "delivery": { "state": "pending", "wokeAt": null, "consumedAt": null } }
EOF

# --- Case 1: scanStalePending 找 stale 信封 ---
echo "--- Case 1: scanStalePending ---"
out=$(node -e "console.log(JSON.stringify(require('$WATCHER').scanStalePending(10)))")
echo "$out" | grep -q "env-A-15min" && _ok "找到 stale 信封 env-A-15min" || _ng "未找到: $out"

# --- Case 2: alertStale 首次告警 + 状态锁定 ---
echo "--- Case 2: 首次告警 → alice inbox 收到 ---"
node "$WATCHER" sweep >/dev/null 2>&1
# 断言 alice 收到告警信封
found=$(ls "$CREW_STATE/inbox/alice"/*.json 2>/dev/null | wc -l)
[ "$found" -ge 1 ] && _ok "alice 收到告警信封($found 条)" || _ng "alice 无告警"
# 断言 watcher-state 里锁了 env-A-15min
grep -q "env-A-15min" "$CREW_STATE/watcher-state.json" && _ok "watcher-state 锁定告警 id" || _ng "state 未锁"

# 再跑一轮:应该 skipped(去重)
echo "--- Case 2b: 二次跑 → 去重 skipped ---"
r=$(node "$WATCHER" sweep 2>&1)
echo "$r" | grep -q '"staleFired": 0' && _ok "二次 sweep fired=0(去重)" || _ng "二次 fired 不对: $r"

# --- Case 3: 多条汇总(同发送者)---
echo "--- Case 3: 同发送者 3 条 → 1 条汇总 ---"
# 造 3 条 alice → bob/carol/dave,间隔 12/13/14 分钟前
for who in carol dave eric; do
  mkdir -p "$CREW_STATE/inbox/$who"
  cat > "$CREW_STATE/inbox/$who/0001.json" <<EOF
{ "id": "grp-alice-to-$who", "ts": "$OLD_TS",
  "from": { "kind": "session", "id": "alice" },
  "note": "group test", "delivery": { "state": "pending", "wokeAt": null, "consumedAt": null } }
EOF
done
before_alice=$(ls "$CREW_STATE/inbox/alice"/*.json 2>/dev/null | wc -l)
node "$WATCHER" sweep >/dev/null 2>&1
after_alice=$(ls "$CREW_STATE/inbox/alice"/*.json 2>/dev/null | wc -l)
diff=$((after_alice - before_alice))
[ "$diff" = "1" ] && _ok "3 条 stale 合并为 1 条汇总告警(alice +1)" || _ng "汇总失败:alice +$diff"
# 汇总内容含"3 条"和"最老"
latest=$(ls -t "$CREW_STATE/inbox/alice"/*.json 2>/dev/null | head -1)
grep -q "3 条消息 stale" "$latest" && _ok "汇总 note 含"3 条消息 stale"" || _ng "汇总内容不对"

# --- Case 4: 自告警短路 ---
echo "--- Case 4: CREW_SESSION_NAME==sender 时不给自己 notify ---"
# 造 1 条 fred 发给 gina 的 stale,CREW_SESSION_NAME=fred 时 sweep → fred 不该收到自己的告警
mkdir -p "$CREW_STATE/inbox/gina"
cat > "$CREW_STATE/inbox/gina/0001.json" <<EOF
{ "id": "self-fred-to-gina", "ts": "$OLD_TS",
  "from": { "kind": "session", "id": "fred" },
  "note": "self-alert test", "delivery": { "state": "pending", "wokeAt": null, "consumedAt": null } }
EOF
# 清 fred inbox 确保干净
rm -rf "$CREW_STATE/inbox/fred"
CREW_SESSION_NAME=fred node "$WATCHER" sweep >/dev/null 2>&1
# 断言 fred 没收到自己的告警(短路生效);走的是 erp 分支(send.js 在测试环境不真发)
fred_msgs=$(ls "$CREW_STATE/inbox/fred"/*.json 2>/dev/null | wc -l)
[ "$fred_msgs" = "0" ] && _ok "fred 没收到自己的告警(短路生效)" || _ng "fred 收到 $fred_msgs 条,短路无效"

# --- Case 5: 全关开关 ---
echo "--- Case 5: CREW_WATCHER_ALERT_STALE=0 全关 ---"
# 造条新 stale 但 watcher 关着
mkdir -p "$CREW_STATE/inbox/hilda"
cat > "$CREW_STATE/inbox/hilda/0001.json" <<EOF
{ "id": "closed-flag-test", "ts": "$OLD_TS",
  "from": { "kind": "session", "id": "alice" },
  "note": "should-skip", "delivery": { "state": "pending", "wokeAt": null, "consumedAt": null } }
EOF
r=$(CREW_WATCHER_ALERT_STALE=0 node "$WATCHER" sweep 2>&1)
echo "$r" | grep -q '"staleFired": 0' && _ok "开关关时不告警" || _ng "关不生效: $r"
# watcher-state 里也不该多这条 id
grep -q "closed-flag-test" "$CREW_STATE/watcher-state.json" && _ng "关时不该写 state" || _ok "关时 state 无污染"

# --- Case 6: baseline 命令 ---
echo "--- Case 6: baseline 静默历史积压 ---"
rm -f "$CREW_STATE/watcher-state.json"
# 恢复 sweeper 状态(前 case 已把 hilda/gina/carol/dave/eric 全 alerted)
# baseline 应把当前全部 stale 一次性锁 → 再 sweep 应 fired=0
r=$(node "$WATCHER" baseline 2>&1)
echo "$r" | grep -q '"baselined"' && _ok "baseline 命令输出 baselined 数" || _ng "baseline 输出异常: $r"
r=$(node "$WATCHER" sweep 2>&1)
echo "$r" | grep -q '"staleFired": 0' && _ok "baseline 后 sweep fired=0(静默历史)" || _ng "baseline 无效: $r"

# --- Case 7: 阈值 CREW_WATCHER_STALE_MIN ---
echo "--- Case 7: 阈值 20 分钟 → 15 分钟的信封应不告警 ---"
rm -f "$CREW_STATE/watcher-state.json"
# 造条新 15 分钟前的
mkdir -p "$CREW_STATE/inbox/ivy"
cat > "$CREW_STATE/inbox/ivy/0001.json" <<EOF
{ "id": "under-threshold", "ts": "$OLD_TS",
  "from": { "kind": "session", "id": "alice" },
  "note": "still fresh", "delivery": { "state": "pending", "wokeAt": null, "consumedAt": null } }
EOF
r=$(CREW_WATCHER_STALE_MIN=20 node "$WATCHER" sweep 2>&1)
# ivy 15 分钟未到 20 分钟阈值 → 不告警;但历史 bob/carol/...(15分钟)也都<20,同样不告警
echo "$r" | grep -q '"staleFired": 0' && _ok "阈值 20min 时 15min stale 不告警" || _ng "阈值不生效: $r"

# --- Case 8: 7 天清理 alerted 不误伤 ISO ts ---
echo "--- Case 8: 7 天清理 alerted 保留有效 ISO ts ---"
# 造条 alerted 记录用真 ISO,sweep 后应仍在
now_iso=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
cat > "$CREW_STATE/watcher-state.json" <<EOF
{"alerted":{"still-valid-id":"$now_iso","malformed-baseline:xxx":"baseline:2020-01-01"}}
EOF
node "$WATCHER" sweep >/dev/null 2>&1
grep -q "still-valid-id" "$CREW_STATE/watcher-state.json" && _ok "有效 ISO ts 保留" || _ng "有效 ts 被误清"
# 坏 ts 的应被清
grep -q "malformed-baseline:xxx" "$CREW_STATE/watcher-state.json" && _ng "坏 ts 未清理" || _ok "坏 ts 已清"

# --- Case 9: watcher 扫 delivered 状态(2026-09-02 修:crew send 默认 wake 后 state 一秒 pending→delivered,不扫 delivered 就永远告警不到"送到没读") ---
echo "--- Case 9: watcher 扫 delivered 状态 ---"
rm -f "$CREW_STATE/watcher-state.json"
DELIV_TS=$(date -u -d "-15 minutes" '+%Y-%m-%dT%H:%M:%S.000Z')
mkdir -p "$CREW_STATE/inbox/jasmin"
cat > "$CREW_STATE/inbox/jasmin/0001.json" <<EOF
{ "id": "delivered-15min", "ts": "$DELIV_TS",
  "from": { "kind": "session", "id": "alice" },
  "note": "hey jasmin task X please read",
  "delivery": { "state": "delivered", "wokeAt": "$DELIV_TS", "consumedAt": null } }
EOF
items=$(node -e "console.log(JSON.stringify(require('$WATCHER').scanStalePending(10)))")
echo "$items" | grep -q "delivered-15min" && _ok "scanStalePending 现在扫 delivered 状态(不再漏)" || _ng "delivered 仍被漏: $items"
echo "$items" | grep -q "\"state\":\"delivered\"" && _ok "结果带 state 字段(便于告警文案区分)" || _ng "state 字段缺"

# --- Case 10: 告警文案区分 pending vs delivered ---
echo "--- Case 10: 告警文案区分 pending vs delivered ---"
r=$(node "$WATCHER" sweep 2>&1)
# alice 应收到告警(jasmin 的信封 from=alice)
latest=$(ls -t "$CREW_STATE/inbox/alice"/*.json 2>/dev/null | head -1)
if [ -n "$latest" ]; then
  grep -q "已送到但对方没消费\|REPL 没跑 crew inbox" "$latest" \
    && _ok "delivered 告警文案说'已送到但对方没消费'" \
    || _ng "告警文案未区分 delivered 语义: $(cat $latest)"
else
  _ng "alice 未收到 delivered 告警"
fi

# --- Case 11: autoheal dead-repl(方案 C · 2026-09-02 用户拍板)---
echo "--- Case 11: autoheal dead-repl ---"
# 造心跳文件模拟 dead-repl
cat > "$CREW_STATE/heartbeat/heal-target.json" <<EOF
{"name":"heal-target","ts":"$(date -Iseconds)","tmux":"crew-heal-target","tmuxStatus":"dead-repl","paneIdle":null,"ctxPct":null,"claudePid":null}
EOF
# 造黑名单目标(不该被 heal)
cat > "$CREW_STATE/heartbeat/crew-dev.json" <<EOF
{"name":"crew-dev","ts":"$(date -Iseconds)","tmux":"crew-crew-dev","tmuxStatus":"dead-repl","paneIdle":null,"ctxPct":null,"claudePid":null}
EOF
# fake crew 命令(简单 exit 0,记录被调)
cat > "$FAKE_BIN/crew" <<'X'
#!/usr/bin/env bash
echo "[fake crew] called with: $*" >> "$FAKE_CREW_CALLS"
exit 0
X
chmod +x "$FAKE_BIN/crew"
FAKE_CALLS="$T/crew-calls.log"; : > "$FAKE_CALLS"
CREW_WATCHER_ALERT_STALE=0 CREW_WATCHER_AUTOHEAL=1 FAKE_CREW_CALLS="$FAKE_CALLS" \
  CREW_WATCHER_AUTOHEAL_BLACKLIST=crew-dev,work \
  CREW_BIN="$FAKE_BIN/crew" \
  node "$WATCHER" sweep >/dev/null 2>&1
grep -q "heal-target" "$FAKE_CALLS" && _ok "heal-target 被自动重建(crew heal-target 已调)" || _ng "autoheal 未触发:$(cat $FAKE_CALLS)"
grep -q "crew-dev" "$FAKE_CALLS" && _ng "crew-dev 不该被 heal(黑名单)" || _ok "crew-dev 黑名单生效不 heal"

# --- Case 12: autoheal 冷却期 ---
echo "--- Case 12: autoheal 冷却期 ---"
: > "$FAKE_CALLS"
# 再跑一次,应该在冷却期内跳过
CREW_WATCHER_ALERT_STALE=0 CREW_WATCHER_AUTOHEAL=1 FAKE_CREW_CALLS="$FAKE_CALLS" \
  CREW_WATCHER_AUTOHEAL_BLACKLIST=crew-dev,work \
  CREW_BIN="$FAKE_BIN/crew" \
  node "$WATCHER" sweep >/dev/null 2>&1
[ ! -s "$FAKE_CALLS" ] && _ok "冷却期内不重复 heal(空调用)" || _ng "冷却未生效:$(cat $FAKE_CALLS)"

# --- Case 13: autoheal 全关 ---
echo "--- Case 13: autoheal 全关 ---"
: > "$FAKE_CALLS"
rm -f "$CREW_STATE/watcher-state.json"  # 清冷却状态
CREW_WATCHER_ALERT_STALE=0 CREW_WATCHER_AUTOHEAL=0 FAKE_CREW_CALLS="$FAKE_CALLS" \
  CREW_BIN="$FAKE_BIN/crew" \
  node "$WATCHER" sweep >/dev/null 2>&1
[ ! -s "$FAKE_CALLS" ] && _ok "AUTOHEAL=0 时不重建" || _ng "开关关不生效"

# --- Case 14: v8 P2-3 · sweepStaleMarkers 清 dedup + turn marker age>7d ---
# Agent-C 复审补测试 · 造陈旧(8d)+ 新(1h)混合 · sweep 后前者删后者留
echo "--- Case 14: sweepStaleMarkers 清 dedup + turn marker age>7d ---"
mkdir -p "$CREW_STATE/.dedup"
touch -d "8 days ago" "$CREW_STATE/.dedup/old-a.stamp"
touch -d "1 hour ago" "$CREW_STATE/.dedup/new-a.stamp"
touch -d "8 days ago" "$CREW_STATE/alice.turn-old.done"
touch -d "1 hour ago" "$CREW_STATE/alice.turn-new.done"
touch "$CREW_STATE/unrelated.file"
# sweep
CREW_WATCHER_ALERT_STALE=0 CREW_WATCHER_AUTOHEAL=0 node "$WATCHER" sweep >/dev/null 2>&1
# 断言:陈旧 marker 已清 · 新 marker 保留 · 无关文件不动
[ ! -f "$CREW_STATE/.dedup/old-a.stamp" ] && [ -f "$CREW_STATE/.dedup/new-a.stamp" ] \
  && _ok "陈旧 dedup stamp 清 · 新 dedup stamp 留" || _ng "dedup sweep 不对"
[ ! -f "$CREW_STATE/alice.turn-old.done" ] && [ -f "$CREW_STATE/alice.turn-new.done" ] \
  && _ok "陈旧 turn marker 清 · 新 turn marker 留" || _ng "turn sweep 不对"
[ -f "$CREW_STATE/unrelated.file" ] && _ok "无关文件 unrelated.file 不动" || _ng "误清无关文件"

echo
echo "=== crew-watcher.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
