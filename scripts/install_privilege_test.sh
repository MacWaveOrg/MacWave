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

# -------------------- 6. SIP 保护范围 --------------------
#
# 两道锁，顺序不能反：先看系统卷是否密封（SSV），再看 SIP 主开关。
# 用替身 csrutil 摆出六种组合 —— 真机上没法为了测试去关 SIP。

echo
echo "========== SIP 保护范围 =========="

STUB_CSRUTIL="$WORK/bin/csrutil"
mkdir -p "$WORK/bin"
cat > "$STUB_CSRUTIL" <<'STUB'
#!/bin/sh
case "$1" in
    status) echo "System Integrity Protection status: ${STUB_SIP:-enabled}." ;;
    authenticated-root) echo "Authenticated Root status: ${STUB_SSV:-enabled}." ;;
esac
STUB
chmod +x "$STUB_CSRUTIL"
export MACWAVE_CSRUTIL="$STUB_CSRUTIL"

sip_run() {
    # sip_run <SIP 状态> <SSV 状态> <目标目录>
    local sip="$1" ssv="$2" target="$3" root out rc
    root=$(new_root "sip-$RANDOM$RANDOM")
    out=$(STUB_SIP="$sip" STUB_SSV="$ssv" dry_run "$root" --dir-option="3=$target")
    rc=$?
    printf '%s' "$out"
    return "$rc"
}

out=$(sip_run enabled enabled /System/macwave); rc=$?
if [[ "$rc" -ne 0 && "$out" == *"sealed system volume"* ]]; then
    pass "SIP 正常 + 系统卷密封 → 拒绝（密封这道锁与 SIP 无关）"
else
    fail "SIP 正常 + 系统卷密封时没有拒绝（exit ${rc}）"
fi

out=$(sip_run disabled enabled /System/macwave); rc=$?
if [[ "$rc" -ne 0 && "$out" == *"sealed system volume"* ]]; then
    pass "SIP 已关闭但系统卷仍密封 → 仍拒绝（这正是会漏判的一种）"
else
    fail "SIP 已关闭、系统卷密封时没有拒绝（exit ${rc}）"
fi

out=$(sip_run "enabled (Custom Configuration)" disabled /System/macwave); rc=$?
if [[ "$rc" -eq 0 && "$out" == *"SIP is reduced"* && "$out" == *"not sealed"* ]]; then
    pass "SIP 降级 + 系统卷未密封 → 警告后继续"
else
    fail "SIP 降级且未密封时的行为不对（exit ${rc}）"
fi

out=$(sip_run disabled disabled /usr/bin/macwave); rc=$?
if [[ "$rc" -eq 0 && "$out" == *"SIP is disabled"* ]]; then
    pass "SIP 关闭 + 未密封 → 警告后继续（讲清是 sudo 真能写）"
else
    fail "SIP 关闭且未密封时的行为不对（exit ${rc}）"
fi

out=$(sip_run enabled enabled /usr/local/macwave); rc=$?
if [[ "$rc" -eq 0 && "$out" != *"sealed"* && "$out" != *"SIP is"* ]]; then
    pass "/usr/local 是明确豁免（Homebrew 在那里）"
else
    fail "/usr/local 被误判成受保护位置（exit ${rc}）"
fi

out=$(sip_run unknown unknown /System/macwave); rc=$?
if [[ "$rc" -eq 0 && "$out" != *"sealed"* ]]; then
    pass "读不到 SIP 状态时不做判断（非 macOS / 老系统不该被挡住）"
else
    fail "读不到状态时不该拒绝，实际 exit ${rc}"
fi

unset MACWAVE_CSRUTIL

# -------------------- 7. 写探针本身 --------------------
#
# 上面的用例全走 --dry-run（承诺不写文件，因此只用 test -w）。
# 这一节把 mw_can_write 抠出来单独跑：真的建一个空文件再删掉，并确认没留下东西。

echo
echo "========== 写探针 =========="

probe_run() {
    # probe_run <目录> → 打印 "rc=<0|1|2> leftovers=<n>"
    /bin/bash -c '
mw_dry_run() { return 1; }
eval "$(sed -n "/^mw_can_write()/,/^}/p" "$1")"
dir="$2"
rc=0
mw_can_write "$dir" || rc=$?
leftovers=$(find "$dir" -maxdepth 1 -name ".macwave-write-probe.*" 2>/dev/null | wc -l | tr -d " ")
echo "rc=$rc leftovers=$leftovers"
' _ "$INSTALL_SH" "$1"
}

PROBE_ROOT=$(new_root probe)
mkdir -p "$PROBE_ROOT/writable"
out=$(probe_run "$PROBE_ROOT/writable")
if [[ "$out" == "rc=0 leftovers=0" ]]; then
    pass "可写目录：探针通过且不留下文件"
else
    fail "可写目录的探针结果不对：$out"
fi

out=$(probe_run "$PROBE_ROOT/writable/deep/nested")
if [[ "$out" == "rc=0 leftovers=0" ]]; then
    pass "不存在的路径：在最近的已存在祖先里探测"
else
    fail "不存在路径的探针结果不对：$out"
fi

mkdir -p "$PROBE_ROOT/locked"
RO_DIRS+=("$PROBE_ROOT/locked")
chmod 555 "$PROBE_ROOT/locked"
out=$(probe_run "$PROBE_ROOT/locked")
if [[ "$out" == "rc=1 leftovers=0" ]]; then
    pass "不可写目录：判定需要提权"
else
    fail "不可写目录的探针结果不对：$out"
fi
chmod 755 "$PROBE_ROOT/locked"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All install privilege tests passed${RESET}"
