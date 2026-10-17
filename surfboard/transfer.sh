#!/bin/bash

# transfer.sh
# MacWave 🌊 路径替换 ：把安装好的产物里所有 Mach-O 文件的
# 动态库引用（LC_LOAD_DYLIB）与自身 install name（LC_ID_DYLIB）改写成
# BASE_DIR 下的绝对路径，让运行时 dyld 能真正加载依赖包里的库。
#
# 用法: bash transfer.sh <目标目录> <BASE_DIR> 或 /bin/bash bash transfer.sh <目标目录> <BASE_DIR>
#
# 解析优先级：
#   1. 目标目录内部的库（产物自己的 lib/，含子目录）
#   2. _DEPS 里列出的依赖所提供的库（deps/{依赖名}/{依赖名}@{版本号}/lib）
#   3. 其余已安装依赖的 lib（兜底，用于传递依赖）
#
# 只处理 Mach-O；系统库（/usr/lib、/System、/Library/Apple）不动。
# 改过的文件会重新做 ad-hoc 签名——Apple Silicon 上这是必须的，否则无法运行。

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 参数与检查 --------------------

TARGET_DIR="$1"
BASE_DIR="$2"
# 可选：多个 target 共用的兜底索引目录。统一收尾会连续处理几十个 target，
# 若每个都重建"全部依赖"的索引就是 O(n²)（实测 18 个依赖要跑 5 分钟）。
# 调用方给一个目录，这里建一次、其余复用。
SHARED_INDEX_DIR="${3:-}"

if [[ -z "$TARGET_DIR" || -z "$BASE_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Missing target directory or base directory.${RESET}"
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Target directory not found: $TARGET_DIR${RESET}"
    exit 1
fi

for tool in otool install_name_tool codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${YELLOW}🌊 Warning: '$tool' not found, skipping path transfer.${RESET}"
        exit 0
    fi
done

# -------------------- 库索引（名字 -> 绝对路径） --------------------

MAP_FILE="$(mktemp -t macwave-transfer)"
TREE_FILE="$(mktemp -t macwave-tree)"
# 共享兜底索引（可选）：调用方给了目录就指向那里的两个文件，由 build_fallback_index 建一次
SHARED_MAP=""
SHARED_TREE=""
if [[ -n "$SHARED_INDEX_DIR" ]]; then
    SHARED_MAP="$SHARED_INDEX_DIR/map"
    SHARED_TREE="$SHARED_INDEX_DIR/tree"
fi
UNRESOLVED_FILE="$(mktemp -t macwave-unresolved)"
MISSING_FILE="$(mktemp -t macwave-missing)"
EXTERNAL_FILE="$(mktemp -t macwave-external)"
FAILED_FILE="$(mktemp -t macwave-failed)"
ERROR_FILE="$(mktemp -t macwave-error)"

cleanup() {
    rm -f "$MAP_FILE" "$TREE_FILE" "$UNRESOLVED_FILE" "$MISSING_FILE" "$EXTERNAL_FILE" "$FAILED_FILE" "$ERROR_FILE"
}
trap cleanup EXIT

index_tree() {
    # 把整棵树登记成 "名字|绝对路径"。
    # 只用 find + bash 内建（${file##*/} 取名字、printf 输出），并且把重定向放在
    # 循环外：原来每行一次 $(basename) 是 fork、一次 >> 是开关文件，依赖树有上万
    # 文件时这两项就是主要瓶颈。
    # 软链接也要收（conda 的 libc++.1.dylib 常是指向 libc++.1.0.dylib 的链接），
    # [[ -f ]] 会把悬空链接滤掉（macOS 的 find 不支持 -xtype）。
    local root="$1" out="$2"
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            printf '%s|%s\n' "${file##*/}" "$file"
        fi
    done < <(find "$root" \( -type f -o -type l \) 2>/dev/null) >> "$out"
}

list_tree_names() {
    # 只登记文件名，用于分辨“我们的树里有但没接上”与“根本不属于我们的库”
    local root="$1" out="$2"
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            printf '%s\n' "${file##*/}"
        fi
    done < <(find "$root" \( -type f -o -type l \) 2>/dev/null) >> "$out"
}

build_fallback_index() {
    # 兜底索引：给了一批已安装依赖，供"引用没写在 _DEPS 里"时兜底解析。
    # 有共享目录就在那里建一次（后续 target 直接复用）；没有就扫进自己的索引。
    if [[ -n "$SHARED_INDEX_DIR" ]]; then
        if [[ ! -s "$SHARED_MAP" ]]; then
            mkdir -p "$SHARED_INDEX_DIR"
            local tree
            for tree in "$BASE_DIR"/deps/*/*; do
                if [[ -d "$tree" ]]; then
                    index_tree "$tree" "$SHARED_MAP"
                fi
            done
            for tree in "$BASE_DIR"/deps/*/*; do
                if [[ -d "$tree" ]]; then
                    list_tree_names "$tree" "$SHARED_TREE"
                fi
            done
        fi
    else
        local tree
        for tree in "$BASE_DIR"/deps/*/*; do
            if [[ -d "$tree" ]]; then
                index_tree "$tree" "$MAP_FILE"
            fi
        done
        for tree in "$BASE_DIR"/deps/*/*; do
            if [[ -d "$tree" ]]; then
                list_tree_names "$tree" "$TREE_FILE"
            fi
        done
    fi
}

map_lookup() {
    # 命中则输出绝对路径，否则返回 1。先查本 target 自己的索引（_DEPS 优先），
    # 再查共享兜底索引。
    local name="$1" line
    line="$(grep -m1 -F "$name|" "$MAP_FILE" 2>/dev/null || true)"

    if [[ -z "$line" && -n "$SHARED_MAP" ]]; then
        line="$(grep -m1 -F "$name|" "$SHARED_MAP" 2>/dev/null || true)"
    fi

    if [[ -z "$line" ]]; then
        return 1
    fi

    echo "${line#*|}"
}

name_in_tree() {
    # 名字是否出现在"我们自己的树"里（含共享兜底索引）
    local name="$1"
    grep -qxF "$name" "$TREE_FILE" 2>/dev/null && return 0
    [[ -n "$SHARED_TREE" ]] && grep -qxF "$name" "$SHARED_TREE" 2>/dev/null && return 0
    return 1
}

# 1. 目标目录自身
index_tree "$TARGET_DIR" "$MAP_FILE"
list_tree_names "$TARGET_DIR" "$TREE_FILE"

# 2. _DEPS 列出的依赖（优先于其它同名库）
DEPS_FILE="$TARGET_DIR/_DEPS"
if [[ -f "$DEPS_FILE" ]]; then
    while IFS= read -r line; do
        ref="${line//\"/}"
        ref="${ref// /}"

        if [[ -z "$ref" || "$ref" != *@* ]]; then
            continue
        fi

        dep_name="${ref%@*}"
        dep_version="${ref##*@}"
        index_tree "$BASE_DIR/deps/$dep_name/$dep_name@$dep_version" "$MAP_FILE"
    done < "$DEPS_FILE"
fi

# 3. 其余已安装依赖（兜底）：整棵树都进索引，不能只扫 lib/ ——
#    依赖的解压目录未必是标准布局（例如 libcxx 的包只有 lib/ 一个顶层目录，
#    会被当成包装目录下沉一层，库文件就落在版本目录根下而不是 lib/ 里）。
#    这些名字同时记进"我们的树"，用于后续分流未解析引用。
#    这一步是 O(依赖数)，统一收尾时借助共享索引只做一次。
build_fallback_index

# -------------------- 辅助函数 --------------------

is_system_path() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

list_macho_files() {
    # 一次 Python 调用列出树里的 Mach-O（按魔数判断），而不是逐个文件 fork
    # `od`/`head`：依赖树有上万文件时，光这一项的开销就超过真正的重写。
    # 与 `find -type f` 保持一致：跳过符号链接本身（链接指向的真实文件会被处理）。
    # 静态库（!<arch>）不参与运行时加载，同样被过滤掉。
    local root="$1"
    python3 - "$root" <<'PY'
import os
import sys

MAGICS = {
    "cffaedfe", "cefaedfe", "feedfacf", "feedface", "cafebabe", "bebafeca",
}

for dirpath, _dirnames, filenames in os.walk(sys.argv[1]):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        try:
            with open(path, "rb") as handle:
                if handle.read(4).hex() in MAGICS:
                    print(path)
        except OSError:
            continue
PY
}

# -------------------- 逐个 Mach-O 替换 --------------------

CHANGED=0

while IFS= read -r file; do
    if ! otool_output="$(otool -L "$file" 2>/dev/null)"; then
        continue
    fi

    if [[ -z "$otool_output" ]]; then
        continue
    fi

    modified=0

    while IFS= read -r ref_line; do
        # otool -L 里只有缩进行是库引用（首行是文件名）
        if [[ "$ref_line" != [[:space:]]* ]]; then
            continue
        fi

        old_path="$(printf '%s' "$ref_line" | awk '{print $1}')"
        if [[ -z "$old_path" ]]; then
            continue
        fi

        if is_system_path "$old_path"; then
            continue
        fi

        new_path="$(map_lookup "${old_path##*/}" || true)"

        if [[ "$new_path" == "$old_path" ]]; then
            # 已经指向正确位置
            continue
        fi

        if [[ -z "$new_path" ]]; then
            # 连"是哪个文件"一起记下来：只看引用名会分不清是目标文件自己引用的
            # 还是某次重定位太早（依赖还没装）留下的
            echo "$file|$old_path" >> "$UNRESOLVED_FILE"
            continue
        fi

        if install_name_tool -change "$old_path" "$new_path" "$file" 2>"$ERROR_FILE"; then
            modified=1
        else
            # 不要静默：改不动的话这个二进制运行时一定加载失败（最常见的原因是
            # 它没预留 headerpad，装不下更长的路径），必须让用户当场知道
            echo "$file|$old_path|$(head -n 1 "$ERROR_FILE")" >> "$FAILED_FILE"
        fi
    done <<< "$otool_output"

    # dylib 自身的 install name 也要指向实际位置。
    # 只有本来就有 LC_ID_DYLIB 的文件才改：engines/ossl-modules 里的插件是
    # MH_BUNDLE 类型，本来没有 id，install_name_tool 也设不上，硬设会每次空改一遍。
    if [[ "$file" == *.dylib ]]; then
        current_id="$(otool -D "$file" 2>/dev/null | sed -n '2p' || true)"
        if [[ -n "$current_id" && "$current_id" != "$file" ]]; then
            if install_name_tool -id "$file" "$file" 2>"$ERROR_FILE"; then
                modified=1
            else
                echo "$file|(install name)|$(head -n 1 "$ERROR_FILE")" >> "$FAILED_FILE"
            fi
        fi
    fi

    if [[ "$modified" -eq 1 ]]; then
        if ! codesign --force --sign - "$file" >/dev/null 2>&1; then
            echo -e "${YELLOW}🌊 Warning: Failed to re-sign: $file${RESET}"
        fi
        CHANGED=$((CHANGED + 1))
    fi
done < <(list_macho_files "$TARGET_DIR")

# -------------------- 输出 --------------------

if [[ "$CHANGED" -gt 0 ]]; then
    echo "🌊 Relocated $CHANGED Mach-O file(s) in ${TARGET_DIR#"$BASE_DIR"/}"
fi

if [[ -s "$FAILED_FILE" ]]; then
    failed_count="$(wc -l < "$FAILED_FILE" | tr -d ' ')"
    echo -e "${YELLOW}🌊 Warning: $failed_count library reference(s) could not be rewritten:${RESET}"
    while IFS='|' read -r failed_file failed_ref failed_reason; do
        echo -e "${YELLOW}🌊   ${failed_file#"$BASE_DIR"/}: $failed_ref${RESET}"
        if [[ -n "$failed_reason" ]]; then
            echo -e "${YELLOW}🌊     $failed_reason${RESET}"
        fi
    done < <(sort -u "$FAILED_FILE" | head -10)
    echo -e "${YELLOW}🌊 This binary will fail to load them at runtime. It was most likely built without header space for a longer path (no -headerpad), so it cannot be relocated in place.${RESET}"
fi

if [[ -s "$UNRESOLVED_FILE" ]]; then
    # 分流：我们自己的树里存在同名文件 → 真的没接上（警告）；
    #       树里根本没有 → 外部/未声明的依赖，MacWave 无从接，只作提示。
    while IFS= read -r entry; do
        ref="${entry##*|}"
        if name_in_tree "${ref##*/}"; then
            echo "$entry" >> "$MISSING_FILE"
        else
            echo "$entry" >> "$EXTERNAL_FILE"
        fi
    done < "$UNRESOLVED_FILE"

    if [[ -s "$MISSING_FILE" ]]; then
        missing_count="$(wc -l < "$MISSING_FILE" | tr -d ' ')"
        echo -e "${YELLOW}🌊 Warning: $missing_count library reference(s) exist in this installation but could not be linked:${RESET}"
        sort -u "$MISSING_FILE" | head -10 | while IFS= read -r entry; do
            echo -e "${YELLOW}🌊   ${entry##*|}  (被 $(basename "${entry%%|*}") 引用)${RESET}"
        done
    fi

    if [[ -s "$EXTERNAL_FILE" ]]; then
        external_count="$(wc -l < "$EXTERNAL_FILE" | tr -d ' ')"
        echo "🌊 Note: $external_count library reference(s) not provided by any installed dependency, left unchanged:"
        sort -u "$EXTERNAL_FILE" | head -10 | while IFS= read -r entry; do
            echo "🌊   ${entry##*|}  (被 $(basename "${entry%%|*}") 引用)"
        done
    fi
fi

exit 0
