#!/usr/bin/env bash
# test/crew-session.test.sh — crew-session 单测(2026-08-30 crew L 重构 Week 1)
# 覆盖 20+ case:get/set/has/del/clean/list/fields + name/field 校验 + 特殊字段

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../bin/crew-session"
export CREW_STATE="/tmp/crew-session-test-$$"

pass=0
fail=0
total=0

_ok() { total=$((total+1)); pass=$((pass+1)); echo "  ✓ $1"; }
_ng() { total=$((total+1)); fail=$((fail+1)); echo "  ✗ $1 [$2]"; }

setup() {
  rm -rf "$CREW_STATE"
  mkdir -p "$CREW_STATE"
}
teardown() {
  rm -rf "$CREW_STATE"
}

trap teardown EXIT
setup

# --- Case 1: fields 命令列出 13 字段 ---
echo "--- Case 1: fields ---"
n=$("$BIN" fields | wc -l)
[ "$n" = "13" ] && _ok "fields 输出 13 个" || _ng "fields 应输出 13,实际 $n" ""

# --- Case 2: set + get 往返 ---
echo "--- Case 2: set/get 往返 ---"
"$BIN" set s1 sid "aaa-bbb-ccc" >/dev/null
v=$("$BIN" get s1 sid)
[ "$v" = "aaa-bbb-ccc" ] && _ok "set sid → get 相同值" || _ng "set/get 不匹配: '$v'" ""

# --- Case 3: has 存在返 0 / 不存在返 非0 ---
echo "--- Case 3: has ---"
"$BIN" has s1 sid && _ok "has 存在字段 → exit 0" || _ng "has 存在字段应 exit 0" ""
"$BIN" has s1 backend 2>/dev/null && _ng "has 不存在字段应 exit 1" "" || _ok "has 不存在字段 → exit 非0"

# --- Case 4: pintmux 特殊(值恒为 1)---
echo "--- Case 4: pintmux 值忽略,恒 '1' ---"
"$BIN" set s1 pintmux "anything" >/dev/null
v=$("$BIN" get s1 pintmux)
[ "$v" = "1" ] && _ok "pintmux 值恒 '1'" || _ng "pintmux 值应 '1',实际 '$v'" ""

# --- Case 5: del 单字段 ---
echo "--- Case 5: del ---"
"$BIN" set s1 backend "GLM-5.3" >/dev/null
"$BIN" del s1 backend >/dev/null
"$BIN" has s1 backend 2>/dev/null && _ng "del 后仍存在" "" || _ok "del backend → has 返 非0"
"$BIN" has s1 sid && _ok "del backend 不影响 sid" || _ng "del 误删 sid" ""

# --- Case 6: name 校验 ---
echo "--- Case 6: name 校验 ---"
"$BIN" set "bad.name" sid X 2>/dev/null && _ng "含 . 的 name 应拒" "" || _ok "含 . 的 name 拒"
"$BIN" set "bad/name" sid X 2>/dev/null && _ng "含 / 的 name 应拒" "" || _ok "含 / 的 name 拒"
"$BIN" set "" sid X 2>/dev/null && _ng "空 name 应拒" "" || _ok "空 name 拒"
"$BIN" set "good_name-123" sid X 2>/dev/null && _ok "字母数字_- 合法 name 通过" || _ng "字母数字_- 应通过" ""

# --- Case 7: field 校验 ---
echo "--- Case 7: field 校验 ---"
"$BIN" set s1 unknown_field X 2>/dev/null && _ng "未知 field 应拒" "" || _ok "未知 field 拒"
"$BIN" set s1 sid X 2>/dev/null && _ok "已知 field 通过" || _ng "已知 field 应通过" ""

# --- Case 8: list 输出格式 ---
echo "--- Case 8: list 输出格式 ---"
setup
"$BIN" set alpha sid "sid-A" >/dev/null
"$BIN" set alpha backend "GLM" >/dev/null
"$BIN" set beta sid "sid-B" >/dev/null
out=$("$BIN" list)
echo "$out" | grep -q "^alpha" && _ok "list 含 alpha 行" || _ng "list 缺 alpha" ""
echo "$out" | grep -q "^beta" && _ok "list 含 beta 行" || _ng "list 缺 beta" ""
echo "$out" | head -1 | grep -q "sid:sid-A" && _ok "alpha 行含 sid:sid-A" || _ng "alpha 缺 sid" ""

# --- Case 9: policy_body 大文件显示 <exists> 不 dump 全文 ---
echo "--- Case 9: policy_body 显示 <exists> ---"
"$BIN" set alpha policy_body "$(printf 'A%.0s' $(seq 1 5000))" >/dev/null
out=$("$BIN" list | grep "^alpha")
echo "$out" | grep -q "policy_body:<exists>" && _ok "policy_body 显示 <exists>" || _ng "policy_body 应显示 <exists>" "$out"

# --- Case 10: clean 删所有字段 ---
echo "--- Case 10: clean ---"
setup
"$BIN" set c1 sid X >/dev/null
"$BIN" set c1 backend Y >/dev/null
"$BIN" set c1 pintmux 1 >/dev/null
"$BIN" clean c1
n=$(ls "$CREW_STATE"/c1.* 2>/dev/null | wc -l)
[ "$n" = "0" ] && _ok "clean 后无 c1.* 文件" || _ng "clean 后仍有 c1.* $n 个" ""

# --- Case 11: clean 不影响其他 name ---
echo "--- Case 11: clean 隔离 ---"
setup
"$BIN" set alpha sid X >/dev/null
"$BIN" set beta sid Y >/dev/null
"$BIN" clean alpha
"$BIN" has beta sid && _ok "clean alpha 不影响 beta" || _ng "clean 误伤 beta" ""

# --- Case 12: clean 清 registry 行 ---
echo "--- Case 12: clean 清 registry ---"
setup
printf "/work/foo\tsess-a\n/work/bar\tsess-b\n" > "$CREW_STATE/registry"
"$BIN" clean sess-a
grep -q "^/work/foo" "$CREW_STATE/registry" && _ng "sess-a 行未清" "" || _ok "sess-a 行已从 registry 清"
grep -q "^/work/bar" "$CREW_STATE/registry" && _ok "sess-b 行保留" || _ng "sess-b 行误清" ""

# --- Case 13: get 不存在返 exit 1 ---
echo "--- Case 13: get 不存在 exit 1 ---"
setup
"$BIN" get missing sid 2>/dev/null; ec=$?
[ "$ec" = "1" ] && _ok "get 不存在 → exit 1" || _ng "get 不存在应 exit 1,实际 $ec" ""

# --- Case 14: usage 错误 exit 2 ---
echo "--- Case 14: usage 错误 exit 2 ---"
"$BIN" get 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "get 少参数 → exit 2" || _ng "get 少参数应 exit 2,实际 $ec" ""
"$BIN" 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "空命令 → exit 2" || _ng "空命令应 exit 2,实际 $ec" ""

# --- Case 15: 未知命令 exit 2 ---
echo "--- Case 15: 未知命令 ---"
"$BIN" bogus-cmd 2>/dev/null; ec=$?
[ "$ec" = "2" ] && _ok "未知命令 → exit 2" || _ng "未知命令应 exit 2,实际 $ec" ""

# --- Case 16: 13 字段全部可 set/get 往返 ---
echo "--- Case 16: 13 字段全部往返 ---"
setup
for field in sid backend key notmux fgpid tmux tmuxname policy policy_body notify settings nohup; do
  "$BIN" set full "$field" "val-$field" >/dev/null
  v=$("$BIN" get full "$field")
  [ "$v" = "val-$field" ] || { _ng "字段 $field 往返失败: '$v'" ""; continue; }
done
_ok "12 普通字段 set/get 往返 OK(pintmux 特殊已测)"

# --- Case 17: --purge-transcript 需 sid 存在才有意义 ---
echo "--- Case 17: --purge-transcript(不真删,只测参数解析)---"
setup
"$BIN" set trans1 sid "test-sid-x" >/dev/null
out=$("$BIN" clean trans1 --purge-transcript 2>&1)
echo "$out" | grep -q "purged transcript test-sid-x" && _ok "--purge-transcript 输出提示" || _ng "--purge 输出未提示" "$out"

# --- Case 18: fields 顺序稳定 ---
echo "--- Case 18: fields 顺序 ---"
first=$("$BIN" fields | head -1)
[ "$first" = "sid" ] && _ok "fields 首个 sid" || _ng "fields 首字段应 sid,实际 '$first'" ""

# --- Case 19: 空 list ---
echo "--- Case 19: 空 list ---"
setup
out=$("$BIN" list)
[ -z "$out" ] && _ok "空 CREW_STATE list 输出空" || _ng "空 CREW_STATE 应空,实际 '$out'" ""

# --- Case 20: help 输出 ---
echo "--- Case 20: help ---"
out=$("$BIN" help 2>&1)
echo "$out" | grep -q "用法:" && _ok "help 输出用法" || _ng "help 缺用法" ""

echo
echo "=== crew-session.test.sh: $pass / $total pass, $fail fail ==="
[ "$fail" -eq 0 ]
