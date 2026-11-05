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
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All directory-guard tests passed${RESET}"
