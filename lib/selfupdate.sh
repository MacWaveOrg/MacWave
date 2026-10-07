#!/bin/bash

# MacWave 🌊 Self Updater
# Re-downloads every MacWave code file and refreshes /opt/macwave_config/VERSION.json.
# Invoked by `wave selfupdate` through the update_command field in
# configdata/versiondata/latest_version, or directly:
#   bash lib/selfupdate.sh [branch]

set -e

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# ==========================================
# 目标仓库、分支与版本
# ==========================================

REPO="MacWaveOrg/MacWave"
BRANCH="${MACWAVE_UPDATE_BRANCH:-${1:-main}}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
VERSION_DATA_URL="https://raw.githubusercontent.com/$REPO/configdata/versiondata/latest_version"

CONFIG_DIR="/opt/macwave_config"
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

echo "🌊 Updating from branch: $BRANCH"
echo ""

# ==========================================
# 读取安装目录
# ==========================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED_BOLD}🌊 Error: MacWave is not installed (missing $CONFIG_FILE).${RESET}"
    echo -e "${RED_BOLD}🌊 Install it first with lib/install.sh.${RESET}"
    exit 1
fi

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")

if [[ -z "$BASE_DIR" || ! -d "$BASE_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot read base_dir from $CONFIG_FILE.${RESET}"
    exit 1
fi

LIB_DIR="$BASE_DIR/lib"
PKG_DIR="$BASE_DIR/pkg"
SURFBOARD_DIR="$BASE_DIR/surfboard"

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
    echo -e "${YELLOW}🌊 Requesting temporary administrator access for the update...${RESET}"
    sudo -v
fi

# ==========================================
# 确定目标版本
# ==========================================

VERSION="${MACWAVE_UPDATE_VERSION:-}"

if [[ -z "$VERSION" ]]; then
    VERSION=$(curl -fsSL --max-time 30 "$VERSION_DATA_URL" \
        | sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' \
        | head -n 1)
fi

if [[ -z "$VERSION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot determine the target version.${RESET}"
    exit 1
fi

echo "🌊 Updating MacWave to $VERSION"

# ==========================================
# 更新 lib/
# ==========================================

run_cmd mkdir -p "$LIB_DIR"

echo "🌊 Updating wave.py..."
run_cmd curl -fsSL -o "$LIB_DIR/wave" "$BASE_URL/lib/wave.py"
run_cmd chmod +x "$LIB_DIR/wave"

echo "🌊 Updating help.py..."
run_cmd curl -fsSL -o "$LIB_DIR/help.py" "$BASE_URL/lib/help.py"

echo "🌊 Updating configerror.py..."
run_cmd curl -fsSL -o "$LIB_DIR/configerror.py" "$BASE_URL/lib/configerror.py"

echo "🌊 Updating selfupdate.py..."
run_cmd curl -fsSL -o "$LIB_DIR/selfupdate.py" "$BASE_URL/lib/selfupdate.py"

echo "🌊 Updating selfupdate.sh..."
run_cmd curl -fsSL -o "$LIB_DIR/selfupdate.sh" "$BASE_URL/lib/selfupdate.sh"
run_cmd chmod +x "$LIB_DIR/selfupdate.sh"

# ==========================================
# 更新 pkg/
# ==========================================

run_cmd mkdir -p "$PKG_DIR"

echo "🌊 Updating pkginstaller.py..."
run_cmd curl -fsSL -o "$PKG_DIR/pkginstaller.py" "$BASE_URL/pkg/pkginstaller.py"

echo "🌊 Updating pkginstaller.sh..."
run_cmd curl -fsSL -o "$PKG_DIR/pkginstaller.sh" "$BASE_URL/pkg/pkginstaller.sh"
run_cmd chmod +x "$PKG_DIR/pkginstaller.sh"

echo "🌊 Updating pkginfohelper.py..."
run_cmd curl -fsSL -o "$PKG_DIR/pkginfohelper.py" "$BASE_URL/pkg/pkginfohelper.py"

echo "🌊 Updating uninstaller.py..."
run_cmd curl -fsSL -o "$PKG_DIR/uninstaller.py" "$BASE_URL/pkg/uninstaller.py"

echo "🌊 Updating pkgversionparser.py..."
run_cmd curl -fsSL -o "$PKG_DIR/pkgversionparser.py" "$BASE_URL/pkg/pkgversionparser.py"

echo "🌊 Updating pkgunzip.sh..."
run_cmd curl -fsSL -o "$PKG_DIR/pkgunzip.sh" "$BASE_URL/pkg/pkgunzip.sh"
run_cmd chmod +x "$PKG_DIR/pkgunzip.sh"

# ==========================================
# 更新 surfboard/
# ==========================================

run_cmd mkdir -p "$SURFBOARD_DIR"

echo "🌊 Updating depsinstaller.py..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsinstaller.py" "$BASE_URL/surfboard/depsinstaller.py"

echo "🌊 Updating depsinstaller.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsinstaller.sh" "$BASE_URL/surfboard/depsinstaller.sh"
run_cmd chmod +x "$SURFBOARD_DIR/depsinstaller.sh"

echo "🌊 Updating depsmanager.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsmanager.sh" "$BASE_URL/surfboard/depsmanager.sh"
run_cmd chmod +x "$SURFBOARD_DIR/depsmanager.sh"

echo "🌊 Updating depsversionparser.py..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/depsversionparser.py" "$BASE_URL/surfboard/depsversionparser.py"

echo "🌊 Updating querier.py..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/querier.py" "$BASE_URL/surfboard/querier.py"

echo "🌊 Updating tagger.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/tagger.sh" "$BASE_URL/surfboard/tagger.sh"
run_cmd chmod +x "$SURFBOARD_DIR/tagger.sh"

echo "🌊 Updating transfer.sh..."
run_cmd curl -fsSL -o "$SURFBOARD_DIR/transfer.sh" "$BASE_URL/surfboard/transfer.sh"
run_cmd chmod +x "$SURFBOARD_DIR/transfer.sh"

# ==========================================
# 清理旧的字节码缓存
# ==========================================

for cache in "$LIB_DIR/__pycache__" "$PKG_DIR/__pycache__" "$SURFBOARD_DIR/__pycache__"; do
    if [[ -d "$cache" ]]; then
        echo "🌊 Removing stale bytecode cache: ${cache#"$BASE_DIR"/}"
        run_cmd rm -rf "$cache"
    fi
done

# ==========================================
# 写入新的版本号
# ==========================================

run_cmd mkdir -p "$CONFIG_DIR"

run_cmd tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "$VERSION",
  "components": {
    "installer": "$VERSION",
    "parser": "$VERSION"
  }
}
EOF

if [[ "$NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
fi

run_cmd chmod 755 "$CONFIG_DIR"
run_cmd chmod 644 "$CONFIG_FILE" "$VERSION_FILE"

echo "🌊 Version saved to $VERSION_FILE"
exit 0
