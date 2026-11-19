#!/bin/bash

# install_flags_test.sh
# `--help` 与 `--print-usage` 的分工，以及 --help 的连用规则。
#
# 两条命令长得像，做的事不一样：
#
#   --help          打用法，**停**在这里（不安装）
#   --print-usage   打用法，然后**继续**（真的安装，或继续 --dry-run）
#
# 而且 --help 只允许单独出现，或与 --dry-run 连用（先打用法、再走一遍流程）。
# 与其它安装参数连用要报错：`--help --ci --dir-option=2` 读起来像「按这些参数装」，
# 实际却只打帮助 —— 静默忽略比报错更容易让人以为装过了。
#
# 第 7 节另测「平台守卫」：非 macOS 时第一句就请用户去 LinuxWave，
# 连安装都不开始（给网站与安装命令，退出码 2）。
#
# 全程离线、隔离测试根、只用 --dry-run（或干脆什么都不做）。

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
trap 'rm -rf "$WORK"' EXIT

has() { case "$1" in (*"$2"*) return 0 ;; (*) return 1 ;; esac; }
hasnt() { case "$1" in (*"$2"*) return 1 ;; (*) return 0 ;; esac; }

# 版本数据必须能读到：它在**参数解析之前**就会去取，读不到时安装器直接退出，
# 那样连 --help 都轮不到。这里用 file:// 指一份最小的 latest.toml —— 离线，
# 且不会因为线上换版本而变红。
SELFUPDATE_DIR="$WORK/selfupdate"
mkdir -p "$SELFUPDATE_DIR/macwavedata"
printf 'version = "9.9.9"\nrelease_date = "2026-01-01"\nbuild_number = "TEST"\nbranch = "9.9"\n' \
    > "$SELFUPDATE_DIR/macwavedata/latest.toml"

# run_install <测试根名> [参数...]：输出放 ${OUT}，rc 放 ${RC}。
run_install() {
    local root="$WORK/$1"; shift
    mkdir -p "$root"
    OUT=$(MACWAVE_TEST="$root" \
          MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          /bin/bash "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

# -------------------- 1. --help 单独：打用法就停 --------------------

run_install help-alone --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "Dry run"; then
    pass "--help：只打用法，rc=0"
else
    fail "--help 的行为不对（rc=${RC}）"
fi

# 「不安装」的证据：没有安装树、也没有写配置。
# 注意 MACWAVE_TEST 的测试根里会先建一个 <根><HOME> 的空目录（那是隔离机制本身），
# 所以这里查的是「安装的产物」，不是「目录是否为空」。
if [[ ! -e "$WORK/help-alone/base" ]] \
   && [[ -z "$(find "$WORK/help-alone" -name config.json 2>/dev/null)" ]]; then
    pass "--help：没有安装树、也没有写配置"
else
    fail "--help 竟然产生了安装产物"
fi

# --help 不该碰网络：版本号请求排在参数解析之后，所以连版本源都连不上时，
# 它也必须能照常打出用法。这条是结构保证，不是巧合 —— 早先的写法是先取版本、
# 再解析参数，`--help` 在断网机器上会直接报「读不到版本号」。
OUT=$(MACWAVE_TEST="$WORK/help-offline" \
      MACWAVE_SELFUPDATE_DOMAIN="http://127.0.0.1:1" \
      /bin/bash "$INSTALL_SH" --help < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "Cannot read the latest version"; then
    pass "--help 不联网：版本源不可达时仍能打用法"
else
    fail "--help 仍然依赖版本源（rc=${RC}）"
fi

# -------------------- 2. --help 与呈现类旗标 --------------------

run_install help-zh --help --zh
if [[ "$RC" -eq 0 ]] && has "$OUT" "用法："; then
    pass "--help --zh：中文用法"
else
    fail "--help --zh 没打中文（rc=${RC}）"
fi

run_install help-raw --help --raw
# 注意：帮助正文里**提到** 🌊（--raw 的说明），所以只查行首有没有。
if [[ "$RC" -eq 0 ]] && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]] \
   && [[ "$(printf '%s\n' "$OUT" | grep -c "$(printf '\033')")" -eq 0 ]]; then
    pass "--help --raw：行首无 🌊、无 ANSI"
else
    fail "--help --raw 的输出不干净"
fi

# -------------------- 3. --help 与 --dry-run：先用法、再走流程 --------------------

run_install help-dry --help --dry-run
if hasnt "$OUT" "cannot be combined" && has "$OUT" "Usage:" && has "$OUT" "Dry run"; then
    pass "--help --dry-run：允许，先打用法再走试运行"
else
    fail "--help --dry-run 被拒或没继续（rc=${RC}）"
fi

# -------------------- 4. --help 与其它参数：必须报错 --------------------

run_install help-ci --help --ci
if [[ "$RC" -eq 1 ]] && has "$OUT" "cannot be combined with '--ci'"; then
    pass "--help --ci：报错并点名 --ci"
else
    fail "--help --ci 没有报错（rc=${RC}）"
fi

run_install help-dir --help --dir-option=1
if [[ "$RC" -eq 1 ]] && has "$OUT" "cannot be combined with '--dir-option=1'"; then
    pass "--help --dir-option=1：报错并点名该参数"
else
    fail "--help --dir-option=1 没有报错（rc=${RC}）"
fi

if has "$OUT" "--print-usage"; then
    pass "报错时指出 --print-usage 这条出路"
else
    fail "报错里没有提到 --print-usage"
fi

# -------------------- 5. --print-usage：打用法后继续 --------------------

run_install pu-dry --print-usage --dry-run --dir-option=1
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && has "$OUT" "Dry run"; then
    pass "--print-usage --dry-run：先用法，再继续试运行"
else
    fail "--print-usage --dry-run 的行为不对（rc=${RC}）"
fi

run_install pu-zh-raw --print-usage --zh --raw --dry-run --dir-option=1
if [[ "$RC" -eq 0 ]] && has "$OUT" "用法：" \
   && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]] \
   && [[ "$(printf '%s\n' "$OUT" | grep -c "$(printf '\033')")" -eq 0 ]]; then
    pass "--print-usage 也遵守 --zh 与 --raw"
else
    fail "--print-usage --zh --raw 的组合没按规矩输出（rc=${RC}）"
fi

# -------------------- 6. 未知选项仍然报错（回归） --------------------

run_install unknown --bogus-flag
if [[ "$RC" -eq 1 ]] && has "$OUT" "unknown option"; then
    pass "未知选项仍然报错"
else
    fail "未知选项没有报错（rc=${RC}）"
fi

# -------------------- 7. 平台守卫：非 macOS 请去 LinuxWave --------------------
#
# 用替身 uname 摆出「宿主是 Linux」：这个脚本里有太多 macOS 专属步骤
# （/usr/local 菜单项、SIP 与系统卷密封、csrutil、Xcode 工具），在 Linux 上装到
# 一半才报错是最差的形态。
#
# 这里**故意不设 MACWAVE_TEST** —— 那正是被绕过的条件（沙箱里宿主是不是 Linux
# 无所谓，CircleCI 的容器就这么跑）。

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/uname" <<'STUB'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    *) exec /usr/bin/uname "$@" ;;
esac
STUB
chmod +x "$STUB_BIN/uname"

mklinux() {
    # mklinux [参数...]：在「Linux 宿主」下跑一次，输出进 OUT，退出码进 RC
    rm -rf "$WORK/linux-root"
    OUT=$(PATH="$STUB_BIN:$PATH" \
          MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          /bin/bash "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

mklinux --dry-run --dir-option=1
if [[ "$RC" -eq 2 ]] \
   && has "$OUT" "LinuxWave" \
   && has "$OUT" "https://linuxwave.org" \
   && has "$OUT" "https://github.com/LinuxWaveOrg/LinuxWave/releases/latest/download/install.sh"; then
    pass "非 macOS：请用户去 LinuxWave，给出官网与完整安装命令（rc=2）"
else
    fail "非 macOS 的提示不对（rc=${RC}）：$(printf '%s' "$OUT" | head -2)"
fi

if [[ ! -e "$WORK/linux-root" ]] && [[ -z "$(find "$WORK" -maxdepth 1 -name 'linux-*' 2>/dev/null)" ]]; then
    pass "非 macOS：拒绝发生在任何安装动作之前（没有测试根、没有产物）"
else
    fail "非 macOS 时还是动了文件"
fi

mklinux --zh
if [[ "$RC" -eq 2 ]] && has "$OUT" "请改用 LinuxWave"; then
    pass "非 macOS --zh：提示是中文的"
else
    fail "非 macOS --zh 没有中文提示（rc=${RC}）"
fi

mklinux --raw
if [[ "$RC" -eq 2 ]] && [[ "$(printf '%s\n' "$OUT" | grep -c '^🌊')" -eq 0 ]]; then
    pass "非 macOS --raw：行首无 🌊（走的是同一个过滤器）"
else
    fail "非 macOS --raw 的输出不干净（rc=${RC}）"
fi

mklinux --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:" && hasnt "$OUT" "LinuxWave"; then
    pass "非 macOS --help：照常打用法，不被平台守卫拦住"
else
    fail "非 macOS --help 被拦住了（rc=${RC}）"
fi

# 沙箱里宿主是 Linux 完全正常：MACWAVE_TEST 一设，守卫就放行。
OUT=$(MACWAVE_TEST="$WORK/linux-sandbox" \
      MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
      PATH="$STUB_BIN:$PATH" \
      /bin/bash "$INSTALL_SH" --dry-run --dir-option=1 < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && has "$OUT" "Dry run" && hasnt "$OUT" "not macOS"; then
    pass "MACWAVE_TEST 下不判平台（沙箱里宿主是 Linux 也照跑）"
else
    fail "MACWAVE_TEST 下被平台守卫拦住了（rc=${RC}）"
fi

# -------------------- 7b. iOS / iPadOS：越狱设备上别让人白装一遍 --------------------
#
# iOS 也报 uname -s = Darwin，光看内核分不出越狱的 iPad 与 Mac，所以脚本会再问
# sw_vers -productName。这里用替身把它摆成 iOS（真机上没法造）。
write_uname() {
    printf '#!/bin/sh\ncase "$1" in\n  -s) echo %s ;;\n  *) exec /usr/bin/uname "$@" ;;\nesac\n' "$1" \
        > "$STUB_BIN/uname"
    chmod +x "$STUB_BIN/uname"
}
write_sw_vers() {
    printf '#!/bin/sh\ncase "$1" in\n  -productName) echo "%s" ;;\n  *) exit 1 ;;\nesac\n' "$1" \
        > "$STUB_BIN/sw_vers"
    chmod +x "$STUB_BIN/sw_vers"
}
run_bare() {
    # run_bare [参数...]：不设 MACWAVE_TEST，平台判断才会真的跑起来
    OUT=$(PATH="$STUB_BIN:$PATH" MACWAVE_SW_VERS="$STUB_BIN/sw_vers" \
          MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
          /bin/bash "$INSTALL_SH" "$@" < /dev/null 2>&1)
    RC=$?
}

write_uname Darwin
write_sw_vers iOS
run_bare --dry-run --dir-option=1
if [[ "$RC" -eq 2 ]] && has "$OUT" "iPhone or iPad" && has "$OUT" "targets macOS only"; then
    pass "iOS/iPadOS：认出越狱设备，说明为什么不该在这上面装（rc=2）"
else
    fail "iOS 的提示不对（rc=${RC}）：$(printf '%s' "$OUT" | head -2)"
fi

write_sw_vers macOS
run_bare --help
if [[ "$RC" -eq 0 ]] && has "$OUT" "Usage:"; then
    pass "Darwin + sw_vers 报 macOS：放行（没有被 iOS 判定误伤）"
else
    fail "正常 macOS 被平台守卫误伤（rc=${RC}）"
fi

# 认不出来的平台（FreeBSD / MSYS 之类）：说清「只支持 macOS」，别静默继续
write_uname FreeBSD
run_bare --dry-run --dir-option=1
if [[ "$RC" -eq 2 ]] && has "$OUT" "not recognised" && has "$OUT" "FreeBSD"; then
    pass "未知平台：报出 uname -s 的原值并拒绝（rc=2）"
else
    fail "未知平台的提示不对（rc=${RC}）"
fi

# -------------------- 7c. Android / ChromeOS：Linux 内核，但不是桌面 Linux --------------------
#
# 两者都报 uname -s = Linux。Android 靠 ANDROID_ROOT/ANDROID_DATA 与 getprop 认，
# ChromeOS 靠 /etc/lsb-release 里的 CHROMEOS_* 认（测试用 MACWAVE_CHROMEOS_RELEASE 指一份赝品）。

write_uname Linux
OUT=$(PATH="$STUB_BIN:$PATH" ANDROID_ROOT=/system \
      MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
      /bin/bash "$INSTALL_SH" --dry-run --dir-option=1 < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 2 ]] && has "$OUT" "Android" && has "$OUT" "Neither installs here"; then
    pass "Android：认出 bionic 上的 shell，说明两个项目都不装这里（rc=2）"
else
    fail "Android 的提示不对（rc=${RC}）：$(printf '%s' "$OUT" | head -2)"
fi

printf 'CHROMEOS_RELEASE_NAME=Chrome OS\nCHROMEOS_ARC_ANDROID_SDK_VERSION=30\n' > "$WORK/lsb-release"
OUT=$(PATH="$STUB_BIN:$PATH" MACWAVE_CHROMEOS_RELEASE="$WORK/lsb-release" \
      MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
      /bin/bash "$INSTALL_SH" --dry-run --dir-option=1 < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 2 ]] && has "$OUT" "ChromeOS" && has "$OUT" "https://linuxwave.org"; then
    pass "ChromeOS：认出容器，指向 LinuxWave（rc=2）"
else
    fail "ChromeOS 的提示不对（rc=${RC}）：$(printf '%s' "$OUT" | head -2)"
fi

# 一份不含 CHROMEOS_ 的 lsb-release（普通发行版）不该被误判
printf 'DISTRIB_ID=Ubuntu\nDISTRIB_RELEASE=22.04\n' > "$WORK/lsb-ubuntu"
OUT=$(PATH="$STUB_BIN:$PATH" MACWAVE_CHROMEOS_RELEASE="$WORK/lsb-ubuntu" \
      MACWAVE_SELFUPDATE_DOMAIN="file://$SELFUPDATE_DIR" \
      /bin/bash "$INSTALL_SH" --dry-run --dir-option=1 < /dev/null 2>&1)
RC=$?
if [[ "$RC" -eq 2 ]] && has "$OUT" "this machine is Linux" && hasnt "$OUT" "ChromeOS"; then
    pass "普通发行版（lsb-release 无 CHROMEOS_）：仍按 Linux 处理"
else
    fail "普通 Linux 被误判成 ChromeOS（rc=${RC}）"
fi

# 真 macOS 上不该出现这段提示（Linux runner 上这条不适用）
write_uname "$(uname -s)"
if [[ "$(uname -s)" == "Darwin" ]]; then
    run_install darwin-host --dry-run --dir-option=1
    if [[ "$RC" -eq 0 ]] && hasnt "$OUT" "LinuxWave"; then
        pass "macOS 宿主：不出现 LinuxWave 提示"
    else
        fail "macOS 宿主上误报了 LinuxWave（rc=${RC}）"
    fi
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All install flag tests passed${RESET}"
