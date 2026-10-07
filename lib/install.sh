#!/bin/bash

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/2.0.0-dev/lib/install.sh)"

set -e

BRANCH="2.0.0-dev"
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
# 显示欢迎信息
# ==========================================

echo "🌊 Welcome to MacWave 2.0RC(243A1039)!"
echo "🌊 Installing from branch: $BRANCH"
echo ""

# ==========================================
# 检测系统架构
# ==========================================

ARCH=$(uname -m)
echo "🌊 Detected architecture: $ARCH"

# ==========================================
# 交互式目录选择（根据架构显示不同选项）
# ==========================================

if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
    # Intel Mac：显示 /usr/local/macwave 选项
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
            BASE_DIR="${custom_dir/#\~/$HOME}"
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/macwave${RESET}"
            BASE_DIR="$HOME/.local/macwave"
            ;;
    esac
else
    # Apple Silicon：不显示 /usr/local（不可写）
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
            BASE_DIR="${custom_dir/#\~/$HOME}"
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/macwave${RESET}"
            BASE_DIR="$HOME/.local/macwave"
            ;;
    esac
fi

DISPLAY_DIR=$(home_to_tilde "$BASE_DIR")

# ==========================================
# 判断是否需要 sudo（无论安装到哪，只要涉及 /opt 都强制获取）
# ==========================================

echo -e "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}"
sudo -v
USE_SUDO="sudo"

# ==========================================
# 创建目录（全用 sudo 创建）
# ==========================================

INSTALL_DIR="$BASE_DIR/bin"
REPO_DIR="$BASE_DIR/pkg"
LIB_DIR="$BASE_DIR/lib"
DOWNLOAD_DIR="$BASE_DIR/downloads/tmp"
CONFIG_DIR="/opt/macwave_config"
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

sudo mkdir -p "$INSTALL_DIR"
sudo mkdir -p "$REPO_DIR"
sudo mkdir -p "$LIB_DIR"
sudo mkdir -p "$DOWNLOAD_DIR"
sudo mkdir -p "$CONFIG_DIR"
sudo chmod 755 "$CONFIG_DIR"

# ==========================================
# 写入配置文件（使用 sudo tee 写入）
# ==========================================

sudo tee "$CONFIG_FILE" > /dev/null << EOF
{
  "base_dir": "$BASE_DIR"
}
EOF

sudo tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "2.0RC(243A1039)",
  "components": {
    "installer": "2.0RC(243A1039)",
    "parser": "2.0RC(243A1039)"
  }
}
EOF

# ==========================================
# 关键：把所有权交还给当前真实用户
# ==========================================

CURRENT_USER=$(whoami)

sudo chown -R "$CURRENT_USER": "$BASE_DIR"
sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
sudo chmod 755 "$CONFIG_DIR"
sudo chmod 644 "$CONFIG_FILE"
sudo chmod 644 "$VERSION_FILE"

echo "🌊 Configuration saved to /opt/macwave_config/config.json"
echo "🌊 Version saved to /opt/macwave_config/VERSION.json"

# ==========================================
# 删除旧版 repo.json（如果存在）
# ==========================================

OLD_JSON="$REPO_DIR/repo.json"
if [ -f "$OLD_JSON" ]; then
    echo "🌊 Removing old repo.json (legacy format)..."
    sudo rm -f "$OLD_JSON"
fi

# ==========================================
# 文件 URL（全部适配新的 GitHub 目录结构）
# ==========================================

WAVE_URL="$BASE_URL/lib/wave.py"
HELP_URL="$BASE_URL/lib/help.py"
PKGINSTALLER_URL="$BASE_URL/pkg/pkginstaller.py"
VERSION_PARSER_URL="$BASE_URL/pkg/versionparser.py"
PARSER_URL="$BASE_URL/pkg/pkgparser.rb"
PKGINFO_URL="$BASE_URL/pkg/pkginfo_${ARCH}.txt"

# ==========================================
# 检查 Ruby 版本（要求 >= 2.6.10）
# ==========================================

echo "🌊 Checking Ruby version..."
if ! command -v ruby &> /dev/null; then
    echo -e "${RED_BOLD}🌊 Error: Ruby is not installed. Please install Ruby 2.6.10 or higher.${RESET}"
    exit 1
fi

RUBY_VERSION=$(ruby -e 'puts RUBY_VERSION')

if ! ruby -e "exit Gem::Version.new('$RUBY_VERSION') >= Gem::Version.new('2.6.10')" 2>/dev/null; then
    echo -e "${RED_BOLD}🌊 Error: Ruby version $RUBY_VERSION is too old. Please upgrade to 2.6.10 or higher.${RESET}"
    exit 1
fi
echo "🌊 Ruby version $RUBY_VERSION is OK."

# ==========================================
# 下载文件（根据新目录放置）
# ==========================================

echo "🌊 Downloading wave..."
sudo curl -fsSL -o "$LIB_DIR/wave" "$WAVE_URL"
sudo chmod +x "$LIB_DIR/wave"

echo "🌊 Downloading help.py..."
sudo curl -fsSL -o "$LIB_DIR/help.py" "$HELP_URL"

echo "🌊 Downloading pkginstaller.py..."
sudo curl -fsSL -o "$REPO_DIR/pkginstaller.py" "$PKGINSTALLER_URL"

echo "🌊 Downloading versionparser.py..."
sudo curl -fsSL -o "$REPO_DIR/versionparser.py" "$VERSION_PARSER_URL"

echo "🌊 Downloading pkgparser.rb..."
sudo curl -fsSL -o "$REPO_DIR/pkgparser.rb" "$PARSER_URL"
sudo chmod +x "$REPO_DIR/pkgparser.rb"

echo "🌊 Downloading pkginfo_${ARCH}.txt..."
sudo curl -fsSL -o "$REPO_DIR/pkginfo_${ARCH}.txt" "$PKGINFO_URL"

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
# 添加到 PATH（bin 和 lib 目录都要加）
# ==========================================

if [[ "$SHELL" == *"zsh"* ]]; then
    RC_FILE="$HOME/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then
    RC_FILE="$HOME/.bashrc"
else
    RC_FILE="$HOME/.profile"
fi

if ! grep -q "$INSTALL_DIR" "$RC_FILE" 2>/dev/null; then
    echo "🌊 Adding MacWave to PATH in $RC_FILE..."
    echo "" >> "$RC_FILE"
    echo "# MacWave" >> "$RC_FILE"
    echo "export PATH=\"$INSTALL_DIR:$LIB_DIR:\$PATH\"" >> "$RC_FILE"
else
    echo "🌊 MacWave is already in your PATH."
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
echo "🌊 Try it now:"
echo "    wave install test_001"

# ==========================================
# 许可协议确认
# ==========================================

echo ""
echo -e "${YELLOW}Please read the agreement before use (see bottom of https://macwave.org).${RESET}"
echo -e "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}"
read -r agreement < /dev/tty
if [[ $agreement =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}You have agreed to the agreement. Installation continues.${RESET}"
else
    echo -e "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}"
    exit 1
fi
