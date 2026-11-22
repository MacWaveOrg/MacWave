#!/bin/bash

# pkginstaller.sh
# 软件包安装入口：接收 pkginstaller.py 传来的长字符串与依赖列表，
# 把软件包安装到 BASE_DIR/bin/{可执行文件名}@{版本号}/，
# 创建软链接、写入 _DEPS，并写入 installed.json。
# 具体安装动作复用 surfboard/depsmanager.sh（与依赖安装共用同一套逻辑）。

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 引入通用安装核心 --------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPSMANAGER_SCRIPT="$(dirname "$SCRIPT_DIR")/surfboard/depsmanager.sh"

if [[ ! -f "$DEPSMANAGER_SCRIPT" ]]; then
    echo -e "${RED_BOLD}🌊 Error: depsmanager.sh not found.${RESET}"
    exit 1
fi

source "$DEPSMANAGER_SCRIPT"

# -------------------- 拆解参数 --------------------

INPUT_STR="$1"
DEPS_STR="$2"

# -------------------- 安装软件包本体 --------------------

# 安装形态来自索引版本记录的 install 字段（缺省 binary），依赖走 tree 模式
# （见 surfboard/depsinstaller.sh）。整树软件包整棵落到 bin/{名}@{版本}/。
mw_install_artifact "$INPUT_STR" "$DEPS_STR" "" "package"

# -------------------- 写入 installed.json --------------------

INSTALLED_DB="$MW_BASE_DIR/pkg/installed.json"
mkdir -p "$(dirname "$INSTALLED_DB")"

python3 - "$INSTALLED_DB" "$MW_NAME" "$MW_VERSION" "$MW_TARGET_DIR" << 'PYEOF'
import sys
import json
import fcntl
import time
from pathlib import Path

db_path = Path(sys.argv[1])
pkg_name = sys.argv[2]
pkg_version = sys.argv[3]
binary_path = sys.argv[4]

db_path.parent.mkdir(parents=True, exist_ok=True)

with open(db_path, 'a+') as f:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
    f.seek(0)
    try:
        content = f.read()
        installed = json.loads(content) if content else {}
    except json.JSONDecodeError:
        installed = {}
    installed[pkg_name] = {
        "version": pkg_version,
        "binary_path": binary_path,
        "installed_at": time.time()
    }
    f.seek(0)
    f.truncate()
    json.dump(installed, f, indent=2)
PYEOF

# -------------------- 输出成功 --------------------

echo -e "${GREEN}🌊 Successfully installed ${MW_NAME}@${MW_VERSION}${RESET}"
DISPLAY_DIR="${MW_TARGET_DIR/$HOME/~}"
DISPLAY_LINK="${MW_LINK_PATH/$HOME/~}"
echo "🌊 Binary installed to: $DISPLAY_DIR/$MW_BIN_NAME"
echo "🌊 Link created at: $DISPLAY_LINK"
exit 0
