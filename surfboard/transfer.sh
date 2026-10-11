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
UNRESOLVED_FILE="$(mktemp -t macwave-unresolved)"
MISSING_FILE="$(mktemp -t macwave-missing)"
EXTERNAL_FILE="$(mktemp -t macwave-external)"
FAILED_FILE="$(mktemp -t macwave-failed)"
ERROR_FILE="$(mktemp -t macwave-error)"

cleanup() {
    rm -f "$MAP_FILE" "$TREE_FILE" "$UNRESOLVED_FILE" "$MISSING_FILE" "$EXTERNAL_FILE" "$FAILED_FILE" "$ERROR_FILE"
}
trap cleanup EXIT

map_add_file() {
    local file="$1"
    echo "$(basename "$file")|$file" >> "$MAP_FILE"
}

map_add_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    local file
    for file in "$dir"/*; do
        if [[ -f "$file" ]]; then
            map_add_file "$file"
        fi
    done
}

map_add_tree() {
    local root="$1"
    local file
    # 软链接也要进索引：conda 的库里 libc++.1.dylib 往往是指向 libc++.1.0.dylib
    # 的软链接，只找 -type f 会漏掉它，引用就永远接不上（-f 会自动跳过悬空链接）。
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            map_add_file "$file"
        fi
    done < <(find "$root" \( -type f -o -type l \) 2>/dev/null)
}

tree_add_tree() {
    # 只登记文件名，用于分辨“我们的树里有但没接上”与“根本不属于我们的库”
    local root="$1"
    local file
    while IFS= read -r file; do
        echo "$(basename "$file")" >> "$TREE_FILE"
    done < <(find "$root" \( -type f -o -type l \) 2>/dev/null)
}

map_lookup() {
    # 命中则输出绝对路径，否则返回 1
    local name="$1"
    local line
    line="$(grep -m1 -F "$name|" "$MAP_FILE" 2>/dev/null || true)"

    if [[ -z "$line" ]]; then
        return 1
    fi

    echo "${line#*|}"
}

# 1. 目标目录自身
map_add_tree "$TARGET_DIR"
tree_add_tree "$TARGET_DIR"

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
        map_add_dir "$BASE_DIR/deps/$dep_name/$dep_name@$dep_version/lib"
    done < "$DEPS_FILE"
fi

# 3. 其余已安装依赖的 lib（兜底）
for dep_lib in "$BASE_DIR"/deps/*/*/lib; do
    map_add_dir "$dep_lib"
done

# 4. 记录“我们自己的树”里出现过的文件名，用于后续分流未解析引用
for dep_tree in "$BASE_DIR"/deps/*/*; do
    if [[ -d "$dep_tree" ]]; then
        tree_add_tree "$dep_tree"
    fi
done

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

is_macho() {
    # 按魔数判断，避开 otool 对非 Mach-O 也会以 0 退出并打印一行提示的问题；
    # 静态库（!<arch>）在此直接滤掉，它们不参与运行时加载。
    local file="$1"
    local magic
    magic="$(head -c 4 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n')"

    case "$magic" in
        cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# -------------------- 逐个 Mach-O 替换 --------------------

CHANGED=0

while IFS= read -r file; do
    if ! is_macho "$file"; then
        continue
    fi

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
            echo "$old_path" >> "$UNRESOLVED_FILE"
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
done < <(find "$TARGET_DIR" -type f 2>/dev/null)

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
    while IFS= read -r ref; do
        if grep -qxF "${ref##*/}" "$TREE_FILE" 2>/dev/null; then
            echo "$ref" >> "$MISSING_FILE"
        else
            echo "$ref" >> "$EXTERNAL_FILE"
        fi
    done < "$UNRESOLVED_FILE"

    if [[ -s "$MISSING_FILE" ]]; then
        missing_count="$(wc -l < "$MISSING_FILE" | tr -d ' ')"
        echo -e "${YELLOW}🌊 Warning: $missing_count library reference(s) exist in this installation but could not be linked:${RESET}"
        sort -u "$MISSING_FILE" | head -10 | while IFS= read -r ref; do
            echo -e "${YELLOW}🌊   $ref${RESET}"
        done
    fi

    if [[ -s "$EXTERNAL_FILE" ]]; then
        external_count="$(wc -l < "$EXTERNAL_FILE" | tr -d ' ')"
        echo "🌊 Note: $external_count library reference(s) not provided by any installed dependency, left unchanged:"
        sort -u "$EXTERNAL_FILE" | head -10 | while IFS= read -r ref; do
            echo "🌊   $ref"
        done
    fi
fi

exit 0
