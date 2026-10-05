#!/bin/bash

# MacWave 🌊 Self Updater
# Re-downloads every MacWave code file and refreshes VERSION.json in the
# active config dir (/opt/macwave_config or ~/.config/macwave_config).
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

REPO="Sha0huaZhang/MacWave"
BRANCH="${MACWAVE_UPDATE_BRANCH:-${1:-main}}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
VERSION_DATA_URL="https://raw.githubusercontent.com/$REPO/configdata/versiondata/latest_version"

# 配置目录：系统级优先，其次用户级（与 lib/configpaths.py 的规则一致）
SYSTEM_CONFIG_DIR="/opt/macwave_config"
USER_CONFIG_DIR="$HOME/.config/macwave_config"

CONFIG_DIR=""
for candidate in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [[ -f "$candidate/config.json" ]]; then
        CONFIG_DIR="$candidate"
        break
    fi
done

if [[ -z "$CONFIG_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: MacWave is not installed (no config.json in $SYSTEM_CONFIG_DIR or $USER_CONFIG_DIR).${RESET}"
    echo -e "${RED_BOLD}🌊 Install it first with lib/install.sh.${RESET}"
    exit 1
fi

CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

if [[ "$CONFIG_DIR" == "$HOME"* ]]; then
    CONFIG_NEED_SUDO=false
else
    CONFIG_NEED_SUDO=true
fi

echo "🌊 Updating from branch: $BRANCH"
echo ""

# ==========================================
# 读取安装目录
# ==========================================

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

# 安装目录与配置目录未必同级：用户级安装也可能读系统级配置（系统级优先），
# 所以配置目录单独判断权限。
config_cmd() {
    if [[ "$CONFIG_NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

if [[ "$NEED_SUDO" == "true" || "$CONFIG_NEED_SUDO" == "true" ]]; then
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
# 文件清单（configdata/versiondata/files_info）
# ==========================================
#
# 要更新哪些文件不再写死在本脚本里，而是去 configdata 分支读一份清单。
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
# 以后新增文件只要改 configdata 的这份清单，不用再动本脚本。

FILES_INFO_URL="https://raw.githubusercontent.com/$REPO/configdata/versiondata/files_info"
FILES_INFO_TMP="$(mktemp)"

cleanup_files_info() {
    rm -f "$FILES_INFO_TMP"
}
trap cleanup_files_info EXIT

echo "🌊 Fetching the file list..."

FILES_INFO_ATTEMPTS=3
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
    echo -e "${RED_BOLD}🌊 Nothing was updated. Check your network or proxy, then try again.${RESET}"
    exit 1
fi

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
    echo -e "${RED_BOLD}🌊 Error: The file list is empty, nothing to update.${RESET}"
    exit 1
fi

FILE_COUNT=$(printf '%s\n' "$FILE_ENTRIES" | wc -l | tr -d ' ')
echo "🌊 Updating $FILE_COUNT file(s) from branch: $BRANCH"
echo ""

# ==========================================
# 按清单更新
# ==========================================

while IFS=$'\t' read -r repo_path local_path executable; do
    if [[ -z "$repo_path" ]]; then
        continue
    fi

    echo "🌊 Updating $repo_path..."
    run_cmd mkdir -p "$(dirname "$BASE_DIR/$local_path")"
    run_cmd curl -fsSL -o "$BASE_DIR/$local_path" "$BASE_URL/$repo_path"

    if [[ "$executable" == "1" ]]; then
        run_cmd chmod +x "$BASE_DIR/$local_path"
    fi
done <<< "$FILE_ENTRIES"

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

config_cmd mkdir -p "$CONFIG_DIR"

config_cmd tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "$VERSION",
  "components": {
    "installer": "$VERSION",
    "parser": "$VERSION"
  }
}
EOF

if [[ "$CONFIG_NEED_SUDO" == "true" ]]; then
    sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
fi

config_cmd chmod 755 "$CONFIG_DIR"
config_cmd chmod 644 "$CONFIG_FILE" "$VERSION_FILE"

echo "🌊 Version saved to $VERSION_FILE"
exit 0
