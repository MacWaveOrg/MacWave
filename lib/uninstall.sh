#!/bin/bash
# MacWave Uninstaller
# 卸载 MacWave 及清理环境配置

SYSTEM_CONFIG_DIR="/opt/macwave_config"
USER_CONFIG_DIR="$HOME/.config/macwave_config"
ARCH=$(uname -m)

# ==========================================
# 命令行参数（批量 / 脚本化卸载）
# ==========================================

CLI_FORCE=false
CLI_REMOVE_USER=false

usage() {
    cat <<'USAGE_EOF'
MacWave uninstaller

Usage:
  uninstall.sh [options]

Options:
      --force         No confirmation prompt. Removes MacWave and its
                      configuration.
      --remove-user   Accepted for compatibility with LinuxWave. MacWave has no
                      dedicated account, so this does nothing.
      -h, --help      Show this help.

Without options the uninstaller asks once before deleting.
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            CLI_FORCE=true
            ;;
        --remove-user)
            CLI_REMOVE_USER=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "🌊 Error: unknown option '$1'. Try --help." >&2
            exit 1
            ;;
    esac
    shift
done

# 通过管道卸载时，选项容易被当成脚本名传进来（--force 会静默失效）
case "$0" in
    -*)
        echo "🌊 Warning: '$0' was treated as the script name, not as an option." >&2
        echo "🌊 When piping the uninstaller, pass options after 'bash -s --'." >&2
        echo "🌊   curl -fsSL <url> | bash -s -- $0" >&2
        ;;
esac

# 默认尝试删除的路径列表
BASE_DIRS=()

# 1. 如果配置文件存在，优先读取（系统级与用户级都读，两边都卸干净）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -f "$CONFIG_DIR/config.json" ]; then
        READ_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json')).get('base_dir', ''))" 2>/dev/null)
        if [ -n "$READ_DIR" ]; then
            BASE_DIRS+=("$READ_DIR")
        fi
    fi
done

# 2. 如果读取失败（或文件不存在），把所有可能的路径都加入列表
if [ ${#BASE_DIRS[@]} -eq 0 ]; then
    BASE_DIRS+=("$HOME/.local/macwave")
    BASE_DIRS+=("/opt/macwave")
    # Intel Mac 才有 /usr/local/macwave
    if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
        BASE_DIRS+=("/usr/local/macwave")
    fi
fi

if [[ "$CLI_REMOVE_USER" == "true" ]]; then
    echo "🌊 --remove-user: MacWave has no dedicated account, nothing to remove."
fi

if [[ "$CLI_FORCE" == "true" ]]; then
    echo "🌊 --force: uninstalling without confirmation."
else
    echo -e "\033[1;31mYou are deleting MacWave, are you sure? [Y/n]\033[0m"
    read -n 1 -r
    echo
    if [[ -n "$REPLY" && ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "🌊 Uninstall cancelled."
        exit 0
    fi
fi

# 逐个尝试删除所有可能的路径
for DIR in "${BASE_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        # 如果是系统级目录，需要 sudo
        if [[ "$DIR" == "$HOME"* ]]; then
            echo "🌊 Removing $DIR..."
            rm -rf "$DIR"
        else
            echo "🌊 Removing $DIR (with sudo)..."
            sudo rm -rf "$DIR"
        fi
    fi
done

# 删除配置目录（系统级与用户级都可能存在）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -d "$CONFIG_DIR" ]; then
        if [[ "$CONFIG_DIR" == "$HOME"* ]]; then
            echo "🌊 Removing $CONFIG_DIR..."
            rm -rf "$CONFIG_DIR"
        else
            echo "🌊 Removing $CONFIG_DIR (with sudo)..."
            sudo rm -rf "$CONFIG_DIR"
        fi
    fi
done

# 清理 PATH 配置（含自定义安装目录：删掉“# MacWave”注释行与紧跟在它后面的 PATH 行）
for RC_FILE in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$RC_FILE" ]; then
        python3 - "$RC_FILE" << 'PYEOF'
import sys
from pathlib import Path

rc_file = Path(sys.argv[1])
kept = []
skip_next = False
for line in rc_file.read_text().splitlines():
    if line.strip() == "# MacWave":
        skip_next = True
        continue
    if skip_next and line.startswith("export PATH="):
        skip_next = False
        continue
    skip_next = False
    kept.append(line)
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
        # 兜底：注释行缺失时，仍按旧版写法删掉 macwave 的 PATH 行
        sed -i '' '/export PATH=".*macwave\//d' "$RC_FILE" 2>/dev/null || true
        echo "🌊 Removed MacWave PATH entries from $RC_FILE"
    fi
done

echo ""
echo "🌊 MacWave has been uninstalled."
echo "🌊 Please restart your terminal to apply changes."

# ========== 删除自身脚本 ==========
rm -f "$0"
exit 0
