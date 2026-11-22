#!/bin/bash

# multi_install_test.sh
# `wave install a, b, c@ver` —— 逗号分隔的多包安装。
#
# 为什么要单独测：
#   * 「逗号后面可以没有空格」是解析层的约定，`jq,yq` 与 `jq, yq` 在 shell 里
#     是**不同的 argv 形态**（一个词 vs 两个词），解析必须两种都认；
#   * 一个包失败不能拖垮其余 —— 汇总里要能看出哪个成了、哪个没成；
#   * 旗标（--no-link / --proxy / --ver）不能因为多包而错位，尤其是带值的旗标，
#     它们的值不能被抓成包名。
#
# 全程离线：假索引与假产物都起在 127.0.0.1，安装目录是 MACWAVE_TEST 临时根。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

# 索引按 arm64 / amd64 分目录，而 CI 的 Linux runner 是 x86_64 —— 写死 arm64
# 会让产物名与客户端要的对不上（platform.machine() 决定它去要哪个）。按本机选。
case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    *) ARCH=amd64 ;;
esac

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

# shellcheck source=./components.sh
source "$SCRIPT_DIR/components.sh"

WORK=$(mktemp -d)
PORT=$((18000 + RANDOM % 1000))
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

MIRROR="$WORK/mirror"
ROOT="$WORK/root"
BASE="$ROOT/opt/macwave"

echo "========== 0. 造一个本地镜像（三个假包） =========="
mkdir -p "$MIRROR/infosource" "$MIRROR/bottle" "$BASE" "$ROOT/opt/macwave_config"
copy_components "$BASE/" >/dev/null
printf '{"version": "4.5.0"}\n' > "$ROOT/opt/macwave_config/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$ROOT/opt/macwave_config/config.json"

make_pkg() {
    local name="$1" dir
    dir="$WORK/src-$name"
    mkdir -p "$dir" "$MIRROR/bottle/$name" "$MIRROR/infosource/pkg/pkginfo_$ARCH/$name"
    printf '#!/bin/sh\necho %s\n' "$name" > "$dir/$name"
    chmod 755 "$dir/$name"
    tar czf "$MIRROR/bottle/$name/$name@1.0.$ARCH.tar.gz" -C "$dir" "$name"

    local sha
    sha=$(shasum -a 256 "$MIRROR/bottle/$name/$name@1.0.$ARCH.tar.gz" | cut -d' ' -f1)
    cat > "$MIRROR/infosource/pkg/pkginfo_$ARCH/$name/_$name@common" <<EOF
bin_name: "$name"
des: "multi-install probe"
hom: "https://example.invalid/"
lic: "MIT"
aut: "probe"
EOF
    cat > "$MIRROR/infosource/pkg/pkginfo_$ARCH/$name/_$name@1.0" <<EOF
sha256: "$sha"
file: "${name}_${ARCH}.tar.gz"
url: "http://127.0.0.1:$PORT/bottle/$name/$name%401.0.$ARCH.tar.gz"
min_os: "12.0"
EOF
}

for name in test_x test_y test_z; do
    make_pkg "$name"
done

"$PYTHON" "$REPO_DIR/scripts/build_versions_index.py" \
    --infosource "$MIRROR/infosource" --mirror "$MIRROR" >/dev/null 2>&1

(cd "$MIRROR" && exec "$PYTHON" -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1

if curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$PORT/infosource/pkg/pkginfo_$ARCH/versions" | grep -q 200; then
    pass "本地镜像起来了（${PORT}）"
else
    fail "本地镜像没起来，后面的用例都会误报"
    exit 1
fi

export MACWAVE_TEST="$ROOT"
export MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT/infosource"
export MACWAVE_BOTTLE_DOMAIN="http://127.0.0.1:$PORT/bottle"

run_wave() { "$PYTHON" "$REPO_DIR/lib/wave.py" "$@" </dev/null; }

echo
echo "========== 1. 逗号分隔、其中一个是坏名字 =========="
OUT=$(run_wave install "test_x, test_zzz" 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then
    pass "有包失败时退出码非 0"
else
    fail "有包失败却返回 0：$OUT"
fi
case "$OUT" in
    *"Installed 1 of 2"*) pass "汇总写明装成 1 个 / 共 2 个" ;;
    *) fail "汇总行不对：$(printf '%s' "$OUT" | tail -3)" ;;
esac
case "$OUT" in
    *"failed test_zzz"*) pass "汇总里点名失败的是 test_zzz" ;;
    *) fail "没点名失败的包" ;;
esac
if [ -L "$BASE/links/test_x" ]; then
    pass "失败的那个没妨碍 test_x 装好"
else
    fail "test_x 没装上（一个坏名字拖垮了整批）"
fi

echo
echo "========== 2. 逗号后面不带空格 =========="
OUT=$(run_wave install "test_y,test_z" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
    pass "test_y,test_z（无空格）安装成功"
else
    fail "无空格写法失败（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)"
fi
for name in test_y test_z; do
    if [ -L "$BASE/links/$name" ]; then
        pass "$name 的链接在"
    else
        fail "$name 没装上"
    fi
done
LIST_OUT=$(run_wave list 2>&1)
case "$LIST_OUT" in
    *test_x*) pass "wave list 里能看到 test_x" ;;
    *) fail "wave list 缺 test_x：$LIST_OUT" ;;
esac
case "$LIST_OUT" in
    *test_z*) pass "wave list 里能看到 test_z" ;;
    *) fail "wave list 缺 test_z：$LIST_OUT" ;;
esac

echo
echo "========== 3. 带值的旗标不能被当成包名 =========="
OUT=$(run_wave install --ver 1.0 "test_x, test_y" 2>&1); RC=$?
case "$OUT" in
    *"--ver cannot be used when installing several packages"*)
        pass "多包 + --ver 明确拒绝" ;;
    *) fail "多包 + --ver 没给出清楚的拒绝（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)" ;;
esac
if [ "$RC" -ne 0 ]; then
    pass "多包 + --ver 退出码非 0"
else
    fail "多包 + --ver 返回了 0"
fi

echo
echo "========== 3.5 只用空格分隔（不带逗号）也认 =========="
# 这是「用户手滑/习惯」的那条路：apt、brew 都是空格分隔，所以这里也照收，
# 而不是把第二个词当噪声丢掉 —— 静默忽略参数比报错更危险。
OUT=$(run_wave install test_x test_y 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
    pass "wave install a b c（空格分隔）同样按多包处理"
else
    fail "空格分隔没被当成多包（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)"
fi
case "$OUT" in
    *"Installed 2 of 2"*) pass "空格分隔的汇总也是 2 of 2" ;;
    *) fail "空格分隔的汇总不对：$(printf '%s' "$OUT" | tail -3)" ;;
esac

echo
echo "========== 4. 单个包的老写法不受影响 =========="
OUT=$(run_wave install test_y 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
    pass "wave install <单个包> 仍然可用"
else
    fail "单包安装坏了（rc=${RC}）：$(printf '%s' "$OUT" | tail -3)"
fi

echo
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [ "$FAILED" -eq 0 ]; then
    echo "🌊 All multi-install checks passed"
    exit 0
else
    echo "🌊 multi-install checks failed"
    exit 1
fi
