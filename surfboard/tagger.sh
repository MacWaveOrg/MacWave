#!/bin/bash

# tagger.sh
# 管理依赖目录下的 .depped_* 标记文件（记录“谁依赖了我”）。
# 标记文件为空文件，命名规则：
#   .depped_pkg_{包名}@{版本号}    该依赖被某个软件包依赖
#   .depped_dep_{依赖名}@{版本号}  该依赖被某个依赖依赖
#
# 命令行用法：
#   bash tagger.sh create-pkg <标记目录> <包名> <版本号>
#   bash tagger.sh create-dep <标记目录> <依赖名> <版本号>
#   bash tagger.sh delete-pkg <标记目录> <包名> <版本号>
#   bash tagger.sh delete-dep <标记目录> <依赖名> <版本号>
#   bash tagger.sh has-marks  <标记目录>   # 退出码 0=还有标记，1=无标记
#
# 也可被其他脚本 source 后调用 tagger_create / tagger_delete / tagger_has_any。

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 标记函数 --------------------

tagger_mark_name() {
    # 生成标记文件名
    local kind="$1"
    local name="$2"
    local version="$3"
    echo ".depped_${kind}_${name}@${version}"
}

tagger_create() {
    # 创建一个空标记文件，重复创建不报错
    local dir="$1"
    local kind="$2"
    local name="$3"
    local version="$4"

    if [[ ! -d "$dir" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Tag directory not found: $dir${RESET}"
        return 1
    fi

    : > "$dir/$(tagger_mark_name "$kind" "$name" "$version")"
}

tagger_delete() {
    # 删除标记文件，不存在时静默跳过
    local dir="$1"
    local kind="$2"
    local name="$3"
    local version="$4"

    local mark
    mark="$dir/$(tagger_mark_name "$kind" "$name" "$version")"
    if [[ -e "$mark" ]]; then
        rm -f "$mark"
    fi
}

tagger_has_any() {
    # 目录内是否还存在任意 .depped_* 标记
    local dir="$1"
    local marks=("$dir"/.depped_*)

    if [[ -e "${marks[0]}" ]]; then
        return 0
    fi
    return 1
}

# -------------------- 命令行入口 --------------------

tagger_main() {
    local action="$1"

    if [[ -z "$action" ]]; then
        echo -e "${RED_BOLD}🌊 Error: No action received.${RESET}"
        exit 1
    fi

    case "$action" in
        create-pkg)
            if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing arguments for create-pkg.${RESET}"
                exit 1
            fi
            tagger_create "$2" "pkg" "$3" "$4"
            ;;
        create-dep)
            if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing arguments for create-dep.${RESET}"
                exit 1
            fi
            tagger_create "$2" "dep" "$3" "$4"
            ;;
        delete-pkg)
            if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing arguments for delete-pkg.${RESET}"
                exit 1
            fi
            tagger_delete "$2" "pkg" "$3" "$4"
            ;;
        delete-dep)
            if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing arguments for delete-dep.${RESET}"
                exit 1
            fi
            tagger_delete "$2" "dep" "$3" "$4"
            ;;
        has-marks)
            if [[ -z "$2" ]]; then
                echo -e "${RED_BOLD}🌊 Error: Missing directory for has-marks.${RESET}"
                exit 1
            fi
            if tagger_has_any "$2"; then
                exit 0
            fi
            exit 1
            ;;
        *)
            echo -e "${RED_BOLD}🌊 Error: Unknown action '$action'.${RESET}"
            exit 1
            ;;
    esac

    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    tagger_main "$@"
fi
