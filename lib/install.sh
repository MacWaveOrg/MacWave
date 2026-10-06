#!/bin/bash

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sha0huaZhang/MacWave/main/lib/install.sh)"
# Unattended: /bin/bash -c "$(curl -fsSL .../main/lib/install.sh)" -- --silent --dir-option=1

set -eE

BRANCH="main"

# 版本号只在这里定义：欢迎语与写入 VERSION.json 都引用它
MACWAVE_VERSION="2.5.2"

BASE_URL="https://raw.githubusercontent.com/Sha0huaZhang/MacWave/$BRANCH"

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

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

CLI_SILENT=false
CLI_DIR_OPTION=""
CLI_CUSTOM_DIR=""

usage() {
    cat <<USAGE_EOF
MacWave installer

Usage:
  install.sh [options]

Options:
  -S, --silent            No interaction at all: the directory menu and the
                          agreement are answered automatically. Without
                          --dir-option the default (option 1) is used.
                          Requires passwordless sudo when privilege is needed.
      --dir-option=N      Pick menu entry N without prompting (1-$CUSTOM_OPTION).
      --dir-option=N=DIR  Pick entry N and, for the custom entry ($CUSTOM_OPTION), use DIR
                          as the installation directory.
  -h, --help              Show this help.

Directory menu:
$(print_dir_menu | sed 's/^/  /')

Examples:
  install.sh --silent --dir-option=1
  install.sh -S --dir-option=2
  install.sh --silent --dir-option=$CUSTOM_OPTION=/opt/my-macwave

Running it straight from the repository (options go after '--'):
  /bin/bash -c "\$(curl -fsSL <url>)" -- --silent --dir-option=1
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S|--silent)
            CLI_SILENT=true
            ;;
        --dir-option=*)
            _value="${1#--dir-option=}"
            if [[ "$_value" == *=* ]]; then
                CLI_DIR_OPTION="${_value%%=*}"
                CLI_CUSTOM_DIR="${_value#*=}"
            else
                CLI_DIR_OPTION="$_value"
            fi
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
#   bash -c "$(curl ...)" --silent     ← --silent 变成 $0，被静默丢掉
# 这里明确提示，避免「静默模式没生效、脚本却卡在交互上」。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        echo -e "${YELLOW}🌊 Warning: '$0' was treated as the script name, not as an option.${RESET}" >&2
        echo -e "${YELLOW}🌊 Put installer options after '--', which ends bash's own options.${RESET}" >&2
        echo "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" >&2
        ;;
esac

if [[ -n "$CLI_DIR_OPTION" && ! "$CLI_DIR_OPTION" =~ ^[0-9]+$ ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option must be a number, got '$CLI_DIR_OPTION'.${RESET}" >&2
    exit 1
fi

if [[ -n "$CLI_DIR_OPTION" ]] && [[ "$CLI_DIR_OPTION" -lt 1 || "$CLI_DIR_OPTION" -gt "$CUSTOM_OPTION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option must be 1-$CUSTOM_OPTION on this architecture, got '$CLI_DIR_OPTION'.${RESET}" >&2
    exit 1
fi

if [[ -n "$CLI_CUSTOM_DIR" && "$CLI_DIR_OPTION" != "$CUSTOM_OPTION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: only --dir-option=$CUSTOM_OPTION takes a directory (this architecture has $CUSTOM_OPTION entries).${RESET}" >&2
    exit 1
fi

if [[ "$CLI_DIR_OPTION" == "$CUSTOM_OPTION" && -z "$CLI_CUSTOM_DIR" && "$CLI_SILENT" == "true" ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option=$CUSTOM_OPTION needs a directory in --silent mode.${RESET}" >&2
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
echo ""

echo "🌊 Detected architecture: $ARCH"

# ==========================================
# 选择安装目录（交互式 / --dir-option / --silent 默认）
# ==========================================

if [[ -n "$CLI_DIR_OPTION" ]]; then
    choice="$CLI_DIR_OPTION"
    echo "🌊 Directory option: $choice (from --dir-option)"
elif [[ "$CLI_SILENT" == "true" ]]; then
    choice="1"
    echo "🌊 --silent: using the default directory option 1."
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
        BASE_DIR="/opt/macwave"
        ;;
    3)
        if [[ "$CUSTOM_OPTION" == "3" ]]; then
            resolve_custom_dir
        else
            BASE_DIR="/usr/local/macwave"
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
    if [[ "$CLI_SILENT" == "true" ]]; then
        # --silent 不能停下来等密码：要么已经是 root，要么已有免密 sudo
        if ! sudo -n true 2> /dev/null; then
            echo -e "${RED_BOLD}🌊 Error: this install needs privilege, but --silent cannot ask for a password.${RESET}" >&2
            echo -e "${RED_BOLD}🌊 Run as root, or configure passwordless sudo for the install user.${RESET}" >&2
            exit 1
        fi
    else
        echo -e "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}"
        sudo -v
    fi
fi

# ==========================================
# 文件清单（configdata/versiondata/files_info）
# ==========================================
#
# 要下载哪些文件不写死在本脚本里，而是去 configdata 分支读一份清单，
# 这样新增文件只要改那份清单，不必再同步修改安装脚本与自更新脚本。
# 清单内容**只表示仓库里的路径**，写法：
#
#     /                      单独一个 / 表示安装根（等价于 BASE_DIR）
#         lib/               以 / 结尾 → 目录，只创建不下载
#             wave.py        其它 → 文件
#         pkg/linker.py      也可以行内直接写完整路径，代替缩进
#             # 以 # 开头的是注释，空行忽略
#
# 缩进每层 4 个空格，Tab 与 4 个空格等价，两种可以混用。
# 每个文件都从 "$BASE_URL/<仓库路径>" 下载，落到 "$BASE_DIR" 下的同名位置。
# 唯一的特例：lib/wave.py 装成可执行的 lib/wave（它是 PATH 里的入口名）。
#
# 这一步刻意放在「建目录 / 写配置 / 清旧版」之前：连不上 configdata 就直接退出，
# 不会留下一个配置已写好、文件却一个都没下的半成品安装。

CONFIGDATA_URL="https://raw.githubusercontent.com/Sha0huaZhang/MacWave/configdata"
FILES_INFO_URL="$CONFIGDATA_URL/versiondata/files_info"
FILES_INFO_TMP="$(mktemp)"
FILES_INFO_ATTEMPTS=3

cleanup_files_info() {
    rm -f "$FILES_INFO_TMP"
}
trap cleanup_files_info EXIT

echo "🌊 Fetching the file list..."

FILES_INFO_OK=false
for attempt in $(seq 1 "$FILES_INFO_ATTEMPTS"); do
    if curl -fsSL --max-time 60 -o "$FILES_INFO_TMP" "$FILES_INFO_URL"; then
        FILES_INFO_OK=true
        break
    fi
    if [[ "$attempt" -lt "$FILES_INFO_ATTEMPTS" ]]; then
        echo -e "${YELLOW}🌊 Retrying the file list ($((attempt + 1))/$FILES_INFO_ATTEMPTS)...${RESET}"
    fi
done

if [[ "$FILES_INFO_OK" != "true" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot fetch versiondata/files_info from the configdata branch.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was installed. Check your network or proxy, then run the installer again.${RESET}"
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
    CONFIG_DIR="/opt/macwave_config"
else
    CONFIG_DIR="$HOME/.config/macwave_config"
fi
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

# 中途失败时给出明确指引。刻意**不自动删除**已下载的内容：升级安装时
# 删掉安装树会把用户原有的可用安装一起毁掉，重跑安装器才是安全的做法。
install_failed() {
    local code=$?
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
# 版本目录结构变更迁移（configdata/updatedata/{版本号}）
# ==========================================
#
# configdata 的 updatedata/{版本号}/dir_structure_change 只有**一个字符**：
#     Y/y → 该版本改变了目录结构，执行同目录下的 transfer_commands 完成迁移
#     N/n → 没有改变，跳过（文件不存在也按「没有改变」处理）
# 目标版本号就是本脚本的 MACWAVE_VERSION（正在安装的这个版本）。
# 迁移逻辑全部由 configdata 里的脚本提供，以后目录结构再变只改 configdata，
# 不用再动这个脚本。

UPDATEDATA_URL="$CONFIGDATA_URL/updatedata/$MACWAVE_VERSION"

DIR_STRUCTURE_CHANGE="$(curl -fsSL --max-time 30 "$UPDATEDATA_URL/dir_structure_change" 2>/dev/null | tr -d '[:space:]')" || DIR_STRUCTURE_CHANGE=""

if [[ "$DIR_STRUCTURE_CHANGE" == "Y" || "$DIR_STRUCTURE_CHANGE" == "y" ]]; then
    echo -e "${YELLOW}🌊 Directory structure changed in $MACWAVE_VERSION, running migration...${RESET}"

    TRANSFER_COMMANDS="$(curl -fsSL --max-time 60 "$UPDATEDATA_URL/transfer_commands" 2>/dev/null)" || TRANSFER_COMMANDS=""
    if [[ -z "$TRANSFER_COMMANDS" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot fetch the migration script for $MACWAVE_VERSION.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was installed. Check your network, then run the installer again.${RESET}"
        exit 1
    fi

    # 把本次安装的位置与配置目录告诉迁移脚本，由它自己判断该不该搬
    export MACWAVE_INSTALL_DIR="$BASE_DIR"
    export MACWAVE_CONFIG_DIR="$CONFIG_DIR"
    export MACWAVE_TARGET_VERSION="$MACWAVE_VERSION"

    if ! bash -c "$TRANSFER_COMMANDS"; then
        echo -e "${RED_BOLD}🌊 Error: The migration for $MACWAVE_VERSION failed.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was installed. Fix the issue above, then run the installer again.${RESET}"
        exit 1
    fi

    echo ""
fi

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
# 删除旧版 repo.json
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
# 解析文件清单
# ==========================================
# 清单已在上面取回（连不上就直接退出了，没动过任何东西），这里只做解析。

parse_files_info() {
    # 把缩进树解析成 "<仓库路径>\t<本地相对路径>\t<是否需要 +x>"，一行一个文件
    python3 - "$1" <<'PY'
import sys

stack = []   # [(缩进宽度, 目录名)]：当前所在目录的祖先链
lines = []

for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue

    # 缩进按 4 个空格算，Tab 等价于 4 个空格（两者可以混用）
    expanded = line.expandtabs(4)
    indent = len(expanded) - len(expanded.lstrip(" "))
    name = line.strip()

    while stack and stack[-1][0] >= indent:   # 缩进回退：弹掉不比当前行浅的祖先
        stack.pop()

    if name == "/":                 # 单独一个 /：安装根，等价于 BASE_DIR
        stack = []
        continue

    if name.endswith("/"):          # 以 / 结尾 → 目录：只记层次，不下载
        stack.append((indent, name.rstrip("/")))
        continue

    if "/" in name:                 # 行内直接写完整路径（可代替缩进）
        repo_path = name.strip("/")
    else:
        repo_path = "/".join([directory for _, directory in stack] + [name])

    if repo_path == "lib/wave.py":
        local_path, executable = "lib/wave", 1
    else:
        local_path, executable = repo_path, int(repo_path.endswith(".sh"))

    lines.append(f"{repo_path}\t{local_path}\t{executable}")

print("\n".join(lines))
PY
}

FILE_ENTRIES="$(parse_files_info "$FILES_INFO_TMP")"

if [[ -z "$FILE_ENTRIES" ]]; then
    echo -e "${RED_BOLD}🌊 Error: The file list is empty, nothing to download.${RESET}"
    exit 1
fi

FILE_COUNT=$(printf '%s\n' "$FILE_ENTRIES" | wc -l | tr -d ' ')
echo "🌊 Downloading $FILE_COUNT file(s) from branch: $BRANCH"
echo ""

# ==========================================
# 下载文件
# ==========================================

while IFS=$'\t' read -r repo_path local_path executable; do
    if [[ -z "$repo_path" ]]; then
        continue
    fi

    if [[ "$CLI_SILENT" != "true" ]]; then
        echo "🌊 Downloading $repo_path..."
    fi
    run_cmd mkdir -p "$(dirname "$BASE_DIR/$local_path")"
    run_cmd curl -fsSL -o "$BASE_DIR/$local_path" "$BASE_URL/$repo_path"

    if [[ "$executable" == "1" ]]; then
        run_cmd chmod +x "$BASE_DIR/$local_path"
    fi
done <<< "$FILE_ENTRIES"

# ==========================================
# 把所有权交还给用户（下载后再次确保）
# ==========================================

if [[ "$NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$BASE_DIR"
fi

# ==========================================
# 安装 Python 依赖
# ==========================================

echo "🌊 Checking Python dependencies..."
if ! python3 -c "import requests" 2>/dev/null; then
    echo "🌊 Installing 'requests' library..."
    pip3 install requests --quiet
else
    echo "🌊 'requests' library is already installed."
fi

if ! python3 -c "from packaging.version import parse" 2>/dev/null; then
    echo "🌊 Installing 'packaging' library..."
    pip3 install packaging --quiet
else
    echo "🌊 'packaging' library is already installed."
fi

if ! python3 -c "import rich" 2>/dev/null; then
    echo "🌊 Installing 'rich' library for progress bar..."
    if pip3 install rich --quiet; then
        echo "🌊 'rich' installed successfully."
    else
        echo -e "${RED_BOLD}🌊 Warning: 'rich' installation failed. Progress bar will not be available.${RESET}"
        echo "🌊 You can install it manually later: pip3 install rich"
    fi
else
    echo "🌊 'rich' library is already installed."
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
if [[ "$CLI_SILENT" == "true" ]]; then
    echo "🌊 --silent: the agreement is accepted automatically."
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