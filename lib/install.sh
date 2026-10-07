#!/bin/bash

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/lib/install.sh)"

set -e

BRANCH="main"

# 版本号只在这里定义：欢迎语与写入 VERSION.json 都引用它
MACWAVE_VERSION="2.3.1"

BASE_URL="https://raw.githubusercontent.com/MacWaveOrg/MacWave/$BRANCH"

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
# 显示欢迎信息
# ==========================================

echo "🌊 Welcome to MacWave $MACWAVE_VERSION!"
echo ""

# ==========================================
# 检测系统架构
# ==========================================

ARCH=$(uname -m)
echo "🌊 Detected architecture: $ARCH"

# ==========================================
# 交互式目录选择
# ==========================================

if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
    echo -e "${YELLOW}Where do you want to install MacWave? (Enter the number)${RESET}"
    echo "1. ~/.local/macwave"
    echo "2. /opt/macwave"
    echo "3. /usr/local/macwave"
    echo "4. other (enter custom directory)"
    echo ""
    echo -e "${YELLOW}Enter your choice:${RESET}"

    read -r choice < /dev/tty

    case "$choice" in
        1)
            BASE_DIR="$HOME/.local/macwave"
            ;;
        2)
            BASE_DIR="/opt/macwave"
            ;;
        3)
            BASE_DIR="/usr/local/macwave"
            ;;
        4)
            echo -e "${YELLOW}Please enter the installation directory:${RESET}"
            read -r custom_dir < /dev/tty
            validated=$(validate_custom_dir "$custom_dir") || exit 1
            BASE_DIR="$validated"
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/macwave${RESET}"
            BASE_DIR="$HOME/.local/macwave"
            ;;
    esac
else
    echo -e "${YELLOW}Where do you want to install MacWave? (Enter the number)${RESET}"
    echo "1. ~/.local/macwave"
    echo "2. /opt/macwave"
    echo "3. other (enter custom directory)"
    echo ""
    echo -e "${YELLOW}Enter your choice:${RESET}"

    read -r choice < /dev/tty

    case "$choice" in
        1)
            BASE_DIR="$HOME/.local/macwave"
            ;;
        2)
            BASE_DIR="/opt/macwave"
            ;;
        3)
            echo -e "${YELLOW}Please enter the installation directory:${RESET}"
            read -r custom_dir < /dev/tty
            validated=$(validate_custom_dir "$custom_dir") || exit 1
            BASE_DIR="$validated"
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/macwave${RESET}"
            BASE_DIR="$HOME/.local/macwave"
            ;;
    esac
fi

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
    echo -e "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}"
    sudo -v
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
CONFIG_DIR="/opt/macwave_config"
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

run_cmd mkdir -p "$INSTALL_DIR"
run_cmd mkdir -p "$LINKS_DIR"
run_cmd mkdir -p "$REPO_DIR"
run_cmd mkdir -p "$SURFBOARD_DIR"
run_cmd mkdir -p "$LIB_DIR"
run_cmd mkdir -p "$DEPS_DIR"
run_cmd mkdir -p "$DOWNLOAD_DIR"
sudo mkdir -p "$CONFIG_DIR"
sudo chmod 755 "$CONFIG_DIR"

# ==========================================
# 写入配置文件
# ==========================================

sudo tee "$CONFIG_FILE" > /dev/null << EOF
{
  "base_dir": "$BASE_DIR"
}
EOF

sudo tee "$VERSION_FILE" > /dev/null << EOF
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

sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
sudo chmod 755 "$CONFIG_DIR"
sudo chmod 644 "$CONFIG_FILE"
sudo chmod 644 "$VERSION_FILE"

echo "🌊 Configuration saved to /opt/macwave_config/config.json"
echo "🌊 Version saved to /opt/macwave_config/VERSION.json"

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
# 文件 URL
# ==========================================

WAVE_URL="$BASE_URL/lib/wave.py"
HELP_URL="$BASE_URL/lib/help.py"
CONFIGERROR_URL="$BASE_URL/lib/configerror.py"
SELFUPDATE_URL="$BASE_URL/lib/selfupdate.py"
SELFUPDATE_SH_URL="$BASE_URL/lib/selfupdate.sh"
PKGINSTALLER_URL="$BASE_URL/pkg/pkginstaller.py"
PKGINSTALLER_SH_URL="$BASE_URL/pkg/pkginstaller.sh"
PKGINFOHELPER_URL="$BASE_URL/pkg/pkginfohelper.py"
UNINSTALLER_URL="$BASE_URL/pkg/uninstaller.py"
PKGVERSIONPARSER_URL="$BASE_URL/pkg/pkgversionparser.py"
PKGUNZIP_URL="$BASE_URL/pkg/pkgunzip.sh"

# 依赖处理相关文件全部从 $BRANCH 分支拉取
DEPSINSTALLER_URL="$BASE_URL/surfboard/depsinstaller.py"
DEPSINSTALLER_SH_URL="$BASE_URL/surfboard/depsinstaller.sh"
DEPSMANAGER_SH_URL="$BASE_URL/surfboard/depsmanager.sh"
DEPSVERSIONPARSER_URL="$BASE_URL/surfboard/depsversionparser.py"
QUERIER_URL="$BASE_URL/surfboard/querier.py"
TAGGER_SH_URL="$BASE_URL/surfboard/tagger.sh"
TRANSFER_SH_URL="$BASE_URL/surfboard/transfer.sh"

# ==========================================
# 下载文件
# ==========================================

echo "🌊 Downloading wave..."
run_cmd curl -fsSL -o "$LIB_DIR/wave" "$WAVE_URL"
run_cmd chmod +x "$LIB_DIR/wave"

echo "🌊 Downloading help.py..."
run_cmd curl -fsSL -o "$LIB_DIR/help.py" "$HELP_URL"

echo "🌊 Downloading configerror.py..."
run_cmd curl -fsSL -o "$LIB_DIR/configerror.py" "$CONFIGERROR_URL"

echo "🌊 Downloading selfupdate.py..."
run_cmd curl -fsSL -o "$LIB_DIR/selfupdate.py" "$SELFUPDATE_URL"

echo "🌊 Downloading selfupdate.sh..."
run_cmd curl -fsSL -o "$LIB_DIR/selfupdate.sh" "$SELFUPDATE_SH_URL"
run_cmd chmod +x "$LIB_DIR/selfupdate.sh"

echo "🌊 Downloading pkginstaller.py..."
run_cmd curl -fsSL -o "$REPO_DIR/pkginstaller.py" "$PKGINSTALLER_URL"

echo "🌊 Downloading pkginstaller.sh..."
run_cmd curl -fsSL -o "$REPO_DIR/pkginstaller.sh" "$PKGINSTALLER_SH_URL"
run_cmd chmod +x "$REPO_DIR/pkginstaller.sh"

echo "🌊 Downloading pkginfohelper.py..."
run_cmd curl -fsSL -o "$REPO_DIR/pkginfohelper.py" "$PKGINFOHELPER_URL"

echo "🌊 Downloading uninstaller.py..."
run_cmd curl -fsSL -o "$REPO_DIR/uninstaller.py" "$UNINSTALLER_URL"

echo "🌊 Downloading pkgversionparser.py..."
run_cmd curl -fsSL -o "$REPO_DIR/pkgversionparser.py" "$PKGVERSIONPARSER_URL"

echo "🌊 Downloading pkgunzip.sh..."
run_cmd curl -fsSL -o "$REPO_DIR/pkgunzip.sh" "$PKGUNZIP_URL"
run_cmd chmod +x "$REPO_DIR/pkgunzip.sh"

echo "🌊 Downloading surfboard/depsinstaller.py..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsinstaller.py" "$DEPSINSTALLER_URL"

echo "🌊 Downloading surfboard/depsinstaller.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsinstaller.sh" "$DEPSINSTALLER_SH_URL"
run_cmd chmod +x "$SURFBOARD_DIR/depsinstaller.sh"

echo "🌊 Downloading surfboard/depsmanager.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsmanager.sh" "$DEPSMANAGER_SH_URL"
run_cmd chmod +x "$SURFBOARD_DIR/depsmanager.sh"

echo "🌊 Downloading surfboard/depsversionparser.py..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsversionparser.py" "$DEPSVERSIONPARSER_URL"

echo "🌊 Downloading surfboard/querier.py..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/querier.py" "$QUERIER_URL"

echo "🌊 Downloading surfboard/tagger.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/tagger.sh" "$TAGGER_SH_URL"
run_cmd chmod +x "$SURFBOARD_DIR/tagger.sh"

echo "🌊 Downloading surfboard/transfer.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/transfer.sh" "$TRANSFER_SH_URL"
run_cmd chmod +x "$SURFBOARD_DIR/transfer.sh"

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

# ==========================================
# 许可协议确认
# ==========================================

echo ""
echo -e "${YELLOW}Please read the agreement before use (see bottom of https://macwave.org).${RESET}"
echo -e "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}"
read -r agreement < /dev/tty
if [[ -z "$agreement" || "$agreement" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}You have agreed to the agreement. Installation continues.${RESET}"
else
    echo -e "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}"
    echo -e "${RED_BOLD}🌊 Cleaning up downloaded files...${RESET}"
    run_cmd rm -rf "$BASE_DIR"
    sudo rm -rf "$CONFIG_DIR"
    echo -e "${RED_BOLD}🌊 All files have been deleted.${RESET}"
    exit 1
fi