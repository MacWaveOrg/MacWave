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
cp -R "$REPO_DIR/lib" "$REPO_DIR/pkg" "$REPO_DIR/surfboard" "$BASE/"
printf '{"version": "4.1.0"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/macwave_config/config.json"

# -------------------- 假镜像 --------------------
#
# 只放三个包的名字清单，用来测「猜包名」。列表格式与 build_versions_index.py 的
# 输出一致：一行一个包名 / 一行一条 <包名>@<版本>。

MIRROR="$WORK/mirror"
mkdir -p "$MIRROR/pkg/pkginfo_arm64/tree" "$MIRROR/pkg/pkginfo_arm64/jq"
printf 'bat\njq\ntree\nwget\n' > "$MIRROR/pkg/pkginfo_arm64/versions"
printf 'tree@2.2.1\ntree@2.1.0\n' > "$MIRROR/pkg/pkginfo_arm64/tree/versions"
printf 'jq@1.8.2\n' > "$MIRROR/pkg/pkginfo_arm64/jq/versions"

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
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/pkg/pkginfo_arm64/versions"; then break; fi
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
ok     "给出完整的改法（参数与旗标原样保留）" "$out" "wave upgrade jq -Xv --max-time=120s"
ok     "说明哪个词打错了"                   "$out" "is not a command"
ok     "仍然打印完整帮助"                   "$out" "Commands:"

wave update jq >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass "退出码是 1"; else fail "退出码应当为 1"; fi

out=$(wave remove jq --all 2>&1)
ok "remove → uninstall" "$out" "wave uninstall jq --all"

out=$(wave ls 2>&1)
ok "ls → list" "$out" "wave list"

echo
echo "========== 2. 不相干的乱词：不乱猜 =========="

out=$(wave frobnicate xyz 2>&1)
not_ok "不给出 Did you mean" "$out" "Did you mean"
ok     "仍然报未知命令"      "$out" "Unknown command or argument"

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
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All message tests passed${RESET}"
