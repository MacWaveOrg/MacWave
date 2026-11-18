#!/bin/bash

# install_privilege_test.sh
# `install.sh` 什么时候需要提权：按**写权限**判断，不按「是不是在家目录下」。
#
# 为什么值得单独一个测试：这条判断错的两个方向都不会崩，只会让人莫名其妙 ——
#   * 装到自己可写的外部卷（/Volumes/SSD/macwave），明明不需要密码却要密码；
#   * ~/.local/macwave 被上一次 `sudo` 装成了 root 所有，安装器认为用户目录
#     无需提权，然后一路 Permission denied，报错指不到原因。
#
# 同时钉住另一件事：**配置目录的位置仍按语义走**（$HOME 之外 → /opt/macwave_config，
# $HOME 之内 → ~/.config/macwave_config）。它与「这次要不要提权」是两个概念，
# 合成一个变量正是上面两类故障的成因。
#
# 全程 `--dry-run`：不下载、不提权、不建目录；版本数据指向一个必然失败的本地地址，
# 于是不必联网。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: install.sh not found at $INSTALL_SH${RESET}"
    exit 1
fi

WORK=$(mktemp -d)
RO_DIRS=()
cleanup() {
    local dir
    for dir in ${RO_DIRS[@]+"${RO_DIRS[@]}"}; do
        [[ -d "$dir" ]] && chmod 755 "$dir" 2>/dev/null
    done
    [[ -d "$WORK" ]] && chmod -R u+rwX "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# 每个用例一个独立的测试根：它们对目录权限的摆弄互不影响。
new_root() {
    local root="$WORK/$1"
    mkdir -p "$root"
    echo "$root"
}

# 干跑一次，返回它的输出。版本数据指向 127.0.0.1:1 —— 立刻失败并回落到占位版本号，
# 于是这条测试不碰网络，也不会因为线上换版本而变红。
dry_run() {
    local root="$1"; shift
    MACWAVE_TEST="$root" \
        MACWAVE_SELFUPDATE_DOMAIN="http://127.0.0.1:1" \
        /bin/bash "$INSTALL_SH" --dry-run "$@" 2>&1
}

needs_admin() {
    case "$1" in
        *"needs administrator access"*) return 0 ;;
        *) return 1 ;;
    esac
}

config_path() {
    # 从「Dry run: would write <config.json> (base_dir)」里取出配置文件的路径
    printf '%s\n' "$1" | sed -n 's/.*would write \([^ ]*config\.json\).*/\1/p' | head -n 1
}

# -------------------- 1. 用户目录：写得了，不提权 --------------------

ROOT=$(new_root user)
out=$(dry_run "$ROOT" --dir-option=1)
if needs_admin "$out"; then
    fail "默认的用户级目录不该要求提权"
else
    pass "默认的用户级目录不提权"
fi
case "$(config_path "$out")" in
    *"/.config/macwave_config/config.json") pass "用户级安装用用户配置目录" ;;
    *) fail "用户级安装的配置目录不对：$(config_path "$out")" ;;
esac

# -------------------- 2. $HOME 之外、但自己可写：不提权（本次修复的重点） --------------------

ROOT=$(new_root writable)
TARGET="$ROOT/custom/macwave"
out=$(dry_run "$ROOT" --dir-option="3=$TARGET")
if needs_admin "$out"; then
    fail "自己可写的外部目录不该要求提权（旧逻辑按「不在家目录」误判）"
else
    pass "自己可写的外部目录不提权"
fi
case "$(config_path "$out")" in
    *"/opt/macwave_config/config.json") pass "系统级语义保留：配置仍进 /opt/macwave_config" ;;
    *) fail "外部目录的配置位置不对：$(config_path "$out")" ;;
esac

# -------------------- 3. $HOME 之内、但写不了：要提权（反方向） --------------------

ROOT=$(new_root unwritable-home)
mkdir -p "$ROOT$HOME/.local/macwave"
RO_DIRS+=("$ROOT$HOME/.local/macwave")
chmod 555 "$ROOT$HOME/.local/macwave"
out=$(dry_run "$ROOT" --dir-option=1)
if needs_admin "$out"; then
    pass "家目录内但不可写 → 要求提权（旧逻辑会漏判）"
else
    fail "家目录内不可写的目标没有被判定为需要提权"
fi
case "$(config_path "$out")" in
    *"/.config/macwave_config/config.json") pass "提权与否不影响配置目录的语义" ;;
    *) fail "家目录目标的配置位置不对：$(config_path "$out")" ;;
esac

# -------------------- 4. $HOME 之外、也写不了：要提权 --------------------

ROOT=$(new_root unwritable)
# 只把目标所在的那一层设成只读：测试根本身必须可写，否则 install.sh 连
# 「把 HOME 搬进测试根」都做不到（那是 MACWAVE_TEST 的准备工作，与提权无关）。
mkdir -p "$ROOT/locked"
RO_DIRS+=("$ROOT/locked")
chmod 555 "$ROOT/locked"
out=$(dry_run "$ROOT" --dir-option="3=$ROOT/locked/macwave")
if needs_admin "$out"; then
    pass "只读的外部目录要求提权"
else
    fail "只读的外部目录没有被判定为需要提权"
fi
chmod 755 "$ROOT/locked"

# -------------------- 5. 目标可写、配置目录不可写：仍要提权 --------------------

# 判断必须同时看两处：只测 BASE_DIR 会漏掉「配置要写 /opt/macwave_config」这一半，
# 结果是安装到一半才在写配置时 permission denied。
ROOT=$(new_root config-ro)
RO_DIRS+=("$ROOT/opt")
mkdir -p "$ROOT/opt"
chmod 555 "$ROOT/opt"
out=$(dry_run "$ROOT" --dir-option="3=$ROOT/custom/macwave")
if needs_admin "$out"; then
    pass "目标可写但系统配置目录不可写 → 要求提权"
else
    fail "配置目录不可写时没有要求提权（会在写配置那一步失败）"
fi
chmod 755 "$ROOT/opt"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All install privilege tests passed${RESET}"
