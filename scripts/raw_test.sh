#!/bin/bash

# raw_test.sh
# `--raw`（install / upgrade）：输出不带 🌊、不带 ANSI 颜色、进度条用井号刻度。
#
# 为什么单独一个测试：这个旗标的实现分在三处 ——
#   cli/silent.py       剥旗标、换输出流（剥 🌊 与颜色码）
#   pkg/pkginstaller.py 下载进度改走 _RawProgress，不再用 rich
# 三处任何一处漏掉，症状都是「--raw 的输出里还混着别的东西」，而那种东西在终端上
# 看着「差不多」，只有落进日志才刺眼。所以这里既断言输出里**有**井号进度条，
# 也断言输出里**没有** emoji 与转义码，还拿不带 --raw 的同一份安装做对照。
#
# 全程离线：假索引与假产物都起在 localhost，安装目录是临时目录（MACWAVE_TEST）。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

ok() {
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里没有「$3」"
        printf '%s\n' "$2" | sed 's/^/      /' | head -20
    fi
}

not_ok() {
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里不该出现「$3」"
        printf '%s\n' "$2" | sed 's/^/      /' | head -20
    fi
}

# -------------------- 沙箱 --------------------

WORK=$(mktemp -d)
HTTP_PID=""
cleanup() {
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

HOME_DIR="$WORK/home"
BASE="$WORK/base"
TEST_ROOT="$WORK/root"
MIRROR="$WORK/mirror"

# 与 info_format_test 同样的理由：系统级配置优先，CI 上那份会盖住这里的沙箱。
export MACWAVE_TEST="$TEST_ROOT"
mkdir -p "$TEST_ROOT/opt/macwave_config" "$HOME_DIR/.config/macwave_config" "$BASE"
copy_components "$BASE/"
printf '{"version": "4.4.0"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$TEST_ROOT/opt/macwave_config/config.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/macwave_config/config.json"

# 装依赖在用户级 site-packages 里，而下面每条命令都把 HOME 换成沙箱目录 ——
# 不补这一条，wave 会报「缺 requests / packaging / rich」而不是跑测试。
# 在换 HOME 之前算好路径，用 PYTHONPATH 带进去。
USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
if [[ -d "$USER_SITE" ]]; then
    export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$USER_SITE"
fi

ARCH=$(python3 -c 'import platform; m=platform.machine().lower(); print("arm64" if m in ("arm64","aarch64") else "amd64")')

# -------------------- 假索引 + 假产物 --------------------

NAME="rawpkg"
INDEX="$MIRROR/pkg/pkginfo_$ARCH"
mkdir -p "$INDEX/$NAME" "$MIRROR/$NAME"

printf '%s\n' "$NAME" > "$INDEX/versions"
# 清单里每个版本占一行，@common 那一条也列出来（客户端会跳过它）。
printf '%s@1.0\n%s@common\n' "$NAME" "$NAME" > "$INDEX/$NAME/versions"
# 落盘名与线上文件同名：包名前的下划线属于文件名，详见 pkg/pkginstaller.py 的取值。
printf 'bin_name: "%s"\n' "$NAME" > "$INDEX/$NAME/_${NAME}@common"

# 产物：tar.gz 里放一个与 bin_name 同名的文件。凑到几百 KB，让下载循环跨过
# 多个 8192 字节的块 —— 否则一次就读完，只打得出 100% 那一行。
PAYLOAD_DIR="$WORK/payload"
mkdir -p "$PAYLOAD_DIR"
printf '#!/bin/sh\necho raw\n' > "$PAYLOAD_DIR/$NAME"
head -c 300000 /dev/zero | tr '\0' 'x' >> "$PAYLOAD_DIR/$NAME"
tar -czf "$MIRROR/$NAME/${NAME}@1.0.${ARCH}.tar.gz" -C "$PAYLOAD_DIR" "$NAME"

SHA=$(shasum -a 256 "$MIRROR/$NAME/${NAME}@1.0.${ARCH}.tar.gz" | awk '{print $1}')
cat > "$INDEX/$NAME/_${NAME}@1.0" <<EOF
sha256: "$SHA"
file: "${NAME}-1.0-${ARCH}.tar.gz"
url: "https://example.invalid/${NAME}-1.0-${ARCH}.tar.gz"
aut: "MacWave Team"
des: "Fixture package for the --raw regression"
EOF

PORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
( cd "$MIRROR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!

for _ in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/pkg/pkginfo_$ARCH/versions" && break
    sleep 0.1
done

wave() {
    env -u MACWAVE_DEPS_DOMAIN -u MACWAVE_CORE_DOMAIN -u MACWAVE_SELFUPDATE_DOMAIN \
        HOME="$HOME_DIR" \
        MACWAVE_TEST="$TEST_ROOT" \
        MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
        MACWAVE_BOTTLE_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$BASE/lib/wave.py" "$@"
}

# -------------------- 1. 不带 --raw：人读的那份 --------------------

echo "========== 1. 默认输出（对照） =========="

out=$(wave install "$NAME" 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]]; then
    pass "默认安装成功"
else
    fail "默认安装失败（exit ${RC}）"
    printf '%s\n' "$out" | sed 's/^/      /' | head -20
fi
ok   "默认输出带 🌊（这正是 --raw 要去掉的东西）" "$out" "🌊"
not_ok "默认输出里没有井号进度条"               "$out" "#"

# 装完了一个版本，后面 --raw 想重新走一遍下载，得先把版本目录删掉
rm -rf "$BASE/bin/${NAME}@1.0"

# -------------------- 2. --raw：无 emoji、无颜色、井号进度条 --------------------

echo
echo "========== 2. --raw =========="

out=$(wave install "$NAME" --raw 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]]; then
    pass "--raw 安装成功"
else
    fail "--raw 安装失败（exit ${RC}）"
    printf '%s\n' "$out" | sed 's/^/      /' | head -20
fi

not_ok "输出里没有 🌊"                 "$out" "🌊"
not_ok "输出里没有 ESC 转义序列"        "$out" "$(printf '\033')"
not_ok "输出里没有 rich 的清行序列"     "$out" "[2K"

# 井号进度条：至少一行形如 "rawpkg: ####....  40%"，并且最后到 100%
progress_lines=$(printf '%s\n' "$out" | grep -cE "^${NAME}: [#.]+ +[0-9]+%$")
if [[ "$progress_lines" -ge 2 ]]; then
    pass "进度条是多行井号刻度（${progress_lines} 行）"
else
    fail "井号进度条行数不对（${progress_lines} 行）"
    printf '%s\n' "$out" | sed 's/^/      /' | head -20
fi
ok "进度条走到 100%" "$out" "#################### 100%"
not_ok "进度条不带百分比以外的装饰" "$out" "━━"

# 安装本身照旧：文件、链接、版本目录都得在
if [[ -x "$BASE/bin/${NAME}@1.0/$NAME" ]]; then
    pass "--raw 装出来的可执行文件在位"
else
    fail "--raw 装完没有可执行文件"
fi
if [[ -L "$BASE/links/$NAME" ]]; then
    pass "--raw 装完建了不带版本号的链接"
else
    fail "--raw 装完没有链接"
fi

# -------------------- 3. 错误输出也不带颜色与 emoji --------------------

echo
echo "========== 3. 出错时的 --raw =========="

out=$(wave install no_such_pkg_here --raw 2>&1)
ok     "--raw 的错误仍然是错误（说清是哪一步）" "$out" "step 4/11"
ok     "--raw 的错误给出下一步"                 "$out" "Next"
not_ok "--raw 的错误里没有 🌊"                  "$out" "🌊"
not_ok "--raw 的错误里没有 ESC 转义序列"        "$out" "$(printf '\033')"

# -------------------- 4. 旗标归属 --------------------

echo
echo "========== 4. 旗标归属 =========="

out=$(wave uninstall "$NAME" --raw 2>&1)
RC=$?
if [[ "$RC" -eq 1 ]]; then
    pass "--raw 用在 uninstall 上被拒绝（exit 1）"
else
    fail "--raw 用在 uninstall 上没有被拒绝（exit ${RC}）"
fi
ok "--raw 被拒绝时指向真正支持它的命令" "$out" "--raw only applies to"
ok "--raw 被拒绝时说的是「用错了命令」"  "$out" "wave install"

out=$(wave install "$NAME" --raw -s 2>&1)
if [[ -z "$out" ]]; then
    pass "-s 与 --raw 同时给：静默胜出，一个字节都不打"
else
    fail "-s 与 --raw 同时给却有输出"
    printf '%s\n' "$out" | sed 's/^/      /' | head -10
fi

# info / mirror 的 --raw 含义不同，不能被 silent 吞掉
out=$(wave info "$NAME" --raw 2>&1)
ok "info --raw 仍是「原文」语义（@common 原文，不是被重排的字段）" \
   "$out" 'bin_name: "rawpkg"' 

# -------------------- 5. upgrade 也认 --raw --------------------

echo
echo "========== 5. upgrade =========="

out=$(wave upgrade "$NAME" --raw 2>&1)
not_ok "upgrade 接受 --raw（没有 illegal option）" "$out" "illegal option"
not_ok "upgrade --raw 的输出里没有 🌊"             "$out" "🌊"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All --raw tests passed${RESET}"
