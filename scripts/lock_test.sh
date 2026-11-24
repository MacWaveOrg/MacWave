#!/bin/bash

# lock_test.sh
# 安装树的互斥锁（lib/lock.py）：同一时刻只允许一个会改动安装树的 wave。
#
# 为什么需要它：同时跑两个 wave 会撞在 bin/<名>@<版本>/ 的 rm -rf+mv、links/、
# .depped_* 引用计数（读-改-写）与 downloads/tmp 的同名 .partial 上。症状都是
# "另一个命令装出来的东西不对"，而报错指向的却是别的地方。锁一旦退化成"永远能拿到"，
# 这条防线就没有了，而且不会有别的测试发现。
#
# 全程离线：只用到 basedir / transfer --all 这类不联网的命令。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lock_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

SANDBOX="$WORK/sandbox"
BASE="$SANDBOX/opt/macwave"
mkdir -p "$SANDBOX/opt/macwave_config" "$BASE/bin" "$BASE/deps"
printf '{"base_dir": "%s"}' "$BASE" > "$SANDBOX/opt/macwave_config/config.json"
for component in cli config lib net pkg surfboard; do
    ln -sfn "$REPO_DIR/$component" "$BASE/$component"
done

LOCK_FILE="$BASE/var/lock/wave.lock"

wave() {
    OUT=$(MACWAVE_TEST="$SANDBOX" "$PYTHON" "$REPO_DIR/lib/wave.py" "$@" < /dev/null 2>&1)
    RC=$?
}

echo "========== 1. 没有别的 wave 时照常工作，退出后不留锁 =========="

wave transfer --all
[[ "$RC" -eq 0 ]] && pass "没有竞争时命令正常完成" \
    || fail "正常路径失败（rc=${RC}）：$(printf '%.200s' "$OUT")"
[[ -f "$LOCK_FILE" ]] && pass "锁文件已创建（${LOCK_FILE}）" \
    || fail "锁文件没有创建"

# 锁文件留着没问题（下一次会覆盖内容），但**内容里的 pid 必须是"没人持锁也能看到"
# 的那种状态**；真正的判据是下一次还能拿到锁。
wave transfer --all
[[ "$RC" -eq 0 ]] && pass "上一次退出后锁已释放（可以再次获取）" \
    || fail "锁没有释放（rc=${RC}）：$(printf '%.200s' "$OUT")"

echo "========== 2. 别人持有锁时立即失败，并说明是谁 =========="

# 起一个持有者：拿到锁、写进自己的 pid 与动作、然后睡住
MACWAVE_TEST="$SANDBOX" "$PYTHON" - "$REPO_DIR" "$BASE" <<'PY' &
import os, sys, time
repo, base = sys.argv[1], sys.argv[2]
sys.path[:0] = [repo + "/lib", repo + "/config", repo + "/cli", repo + "/net",
                repo + "/pkg", repo + "/surfboard"]
from lock import tree_lock
with tree_lock("install jq"):
    print("HOLDING", flush=True)
    time.sleep(30)
PY
HOLDER=$!

# 等它真的拿到锁（最多 10 秒），否则后面的断言只是在测"没锁"
for _ in $(seq 1 100); do
    if [ -f "$LOCK_FILE" ] && grep -q "install jq" "$LOCK_FILE" 2> /dev/null; then
        break
    fi
    sleep 0.1
done
grep -q "install jq" "$LOCK_FILE" 2> /dev/null \
    && pass "持有者已拿到锁并写下自己的动作" \
    || fail "持有者没能拿到锁（$(cat "$LOCK_FILE" 2> /dev/null)）"

wave transfer --all
[[ "$RC" -ne 0 ]] && pass "竞争时命令失败" || fail "竞争时仍然成功（rc=${RC}）"
[[ "$OUT" == *"another wave is running"* ]] \
    && pass "报错说清了是「另一个 wave」" || fail "报错没有说明原因：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"install jq"* ]] \
    && pass "报错里带上了持有者正在做的事" || fail "报错没有持有者信息：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"do not delete"* ]] \
    && pass "提示不要手删锁文件" || fail "缺少「别删锁文件」的提示"

kill "$HOLDER" 2> /dev/null
wait "$HOLDER" 2> /dev/null

echo "========== 3. 持有者被 kill -9 之后锁自动释放 =========="

MACWAVE_TEST="$SANDBOX" "$PYTHON" - "$REPO_DIR" <<'PY' &
import sys, time
repo = sys.argv[1]
sys.path[:0] = [repo + "/lib", repo + "/config", repo + "/cli", repo + "/net",
                repo + "/pkg", repo + "/surfboard"]
from lock import tree_lock
with tree_lock("uninstall yq"):
    print("HOLDING", flush=True)
    time.sleep(30)
PY
HOLDER=$!
for _ in $(seq 1 100); do
    grep -q "uninstall yq" "$LOCK_FILE" 2> /dev/null && break
    sleep 0.1
done
kill -9 "$HOLDER" 2> /dev/null
wait "$HOLDER" 2> /dev/null
sleep 0.3
wave transfer --all
[[ "$RC" -eq 0 ]] && pass "持有者被 kill -9 后锁可立即重新获取（flock 由内核释放）" \
    || fail "kill -9 之后仍然拿不到锁（rc=${RC}）：$(printf '%.200s' "$OUT")"

echo "========== 4. 同一进程内可重入（不自己锁死） =========="

Out=$(MACWAVE_TEST="$SANDBOX" "$PYTHON" - "$REPO_DIR" <<'PY' 2>&1
import sys
repo = sys.argv[1]
sys.path[:0] = [repo + "/lib", repo + "/config", repo + "/cli", repo + "/net",
                repo + "/pkg", repo + "/surfboard"]
from lock import tree_lock
with tree_lock("outer"):
    with tree_lock("inner"):
        with tree_lock("inner2"):
            print("NESTED-OK")
print("RELEASED")
PY
)
RC=$?
[[ "$RC" -eq 0 && "$Out" == *"NESTED-OK"* && "$Out" == *"RELEASED"* ]] \
    && pass "嵌套获取同一把锁不会死锁" || fail "嵌套获取失败（rc=${RC}）：$(printf '%.200s' "$Out")"

echo "========== 5. 该上锁的命令都上了 =========="

for spec in "pkg/pkginstaller.py:install" "pkg/uninstaller.py:uninstall" \
            "pkg/upgrader.py:upgrade" "pkg/transferrer.py:transfer" \
            "lib/basedir.py:basedir" "lib/selfupdate.py:selfupdate"; do
    file="${spec%%:*}"
    label="${spec##*:}"
    if grep -q "tree_lock" "$REPO_DIR/$file"; then
        pass "$label 会获取安装锁"
    else
        fail "$file 没有获取安装锁（改树的命令必须互斥）"
    fi
done

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All lock tests passed${RESET}"
