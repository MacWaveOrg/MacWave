#!/bin/bash

# message_test.sh
# 两条「说清楚该怎么办」的回归：
#   1. 命令打错（wave update …）→ 提示正确的命令，并把其余参数原样带出来
#   2. 包名打错（wave upgrade treee）→ 从索引的名字清单里猜出最接近的包名
#
# 全程离线：假镜像用 python3 -m http.server 起在 localhost，
# 假安装目录用临时 HOME，不碰真实安装、不发外网请求。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"
WAVE_SRC="$REPO_DIR/lib/wave.py"

if [[ ! -f "$WAVE_SRC" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_SRC${RESET}"
    exit 1
fi

FAILED=0
PASSED=0

pass()  { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail()  { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# ok <描述> <命令输出> <应包含的片段>
ok() {
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里没有「$3」"
        printf '%s\n' "$2" | sed 's/^/      /'
    fi
}

# not_ok <描述> <命令输出> <不该出现的片段>
not_ok() {
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里不该出现「$3」"
    fi
}

# strip_ansi <文本> —— 去掉颜色码。
# 断言应当比对**用户看到的字**，而不是终端转义序列：文案里高亮的是哪个词属于
# 呈现细节，随时可能调整，不该让断言跟着碎。
strip_ansi() { printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

# -------------------- 沙箱 --------------------
#
# wave.py 会从配置里读 base_dir，再从那里加载 lib/ pkg/ surfboard/。
# 这里造一份临时安装，HOME 也指到临时目录，确保不会用到本机已有的配置。

WORK=$(mktemp -d)
HTTP_PID=""
cleanup() {
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

HOME_DIR="$WORK/home"
BASE="$WORK/base"
mkdir -p "$HOME_DIR/.config/macwave_config" "$BASE"
copy_components "$BASE/"
printf '{"version": "4.1.0"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/macwave_config/config.json"

# -------------------- 假镜像 --------------------
#
# 只放三个包的名字清单，用来测「猜包名」。列表格式与 build_versions_index.py 的
# 输出一致：一行一个包名 / 一行一条 <包名>@<版本>。

MIRROR="$WORK/mirror"

# 索引目录按架构分家。写死 arm64 的话，测试只在 Apple Silicon 上成立 ——
# Linux runner 是 x86_64，代码会去请求 pkginfo_amd64，目录不存在，全部 404。
# 这段映射必须与 pkg/pkginstaller.detect_arch() 保持一致。
ARCH=$(python3 -c 'import platform; m = platform.machine().lower(); print("arm64" if m in ("arm64", "aarch64") else "amd64")')

mkdir -p "$MIRROR/pkg/pkginfo_$ARCH/tree" "$MIRROR/pkg/pkginfo_$ARCH/jq"
printf 'bat\njq\ntree\nwget\n' > "$MIRROR/pkg/pkginfo_$ARCH/versions"
printf 'tree@2.2.1\ntree@2.1.0\n' > "$MIRROR/pkg/pkginfo_$ARCH/tree/versions"
printf 'jq@1.8.2\n' > "$MIRROR/pkg/pkginfo_$ARCH/jq/versions"

PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
( cd "$MIRROR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!

for _ in $(seq 1 40); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/pkg/pkginfo_$ARCH/versions"; then break; fi
    sleep 0.1
done

# wave <args> —— 全部在沙箱里跑，索引指向假镜像
wave() {
    env -u MACWAVE_BOTTLE_DOMAIN -u MACWAVE_DEPS_DOMAIN \
        HOME="$HOME_DIR" \
        MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$BASE/lib/wave.py" "$@"
}

# 依赖装在本机解释器里；HOME 换了之后 --user 目录也跟着换，补回真实路径。
# 用 site.getusersitepackages()，它算的就是 HOME 改掉之后会丢的那个目录。
USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
if [[ -d "$USER_SITE" ]]; then
    export PYTHONPATH="$USER_SITE"
fi

echo "========== 1. 命令打错：update → upgrade =========="

out=$(wave update jq -Xv --max-time=120s 2>&1)
ok     "给出完整的改法（参数与旗标原样保留）" "$(strip_ansi "$out")" "wave upgrade jq -Xv --max-time=120s"
ok     "说明哪个词打错了"                   "$out" "is not a command"
# 猜到该敲什么时不再展开整篇帮助：那五六十行会淹掉唯一有用的那一句。
# 但也得留一个自查入口，否则用户想知道还有哪些命令就没地方去了。
not_ok "猜对时不再打印整篇帮助"               "$out" "Commands:"
ok     "改而指向 wave --help"                 "$out" "wave --help"

wave update jq >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass "退出码是 1"; else fail "退出码应当为 1"; fi

out=$(wave remove jq --all 2>&1)
ok "remove → uninstall" "$(strip_ansi "$out")" "wave uninstall jq --all"

out=$(wave ls 2>&1)
ok "ls → list" "$(strip_ansi "$out")" "wave list"

echo
echo "========== 2. 不相干的乱词：不乱猜 =========="

out=$(wave frobnicate xyz 2>&1)
plain=$(strip_ansi "$out")
not_ok "不给出 Did you mean" "$plain" "Did you mean"
ok     "仍然报未知命令"      "$plain" "Unknown command or argument"

# 猜不到该敲什么时，**仍然要指出是哪个词有问题** —— 否则整段输出里没有任何
# 定位信息，用户只能自己盯着命令行找。caret 长度必须与那个词等长。
ok     "无建议时也回显命令行" "$plain" "wave frobnicate xyz"
if [[ "$plain" == *"^^^^^^^^^^"* ]]; then
    pass "无建议时也用 ^ 指住出错的词"
else
    fail "无建议时没有用 ^ 指住出错的词"
fi
# caret 必须落在 frobnicate 底下，而不是行首
if printf '%s\n' "$plain" | grep -qE '^ +\^{10}$'; then
    pass "caret 单独成行且带缩进"
else
    fail "caret 行的形状不对（应只有缩进与 ^）"
fi

echo
echo "========== 3. 包名打错：treee → tree =========="

out=$(wave upgrade treee 2>&1)
ok "猜出近似的包名" "$out" 'did you mean `tree`?'
ok "给出可以直接跑的命令" "$out" "try: wave info tree"
ok "不带架构后缀地列出真实版本" "$(wave info tree 2>&1)" "Available versions: 2.2.1"

out=$(wave upgrade zzzznonsense 2>&1)
not_ok "猜不出来时保持沉默" "$out" 'did you mean'

echo
echo "========== 4. 正常用法不受影响 =========="

out=$(wave -V 2>&1)
not_ok "-V 不触发纠错" "$out" "Did you mean"
ok     "-V 打印版本"   "$out" "MacWave"

out=$(wave upgrade --help 2>&1)
ok "upgrade --help 仍是用法说明" "$out" "wave upgrade <package>"

out=$(wave search tre 2>&1)
ok "search 按片段匹配" "$out" "tree"

echo
echo "========== 3. 旗标拼错：给候选，但只在真有候选时 =========="

# --connect-time 是 --connect-timeout 少了三个字母。只说 "illegal option"
# 等于让用户回去翻 --help。
out=$(wave install jq --connect-time=1min 2>&1)
# 出错的那个旗标被标红，所以「you ran:」那一行里夹着转义序列。
plain=$(strip_ansi "$out")
ok     "给出最接近的旗标"   "$plain" "Did you mean --connect-timeout?"
ok     "仍然点名哪个旗标"   "$plain" "illegal option --connect-time"
ok     "仍然回显整条命令"   "$plain" "you ran: wave install jq --connect-time=1min"
ok     "保留 --help 自查"   "$plain" "wave install --help"
# 高亮只落在出错的旗标上：整行唯一的红色片段应当就是它
if [[ "$out" == *$'\033[1;31m--connect-time'* ]]; then
    pass "出错的旗标被单独标红"
else
    fail "出错的旗标没有被标红"
fi

out=$(wave install jq --limt-rate=10M 2>&1)
ok     "限速旗标拼错也给建议" "$out" "Did you mean --limit-rate?"

# 没有任何接近的候选时不要瞎猜 —— 编一个坏建议比不给建议更伤人。
out=$(wave install jq --unkown-flag 2>&1)
not_ok "无候选时不编造建议"   "$out" "Did you mean"
ok     "仍然给出 --help"      "$out" "wave install --help"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All message tests passed${RESET}"
