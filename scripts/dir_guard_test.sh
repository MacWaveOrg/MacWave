#!/bin/bash

# dir_guard_test.sh
# 安装目录的白名单校验：哪些路径绝不能当安装根目录。
#
# 为什么单独测：装到系统目录时，install.sh 会
#
#   sudo chown -R "$CURRENT_USER": "$BASE_DIR"     # 让之后 wave install 不必提权
#   rm -rf "$BASE_DIR"                             # 拒绝协议时的回滚
#
# 如果 BASE_DIR 是 /usr/local 这种「别的软件的家」，这两件事分别是**把整个
# Homebrew 变成当前用户的**和**删掉它**。而旧版校验只挡了 `..`、控制字符、
# 非 ASCII、相对路径和 `/` —— `--dir-option=3=/usr/local` 能一路通过。
#
# 只测 validate_custom_dir 这一个纯函数：不跑安装、不碰网络、不需要 sandbox-exec，
# 所以任何机器上都能跑。
#
# 全程离线，秒级。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_DIR/lib/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: install.sh not found at $INSTALL_SH${RESET}"
    exit 1
fi

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 从 install.sh 里只抽出这两个函数。整个文件的顶层会执行安装流程，不能 source。
# validate_custom_dir 内部只有 if/fi 与 for/done，唯一顶格（无缩进）的 `}` 就是
# 函数结尾，所以按 `^}` 截断是安全的 —— 下面有一条断言盯着这件事。
extract() {
    sed -n "/^$1() {/,/^}/p" "$INSTALL_SH"
}

BODY="$(extract mw_say_err)
$(extract validate_custom_dir)"

# 这里只确认「抽到了」。黑名单在不在由第 6 组逐项断言 —— 混在一起报错会让人
# 以为抽取坏了，而实际是有人删了黑名单。
if [[ "$BODY" != *"validate_custom_dir"* ]]; then
    echo -e "${RED_BOLD}🌊 Error: 没能从 install.sh 抽出校验函数（函数结构可能变了）${RESET}"
    exit 1
fi

# 校验函数只依赖 mw_say_err 与 $HOME
probe() {
    bash -c 'source /dev/stdin <<< "$1"; validate_custom_dir "$2"' _ "$BODY" "$1" >/dev/null 2>&1
}

expect_reject() {
    local dir="$1" label="${2:-$1}"
    if probe "$dir"; then
        fail "${label} 被放行了（应当拒绝）"
    else
        pass "${label} 被拒绝"
    fi
}

expect_accept() {
    local dir="$1" label="${2:-$1}"
    if probe "$dir"; then
        pass "${label} 被放行"
    else
        fail "${label} 被拒绝了（应当放行）"
    fi
}

echo "========== 1. 系统目录本身：一律拒绝 =========="

# 这些是「别的软件的家」。chown -R 到这里 = 接管别人的文件；
# rm -rf 到这里 = 删掉别人的软件。
for dir in /bin /sbin /usr /usr/bin /usr/sbin /usr/lib /usr/libexec \
           /usr/local /usr/share /opt /etc /var /tmp /private \
           /System /Library /Applications /Users /Volumes /Network; do
    expect_reject "$dir"
done

echo
echo "========== 2. 家目录本身：拒绝 =========="

expect_reject "$HOME" '$HOME'

echo
echo "========== 3. 系统目录的子目录：放行 =========="

# 按完全相等判、不用前缀，正是为了保住这三个默认选项。
expect_accept /opt/macwave
expect_accept /usr/local/macwave
expect_accept "$HOME/.local/macwave"

echo
echo "========== 4. 已存在且非空、又不是 MacWave 的目录：拒绝 =========="

mkdir -p "$WORK/someone-else"
touch "$WORK/someone-else/their-file"
expect_reject "$WORK/someone-else"

# 空目录可以（新建的目录本来就是空的）
mkdir -p "$WORK/empty"
expect_accept "$WORK/empty"

# 已有的 MacWave 安装要能重装/升级 —— 判据是 lib/wave.py
mkdir -p "$WORK/macwave/lib"
touch "$WORK/macwave/lib/wave.py"
expect_accept "$WORK/macwave" "已有 MacWave 安装的目录"

echo
echo "========== 5. 原有校验不能丢 =========="

expect_reject "" "空路径"
expect_reject "/tmp/../etc" "路径穿越"
expect_reject "relative/path" "相对路径"
expect_reject "/" "根目录"
expect_reject "/tmp//double" "连续斜杠"

echo
echo "========== 6. 黑名单本身必须在（不能只靠「非空」兜底） =========="

# 上面第 1 组能通过，可能只是因为那些目录恰好非空（被第 4 组的规则挡下）。
# 但**空目录或不存在的系统目录**只能靠黑名单拦：`/opt` 在全新 macOS 上可能
# 为空甚至不存在，`/usr/local` 在没装 Homebrew 时压根没有。那种情况下
# `sudo chown -R` 会把一个空的系统目录接管过来，之后别人装东西进去就中招。
#
# 所以这里直接盯结构：黑名单必须逐项列出这些路径。
# 黑名单的写法是「空格分隔 + 反斜杠续行」，先拍平成一行再按词边界匹配。
FLAT=$(printf '%s\n' "$BODY" | tr '\n' ' ' | tr -d '\\')
for dir in /usr/local /opt /etc /usr /bin /System /Library; do
    if printf '%s' "$FLAT" | grep -qE "(^|[[:space:]])$dir([[:space:]]|$)"; then
        pass "黑名单包含 ${dir}"
    else
        fail "黑名单缺少 ${dir}（空目录时会被接管）"
    fi
done

echo
echo "========== 7. 系统级安装：管理员可写，其他人只读 =========="

# 目标模型：管理员能装能删，其他用户只能运行。
#
# 所以安装树归 root:<管理员组>、755 —— 组可写与 ACL 继承都不需要：管理员本来就
# 知道密码、本来就能 sudo。反过来，把系统 PATH 里的二进制做成组可写是白白多一层
# 风险，收益不抵。
#
# 代价是系统级安装下 `wave install` 要 sudo，因此运行时必须**先检查可写性**并把
# 原因说清楚 —— 否则报错会落在下载那一步、被归因成网络问题。

if grep -q 'chown -R "root:' "$INSTALL_SH"; then
    pass "安装树归 root:<管理员组>"
else
    fail "安装树没有归 root"
fi

if grep -qE 'chmod -R u\+rwX,go\+rX,go-w' "$INSTALL_SH"; then
    pass "755 语义：所有人可读可执行，组不可写"
else
    fail "权限没有收敛成 755 语义"
fi

if grep -qE 'chown -R "\$CURRENT_USER": "\$BASE_DIR"' "$INSTALL_SH"; then
    fail "仍然把安装树 chown 给当前用户"
else
    pass "不再把安装树 chown 给当前用户"
fi

# 运行时（不是安装脚本）要有可写性前置检查，报错要能直接照抄命令
PY_INSTALLER="$REPO_DIR/pkg/pkginstaller.py"
if grep -q 'no write permission' "$PY_INSTALLER"; then
    pass "运行时检查安装树可写性"
else
    fail "运行时不检查可写性，只读树会在下载步骤报错并被归因成网络问题"
fi

if grep -q 'sudo {_invoked_as()}' "$PY_INSTALLER"; then
    pass "提示里给出可照抄的 sudo 命令"
else
    fail "提示里没有 sudo 命令"
fi

# 提示必须说清「其他用户仍可运行」，否则读者会以为整台机器都用不了
if grep -q 'still run the installed packages' "$PY_INSTALLER"; then
    pass "说明其他人仍可运行"
else
    fail "没有说明其他用户仍可运行"
fi

# 「其他人可运行」还差一步：PATH 归每个用户自己加（4.3 起安装器不再写 rc），
# 别人不加就找不到 wave。安装结束时必须把这一行印出来。
if grep -q 'each of them needs to run' "$INSTALL_SH"; then
    pass "安装结束时提示其他用户怎么加 PATH"
else
    fail "没有提示其他用户如何把 links 加进 PATH"
fi

if grep -q 'Changing packages (install / uninstall / upgrade) needs sudo' "$INSTALL_SH"; then
    pass "说明改动软件包需要 sudo"
else
    fail "没有说明改动软件包需要 sudo"
fi

echo
echo "========== 8. 抽函数的方式本身要可靠 =========="

# 上面所有断言都建立在「extract 抽对了」之上。如果 install.sh 里
# validate_custom_dir 被改成有顶格的 `}`（例如嵌套 heredoc），抽取会截断，
# 断言就全变成假的。这里数一下抽出来的行数是否合理。
LINES=$(printf '%s\n' "$BODY" | wc -l | tr -d ' ')
if [[ "$LINES" -ge 40 ]]; then
    pass "抽出的函数体行数合理（${LINES} 行）"
else
    fail "抽出的函数体只有 ${LINES} 行，可能被截断了"
fi

echo
echo "========== 9. selfupdate 也要把系统级安装树交给 root =========="

# 4.3.0 只让 install.sh 做了这一步。升级是最常见的路径：`wave selfupdate`
# 若不迁移属主，升级上来的机器仍然「用户可写系统 PATH 上的二进制」，② 没修好。
SELFUPDATE_SH="$REPO_DIR/lib/selfupdate.sh"

if [[ -f "$SELFUPDATE_SH" ]]; then
    pass "selfupdate.sh 存在"
else
    fail "找不到 $SELFUPDATE_SH"
fi

if grep -q 'hand_over_system_install "\$BASE_DIR"' "$SELFUPDATE_SH"; then
    pass "selfupdate 调用了属主迁移"
else
    fail "selfupdate 没有把安装树交给 root（升级路径上的 ② 仍然成立）"
fi

if grep -q 'chown -R "root:' "$SELFUPDATE_SH" && \
   grep -q 'chmod -R u+rwX,go+rX,go-w' "$SELFUPDATE_SH"; then
    pass "selfupdate 与 install.sh 用同一套所有权模型"
else
    fail "selfupdate 的属主/权限规则与 install.sh 不一致"
fi

# 顺序：迁移必须在所有写树的动作之后。反了的话，迁移之后的写入要用 sudo，
# 本次升级会自己卡死；更糟的是先 chown 再写，写出来的文件又回到用户所有。
LAUNCHER_LINE=$(grep -n 'write_launcher "\$BASE_DIR"' "$SELFUPDATE_SH" | head -1 | cut -d: -f1)
HANDOVER_LINE=$(grep -n 'hand_over_system_install "\$BASE_DIR"' "$SELFUPDATE_SH" | head -1 | cut -d: -f1)
if [[ -n "$LAUNCHER_LINE" && -n "$HANDOVER_LINE" && "$HANDOVER_LINE" -gt "$LAUNCHER_LINE" ]]; then
    pass "属主迁移在写 launcher 之后（${LAUNCHER_LINE} < ${HANDOVER_LINE}）"
else
    fail "属主迁移的位置不对（launcher=${LAUNCHER_LINE:-?}, handover=${HANDOVER_LINE:-?}）"
fi

# 行为：把两个函数抽出来，用假的 sudo 观察它到底下发了什么命令。
SELF_BODY="$(sed -n '/^admin_group() {/,/^}/p' "$SELFUPDATE_SH")
$(sed -n '/^hand_over_system_install() {/,/^}/p' "$SELFUPDATE_SH")"

if [[ "$SELF_BODY" != *hand_over_system_install* || "$SELF_BODY" != *admin_group* ]]; then
    fail "没能从 selfupdate.sh 抽出 admin_group / hand_over_system_install"
else
    pass "抽出了 admin_group 与 hand_over_system_install"
fi

mkdir -p "$WORK/bin"
SUDO_LOG="$WORK/sudo.log"
cat > "$WORK/bin/sudo" <<'SHIM'
#!/bin/bash
# 记录调用；chown/chmod 只记录不执行（测试里没有 root，执行必然失败），
# rm 之类照常执行 —— 测试目录都在 $WORK 里，删掉是预期的。
printf '%s\n' "$*" >> "$SUDO_LOG"
case "$1" in
    chown|chmod) exit 0 ;;
esac
exec "$@"
SHIM
chmod 755 "$WORK/bin/sudo"

probe_handover() {   # probe_handover <need_sudo> <dir>
    : > "$SUDO_LOG"
    PATH="$WORK/bin:$PATH" SUDO_LOG="$SUDO_LOG" \
        bash -c 'source /dev/stdin <<< "$1"; NEED_SUDO="$2"; CURRENT_USER="$(whoami)"; hand_over_system_install "$3"' \
        _ "$SELF_BODY" "$1" "$2" >/dev/null 2>&1
    cat "$SUDO_LOG"
}

TARGET="$WORK/sys-level-macwave"
mkdir -p "$TARGET/lib"

CALLS=$(probe_handover true "$TARGET")
if [[ "$CALLS" == *"chown -R root:"*"$TARGET"* ]]; then
    pass "系统级：把树交给 root"
else
    fail "系统级没有下发 chown root（实际：${CALLS:-无}）"
fi
if [[ "$CALLS" == *"chmod -R u+rwX,go+rX,go-w"*"$TARGET"* ]]; then
    pass "系统级：权限收敛成 755 语义"
else
    fail "系统级没有下发 755 的 chmod（实际：${CALLS:-无}）"
fi

CALLS=$(probe_handover false "$TARGET")
if [[ -z "$CALLS" ]]; then
    pass "用户级安装不动属主"
else
    fail "用户级安装也动了属主（实际：${CALLS}）"
fi

echo
echo "========== 10. uninstall 只删真正的 MacWave 树 =========="

# base_dir 来自 config.json，而用户级配置对任何以该用户身份运行的进程都可写。
# 不校验就拿去 `sudo rm -rf`，一条被改过的 base_dir 就能删掉 /usr/local。
UNINSTALL_SH="$REPO_DIR/lib/uninstall.sh"

if grep -q 'skip_reason' "$UNINSTALL_SH" && grep -q 'lib/wave.py' "$UNINSTALL_SH"; then
    pass "uninstall 有「是不是 MacWave 树」的判据"
else
    fail "uninstall 仍然直接 rm -rf 配置里的 base_dir"
fi

# 必须跑副本，而且每次都要重新拷：卸载脚本收尾时会删掉自己（$0，判据是内容里
# 有 "MacWave Uninstaller"）。直接跑仓库里那份，等于把 lib/uninstall.sh 从工作区
# 删掉 —— 已经踩过一次；同一个副本跑第二次会找不到文件。
run_uninstall() {   # run_uninstall <测试根>
    local copy="$WORK/uninstall-copy.sh"
    cp "$UNINSTALL_SH" "$copy"
    PATH="$WORK/bin:$PATH" SUDO_LOG="$SUDO_LOG" MACWAVE_TEST="$1" \
        bash "$copy" --force 2>&1
}

# 真实跑一遍：两个目录，一个像 MacWave、一个不像。
UBOX="$WORK/uninstall"
mkdir -p "$UBOX/opt/macwave_config"
DECOY="$UBOX/usr/local"
mkdir -p "$DECOY" && echo keep > "$DECOY/precious.txt"
REAL="$UBOX/opt/macwave"
mkdir -p "$REAL/lib" && echo x > "$REAL/lib/wave.py"

printf '{"base_dir": "%s"}\n' "$DECOY" > "$UBOX/opt/macwave_config/config.json"
OUT=$(run_uninstall "$UBOX")
if [[ -f "$DECOY/precious.txt" ]]; then
    pass "非 MacWave 目录没被删"
else
    fail "非 MacWave 目录被删掉了"
fi
if [[ "$OUT" == *"Skipping"* && "$OUT" == *"not a MacWave install"* ]]; then
    pass "跳过时点名了原因"
else
    fail "跳过了却没点名原因（实际：${OUT:0:200}）"
fi

mkdir -p "$UBOX/opt/macwave_config"
printf '{"base_dir": "%s"}\n' "$REAL" > "$UBOX/opt/macwave_config/config.json"
run_uninstall "$UBOX" >/dev/null 2>&1
if [[ ! -d "$REAL" ]]; then
    pass "真正的 MacWave 树照常卸载"
else
    fail "真正的 MacWave 树没被删掉（正常卸载被挡住了）"
fi

# 家目录本身永远不能删，哪怕它里面碰巧有 lib/wave.py。
# 注意沙箱里的家目录是 "$测试根$HOME"（uninstall.sh 会把 HOME 搬到测试根下），
# 不是 $UBOX/home —— 写错了就会「测了一个普通目录」，断言看起来很绿。
HOME_TREE="$UBOX$HOME"
mkdir -p "$HOME_TREE/lib" && echo x > "$HOME_TREE/lib/wave.py"
mkdir -p "$UBOX/opt/macwave_config"
printf '{"base_dir": "%s"}\n' "$HOME_TREE" > "$UBOX/opt/macwave_config/config.json"
HOME_OUT=$(run_uninstall "$UBOX" 2>&1)
if [[ -d "$HOME_TREE/lib" ]]; then
    pass "家目录本身不会被当成安装树删掉"
else
    fail "家目录被当安装树删掉了"
fi
if [[ "$HOME_OUT" == *"your home directory"* ]]; then
    pass "家目录被拒时说的是「家目录」，不是笼统的「不是 MacWave 树」"
else
    fail "家目录被拒的理由不对（实际：${HOME_OUT:0:200}）"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All directory-guard tests passed${RESET}"
