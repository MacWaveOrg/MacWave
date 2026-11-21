#!/bin/bash

# rc_channel_test.sh
# RC 渠道的隔离：装的是 RC 就只读 rcdata/latest.toml，正式版永远看不到 RC 探针；
# RC 渠道没有更新的构建时，正式版更新则以**全量**方式切过去。
#
# 为什么值得一条测试：这条逻辑只在「装 RC 的人」身上跑，而 RC 是少数人。坏了的表现
# 两头都不好看 —— 要么正式版用户被 RC 卷进来（渠道串了），要么 RC 用户永远停在
# 那一版（构建号没参与比较）。两种都只会在发版之后才被发现。
#
# 全程离线：起一个本地 http.server 当镜像，用 --dry-run 只读地跑一遍。
# 最后一条断言要的是「正式版客户端不请求 rcdata」，这条只能从服务器日志里看出来。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
cleanup() {
    [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

SITE="$WORK/srv"
HOME_DIR="$WORK/home"
mkdir -p "$SITE/rcdata" "$SITE/macwavedata" "$HOME_DIR/.config/macwave_config"
printf '{"base_dir": "%s"}\n' "$WORK/base" > "$HOME_DIR/.config/macwave_config/config.json"

USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null)
PYTHONPATH="$(component_paths)"
export PYTHONPATH
[[ -d "$USER_SITE" ]] && export PYTHONPATH="$PYTHONPATH:$USER_SITE"

PORT=$(python3 - <<'PY'
import socket

s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
( cd "$SITE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 > "$WORK/http.log" 2>&1 ) &
HTTP_PID=$!
for _ in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/macwavedata/latest.toml" && break
    sleep 0.1
done

# 探针内容：三个参数分别是 RC 版本/构建号、正式版版本/构建号
probe() {
    printf 'version = "%s"\nbuild_number = "%s"\nbranch = "4.4-261119"\n' "$1" "$2" \
        > "$SITE/rcdata/latest.toml"
    printf 'version = "%s"\nbuild_number = "%s"\nbranch = "main"\n' "$3" "$4" \
        > "$SITE/macwavedata/latest.toml"
}

# 本机装的是什么
installed() {
    printf '{"version": "%s", "build_number": "%s"}\n' "$1" "$2" \
        > "$HOME_DIR/.config/macwave_config/VERSION.json"
}

wave() {
    env -u MACWAVE_API_DOMAIN -u MACWAVE_BOTTLE_DOMAIN -u MACWAVE_DEPS_DOMAIN \
        -u MACWAVE_CORE_DOMAIN -u MACWAVE_PYTHON_DOMAIN \
        HOME="$HOME_DIR" \
        MACWAVE_SELFUPDATE_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$REPO_DIR/lib/wave.py" selfupdate --dry-run 2>&1
}

echo "========== 1. RC 客户端只读 RC 探针 =========="

installed "4.4.1-rc" "323R1200"
probe "4.4.1-rc" "323R1300" "4.4.1" "324D0900"
OUT=$(wave)
if grep -q "Channel: RC" <<< "$OUT" && grep -q "build 323R1300" <<< "$OUT"; then
    pass "RC 客户端读到 RC 探针里更新的构建（323R1200 → 323R1300）"
else
    fail "RC 客户端没有读到 RC 探针的新构建：$OUT"
fi
if grep -q "branch *4.4-261119" <<< "$OUT"; then
    pass "用的是 RC 探针里的分支"
else
    fail "分支不是 RC 探针里的那条：$OUT"
fi

echo "========== 2. 构建号相同 = 已是最新 =========="

probe "4.4.1-rc" "323R1200" "4.4.0" "320D0900"
OUT=$(wave)
if grep -q "already up to date" <<< "$OUT"; then
    pass "同一个版本、同一个构建号 → 已是最新（不会被反复重装）"
else
    fail "同构建号时不该更新：$OUT"
fi

echo "========== 3. RC 渠道收尾：全量切到正式版 =========="

installed "4.4.1-rc" "323R1200"
probe "4.4.1-rc" "323R1100" "4.4.1" "324D0900"
OUT=$(wave)
if grep -q "RC channel has no newer build" <<< "$OUT" && grep -q "full install" <<< "$OUT"; then
    pass "RC 没有更新构建、正式版更新 → 提示走全量切换"
else
    fail "RC 收尾时没有走全量切换：$OUT"
fi

echo "========== 4. 正式版客户端永远不碰 rcdata =========="

installed "4.4.0" "320D0900"
probe "9.9.9-rc" "330R1200" "4.4.0" "320D0900"
: > "$WORK/http.log"
OUT=$(wave)
if grep -q "already up to date" <<< "$OUT"; then
    pass "正式版客户端不受更新的 RC 影响"
else
    fail "正式版客户端被 RC 探针影响了：$OUT"
fi
if grep -q "rcdata" "$WORK/http.log"; then
    fail "正式版客户端请求了 rcdata（渠道隔离失效）：$(grep rcdata "$WORK/http.log" | head -2)"
else
    pass "正式版客户端一次都没有请求 rcdata"
fi

echo "========== 5. 没有 RC 探针时不炸 =========="

installed "4.4.1-rc" "323R1200"
rm -f "$SITE/rcdata/latest.toml"
printf 'version = "4.4.1"\nbuild_number = "324D0900"\nbranch = "main"\n' > "$SITE/macwavedata/latest.toml"
OUT=$(wave)
if grep -q "full install" <<< "$OUT" && grep -q "4.4.1" <<< "$OUT"; then
    pass "RC 探针 404 时退到正式版，并仍按全量切换"
else
    fail "RC 探针缺失时行为不对：$OUT"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 RC channel isolation is intact${RESET}"
