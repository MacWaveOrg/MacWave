#!/bin/bash

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/lib/install.sh)"
# Unattended (CI): /bin/bash -c "$(curl -fsSL .../main/lib/install.sh)" -- --ci --dir-option=1

# -------------------- 测试根（隔离） --------------------
# MACWAVE_TEST 指向一个目录时，把它当作 /：HOME 和所有系统路径都挂到它下面，
# 整条链路都落在那个目录里，完全不碰真实系统。
# 没设置时 SYS_ROOT 为空，下面 "$SYS_ROOT/opt/..." 就还是 "/opt/..."，行为不变。
SYS_ROOT=""
if [[ -n "${MACWAVE_TEST:-}" ]]; then
    _mw_root="$MACWAVE_TEST"
    if [[ "$_mw_root" == "~"* ]]; then
        _mw_root="${HOME}${_mw_root#\~}"
    fi
    mkdir -p "$_mw_root"
    # 物理路径：macOS 上 /var 是指向 /private/var 的符号链接，这里若用逻辑路径，
    # 与下面比较用的 HOME（configpaths 已经 resolve 过）对不上，前缀判断就会失效。
    SYS_ROOT="$(cd "$_mw_root" && pwd -P)"
    # 幂等：lib/configpaths.py 也会把 HOME 搬进测试根。从 wave.py 一路调用下来时
    # HOME 已经被改过一次，这里再套一层就会变成 "<根><根>/Users/<你>"，配置目录于是
    # 永远找不到。两边都取物理路径再比较，才不会被 /var 与 /private/var 骗过去。
    _mw_home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || _mw_home_real="$HOME"
    case "$_mw_home_real" in
        "$SYS_ROOT"|"$SYS_ROOT"/*) ;;
        *) export HOME="$SYS_ROOT${HOME}" ;;
    esac
    export MACWAVE_TEST_ROOT="$SYS_ROOT"
    mkdir -p "$HOME"
    echo "🌊 Test root: $SYS_ROOT"
fi

set -eE

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# ==========================================
# 域名（4.0：每个对外地址都能用环境变量换掉）
# ==========================================
#
# 与 lib/domains.py 是同一张表，一份给 Python、一份给 shell：install.sh 是
# `curl | bash` 直接执行的，没有本地文件可以 source，只能在这里重复一遍。
# 默认值仍是 3.x 在用的地址，一个变量都不设时行为与 3.x 完全一致。
#
# 这一段必须与 lib/selfupdate.sh 逐字一致 —— scripts/domains_test.sh 有断言。

mw_domain() {
    # mw_domain <变量名> <值>：校验协议、去掉末尾斜杠，然后打印规范化后的值
    local name="$1"
    local value="$2"

    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done

    case "$value" in
        https://?*|file://?*) printf '%s\n' "$value"; return 0 ;;
        # 明文 http 只给本机镜像（离线测试、本机代理）
        http://127.0.0.1:?*|http://localhost:?*) printf '%s\n' "$value"; return 0 ;;
    esac

    echo -e "${RED_BOLD}🌊 Error: $name must be an https:// (or file://) address, got: $value${RESET}" >&2
    exit 1
}

mw_redact() {
    # mw_redact <url>：把 URL 里的口令换成 ***，日志与报错里不能出现明文。
    # 只在 host 段找 @ —— path 里的 @ 是合法文件名（jq@1.7.1.arm64）。
    local url="$1"
    local scheme rest authority path userinfo host user

    case "$url" in
        *://*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    scheme="${url%%://*}"
    rest="${url#*://}"
    authority="${rest%%/*}"
    if [[ "$rest" == */* ]]; then path="/${rest#*/}"; else path=""; fi

    case "$authority" in
        *@*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    userinfo="${authority%@*}"
    host="${authority##*@}"
    user="${userinfo%%:*}"
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s\n' "$scheme" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s\n' "$scheme" "$host" "$path"
    fi
}

# pip 依赖（requests / packaging / rich）不在我们自己的存储里，仍走 PyPI。
# 国内直连 pypi.org 常超时，所以留一个可覆盖的索引地址：默认官方，设了就换。
#
# 与上面六个变量的差别：它不参与「MacWave 从哪取文件」的判断，只影响 pip 一次调用，
# 所以校验规则更松（允许 https 与 http 回环，与 mw_domain 同）。
PIP_INDEX_URL="$(mw_domain MACWAVE_PIP_INDEX "${MACWAVE_PIP_INDEX:-https://pypi.org/simple}")"

# MacWave 自身文件（后面再拼 /<分支>/<路径>）
CORE_URL="$(mw_domain MACWAVE_CORE_DOMAIN "${MACWAVE_CORE_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/MacWave}")"
# 自更新数据：版本号、文件清单、目录迁移脚本
SELFUPDATE_URL="$(mw_domain MACWAVE_SELFUPDATE_DOMAIN "${MACWAVE_SELFUPDATE_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/main}")"
# 自带 CPython 的清单
# 解释器单独一个仓库（体积与发布节奏都和自更新数据不同）
PYTHON_DOMAIN_URL="$(mw_domain MACWAVE_PYTHON_DOMAIN "${MACWAVE_PYTHON_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Python/main}")"

# ==========================================
# 版本号与代码分支（从自更新数据读取，不写死在脚本里）
# ==========================================
#
# macwavedata/latest.toml 里的 version 是这次要安装的版本，branch 是配套的代码分支：
# 两者一起读，保证「下载的代码」和「写进 VERSION.json 的版本号」对应同一个版本。
#
# 格式是 TOML 的一个子集：平铺的 `key = "value"`，允许行尾 # 注释。
# 这里用 sed 而不是引 TOML 解析器，因为此刻客户端还没有可用的 Python 环境。

LATEST_DATA_URL="$SELFUPDATE_URL/macwavedata/latest.toml"
LATEST_VERSION_DATA="$(curl -fsSL --max-time 30 "$LATEST_DATA_URL" 2>/dev/null)"

read_toml_string() {
    # read_toml_string <文本> <键> —— 取平铺的字符串值，去掉引号与行尾注释
    printf '%s\n' "$1" \
        | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

MACWAVE_VERSION="$(read_toml_string "$LATEST_VERSION_DATA" version)"
LATEST_BRANCH="$(read_toml_string "$LATEST_VERSION_DATA" branch)"

if [[ -z "$MACWAVE_VERSION" || -z "$LATEST_BRANCH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot read the latest version from the self-update data.${RESET}" >&2
    echo -e "${RED_BOLD}🌊   $(mw_redact "$LATEST_DATA_URL")${RESET}" >&2
    echo -e "${RED_BOLD}🌊 Check your network or proxy, then run the installer again.${RESET}" >&2
    exit 1
fi

BRANCH="$LATEST_BRANCH"
BASE_URL="$CORE_URL/$BRANCH"

# ==========================================
# 辅助函数：将路径中的 $HOME 替换为 ~
# ==========================================

home_to_tilde() {
    local path="$1"
    if [[ "$path" == "$HOME"* ]]; then
        echo "~${path#$HOME}"
    else
        echo "$path"
    fi
}

# ==========================================
# 辅助函数：校验自定义目录，防止路径穿越
# ==========================================

validate_custom_dir() {
    local dir="$1"

    if [[ -z "$dir" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Empty path is not allowed.${RESET}" >&2
        return 1
    fi

    if [[ "$dir" == *".."* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Path traversal ('..') is not allowed.${RESET}" >&2
        return 1
    fi

    if [[ "$dir" == *$'\n'* ]] || [[ "$dir" == *$'\r'* ]] || [[ "$dir" == *$'\t'* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Invalid control characters in path.${RESET}" >&2
        return 1
    fi

    if LC_ALL=C grep -q '[^a-zA-Z0-9/_.~ -]' <<< "$dir"; then
        echo -e "${RED_BOLD}🌊 Error: Path contains non-ASCII or invalid characters.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Only ASCII letters, digits, '/', '-', '_', '.', '~', and spaces are allowed.${RESET}" >&2
        return 1
    fi

    local expanded="${dir/#\~/$HOME}"

    if [[ "$expanded" != /* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Please use an absolute path (starting with / or ~).${RESET}" >&2
        return 1
    fi

    if [[ "$expanded" == *"//"* ]]; then
        echo -e "${RED_BOLD}🌊 Error: Path contains consecutive slashes.${RESET}" >&2
        return 1
    fi

    if [[ "$expanded" == "/" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot install to root directory.${RESET}" >&2
        return 1
    fi

    echo "$expanded"
    return 0
}

# ==========================================
# 系统架构与目录菜单
# ==========================================
#
# 菜单项数随架构变化：Intel 机器多提供一个 /usr/local/macwave
# （Apple 芯片上不建议写入 /usr/local，因此只对 Intel 提供），
# 自定义目录的编号也随之变化，所以这里统一算好。

ARCH=$(uname -m)

if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
    CUSTOM_OPTION=4
else
    CUSTOM_OPTION=3
fi

print_dir_menu() {
    echo "1. ~/.local/macwave"
    echo "2. /opt/macwave"
    if [[ "$CUSTOM_OPTION" == "4" ]]; then
        echo "3. /usr/local/macwave"
    fi
    echo "$CUSTOM_OPTION. other (enter custom directory)"
}

# ==========================================
# 命令行参数（批量 / 脚本化安装）
# ==========================================

CLI_CI=false
CLI_DIR_OPTION=""
CLI_CUSTOM_DIR=""
# 默认从我们自己的 Python 仓库取解释器；这个开关让它回上游取
INSTALL_PYTHON_FROM_SOURCE=""

usage() {
    cat <<USAGE_EOF
MacWave installer

Usage:
  install.sh [options]

Options:
      --ci, --CI          No interaction at all: the directory menu and the
                          agreement are answered automatically. Without
                          --dir-option the default (option 1) is used.
                          Requires passwordless sudo when privilege is needed.
      --dir-option=N      Pick menu entry N without prompting (1-$CUSTOM_OPTION).
      --dir-option=DIR    Use DIR as the installation directory (shorthand for
                          --dir-option=$CUSTOM_OPTION=DIR).
      --dir-option=N=DIR  Pick entry N and, for the custom entry ($CUSTOM_OPTION), use DIR
                          as the installation directory.
        --install-python-from-source
                            Download the bundled CPython from its upstream URL
                            (recorded in pythondata/<version>/python_url.toml)
                            instead of from MacWave's own Python repository.
  -h, --help              Show this help.

Directory menu:
$(print_dir_menu | sed 's/^/  /')

Examples:
  install.sh --ci --dir-option=1
  install.sh --CI --dir-option=2
  install.sh --ci --dir-option=$CUSTOM_OPTION=/opt/my-macwave
  install.sh --ci --dir-option=/opt/my-macwave

Running it straight from the repository (options go after '--'):
  /bin/bash -c "\$(curl -fsSL <url>)" -- --ci --dir-option=1
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci|--CI)
            CLI_CI=true
            ;;
        --dir-option=*)
            _value="${1#--dir-option=}"
            # 只有 N=DIR（前缀是数字）才拆分；--dir-option=<路径> 里若本身带 '='，
            # 整条按路径处理，不会被误拆。
            if [[ "$_value" == *=* && "${_value%%=*}" =~ ^[0-9]+$ ]]; then
                CLI_DIR_OPTION="${_value%%=*}"
                CLI_CUSTOM_DIR="${_value#*=}"
            else
                CLI_DIR_OPTION="$_value"
            fi
            ;;
        --install-python-from-source)
            INSTALL_PYTHON_FROM_SOURCE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Error: unknown option '$1'. Try --help.${RESET}" >&2
            exit 1
            ;;
    esac
    shift
done

# 通过管道安装时，选项很容易被当成脚本名传进来：
#   bash -c "$(curl ...)" --ci         ← --ci 变成 $0，被静默丢掉
# 这里明确提示，避免「静默模式没生效、脚本却卡在交互上」。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        echo -e "${YELLOW}🌊 Warning: '$0' was treated as the script name, not as an option.${RESET}" >&2
        echo -e "${YELLOW}🌊 Put installer options after '--', which ends bash's own options.${RESET}" >&2
        echo "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" >&2
        ;;
esac

# --dir-option=<路径> 是 --dir-option=<自定义项>=<路径> 的简写：值不是数字时，
# 直接把该值当作自定义安装目录。
if [[ -n "$CLI_DIR_OPTION" && ! "$CLI_DIR_OPTION" =~ ^[0-9]+$ ]]; then
    CLI_CUSTOM_DIR="$CLI_DIR_OPTION"
    CLI_DIR_OPTION="$CUSTOM_OPTION"
fi

if [[ -n "$CLI_DIR_OPTION" ]] && [[ "$CLI_DIR_OPTION" -lt 1 || "$CLI_DIR_OPTION" -gt "$CUSTOM_OPTION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option must be 1-$CUSTOM_OPTION on this architecture, got '$CLI_DIR_OPTION'.${RESET}" >&2
    exit 1
fi

if [[ -n "$CLI_CUSTOM_DIR" && "$CLI_DIR_OPTION" != "$CUSTOM_OPTION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: only --dir-option=$CUSTOM_OPTION takes a directory (this architecture has $CUSTOM_OPTION entries).${RESET}" >&2
    exit 1
fi

if [[ "$CLI_DIR_OPTION" == "$CUSTOM_OPTION" && -z "$CLI_CUSTOM_DIR" && "$CLI_CI" == "true" ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option=$CUSTOM_OPTION needs a directory in --ci mode.${RESET}" >&2
    echo -e "${RED_BOLD}🌊 Use --dir-option=$CUSTOM_OPTION=/some/dir${RESET}" >&2
    exit 1
fi

# 解析自定义安装目录：命令行给了就直接用，否则提示输入
resolve_custom_dir() {
    local custom_dir validated
    if [[ -n "$CLI_CUSTOM_DIR" ]]; then
        custom_dir="$CLI_CUSTOM_DIR"
        echo "🌊 Installation directory: $custom_dir (from --dir-option)"
    else
        echo -e "${YELLOW}Please enter the installation directory:${RESET}"
        read -r custom_dir < /dev/tty
    fi
    validated=$(validate_custom_dir "$custom_dir") || exit 1
    BASE_DIR="$validated"
}

# ==========================================
# 显示欢迎信息
# ==========================================

echo "🌊 Welcome to MacWave $MACWAVE_VERSION!"

if [[ "$CORE_URL" != "https://raw.githubusercontent.com/MacWaveOrg/MacWave" ]]; then
    echo "🌊 Install from mirror: $(mw_redact "$CORE_URL")"
fi

echo ""

echo "🌊 Detected architecture: $ARCH"

# ==========================================
# 选择安装目录（交互式 / --dir-option / --ci 默认）
# ==========================================

if [[ -n "$CLI_DIR_OPTION" ]]; then
    choice="$CLI_DIR_OPTION"
    echo "🌊 Directory option: $choice (from --dir-option)"
elif [[ "$CLI_CI" == "true" ]]; then
    choice="1"
    echo "🌊 --ci: using the default directory option 1."
else
    echo -e "${YELLOW}Where do you want to install MacWave? (Enter the number)${RESET}"
    print_dir_menu
    echo ""
    echo -e "${YELLOW}Enter your choice:${RESET}"

    read -r choice < /dev/tty
fi

case "$choice" in
    1)
        BASE_DIR="$HOME/.local/macwave"
        ;;
    2)
        BASE_DIR="$SYS_ROOT/opt/macwave"
        ;;
    3)
        if [[ "$CUSTOM_OPTION" == "3" ]]; then
            resolve_custom_dir
        else
            BASE_DIR="$SYS_ROOT/usr/local/macwave"
        fi
        ;;
    4)
        resolve_custom_dir
        ;;
    *)
        echo -e "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/macwave${RESET}"
        BASE_DIR="$HOME/.local/macwave"
        ;;
esac

DISPLAY_DIR=$(home_to_tilde "$BASE_DIR")

# ==========================================
# 判断是否需要 sudo
# ==========================================

CURRENT_USER=$(whoami)

if [[ "$BASE_DIR" == "$HOME"* ]]; then
    NEED_SUDO=false
else
    NEED_SUDO=true
fi

run_cmd() {
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

if [[ "$NEED_SUDO" == "true" ]]; then
    if [[ "$CLI_CI" == "true" ]]; then
        # --ci 不能停下来等密码：要么已经是 root，要么已有免密 sudo
        if ! sudo -n true 2> /dev/null; then
            echo -e "${RED_BOLD}🌊 Error: this install needs privilege, but --ci cannot ask for a password.${RESET}" >&2
            echo -e "${RED_BOLD}🌊 Run as root, or configure passwordless sudo for the install user.${RESET}" >&2
            exit 1
        fi
    else
        echo -e "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}"
        sudo -v
    fi
fi

# ==========================================
# 更新脚本（macwavedata/<版本>/update_commands.sh）
# ==========================================
#
# 要下载哪些文件、放到哪里，以前是客户端读一份 files_info 自己解析。现在改成
# 由自更新数据提供一个脚本，客户端只负责取回来执行：
#
#   - 脚本自己知道这一版该下哪些文件，所以能只列变动的那些（没碰过的文件不必重下）；
#   - 目录结构变更的迁移也写在同一个脚本里，不必再维护第二套机制；
#   - 客户端不再需要「缩进树」这种自定义格式的解析器。
#
# 这一步刻意放在「建目录 / 写配置 / 清旧版」之前：连不上自更新数据就直接退出，
# 不会留下一个配置已写好、文件却一个都没下的半成品安装。

UPDATE_COMMANDS_URL="$SELFUPDATE_URL/macwavedata/$MACWAVE_VERSION/update_commands.sh"
UPDATE_COMMANDS_TMP="$(mktemp)"

cleanup_update_commands() {
    rm -f "$UPDATE_COMMANDS_TMP"
}
trap cleanup_update_commands EXIT

echo "🌊 Fetching the update commands..."

UPDATE_COMMANDS_OK=false
for attempt in 1 2 3; do
    if curl -fsSL --max-time 60 -o "$UPDATE_COMMANDS_TMP" "$UPDATE_COMMANDS_URL"; then
        UPDATE_COMMANDS_OK=true
        break
    fi
    if [[ "$attempt" -lt 3 ]]; then
        echo -e "${YELLOW}🌊 Retrying the update commands ($((attempt + 1))/3)...${RESET}"
    fi
done

if [[ "$UPDATE_COMMANDS_OK" != "true" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot fetch the update commands.${RESET}"
    echo -e "${RED_BOLD}🌊   $(mw_redact "$UPDATE_COMMANDS_URL")${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was installed. Check your network or proxy, then run the installer again.${RESET}"
    exit 1
fi

if ! bash -n "$UPDATE_COMMANDS_TMP" 2>/dev/null; then
    echo -e "${RED_BOLD}🌊 Error: the update commands for $MACWAVE_VERSION are not valid shell.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was installed. Please report this to the administrator.${RESET}"
    exit 1
fi

# ==========================================
# 创建目录
# ==========================================

INSTALL_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"
REPO_DIR="$BASE_DIR/pkg"
SURFBOARD_DIR="$BASE_DIR/surfboard"
LIB_DIR="$BASE_DIR/lib"
DEPS_DIR="$BASE_DIR/deps"
DOWNLOAD_DIR="$BASE_DIR/downloads/tmp"

# 配置文件目录：装到系统目录（需要 sudo）时用 /opt/macwave_config，
# 装到用户目录（无需 sudo）时用 ~/.config/macwave_config。
# 读取时系统级优先，所以系统级 MacWave 总是盖过用户级的。
if [[ "$NEED_SUDO" == "true" ]]; then
    CONFIG_DIR="$SYS_ROOT/opt/macwave_config"
else
    CONFIG_DIR="$HOME/.config/macwave_config"
fi
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

MW_OPTIONAL_RESULT=""

mw_try() {
    # mw_try <命令...>：跑一个「失败也无所谓」的命令，stdout 存进 MW_OPTIONAL_RESULT。
    # 失败时不惊动 ERR trap —— 否则用户会先看到「Installation did not finish」，
    # 几百行之后再看到「Installation complete!」，比不提示更糟。
    #
    # 旗标必须在**命令替换的整个生命周期内**保持设置：`set -E` 让 ERR trap 传进
    # 子 shell，而子 shell 退出时如果那条命令返回非零，trap 照样会响。所以赋值写进
    # 本函数内部，而不是让调用方写 `X="$(mw_try ...)"`。
    local output
    MW_FAILURE_HANDLED=1
    output="$("$@")" && MW_OPTIONAL_RESULT="$output" || MW_OPTIONAL_RESULT=""
    unset MW_FAILURE_HANDLED
    return 0
}

# 中途失败时给出明确指引。刻意**不自动删除**已下载的内容：升级安装时
# 删掉安装树会把用户原有的可用安装一起毁掉，重跑安装器才是安全的做法。
install_failed() {
    local code=$?

    # 有些失败是**预期之内**的：自带解释器取不到时会回落到系统 python3，
    # 安装照常完成。那些地方用 mw_optional 包着，会临时立这个旗标，
    # 于是这里不报「安装未完成」—— 否则用户看到的是「安装失败」接着
    # 「Installation complete!」，比没有提示更糟。
    if [[ -n "${MW_FAILURE_HANDLED:-}" ]]; then
        return 0
    fi

    echo "" >&2
    echo -e "${RED_BOLD}🌊 Installation did not finish (exit $code).${RESET}" >&2
    echo "🌊 Nothing was removed. Files already downloaded may be left in:" >&2
    echo "     ${BASE_DIR:-<not chosen yet>}" >&2
    echo "     ${CONFIG_DIR:-<not chosen yet>}" >&2
    echo "🌊 Fix the cause (network, permissions, disk space) and run the installer again;" >&2
    echo "🌊 a repeated install overwrites what it downloaded and is safe to rerun." >&2
}
trap install_failed ERR

run_cmd mkdir -p "$INSTALL_DIR"
run_cmd mkdir -p "$LINKS_DIR"
run_cmd mkdir -p "$REPO_DIR"
run_cmd mkdir -p "$SURFBOARD_DIR"
run_cmd mkdir -p "$LIB_DIR"
run_cmd mkdir -p "$DEPS_DIR"
run_cmd mkdir -p "$DOWNLOAD_DIR"
run_cmd mkdir -p "$CONFIG_DIR"
run_cmd chmod 755 "$CONFIG_DIR"

# ==========================================
# 写入配置文件
# ==========================================

run_cmd tee "$CONFIG_FILE" > /dev/null << EOF
{
  "base_dir": "$BASE_DIR"
}
EOF

run_cmd tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "$MACWAVE_VERSION",
  "components": {
    "installer": "$MACWAVE_VERSION",
    "parser": "$MACWAVE_VERSION"
  }
}
EOF

# ==========================================
# 把所有权交还给当前真实用户
# ==========================================

if [[ "$NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$BASE_DIR"
fi

if [[ "$NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
fi
run_cmd chmod 755 "$CONFIG_DIR"
run_cmd chmod 644 "$CONFIG_FILE"
run_cmd chmod 644 "$VERSION_FILE"

echo "🌊 Configuration saved to $CONFIG_FILE"
echo "🌊 Version saved to $VERSION_FILE"

# ==========================================
# 删除1.x旧版 repo.json，软件包索引现已网络实时拉取，不再依赖需要记得刷新（否则安装不到新版）、冗余（用户还得下载且没什么用）的本地索引
# ==========================================

OLD_JSON="$REPO_DIR/repo.json"
if [ -f "$OLD_JSON" ]; then
    echo "🌊 Removing old repo.json (legacy format)..."
    run_cmd rm -f "$OLD_JSON"
fi

# ==========================================
# 清理旧版（2.1.0）遗留的平铺 bin/ 文件
# ==========================================

LEGACY_BINS=$(find "$INSTALL_DIR" -maxdepth 1 -type f 2>/dev/null || true)
if [[ -n "$LEGACY_BINS" ]]; then
    echo -e "${YELLOW}🌊 Removing files installed by an older version in $DISPLAY_DIR/bin:${RESET}"
    while IFS= read -r legacy_file; do
        echo -e "${YELLOW}    $(basename "$legacy_file")${RESET}"
    done <<< "$LEGACY_BINS"
    while IFS= read -r legacy_file; do
        run_cmd rm -f "$legacy_file"
    done <<< "$LEGACY_BINS"
    echo -e "${YELLOW}🌊 ${BRANCH} keeps packages in bin/{name}@{version}/ directories.${RESET}"
    echo -e "${YELLOW}🌊 Please reinstall the packages: wave install {name}${RESET}"
fi

# ==========================================
# 检查动态库路径替换所需的工具
# ==========================================

if command -v otool > /dev/null 2>&1 && command -v install_name_tool > /dev/null 2>&1 && command -v codesign > /dev/null 2>&1; then
    echo "🌊 Xcode Command Line Tools detected (otool / install_name_tool / codesign)."
else
    echo -e "${YELLOW}🌊 Warning: Xcode Command Line Tools not found.${RESET}"
    echo -e "${YELLOW}🌊 Dependency libraries cannot be relocated, so some packages may fail to run.${RESET}"
    echo "🌊 You can install them later with: xcode-select --install"
fi

# ==========================================
# 执行更新脚本
# ==========================================
#
# 环境变量就是它与客户端之间的全部契约（见脚本头部注释）。
# MACWAVE_CURRENT_VERSION 留空 → 脚本走「首次安装」那条路，下载全部文件。

export MACWAVE_INSTALL_DIR="$BASE_DIR"
export MACWAVE_CONFIG_DIR="$CONFIG_DIR"
export MACWAVE_CORE_URL="$CORE_URL"
export MACWAVE_BRANCH="$BRANCH"
export MACWAVE_TARGET_VERSION="$MACWAVE_VERSION"
export MACWAVE_CURRENT_VERSION=""
export MACWAVE_FILE_TIMEOUT=60
export MACWAVE_NEED_SUDO="$([ "$NEED_SUDO" = "true" ] && echo 1 || echo "")"
export MACWAVE_SILENT="$([ "$CLI_CI" = "true" ] && echo 1 || echo "")"

if ! bash "$UPDATE_COMMANDS_TMP"; then
    echo -e "${RED_BOLD}🌊 Error: the update commands for $MACWAVE_VERSION failed.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was recorded as installed. Fix the cause above, then run the installer again.${RESET}"
    exit 1
fi

# ==========================================
# Python 运行环境（私有 venv + 启动器）
# ==========================================

# 为什么不用 PATH 上的 python3 直接当入口：
#   macOS 上 `python3` 可能指向 Homebrew 管理的版本，升级一次就换了路径，
#   而第三方依赖仍留在旧版本的 site-packages 里。入口写死 `#!/usr/bin/env python3`
#   就会在升级后全线报错（3.0.5 之前真实发生过）。
#
# 做法：
#   1. 在安装根目录建私有 venv，把 requests / packaging / rich 装进去；
#   2. lib/wave 变成一个 sh 启动器，按「venv → 安装时的解释器 → PATH」顺序挑选，
#      并且只有能真正 import 到三个依赖时才使用。
#
# 这样系统 Python 怎么升都不会影响已安装的 MacWave。

# 先确保安装树归当前用户所有：venv 与依赖都要以用户身份写入。
if [[ "$NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$BASE_DIR"
fi

# ==========================================
# 便携 Python（自带解释器）
# ==========================================
#
# 为什么自带：用户机器上的 python3 由 Homebrew / pyenv / 系统自带的版本轮流接管，
# 升级一次就可能换掉解释器，而第三方依赖仍留在旧版本里 —— 3.0.5 之前真实发生过
# 一次「系统 Python 从 3.14 升到 3.15，所有命令都报模块缺失」。
#
# 自带之后，「用哪个解释器」由 MacWave 自己决定，报错也就能稳定复现。
# 数据来自 MACWAVE_PYTHON_DOMAIN 的 pythondata/latest.toml，换版本不用改脚本。
# 下载失败（网络问题）时回退到系统 python3，安装不会因此中断。

portable_python_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "" ;;
    esac
}

portable_python_binary() {
    # 不同构建产物的目录布局不同，这里按常见位置逐个试探。
    local root="$1" candidate
    for candidate in \
        "$root/install/bin/python3" \
        "$root/bin/python3" \
        "$root/python/install/bin/python3" \
        "$root/python/bin/python3"
    do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    candidate="$(find "$root" -maxdepth 4 -type f \( -name 'python3' -o -name 'python3.*' \) -perm -u+x 2>/dev/null | head -n 1)"
    if [[ -n "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

normalize_portable_python() {
    # 把各种布局归一化成 <target>/bin/python3。
    #
    # 启动器只认 python/current/bin/python3，而上游 install_only 产物把解释器放在
    # python/install/bin/python3 —— 不归一化的话，自带解释器在启动器第 2 层永远命中不了，
    # 只有第 1 层的私有 venv 能救场；venv 一旦坏掉就等于没有自带解释器。
    local target="$1"
    local py="$2"
    local link="$target/bin/python3"
    local relative

    mkdir -p "$target/bin" 2>/dev/null || return 0
    if [[ "$py" == "$link" ]]; then
        return 0
    fi
    if [[ "$py" != "$target"/* ]]; then
        return 0
    fi

    # 用相对链接：整个 python/ 目录搬走以后仍然有效
    relative="../${py#"$target"/}"
    ln -sfn "$relative" "$link" 2>/dev/null || true
    return 0
}

ensure_portable_python() {
    # 成功时把解释器路径打到 stdout，失败返回 1（调用方回退系统 python3）。
    #
    # 两种来源：
    #   默认                —— 从我们自己的 Python 仓库取（pythondata/<版本>/<文件名>）
    #   --install-python-from-source —— 按 python_url.toml 记的上游地址直接回上游取
    # 两条路径的校验值相同：字节原样搬运，所以 sha256 可以复用。
    local base_dir="$1"
    local arch="$2"
    local latest_file url_file version="" url="" sha="" filename="" archive_url
    local target current archive actual py

    [[ -n "$arch" ]] || return 1

    # ── 第一步：MacWave 现在提供哪个版本的解释器 ──
    # 这一步失败不算错：网络不好时继续用本机已有的那份，安装照常完成。
    # 但**必须先问一次**，否则「本机已有 3.14.9」会让升级到「要求 3.15」的版本时
    # 永远发现不了自己落后 —— 这正是 per-version 目录存在的理由。
    echo "🌊 Checking the bundled Python version..." >&2
    latest_file="$(mktemp -t macwave-pylatest)"
    if curl -fsSL --max-time 30 -o "$latest_file" "$PYTHON_DOMAIN_URL/pythondata/latest.toml" 2>/dev/null; then
        version="$(read_toml_string "$(cat "$latest_file")" version)"
    fi
    rm -f "$latest_file"

    if [[ -n "$version" ]]; then
        target="$base_dir/python/$version"
        current="$base_dir/python/current"

        # 已经是最新版：直接用，一个字节都不下
        if py="$(portable_python_binary "$target" 2>/dev/null)" \
           && "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
            echo "$py"
            return 0
        fi
    else
        # 问不到最新版：退回到「本机有任何一份可用解释器就用它」
        for candidate in "$base_dir/python/current" "$base_dir"/python/*/; do
            [[ -d "$candidate" ]] || continue
            if py="$(portable_python_binary "$candidate" 2>/dev/null)" \
               && "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
                echo "$py"
                return 0
            fi
        done
        return 1
    fi

    # ── 第二步：这个版本各架构的地址与校验值 ──
    echo "🌊 Fetching the bundled Python $version definition..." >&2
    url_file="$(mktemp -t macwave-pyurl)"
    if ! curl -fsSL --max-time 30 -o "$url_file" \
         "$PYTHON_DOMAIN_URL/pythondata/$version/python_url.toml" 2>/dev/null; then
        rm -f "$url_file"
        return 1
    fi

    url="$(sed -n "s/^[[:space:]]*${arch}_url[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$url_file" | head -n 1)"
    sha="$(sed -n "s/^[[:space:]]*${arch}_sha256[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$url_file" | head -n 1)"
    rm -f "$url_file"

    if [[ -z "$url" || -z "$sha" ]]; then
        return 1
    fi

    # 文件名取上游地址的末段：我们自己托管的那份用同一个名字，校验值才能共用
    filename="${url##*/}"
    if [[ -n "$INSTALL_PYTHON_FROM_SOURCE" ]]; then
        archive_url="$url"
    else
        archive_url="$PYTHON_DOMAIN_URL/pythondata/$version/$filename"
    fi

    # ── 第三步：下载并校验 ──
    echo "🌊 Downloading the bundled Python $version (about 26 MB)..." >&2
    archive="$base_dir/downloads/tmp/portable-python-$version.tar.gz"
    mkdir -p "$base_dir/downloads/tmp" 2>/dev/null || true
    if ! curl -fsSL --max-time 900 -o "$archive" "$archive_url" 2>/dev/null; then
        rm -f "$archive"
        echo -e "${YELLOW}🌊 Could not download the bundled Python from $(mw_redact "$archive_url")${RESET}" >&2
        return 1
    fi
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$sha" ]]; then
        rm -f "$archive"
        echo -e "${RED_BOLD}🌊 Error: the bundled Python download failed its checksum check.${RESET}" >&2
        return 1
    fi
    mkdir -p "$target" 2>/dev/null || true
    if ! tar -xzf "$archive" -C "$target" 2>/dev/null; then
        rm -f "$archive"
        return 1
    fi
    rm -f "$archive"
    py="$(portable_python_binary "$target" 2>/dev/null)" || return 1
    if ! "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        return 1
    fi

    normalize_portable_python "$target" "$py"

    mkdir -p "$base_dir/python" 2>/dev/null || true
    ln -sfn "$version" "$current" 2>/dev/null || true
    echo "$py"
    return 0
}

VENV_DIR="$BASE_DIR/venv"
VENV_PY=""
PYTHON_BIN=""
PYTHON_SOURCE=""

mw_try ensure_portable_python "$BASE_DIR" "$(portable_python_arch)"
BUNDLED_PY="$MW_OPTIONAL_RESULT"
if [[ -n "$BUNDLED_PY" ]]; then
    PYTHON_BIN="$BUNDLED_PY"
    PYTHON_SOURCE="bundled"
    echo "🌊 Using the bundled Python: ${BUNDLED_PY#"$BASE_DIR"/}"
else
    PYTHON_BIN="$(command -v python3 || true)"
    PYTHON_SOURCE="system"
    if [[ -z "$PYTHON_BIN" ]]; then
        echo -e "${RED_BOLD}🌊 Error: no Python 3 interpreter is available.${RESET}"
        echo -e "${RED_BOLD}🌊 The bundled Python could not be downloaded and python3 is not in PATH.${RESET}"
        exit 1
    fi
    echo -e "${YELLOW}🌊 Warning: could not prepare the bundled Python; using $PYTHON_BIN instead.${RESET}"
    echo -e "${YELLOW}🌊 Re-run the installer when the network is available to make this installation self-contained.${RESET}"
fi

echo "🌊 Creating the private Python environment..."
mkdir -p "$VENV_DIR" 2>/dev/null || true

if "$PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1; then
    VENV_PY="$VENV_DIR/bin/python3"
    [[ -x "$VENV_PY" ]] || VENV_PY="$VENV_DIR/bin/python"
    echo "🌊 Private Python environment ready: ${VENV_DIR#"$BASE_DIR"/}"
else
    echo -e "${YELLOW}🌊 Warning: could not create a private virtualenv; using the ${PYTHON_SOURCE} interpreter directly.${RESET}"
fi

# pip 的公共参数。--index-url 指向 MACWAVE_PIP_INDEX（默认官方 PyPI）；
# 国内直连 pypi.org 常超时，用户可以把它换成本地镜像。
PIP_DEPS=(requests packaging rich)
PIP_FLAGS=(--quiet --disable-pip-version-check --timeout 30 --retries 2
           --index-url "$PIP_INDEX_URL")

if [[ -n "$VENV_PY" && -x "$VENV_PY" ]]; then
    echo "🌊 Installing Python dependencies into the private environment..."
    # pip 默认会无限等下去，网络不好时看上去就是卡死。给它超时与重试，
    # 并说明这一步可能要一会儿，免得用户以为程序挂了。
    echo "🌊 Installing Python dependencies into the private environment (this can take a minute)..."
    "$VENV_PY" -m pip install "${PIP_FLAGS[@]}" --upgrade pip >/dev/null 2>&1 || true
    if ! "$VENV_PY" -m pip install "${PIP_FLAGS[@]}" "${PIP_DEPS[@]}"; then
        echo -e "${RED_BOLD}🌊 Error: failed to install the Python dependencies.${RESET}"
        echo -e "${RED_BOLD}🌊 Index used: $PIP_INDEX_URL${RESET}"
        echo -e "${RED_BOLD}🌊 Set MACWAVE_PIP_INDEX to a reachable mirror and try again,${RESET}"
        echo -e "${RED_BOLD}🌊 or install them manually into $VENV_PY.${RESET}"
        exit 1
    fi
else
    echo "🌊 Installing Python dependencies into $PYTHON_BIN..."
    if ! "$PYTHON_BIN" -m pip install "${PIP_FLAGS[@]}" "${PIP_DEPS[@]}" 2>/dev/null; then
        if ! "$PYTHON_BIN" -m pip install "${PIP_FLAGS[@]}" --user --break-system-packages "${PIP_DEPS[@]}"; then
            echo -e "${RED_BOLD}🌊 Error: failed to install the Python dependencies.${RESET}"
            echo -e "${RED_BOLD}🌊 Index used: $PIP_INDEX_URL${RESET}"
            echo -e "${RED_BOLD}🌊 Set MACWAVE_PIP_INDEX to a reachable mirror and try again.${RESET}"
            exit 1
        fi
    fi
fi

# 生成入口启动器：把当前解释器路径烘进去，作为 venv 失效时的第二选择。
write_launcher() {
    local base_dir="$1"
    local recorded="$2"
    local target="$base_dir/lib/wave"
    local tmp
    tmp="$(mktemp -t macwave-launcher)"

    cat > "$tmp" <<'LAUNCHER'
#!/bin/sh
# MacWave launcher
# 由 install.sh / selfupdate.sh 生成，会被覆盖，请不要手工编辑。
#
# 选择一个**真正能 import 到依赖**的解释器来运行 lib/wave.py：
#   1. 安装根目录下的私有 venv（与系统 Python 升级完全解耦）
#   2. 生成这个启动器时的解释器路径
#   3. PATH 上的 python3（最后兜底，wave.py 会给出缺少哪个依赖）

set -u

# 解析自身真实路径（可能经由 PATH 上的符号链接调用）
self="$0"
while [ -L "$self" ]; do
    link="$(readlink "$self")"
    case "$link" in
        /*) self="$link" ;;
        *)  self="$(dirname "$self")/$link" ;;
    esac
done
lib_dir="$(cd -- "$(dirname -- "$self")" && pwd)" || exit 1
root_dir="$(cd -- "$lib_dir/.." && pwd)" || exit 1
entry="$lib_dir/wave.py"

#__MACWAVE_PYTHON__

deps_ok() {
    [ -x "$1" ] || return 1
    "$1" -c 'import requests, packaging, rich' >/dev/null 2>&1
}

# 1. 私有 venv（正常情况下就是它；由自带 Python 创建）
if deps_ok "$root_dir/venv/bin/python3"; then
    exec "$root_dir/venv/bin/python3" "$entry" "$@"
fi
if deps_ok "$root_dir/venv/bin/python"; then
    exec "$root_dir/venv/bin/python" "$entry" "$@"
fi

# 2. 自带的便携 Python（venv 坏掉时的第一选择；它自己也可以带依赖）
if [ -x "$root_dir/python/current/bin/python3" ] && deps_ok "$root_dir/python/current/bin/python3"; then
    exec "$root_dir/python/current/bin/python3" "$entry" "$@"
fi

# 3. 安装时记录的系统解释器
if [ -n "${MACWAVE_PYTHON:-}" ] && deps_ok "$MACWAVE_PYTHON"; then
    exec "$MACWAVE_PYTHON" "$entry" "$@"
fi

# 4. 最后才用 PATH 上的 python3（wave.py 会明确指出缺哪个依赖）
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$entry" "$@"
fi

echo "🌊 Error: no usable Python 3 interpreter was found." >&2
echo "🌊 Reinstall MacWave with lib/install.sh." >&2
exit 1
LAUNCHER

    local escaped rendered
    escaped="$(printf '%s' "$recorded" | sed 's/[\\"`$]/\\&/g')"

    # 内容先在普通权限下生成，只有落地那几步才可能需要提权。
    # 调用本函数时**不能**写 run_cmd write_launcher：sudo 无法执行 shell 函数，
    # 会遇到 "sudo: write_launcher: command not found"。
    rendered="$(mktemp -t macwave-launcher-out)"
    sed "s|#__MACWAVE_PYTHON__|MACWAVE_PYTHON=\"$escaped\"|" "$tmp" > "$rendered"
    rm -f "$tmp"

    run_cmd mkdir -p "$(dirname "$target")"
    run_cmd cp "$rendered" "$target"
    run_cmd chmod 755 "$target"
    rm -f "$rendered"
}

write_launcher "$BASE_DIR" "$PYTHON_BIN"

# ==========================================
# 把所有权交还给用户（下载后再次确保）
# ==========================================

if [[ "$NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$BASE_DIR"
fi

# ==========================================
# 添加到 PATH
# ==========================================

if [[ "$SHELL" == *"zsh"* ]]; then
    RC_FILE="$HOME/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then
    RC_FILE="$HOME/.bashrc"
else
    RC_FILE="$HOME/.profile"
fi

PATH_LINE="export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\""

# 从 rc 文件里摘掉我们写入的 PATH 行（连同标记行）。
# 安装回滚时要靠它，否则会留下一个指向已删除目录的 PATH。
remove_lw_path_entries() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    grep -qF -e "$PATH_LINE" -e "# MacWave" "$rc" 2>/dev/null || return 0
    grep -v -F -e "$PATH_LINE" -e "# MacWave" "$rc" > "$rc.macwave.tmp" || true
    cat "$rc.macwave.tmp" > "$rc"
    rm -f "$rc.macwave.tmp"
    echo "🌊 Removed MacWave PATH entries from $rc"
}

if grep -qF "$PATH_LINE" "$RC_FILE" 2>/dev/null; then
    echo "🌊 MacWave is already in your PATH."
else
    if grep -qF "$INSTALL_DIR" "$RC_FILE" 2>/dev/null; then
        # 旧版本（如 2.1.0）的 PATH 行只有 bin/ 与 lib/，升级后需要换成含 links/ 的新行
        echo "🌊 Replacing old MacWave PATH entry in $RC_FILE..."
        grep -v -F "export PATH=\"$INSTALL_DIR" "$RC_FILE" > "$RC_FILE.macwave.tmp" || true
        cat "$RC_FILE.macwave.tmp" > "$RC_FILE"
        rm -f "$RC_FILE.macwave.tmp"
    else
        echo "🌊 Adding MacWave to PATH in $RC_FILE..."
        echo "" >> "$RC_FILE"
        echo "# MacWave" >> "$RC_FILE"
    fi

    echo "$PATH_LINE" >> "$RC_FILE"
fi

# ==========================================
# 许可协议确认
# ==========================================
# 必须放在「安装完成」之前：否则先告诉用户已经装好，随后又因为不同意而全部删除。

echo ""
echo -e "${YELLOW}Please read the agreement before use (see bottom of https://macwave.org).${RESET}"
if [[ "$CLI_CI" == "true" ]]; then
    echo "🌊 --ci: the agreement is accepted automatically."
    agreement="y"
else
    echo -e "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}"
    read -r agreement < /dev/tty
fi
if [[ -z "$agreement" || "$agreement" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}You have agreed to the agreement.${RESET}"
else
    # 回滚要连 rc 里的 PATH 一起清掉，否则会留下指向已删除目录的一行。
    # 这里不写死 sudo：用户级安装全程无需提权，回滚也不该突然要密码。
    echo -e "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}"
    echo -e "${RED_BOLD}🌊 Cleaning up downloaded files...${RESET}"
    run_cmd rm -rf "$BASE_DIR"
    run_cmd rm -rf "$CONFIG_DIR"
    remove_lw_path_entries "$RC_FILE"
    echo -e "${RED_BOLD}🌊 All files have been deleted.${RESET}"
    exit 1
fi

# ==========================================
# 完成信息
# ==========================================

echo ""
echo "🌊 Installation complete!"
echo "🌊 MacWave installed to: $DISPLAY_DIR"
echo "🌊 Architecture: $ARCH"
echo ""
RC_DISPLAY=$(home_to_tilde "$RC_FILE")
echo "🌊 To use 'wave' immediately in this terminal, run:"
echo -e "${YELLOW}    source $RC_DISPLAY${RESET}"
echo "🌊 Or simply open a new terminal window."
echo ""
