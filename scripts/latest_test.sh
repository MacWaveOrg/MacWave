#!/bin/bash

# latest_test.sh
# `wave latest` 的回归：三种比较结果、未安装、包名打错、清单缺失、
# --all 的汇总、链接指向旧版本时的附注，以及参数校验。
#
# 全程离线：假索引起在 localhost，假安装目录用临时 HOME，
# 不碰真实安装、不发外网请求、不下载任何产物。

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

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# ok <描述> <输出> <应包含的片段>
ok() {
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里没有「$3」"
        printf '%s\n' "$2" | sed 's/^/      /'
    fi
}

# not_ok <描述> <输出> <不该出现的片段>
not_ok() {
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里不该出现「$3」"
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

# 用 MACWAVE_TEST 把 /opt 映射到测试根下。
#
# 不这么做的后果（CI 上真实发生过）：config_dir_candidates() 是**系统级优先**，
# 而 CI 的 workflow 为了跑别的测试预先写过 /opt/macwave_config/config.json，
# 于是 load_base_dir() 读到那一份、返回 /tmp/macwave-test，本测试安装的包
# 一个都认不出来，12 项断言全挂 —— 而本地没有那个文件，所以本地一直是绿的。
export MACWAVE_TEST="$TEST_ROOT"
mkdir -p "$TEST_ROOT/opt/macwave_config" "$HOME_DIR/.config/macwave_config" "$BASE"
cp -R "$REPO_DIR/lib" "$REPO_DIR/pkg" "$REPO_DIR/surfboard" "$BASE/"
printf '{"version": "4.1.0"}\n' > "$BASE/VERSION.json"
# 两处都写：系统级是首选，用户级兜底
printf '{"base_dir": "%s"}\n' "$BASE" > "$TEST_ROOT/opt/macwave_config/config.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/macwave_config/config.json"

ARCH=$(python3 -c 'import platform; m=platform.machine().lower(); print("arm64" if m in ("arm64","aarch64") else "amd64")')

# 装三个包：jq 旧（有新版）、bat 最新、tree 本地比索引新
for spec in "jq@1.7.1" "bat@0.26.1" "tree@2.2.1"; do
    mkdir -p "$BASE/bin/$spec"
    : > "$BASE/bin/$spec/${spec%@*}"
done
mkdir -p "$BASE/links"
ln -s "../bin/jq@1.7.1/jq"     "$BASE/links/jq"
ln -s "../bin/bat@0.26.1/bat"  "$BASE/links/bat"
ln -s "../bin/tree@2.2.1/tree" "$BASE/links/tree"

# -------------------- 假索引 --------------------
#
# wget 故意写了名字、不给版本清单 —— 用来区分「索引里没这个名字」
# 和「有名字但没出清单」这两种完全不同的故障。

MIRROR="$WORK/mirror"
INDEX="$MIRROR/pkg/pkginfo_$ARCH"
mkdir -p "$INDEX"/{jq,bat,tree}
printf 'bat\njq\ntree\nwget\n' > "$INDEX/versions"
printf 'jq@1.8.2\njq@1.7.1\njq@common\n' > "$INDEX/jq/versions"
printf 'bat@0.26.1\nbat@common\n'        > "$INDEX/bat/versions"
printf 'tree@2.1.0\ntree@common\n'       > "$INDEX/tree/versions"

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

USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
[[ -d "$USER_SITE" ]] && export PYTHONPATH="$USER_SITE"

wave() {
    env -u MACWAVE_BOTTLE_DOMAIN -u MACWAVE_DEPS_DOMAIN \
        HOME="$HOME_DIR" \
        MACWAVE_TEST="$TEST_ROOT" \
        MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$BASE/lib/wave.py" "$@"
}

# 诊断：CI 上出现过「索引读得到、已装包却一个都不认」，本地复现不出。
# 这里把关键路径打出来，失败时日志能直接看出差在哪一步。
echo "---------- 环境 ----------"
echo "HOME       = $HOME_DIR"
echo "BASE       = $BASE"
echo "ARCH       = $ARCH"
echo "索引端口   = $PORT"
echo -n "BASE_DIR 解析 = "
HOME="$HOME_DIR" MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
  python3 -c "
import sys
sys.path.insert(0, '$BASE/lib')
from configpaths import load_base_dir
print(load_base_dir())
" 2>&1 | tail -1
echo -n "bin/ 内容     = "
ls "$BASE/bin" 2>/dev/null | tr '\n' ' '
echo
echo "--------------------------"
echo

echo "========== 1. 三种比较结果 =========="

out=$(wave latest jq)
ok "有新版：给出当前版本"   "$out" "1.7.1"
ok "有新版：给出远端最新"   "$out" "1.8.2"
ok "有新版：状态一眼可见"   "$out" "update available"
ok "有新版：用 → 指向新版"  "$out" "→ 1.8.2"

out=$(wave latest bat)
ok "已最新：两个版本都给出"   "$out" "0.26.1"
ok "已最新：状态是 up to date" "$out" "up to date"

out=$(wave latest tree)
ok "本地更新：状态是 local is newer" "$out" "local is newer"
ok "本地更新：用 ← 指向索引里那份"  "$out" "← 2.1.0"

echo
echo "========== 2. 未安装 =========="

out=$(wave latest wget 2>&1)
ok "名字在索引里但没清单：指到镜像的清单" "$out" "no version list"

echo
echo "========== 3. 查不到时怎么说 =========="

out=$(wave latest treee 2>&1)
ok "拼错了就猜一个"        "$out" 'did you mean `tree`?'
not_ok "不把自己当建议"    "$out" 'did you mean `treee`'

if [[ -n "$out" ]]; then
    wave latest treee >/dev/null 2>&1
    if [[ $? -eq 1 ]]; then pass "查不到时退出码 1"; else fail "查不到时退出码应当为 1"; fi
fi

out=$(wave latest wget 2>&1)
not_ok "缺清单不是拼写问题，不乱猜" "$out" "did you mean"

echo
echo "========== 4. --all =========="

out=$(wave latest --all)
ok "--all 列出全部已装包"   "$out" "bat"
ok "--all 也包含 jq"        "$out" "jq"
ok "--all 汇总有更新的数量" "$out" "1 of 3 package(s) have an update"
ok "--all 指向下一步命令"   "$out" "wave upgrade <name>"

out=$(wave latest -a)
ok "-a 是 --all 的短形式" "$out" "1 of 3 package(s) have an update"

mkdir -p "$WORK/empty/base" "$WORK/empty/home/.config/macwave_config"
cp -R "$REPO_DIR/lib" "$REPO_DIR/pkg" "$REPO_DIR/surfboard" "$WORK/empty/base/"
# 这个用例要一个「什么都没装」的根，必须与主沙箱分开：MACWAVE_TEST 是全局导出的，
# 沿用主沙箱的测试根就会读到主沙箱那份 config.json，三条包记录全被认成已安装。
mkdir -p "$WORK/empty/root/opt/macwave_config"
printf '{"base_dir": "%s"}\n' "$WORK/empty/base" > "$WORK/empty/root/opt/macwave_config/config.json"
out=$(env HOME="$WORK/empty/home" MACWAVE_TEST="$WORK/empty/root" \
      MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
      PYTHONPATH="$USER_SITE" python3 "$WORK/empty/base/lib/wave.py" latest --all 2>&1)
ok "--all 在没装任何包时说清楚" "$out" "No packages installed yet"

echo
echo "========== 5. 链接指向旧版本时的附注 =========="

mkdir -p "$BASE/bin/jq@1.8.2" && : > "$BASE/bin/jq@1.8.2/jq"
out=$(env HOME="$HOME_DIR" MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
      PYTHONPATH="$USER_SITE" python3 "$BASE/lib/wave.py" latest jq 2>&1)
ok "已装新版：状态是 up to date" "$out" "up to date"
ok "但仍附注真正在跑的旧版本"     "$out" "(linked: 1.7.1)"
rm -rf "$BASE/bin/jq@1.8.2"

echo
echo "========== 6. 参数校验 =========="

out=$(wave latest 2>&1)
ok "缺包名"                "$out" "Missing package name"
ok "缺包名时给出两种用法"  "$out" "wave latest --all"

out=$(wave latest jq@1.7.1 2>&1)
ok "拒绝带版本号并给出改法" "$out" "wave latest jq"

out=$(wave latest -z jq 2>&1)
ok "未知旗标点名是哪条命令" "$out" "illegal option -z for \`wave latest\`"

out=$(wave latest -a --max-time=bogus)
ok "--max-time 值非法时报错" "$out" "cannot parse --max-time"

echo
echo "========== 7. 帮助里能看到这条命令 =========="

out=$(wave --help)
ok "命令清单里有 latest"  "$out" "latest"
ok "说明写清了用途"        "$out" "newer version available"

out=$(wave latest --help)
ok "latest --help 有用法" "$out" "wave latest <package> | wave latest --all"
ok "latest --help 列出 -a" "$out" "-a, --all"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All latest tests passed${RESET}"
