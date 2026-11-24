#!/bin/bash

# depsinstaller.sh
# 依赖安装入口：接收 depsinstaller.py 传来的长字符串与依赖列表，
# 把依赖安装到 BASE_DIR/deps/{依赖引用名}/{依赖引用名}@{版本号}/，
# 创建软链接、写入 _DEPS，并记录“谁依赖了我”的标记文件。

set -e

# -------------------- 引入通用安装核心 --------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/depsmanager.sh"

# -------------------- 拆解参数 --------------------

INPUT_STR="$1"
DEPS_STR="$2"

if [[ -z "$INPUT_STR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: No input received.${RESET}"
    exit 1
fi

# -------------------- 安装依赖本体 --------------------

# 依赖包多为库包，整棵目录保留，bin/ 下的可执行文件由 links/ 提供
mw_install_artifact "$INPUT_STR" "$DEPS_STR" "tree" "dependency"

# -------------------- 记录依赖者 --------------------

if [[ -n "$MW_DEPENDER" ]]; then
    DEPENDER_KIND="${MW_DEPENDER%%:*}"
    DEPENDER_REF="${MW_DEPENDER#*:}"
    DEPENDER_NAME="${DEPENDER_REF%@*}"
    DEPENDER_VERSION="${DEPENDER_REF#*@}"

    if [[ -z "$DEPENDER_KIND" || -z "$DEPENDER_NAME" || -z "$DEPENDER_VERSION" || "$DEPENDER_REF" == "$DEPENDER_NAME" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Invalid depender info '$MW_DEPENDER'.${RESET}"
        exit 1
    fi

    mw_tag_add_depender "$MW_TARGET_DIR" "$DEPENDER_KIND" "$DEPENDER_NAME" "$DEPENDER_VERSION"
fi

# -------------------- 输出成功 --------------------

echo -e "${GREEN}🌊 Successfully installed ${MW_NAME}@${MW_VERSION}${RESET}"
DISPLAY_DIR="${MW_TARGET_DIR/$HOME/~}"
echo "🌊 Dependency installed to: $DISPLAY_DIR"
exit 0
