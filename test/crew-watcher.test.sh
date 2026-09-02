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

echo
echo "=== crew-watcher.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
