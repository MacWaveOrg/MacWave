#!/bin/bash

# multi_uninstall_test.sh
# `wave uninstall` 的三种位置参数写法与 `-a`：
#
#   1. 逗号分隔多包（带不带空格都行）；
#   2. 同一个包用 `@` 连写多个版本，或 `@all` / `@*` 表示全部版本；
#   3. `wave uninstall <包> -a` 卸全部版本；不带版本又不带 `-a` 且装了多个版本时询问；
#   4. 全角逗号（，、）必须被明确拒绝，并把半角写法直接给出来。
#
# 全程离线：假索引与假产物起在 127.0.0.1，安装目录是 MACWAVE_TEST 临时根。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

# shellcheck source=./components.sh
source "$SCRIPT_DIR/components.sh"

WORK=$(mktemp -d)
PORT=$((19000 + RANDOM % 1000))
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

MIRROR="$WORK/mirror"
ROOT="$WORK/root"
BASE="$ROOT/opt/macwave"

echo "========== 0. 本地镜像：三个包，其中 one 有两个版本 =========="
mkdir -p "$MIRROR/infosource" "$MIRROR/bottle" "$BASE" "$ROOT/opt/macwave_config"
copy_components "$BASE/" >/dev/null
printf '{"version": "4.5.0"}\n' > "$ROOT/opt/macwave_config/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$ROOT/opt/macwave_config/config.json"

make_pkg() {
    local name="$1" version="$2" dir
    dir="$WORK/src-$name-$version"
    mkdir -p "$dir" "$MIRROR/bottle/$name" "$MIRROR/infosource/pkg/pkginfo_arm64/$name"
    printf '#!/bin/sh\necho %s %s\n' "$name" "$version" > "$dir/$name"
    chmod 755 "$dir/$name"
    tar czf "$MIRROR/bottle/$name/$name@$version.arm64.tar.gz" -C "$dir" "$name"

    local sha
    sha=$(shasum -a 256 "$MIRROR/bottle/$name/$name@$version.arm64.tar.gz" | cut -d' ' -f1)
    [ -f "$MIRROR/infosource/pkg/pkginfo_arm64/$name/_$name@common" ] || cat > "$MIRROR/infosource/pkg/pkginfo_arm64/$name/_$name@common" <<EOF
bin_name: "$name"
des: "multi-uninstall probe"
hom: "https://example.invalid/"
lic: "MIT"
aut: "probe"
EOF
    cat > "$MIRROR/infosource/pkg/pkginfo_arm64/$name/_$name@$version" <<EOF
sha256: "$sha"
file: "${name}_arm64.tar.gz"
url: "http://127.0.0.1:$PORT/bottle/$name/$name%40$version.arm64.tar.gz"
min_os: "12.0"
EOF
}

make_pkg one 1.0
make_pkg one 2.0
make_pkg two 1.0
make_pkg three 1.0

"$PYTHON" "$REPO_DIR/scripts/build_versions_index.py" \
    --infosource "$MIRROR/infosource" --mirror "$MIRROR" >/dev/null 2>&1

(cd "$MIRROR" && exec "$PYTHON" -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1
if curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$PORT/infosource/pkg/pkginfo_arm64/versions" | grep -q 200; then
    pass "本地镜像起来了（${PORT}）"
else
    fail "本地镜像没起来"
    exit 1
fi

export MACWAVE_TEST="$ROOT"
export MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT/infosource"
export MACWAVE_BOTTLE_DOMAIN="http://127.0.0.1:$PORT/bottle"

run_wave() { "$PYTHON" "$REPO_DIR/lib/wave.py" "$@" </dev/null; }

# 一次装齐：one 的两个版本 + two + three
run_wave install "one@1.0, one@2.0, two, three" >/dev/null 2>&1
installed() { run_wave list 2>/dev/null; }

echo
echo "========== 1. 全角逗号：拒绝并给出半角写法 =========="
OUT=$(run_wave uninstall "one@1.0，two" 2>&1); RC=$?
case "$OUT" in
    *"full-width comma"*) pass "全角逗号被明确指出" ;;
    *) fail "全角逗号没被识别（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)" ;;
esac
case "$OUT" in
    *"Try: wave uninstall one@1.0,two"*) pass "错误里直接给出半角写法" ;;
    *) fail "没有给出可直接照抄的半角写法" ;;
esac
if [ "$RC" -ne 0 ]; then
    pass "全角逗号时退出码非 0"
else
    fail "全角逗号却返回 0"
fi
case "$(installed)" in
    *one@1.0*) pass "被拒绝时什么都没删" ;;
    *) fail "被拒绝却删掉了东西" ;;
esac

echo
echo "========== 2. 一个包连写多个版本 + 另一个包（@all） =========="
OUT=$(run_wave uninstall "one@1.0@2.0, two" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
    pass "one@1.0@2.0, two 一次卸完"
else
    fail "连写多版本失败（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)"
fi
LIST=$(installed)
case "$LIST" in
    *one@*) fail "one 还有版本没卸掉：$LIST" ;;
    *) pass "one 的两个版本都没了" ;;
esac
case "$LIST" in
    *two@*) fail "two 没卸掉：$LIST" ;;
    *) pass "two 也没了" ;;
esac
case "$LIST" in
    *three@*) pass "没点名的 three 没被碰" ;;
    *) fail "three 被误删" ;;
esac

echo
echo "========== 2.5 @all 与旧的 @* 都表示全部版本 =========="
run_wave install "one@1.0, one@2.0" >/dev/null 2>&1
OUT=$(run_wave uninstall one@all 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
    pass "wave uninstall one@all 成功"
else
    fail "one@all 失败（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)"
fi
case "$(installed)" in
    *one@*) fail "@all 之后 one 还有残留" ;;
    *) pass "@all 把 one 的全部版本都卸了" ;;
esac

run_wave install "one@1.0, one@2.0" >/dev/null 2>&1
OUT=$(run_wave uninstall one@\* 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
    pass "旧的 one@* 仍然可用"
else
    fail "one@* 坏了（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)"
fi
case "$(installed)" in
    *one@*) fail "@* 之后 one 还有残留" ;;
    *) pass "@* 也卸干净了" ;;
esac

echo
echo "========== 3. -a 卸全部版本 =========="
run_wave install "one@1.0, one@2.0" >/dev/null 2>&1
OUT=$(run_wave uninstall one -a 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
    pass "wave uninstall one -a 成功"
else
    fail "uninstall -a 失败（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)"
fi
case "$(installed)" in
    *one@*) fail "-a 之后 one 还有残留" ;;
    *) pass "-a 把 one 的全部版本都卸了" ;;
esac

echo
echo "========== 4. -a 与显式版本互斥 =========="
OUT=$(run_wave uninstall "one@1.0" -a 2>&1); RC=$?
case "$OUT" in
    *"cannot be combined with a version"*) pass "-a 与 @版本 明确拒绝" ;;
    *) fail "-a 与 @版本 没被拒绝（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)" ;;
esac
if [ "$RC" -ne 0 ]; then
    pass "混用时退出码非 0"
else
    fail "混用却返回 0"
fi

echo
echo "========== 5. 不带版本、多个版本：询问（stdio 不是终端时拒绝） =========="
run_wave install "one@1.0, one@2.0" >/dev/null 2>&1
OUT=$(run_wave uninstall one 2>&1); RC=$?
case "$OUT" in
    *"Multiple versions found"*|*"has 2 installed versions"*)
        pass "多版本且没写 -a 时进入询问/拒绝分支" ;;
    *) fail "多版本没走询问分支（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)" ;;
esac
case "$(installed)" in
    *one@1.0*) pass "询问未答时一个都没删" ;;
    *) fail "询问未答却删掉了版本" ;;
esac

echo
echo "========== 6. 询问分支确实能选：回数字、回空、回越界 =========="
answer() { printf '%s\n' "$1" | "$PYTHON" "$REPO_DIR/lib/wave.py" uninstall one 2>&1; }

# 列表是降序（最新在前），所以编号 1 = 最新版本 —— 这一条就是钉住这个顺序。
run_wave install "one@1.0, one@2.0" >/dev/null 2>&1
OUT=$(answer 1)
case "$OUT" in
    *"1. 2.0"*) pass "编号 1 是最新版本 2.0" ;;
    *) fail "版本列表不是降序：$(printf '%s' "$OUT" | head -3)" ;;
esac
case "$OUT" in
    *"Successfully uninstalled one@2.0"*) pass "回 1 卸掉的是 2.0" ;;
    *) fail "回 1 没卸掉 2.0：$(printf '%s' "$OUT" | tail -3)" ;;
esac
case "$(installed)" in
    *one@1.0*) pass "回 1 之后 1.0 还在" ;;
    *) fail "回 1 时 1.0 也丢了" ;;
esac
case "$(installed)" in
    *one@2.0*) fail "回 1 之后 2.0 没删掉" ;;
    *) pass "回 1 之后 2.0 没了" ;;
esac

run_wave install "one@1.0, one@2.0" >/dev/null 2>&1
OUT=$(answer "")
case "$OUT" in
    *"Nothing selected"*) pass "回空行明确说「什么都没选」" ;;
    *) fail "回空行没有明确提示：$(printf '%s' "$OUT" | tail -3)" ;;
esac
case "$(installed)" in
    *one@1.0*one@2.0*|*one@2.0*one@1.0*) pass "回空行一个都没删" ;;
    *) fail "回空行却删了版本" ;;
esac

OUT=$(answer 9); RC=$?
case "$OUT" in
    *"Invalid selection"*) pass "越界数字被拒绝" ;;
    *) fail "越界数字没被拒绝：$(printf '%s' "$OUT" | tail -3)" ;;
esac
if [ "$RC" -ne 0 ]; then
    pass "越界数字退出码非 0"
else
    fail "越界数字却返回 0"
fi

echo
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [ "$FAILED" -eq 0 ]; then
    echo "🌊 All multi-uninstall checks passed"
    exit 0
else
    echo "🌊 multi-uninstall checks failed"
    exit 1
fi
