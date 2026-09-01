#!/usr/bin/env bash
# crew-register.test.sh — crew register 单元测试(阶段 1,crew v2)
# 覆盖:未注册 push / 已注册幂等 / project.json 缺失 exit5 / dir 非项目根 exit5 /
#      并发只写一次(rename 原子性) / 子目录归属 / remove 反向删除 / 通过 crew 命令入口

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$SCRIPT_DIR/../bin/crew"
REG="$SCRIPT_DIR/../bin/crew-register.js"

pass=0; fail=0; total=0
_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1"; }

# 每 case 独立临时 project 树,互不污染
mk_proj() {
  local root="$1" name="$2"
  mkdir -p "$root/$name/.chaos-bridge"
  cat > "$root/$name/.chaos-bridge/project.json" <<EOF
{"name":"$name","displayName":"$name","workDir":"$root/$name","main":"m","sessions":[{"name":"m","role":"main","kind":"crew","description":"main"}]}
EOF
}
sess_names() { # 打印某 project 的 sessions name 列表(逗号分隔)
  node -e "console.log(JSON.parse(require('fs').readFileSync('$1')).sessions.map(s=>s.name).join(','))"
}
sess_count() {
  node -e "console.log(JSON.parse(require('fs').readFileSync('$1')).sessions.length)"
}

T="$(mktemp -d /tmp/crew-register-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# --- Case 1: 未注册 → push ---
echo "--- Case 1: 未注册 → push ---"
mk_proj "$T" projA
cfg="$T/projA/.chaos-bridge/project.json"
node "$REG" --name w1 --dir "$T/projA" --scan-root "$T" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && _ok "push exit 0" || _ng "push exit=$rc (期望 0)"
[ "$(sess_names "$cfg")" = "m,w1" ] && _ok "sessions 追加 w1" || _ng "sessions=$(sess_names "$cfg")"
node -e "const s=JSON.parse(require('fs').readFileSync('$cfg')).sessions.find(x=>x.name==='w1'); process.exit(s&&s.kind==='crew'&&s.role==='sub'?0:1)" \
  && _ok "w1 默认 role=sub kind=crew" || _ng "w1 字段不对"

# --- Case 2: 已注册 → 幂等 no-op ---
echo "--- Case 2: 已注册 → 幂等 ---"
node "$REG" --name w1 --dir "$T/projA" --scan-root "$T" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && _ok "幂等 exit 0" || _ng "幂等 exit=$rc"
[ "$(sess_count "$cfg")" = "2" ] && _ok "重复 register 不追加(仍 2 条)" || _ng "sessions 数=$(sess_count "$cfg")(期望 2)"

# --- Case 3: project.json 缺失(dir 无归属)→ exit 5 ---
echo "--- Case 3: project.json 缺失 → exit 5 ---"
mkdir -p "$T/noproj/deep"
node "$REG" --name orphan --dir "$T/noproj/deep" --scan-root "$T" >/dev/null 2>&1
rc=$?
[ "$rc" = 5 ] && _ok "缺失归属 exit 5" || _ng "exit=$rc(期望 5)"

# --- Case 4: dir 在 scan-root 但非任何项目根下 → exit 5 ---
echo "--- Case 4: dir 非项目根 → exit 5 ---"
node "$REG" --name x --dir "$T" --scan-root "$T" >/dev/null 2>&1
rc=$?
[ "$rc" = 5 ] && _ok "dir 非项目根 exit 5" || _ng "exit=$rc(期望 5)"

# --- Case 5: 并发 register → rename 原子性,无损坏,幂等去重 ---
echo "--- Case 5: 并发只写一次 ---"
mk_proj "$T" projB
cfgB="$T/projB/.chaos-bridge/project.json"
pids=()
for i in $(seq 1 10); do
  node "$REG" --name concurrent --dir "$T/projB" --scan-root "$T" >/dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
# JSON 未损坏(可 parse)
if node -e "JSON.parse(require('fs').readFileSync('$cfgB'))" 2>/dev/null; then
  _ok "10 并发后 JSON 未损坏"
else
  _ng "并发写坏 JSON"
fi
# concurrent 出现次数 —— 允许竞态下多写(无锁),但不能损坏;记录实际次数
cnt=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$cfgB')).sessions.filter(s=>s.name==='concurrent').length)" 2>/dev/null || echo ERR)
if [ "$cnt" = "1" ]; then
  _ok "并发去重:concurrent 恰 1 条"
else
  # 无锁 read-modify-write 存在 TOCTOU 窗口,可能 >1;标记为已知(需加锁修)
  _ng "并发出现 $cnt 条 concurrent(TOCTOU 竞态,需 flock 修)"
fi

# --- Case 6: 子目录 dir → 归属最近项目根 ---
echo "--- Case 6: 子目录归属 ---"
mk_proj "$T" projC
mkdir -p "$T/projC/src/inner"
node "$REG" --name deep --dir "$T/projC/src/inner" --scan-root "$T" >/dev/null 2>&1
[ "$?" = 0 ] && node -e "process.exit(JSON.parse(require('fs').readFileSync('$T/projC/.chaos-bridge/project.json')).sessions.some(s=>s.name==='deep')?0:1)" \
  && _ok "子目录会话归属 projC" || _ng "子目录归属失败"

# --- Case 7: remove 反向删除 ---
echo "--- Case 7: remove ---"
node "$REG" --name w1 --remove --dir "$T/projA" --scan-root "$T" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && _ok "remove exit 0" || _ng "remove exit=$rc"
node -e "process.exit(JSON.parse(require('fs').readFileSync('$cfg')).sessions.some(s=>s.name==='w1')?1:0)" \
  && _ok "w1 已从 sessions 删除" || _ng "w1 未删除"

# --- Case 8: 通过 crew 命令入口(bash 封装透传 exit code) ---
echo "--- Case 8: crew register 命令入口 ---"
CREW_SCAN_ROOT="$T" "$CREW" register cliW --dir "$T/projC" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && _ok "crew register 入口 exit 0" || _ng "crew register exit=$rc"
CREW_SCAN_ROOT="$T" "$CREW" register cliX --dir "$T/noproj" >/dev/null 2>&1
rc=$?
[ "$rc" = 5 ] && _ok "crew register 无归属透传 exit 5" || _ng "crew register exit=$rc(期望 5)"

echo
echo "=== crew-register.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
