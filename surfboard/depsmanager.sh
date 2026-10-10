#!/bin/bash

# depsmanager.sh
# MacWave 🌊 通用安装核心：定位下载文件、SHA256 校验、解压、落盘、创建软链接、
# 写入 _DEPS、依赖标记文件管理。
# 由 pkg/pkginstaller.sh 与 surfboard/depsinstaller.sh source 使用，不单独执行。
#
# 传入的长字符串（由 Python 侧拼接，\n 分隔）：
#   第 1 行 名称（软件包名 / 依赖引用名）
#   第 2 行 版本号
#   第 3 行 SHA256（可为空）
#   第 4 行 安装目标目录（绝对路径）
#   第 5 行 BASE_DIR（绝对路径）
#   第 6 行 可执行文件名
#   第 7 行 依赖者信息（可选，形如 pkg:machox@1.0 / dep:openssl@3.0.15）
#   第 8 行 下载到的原文件名

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 引入标记文件管理 --------------------

MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAGGER_SCRIPT="$MANAGER_DIR/tagger.sh"

if [[ ! -f "$TAGGER_SCRIPT" ]]; then
    echo -e "${RED_BOLD}🌊 Error: tagger.sh not found.${RESET}"
    exit 1
fi

source "$TAGGER_SCRIPT"

# -------------------- 全局变量 --------------------

MW_NAME=""
MW_VERSION=""
MW_SHA256=""
MW_TARGET_DIR=""
MW_BASE_DIR=""
MW_BIN_NAME=""
MW_DEPENDER=""
MW_RELATIVE_DIR=""
MW_LINK_PATH=""
MW_ORIGINAL_NAME=""

# -------------------- 拆解长字符串 --------------------

mw_parse_info() {
    local input_str="$1"

    if [[ -z "$input_str" ]]; then
        echo -e "${RED_BOLD}🌊 Error: No input received.${RESET}"
        exit 1
    fi

    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done <<< "$input_str"

    MW_NAME="${lines[0]}"
    MW_VERSION="${lines[1]}"
    MW_SHA256="${lines[2]}"
    MW_TARGET_DIR="${lines[3]}"
    MW_BASE_DIR="${lines[4]}"
    MW_BIN_NAME="${lines[5]}"
    MW_DEPENDER="${lines[6]}"
    MW_ORIGINAL_NAME="${lines[7]}"

    if [[ -z "$MW_NAME" || -z "$MW_VERSION" || -z "$MW_TARGET_DIR" || -z "$MW_BASE_DIR" || -z "$MW_BIN_NAME" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Incomplete install info.${RESET}"
        exit 1
    fi
}

# -------------------- 原文件与校验 --------------------

mw_locate_original_file() {
    # 在下载临时目录里定位本次下载的原文件。
    # 传入原文件名时精确匹配，避免残留文件被误用；
    # 未传时退回“第一个非 .partial 文件”。
    local download_tmp="$1"
    local expected_name="$2"
    local found=""

    if [[ -n "$expected_name" ]]; then
        if [[ -f "$download_tmp/$expected_name" ]]; then
            echo "$download_tmp/$expected_name"
            return 0
        fi
        echo -e "${RED_BOLD}🌊 Error: Download file not found: $download_tmp/$expected_name${RESET}"
        exit 1
    fi

    for f in "$download_tmp"/*; do
        if [[ -f "$f" && "$f" != *.partial ]]; then
            found="$f"
            break
        fi
    done

    if [[ -z "$found" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Download file not found in $download_tmp.${RESET}"
        exit 1
    fi

    echo "$found"
}

mw_verify_sha256() {
    local original_file="$1"
    local expected_sha256="$2"

    if [[ -z "$expected_sha256" ]]; then
        echo -e "${YELLOW}🌊 Warning: No SHA256 provided, skipping verification.${RESET}"
        return 0
    fi

    echo "🌊 Verifying SHA256..."
    local actual_sha256
    actual_sha256=$(shasum -a 256 "$original_file" | awk '{print $1}')

    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        echo -e "${RED_BOLD}🌊 Error: SHA256 verification failed. Removing corrupted file.${RESET}"
        echo -e "${RED_BOLD}🌊 Actual:   $actual_sha256${RESET}"
        echo -e "${GREEN}🌊 Expected: $expected_sha256${RESET}"
        rm -f "$original_file"
        exit 1
    fi

    echo -e "${GREEN}🌊 SHA256 verification passed!${RESET}"
}

# -------------------- 解压与落盘 --------------------

mw_extract_binary() {
    # 解压压缩包并输出二进制文件路径（提示信息走 stderr，避免污染返回值）
    local original_file="$1"
    local extract_dir="$2"
    local unzip_script="$3"
    local bin_name="$4"

    case "$original_file" in
        *.zip|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar|*.gz|*.bz2|*.xz|*.conda)
            mkdir -p "$extract_dir"

            # 解压脚本的输出全部转 stderr，保证本函数的 stdout 只有二进制路径
            if ! bash "$unzip_script" "$original_file" "$extract_dir" >&2; then
                echo -e "${RED_BOLD}🌊 Error: Extraction failed.${RESET}" >&2
                rm -rf "$extract_dir"
                exit 1
            fi

            local file_count
            file_count=$(find "$extract_dir" -type f | wc -l | tr -d ' ')

            if [[ "$file_count" -eq 0 ]]; then
                echo -e "${RED_BOLD}🌊 Error: No binary found after extraction.${RESET}" >&2
                rm -rf "$extract_dir"
                exit 1
            fi

            # 同名优先：解压结果里 basename 与可执行文件名一致的文件
            local same_name_file=""
            same_name_file=$(find "$extract_dir" -type f -name "$bin_name" | head -n 1)

            if [[ -n "$same_name_file" ]]; then
                echo "$same_name_file"
                return 0
            fi

            if [[ "$file_count" -gt 1 ]]; then
                echo -e "${YELLOW}🌊 Warning: No file named '$bin_name' found, using the first one.${RESET}" >&2
            fi

            find "$extract_dir" -type f | head -n 1
            ;;
        *)
            # 裸二进制，直接使用下载到的原文件
            echo "$original_file"
            ;;
    esac
}

mw_install_binary() {
    local bin_file="$1"
    local target_dir="$2"
    local bin_name="$3"

    mkdir -p "$target_dir"
    mv "$bin_file" "$target_dir/$bin_name"
    chmod 755 "$target_dir/$bin_name"
}

mw_extract_all() {
    # 解压整包并输出可整体搬运的目录（提示信息走 stderr）
    local original_file="$1"
    local extract_dir="$2"
    local unzip_script="$3"

    case "$original_file" in
        *.zip|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar|*.gz|*.bz2|*.xz|*.conda)
            mkdir -p "$extract_dir"

            # 解压脚本的输出全部转 stderr，保证本函数的 stdout 只有目录路径
            if ! bash "$unzip_script" "$original_file" "$extract_dir" >&2; then
                echo -e "${RED_BOLD}🌊 Error: Extraction failed.${RESET}" >&2
                rm -rf "$extract_dir"
                exit 1
            fi

            # 只有一个顶层目录时视为包装目录，下沉一层便于后续搬运
            local entries=("$extract_dir"/*)
            if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
                echo "${entries[0]}"
                return 0
            fi

            echo "$extract_dir"
            ;;
        *)
            # 裸二进制，没有目录结构
            echo "$original_file"
            ;;
    esac
}

mw_install_tree() {
    # 保留整棵解压目录（依赖包是库包，不能只取一个文件）
    local source_dir="$1"
    local target_dir="$2"
    local bin_name="$3"

    mkdir -p "$target_dir"

    if [[ ! -d "$source_dir" ]]; then
        mv "$source_dir" "$target_dir/$bin_name"
        chmod 755 "$target_dir/$bin_name"
        return 0
    fi

    shopt -s dotglob
    mv "$source_dir"/* "$target_dir"/
    shopt -u dotglob

    # bin/ 下的文件保留可执行权限
    if [[ -d "$target_dir/bin" ]]; then
        find "$target_dir/bin" -type f -exec chmod 755 {} \;
    fi
}

mw_link_tree_binaries() {
    # 把依赖包里 bin/ 下的可执行文件软链到 links/{名字}@{版本号}，
    # 由已在 PATH 上的 links/ 目录提供命令，不再依赖“与包同名的二进制”。
    local base_dir="$1"
    local relative_dir="$2"
    local version="$3"
    local target_dir="$4"

    local bin_dir="$target_dir/bin"
    if [[ ! -d "$bin_dir" ]]; then
        echo -e "${YELLOW}🌊 Warning: No bin/ directory in this dependency, no command linked.${RESET}"
        return 0
    fi

    local file
    local name
    for file in "$bin_dir"/*; do
        if [[ ! -f "$file" ]]; then
            continue
        fi

        name="$(basename "$file")"
        mw_create_link "$base_dir" "$relative_dir/bin" "$name" "$name" "$version" > /dev/null
    done
}

# -------------------- 软链接 --------------------

mw_create_link() {
    # links/{链接名}@{版本号} -> ../{相对目录}/{目标名}
    # 软件包：链接名 = 可执行文件名；依赖：每个 bin/ 下的可执行文件各一条
    local base_dir="$1"
    local relative_dir="$2"
    local target_name="$3"
    local link_name="$4"
    local version="$5"

    local links_dir="$base_dir/links"
    local link_path="$links_dir/$link_name@$version"
    mw_assert_inside "$link_path"

    mkdir -p "$links_dir"

    # 重装场景：软链接已存在则先删除再创建
    if [[ -L "$link_path" || -e "$link_path" ]]; then
        rm -f "$link_path"
    fi

    ln -s "../$relative_dir/$target_name" "$link_path"

    echo "$link_path"
}

# -------------------- _DEPS --------------------

mw_write_deps_file() {
    # 每行一个依赖，形如 "a@1.0"
    local target_dir="$1"
    local deps_str="$2"
    local deps_file="$target_dir/_DEPS"

    : > "$deps_file"

    if [[ -z "$deps_str" ]]; then
        return 0
    fi

    local line
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            echo "\"$line\"" >> "$deps_file"
        fi
    done <<< "$deps_str"
}

# -------------------- 标记文件 --------------------

mw_tag_add_depender() {
    # 在依赖目录下记录“谁依赖了我”
    local dir="$1"
    local kind="$2"
    local name="$3"
    local version="$4"

    tagger_create "$dir" "$kind" "$name" "$version"
}

mw_tag_remove_depender() {
    local dir="$1"
    local kind="$2"
    local name="$3"
    local version="$4"

    tagger_delete "$dir" "$kind" "$name" "$version"
}

mw_tag_has_marks() {
    local dir="$1"

    tagger_has_any "$dir"
}

# -------------------- 路径安全兜底 --------------------

mw_assert_inside() {
    # 目标路径必须落在 BASE_DIR 之内。Python 侧已经校验过输入字符，
    # 这里再兜一层，避免将来有别的调用方绕过校验。
    local path="$1"
    case "$path" in
        "$MW_BASE_DIR"/*) return 0 ;;
        *)
            echo -e "${RED_BOLD}🌊 Error: Refusing to write outside ${MW_BASE_DIR}: ${path}${RESET}" >&2
            exit 1
            ;;
    esac
}

# -------------------- 通用安装流程 --------------------

mw_install_artifact() {
    # 软件包与依赖共用的安装流程，区别只在安装形态：
    #   binary：只取一个可执行文件（软件包）
    #   tree  ：保留整棵解压目录，并把 bin/ 下的可执行文件软链到 links/（依赖）
    local info_str="$1"
    local deps_str="$2"
    local install_mode="${3:-binary}"

    mw_parse_info "$info_str"
    mw_assert_inside "$MW_TARGET_DIR"

    local unzip_script="$MW_BASE_DIR/pkg/pkgunzip.sh"
    if [[ ! -f "$unzip_script" ]]; then
        echo -e "${RED_BOLD}🌊 Error: pkgunzip.sh not found.${RESET}"
        exit 1
    fi

    local download_tmp="$MW_BASE_DIR/downloads/tmp"
    local original_file
    original_file="$(mw_locate_original_file "$download_tmp" "$MW_ORIGINAL_NAME")"

    mw_verify_sha256 "$original_file" "$MW_SHA256"

    echo "🌊 Extracting package..."
    local extract_dir="$download_tmp/extract_$$"
    MW_RELATIVE_DIR="${MW_TARGET_DIR#"$MW_BASE_DIR"/}"

    if [[ "$install_mode" == "tree" ]]; then
        local tree_dir
        tree_dir="$(mw_extract_all "$original_file" "$extract_dir" "$unzip_script")"
        mw_install_tree "$tree_dir" "$MW_TARGET_DIR" "$MW_BIN_NAME"
        mw_link_tree_binaries "$MW_BASE_DIR" "$MW_RELATIVE_DIR" "$MW_VERSION" "$MW_TARGET_DIR"
    else
        local bin_file
        bin_file="$(mw_extract_binary "$original_file" "$extract_dir" "$unzip_script" "$MW_BIN_NAME")"
        mw_install_binary "$bin_file" "$MW_TARGET_DIR" "$MW_BIN_NAME"
        MW_LINK_PATH="$(mw_create_link "$MW_BASE_DIR" "$MW_RELATIVE_DIR" "$MW_BIN_NAME" "$MW_BIN_NAME" "$MW_VERSION")"
    fi

    rm -rf "$extract_dir"
    rm -f "$original_file"

    mw_write_deps_file "$MW_TARGET_DIR" "$deps_str"
}
