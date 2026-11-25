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
#
# 4.6 起：产物如果已经是**位置无关**的形式（构建时就用 @loader_path 相对引用
# 重定位过），这里不再改写、也不再重签，只做一次"目标是否存在"的核对。
# 这样同一份字节在任意 BASE_DIR 下都成立，安装时零改写；见 docs/RELOCATION.md。

set -e

# -------------------- 颜色定义 --------------------

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# -------------------- 参数与检查 --------------------

# --relative：把引用写成 @loader_path 相对形式（而不是 BASE_DIR 下的绝对路径）。
# 用途有两个，都不是"每次安装必做"：
#   1. 把已装的老树（绝对路径）迁移成位置无关，之后整棵树可以搬走；
#   2. 兼容期里让老产物也直接落到相对形式。
# 从任意位置取走，剩下的按位置参数解释。
RELATIVE=0
CHECK_ONLY=0
RESCAN=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --relative|-r) RELATIVE=1 ;;
        --check) CHECK_ONLY=1 ;;
        --rescan) RESCAN=1 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

TARGET_DIR="${POSITIONAL[0]:-}"
BASE_DIR="${POSITIONAL[1]:-}"
# 可选：多个 target 共用的兜底索引目录。统一收尾会连续处理几十个 target，
# 若每个都重建"全部依赖"的索引就是 O(n²)（实测 18 个依赖要跑 5 分钟）。
# 调用方给一个目录，这里建一次、其余复用。
SHARED_INDEX_DIR="${POSITIONAL[2]:-}"

# -------------------- 构建时就重定位好的产物：直接跳过 --------------------
#
# 构建端（Ports/scripts/relocate_stage.sh）是照**运行时布局**（bin/<名>@<版本号>/、
# deps/<名>/<名>@<版本号>/）算相对路径的，所以打包出来的瓶已经是 @loader_path
# 形式，并在版本目录里留下 _RELOCATED 标记。这种产物在客户端没有任何要改的地方，
# 逐个文件确认只是白花时间（git 的 164 个 Mach-O 实测 6 秒）。
#
# 标记可信度：索引里的 sha256 锁的是整份产物，改标记就要改校验值，改不了。
# --check（`wave doctor` 用）与 --rescan 不跳过 —— 它们存在的意义就是真的扫一遍。
if [[ "$CHECK_ONLY" -eq 0 && "$RESCAN" -eq 0 && -f "$TARGET_DIR/_RELOCATED" ]]; then
    exit 0
fi

if [[ -z "$TARGET_DIR" || -z "$BASE_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Missing target directory or base directory.${RESET}"
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Target directory not found: $TARGET_DIR${RESET}"
    exit 1
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    # 只读检查：不改字节、不重签，所以只要 otool。缺了它才真的没法判断。
    # 退出码 2 = "判断不了"（缺 otool / 非 Darwin），与 1 = "确实有绝对路径" 区分开：
    # `wave doctor` 要把前者报成"跳过"，而不是"这个包是坏的"。
    if ! command -v otool >/dev/null 2>&1; then
        echo -e "${YELLOW}🌊 Note: 'otool' not found, cannot inspect Mach-O files.${RESET}"
        exit 2
    fi
else
    for tool in otool install_name_tool codesign; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo -e "${YELLOW}🌊 Warning: '$tool' not found, skipping path transfer.${RESET}"
            exit 0
        fi
    done
fi

# -------------------- 库索引（名字 -> 绝对路径） --------------------

MAP_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-transfer.XXXXXX")"
TREE_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-tree.XXXXXX")"
# 共享兜底索引（可选）：调用方给了目录就指向那里的两个文件，由 build_fallback_index 建一次
SHARED_MAP=""
SHARED_TREE=""
if [[ -n "$SHARED_INDEX_DIR" ]]; then
    SHARED_MAP="$SHARED_INDEX_DIR/map"
    SHARED_TREE="$SHARED_INDEX_DIR/tree"
fi
UNRESOLVED_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-unresolved.XXXXXX")"
MISSING_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-missing.XXXXXX")"
EXTERNAL_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-external.XXXXXX")"
FAILED_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-failed.XXXXXX")"
ERROR_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-error.XXXXXX")"
# --check 用：发现仍然写死绝对路径的引用/ID，一个都不改，只报告。
ABSOLUTE_FILE="$(mktemp "${TMPDIR:-/tmp}/macwave-absolute.XXXXXX")"

cleanup() {
    rm -f "$MAP_FILE" "$TREE_FILE" "$UNRESOLVED_FILE" "$MISSING_FILE" "$EXTERNAL_FILE" "$FAILED_FILE" "$ERROR_FILE" "$ABSOLUTE_FILE"
}
trap cleanup EXIT

index_tree() {
    # 把整棵树登记成 "名字|绝对路径"。
    # 只用 find + bash 内建（${file##*/} 取名字、printf 输出），并且把重定向放在
    # 循环外：原来每行一次 $(basename) 是 fork、一次 >> 是开关文件，依赖树有上万
    # 文件时这两项就是主要瓶颈。
    # 软链接也要收（conda 的 libc++.1.dylib 常是指向 libc++.1.0.dylib 的链接），
    # [[ -f ]] 会把悬空链接滤掉（macOS 的 find 不支持 -xtype）。
    # file 必须 local：这个函数会在主循环里被惰性调用（ensure_index），
    # 不声明就会把主循环的 $file 覆盖成"最后一个被索引的文件"。
    local root="$1" out="$2" file
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            printf '%s|%s\n' "${file##*/}" "$file"
        fi
    done < <(find "$root" \( -type f -o -type l \) 2>/dev/null) >> "$out"
}

list_tree_names() {
    # 只登记文件名，用于分辨“我们的树里有但没接上”与“根本不属于我们的库”
    # 同上：file 必须 local，否则覆盖主循环的 ${file}。
    local root="$1" out="$2" file
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

MAP_RESULT=""

map_lookup() {
    # 命中则把绝对路径写进 MAP_RESULT 并返回 0，否则返回 1。先查本 target
    # 自己的索引（_DEPS 优先），再查共享兜底索引。
    #
    # 用全局变量而不是 `$(...)` 输出：命令替换会开子 shell，ensure_index 的
    # 惰性初始化就带不回来，索引会被反复重建（依赖树有上万文件）。
    ensure_index
    local name="$1" line
    line="$(grep -m1 -F "$name|" "$MAP_FILE" 2>/dev/null || true)"

    if [[ -z "$line" && -n "$SHARED_MAP" ]]; then
        line="$(grep -m1 -F "$name|" "$SHARED_MAP" 2>/dev/null || true)"
    fi

    if [[ -z "$line" ]]; then
        return 1
    fi

    MAP_RESULT="${line#*|}"
}

name_in_tree() {
    # 名字是否出现在"我们自己的树"里（含共享兜底索引）
    ensure_index
    local name="$1"
    grep -qxF "$name" "$TREE_FILE" 2>/dev/null && return 0
    [[ -n "$SHARED_TREE" ]] && grep -qxF "$name" "$SHARED_TREE" 2>/dev/null && return 0
    return 1
}

build_index() {
    local line ref dep_name dep_version DEPS_FILE

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
}

INDEX_READY=0

ensure_index() {
    # 惰性建索引：位置无关的产物（4.6 起构建时重定位好的那些）一个引用都不需要
    # 改写，也就永远走不到这里 —— 安装时省掉整棵依赖树的扫描。
    if [[ "$INDEX_READY" -eq 1 ]]; then
        return 0
    fi
    build_index
    INDEX_READY=1
}

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

is_position_independent() {
    # 构建时重定位过的产物：引用是相对形式，与 BASE_DIR 无关，因此不需要改写。
    #
    # 注意 `@rpath/*` **不能**无条件算数：4.6 之前的产物普遍是「引用写 @rpath/<名>
    # + LC_RPATH 指向 @loader_path/../lib」，而那个 `../lib` 是相对**包自己**的
    # 老布局 —— 依赖其实装在 deps/<依赖>/<依赖>@<版本>/lib 下，靠安装期改写才对得上。
    # 2026-11-24 把 @rpath 一律当成已重定位，结果 htop / ncdu / tmux 装完就
    # "Library not loaded: @rpath/libncursesw.6.dylib"（deps_test 抓到的）。
    # 所以 @rpath 要看它**在这个文件身上能不能解析**，见 rpath_target_resolves。
    case "$1" in
        @loader_path/*|@executable_path/*)
            return 0
            ;;
        @rpath/*)
            rpath_target_resolves "$2" "${1#@rpath/}"
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

is_position_independent_id() {
    # install name（LC_ID_DYLIB）是"别人加载我时用的名字"，不参与本次加载路径的
    # 解析 —— `@rpath/<文件名>` 本来就是位置无关产物的惯例写法，不需要能解析到。
    # 引用那边才要查解析（见 rpath_target_resolves）。
    case "$1" in
        @loader_path/*|@executable_path/*|@rpath/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_dylib_file() {
    # MH_DYLIB 才是"别人会加载的库"。看 otool -hv 的 filetype 列，比扩展名可靠：
    # libfoo.dylib.1.2.3 / libfoo.1.dylib / libfoo.dylib 都算。
    otool -hv "$1" 2> /dev/null | awk 'NR > 1 && $5 == "DYLIB" { found = 1 } END { exit !found }'
}

needs_conda_libiconv() {
    # 判据是**符号名**，不是文件名：`libiconv`/`libiconv_open`/`libiconv_close`
    # 只有 conda 那一份导出；`iconv`/`iconv_open`/`iconv_close` 两组都该走系统那份。
    nm -u "$1" 2> /dev/null | grep -qE '^_libiconv(_open|_close|_open_into)?$'
}

rpath_target_resolves() {
    # rpath_target_resolves <文件> <库文件名>：<文件> 的 LC_RPATH 里有没有一条能解析到它。
    #
    # 只认 @loader_path 形式的 rpath（相对<文件>自身，本地可判定）与绝对路径 rpath。
    # @executable_path 的 rpath 取决于谁加载我，静态判断会误判，当作"解析得到"放行 ——
    # 那种产物是 4.6 之后构建的新形态，改写反而会把对的改错。
    local file="$1" base="$2" rpath expanded
    [ -n "$base" ] || return 1
    while IFS= read -r rpath; do
        case "$rpath" in
            @loader_path/*) expanded="$(dirname "$file")/${rpath#@loader_path/}" ;;
            @executable_path/*) return 0 ;;
            /*) expanded="$rpath" ;;
            *) continue ;;
        esac
        [[ -e "$expanded/$base" ]] && return 0
    done <<< "$(otool -l "$file" 2> /dev/null | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { want = 1; next }
        want && $1 == "path" { print $2; want = 0 }')"
    return 1
}

position_independent_target_exists() {
    # 只对 @loader_path 判断：它相对"发起这次加载的文件"，本地可解析。
    # @executable_path / @rpath 的解析依赖加载者，静态判断会误报，一律当作存在。
    local file="$1" ref="$2" rel
    case "$ref" in
        @loader_path/*) rel="${ref#@loader_path/}" ;;
        *) return 0 ;;
    esac
    [[ -e "$(dirname "$file")/$rel" ]]
}

relative_path() {
    # 从目录 $1 到绝对路径 $2 的相对路径。纯 bash：macOS 没有
    # `realpath --relative-to`（那是 GNU coreutils），而这里不能靠外部工具。
    local from="$1" to="$2"
    local IFS=/
    local -a from_parts to_parts
    local i=0 out="" part

    read -r -a from_parts <<< "${from#/}"
    read -r -a to_parts <<< "${to#/}"

    while [[ $i -lt ${#from_parts[@]} && $i -lt ${#to_parts[@]} \
             && "${from_parts[$i]}" == "${to_parts[$i]}" ]]; do
        i=$((i + 1))
    done

    local j=$i
    while [[ $j -lt ${#from_parts[@]} ]]; do
        out="${out}../"
        j=$((j + 1))
    done
    while [[ $i -lt ${#to_parts[@]} ]]; do
        out="${out}${to_parts[$i]}/"
        i=$((i + 1))
    done

    out="${out%/}"
    # 目标是目录本身时没有剩余分量；这种情况对引用没有意义，保持原样。
    printf '%s' "${out:-.}"
}

list_macho_files() {
    # 一次 Python 调用列出树里的 Mach-O（按魔数判断），而不是逐个文件 fork
    # `od`/`head`：依赖树有上万文件时，光这一项的开销就超过真正的重写。
    # 与 `find -type f` 保持一致：跳过符号链接本身（链接指向的真实文件会被处理）。
    # 静态库（!<arch>）不参与运行时加载，同样被过滤掉。
    #
    # 每行输出 "路径<TAB>signed"，signed 顺带回答"这个文件有没有 LC_CODE_SIGNATURE"：
    # arm64 上 dyld 拒绝加载未签名的 Mach-O，所以每个文件都要确认一次签名，
    # 以前是逐文件 fork `codesign --verify`（一次约 40 毫秒，164 个 Mach-O 的
    # git 光这一步就是 6 秒多），而它绝大多数时候只是在确认"本来就签好的没坏"。
    # 没有 LC_CODE_SIGNATURE 的一定没签 → 直接补签；有的按已签处理（被改写过的
    # 文件在下面本来就会重新签一遍）。fat 二进制各架构可能不同，标成 "?" 仍走
    # 原来的 verify 路径，不冒进。
    local root="$1"
    python3 - "$root" <<'PY'
import os
import struct
import sys

MAGICS = {"cffaedfe", "cefaedfe", "feedfacf", "feedface"}
FAT_MAGICS = {"cafebabe", "bebafeca"}
LC_CODE_SIGNATURE = 0x1D


def thin_is_signed(data):
    # 读 Mach-O 头与 load commands，找 LC_CODE_SIGNATURE 且 datasize > 0
    if len(data) < 32:
        return "?"
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic in (0xFEEDFACE, 0xFEEDFACF):
        endian, is64 = "<", magic == 0xFEEDFACF
    elif magic in (0xCEFAEDFE, 0xCFFAEDFE):
        endian, is64 = ">", magic == 0xCFFAEDFE
    else:
        return "?"

    ncmds, sizeofcmds = struct.unpack_from(endian + "II", data, 16)
    offset = 32 if is64 else 28
    end = min(offset + sizeofcmds, len(data))

    for _ in range(ncmds):
        if offset + 8 > end:
            break
        cmd, cmdsize = struct.unpack_from(endian + "II", data, offset)
        if cmdsize < 8:
            break
        if cmd == LC_CODE_SIGNATURE and offset + 16 <= end:
            _dataoff, datasize = struct.unpack_from(endian + "II", data, offset + 8)
            return "1" if datasize > 0 else "0"
        offset += cmdsize
    return "0"


for dirpath, _dirnames, filenames in os.walk(sys.argv[1]):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        try:
            with open(path, "rb") as handle:
                head = handle.read(4)
                magic = head.hex()
                if magic in FAT_MAGICS:
                    print(path + "\t?")
                elif magic in MAGICS:
                    handle.seek(0)
                    print(path + "\t" + thin_is_signed(handle.read()))
        except OSError:
            continue
PY
}

# -------------------- 逐个 Mach-O 替换 --------------------

CHANGED=0
SIGNED=0

# 惰性求值：只有在真要判断某条引用时才去问 filetype 与自己的 install name。
# 绝大多数产物引用的全是系统库（git 的 164 个 Mach-O 一个例外都没有），
# 提前求值等于每个文件白花两次 otool。
SELF_ID=""
SELF_ID_KNOWN=0

ensure_self_id() {
    # $1 = 当前文件；结果写进 SELF_ID
    [[ "$SELF_ID_KNOWN" -eq 1 ]] && return 0
    SELF_ID_KNOWN=1
    if is_dylib_file "$1"; then
        SELF_ID="$(otool -D "$1" 2>/dev/null | sed -n '2p' || true)"
    fi
    return 0
}

while IFS=$'\t' read -r file file_signed; do
    if ! otool_output="$(otool -L "$file" 2>/dev/null)"; then
        continue
    fi

    if [[ -z "$otool_output" ]]; then
        continue
    fi

    modified=0

    # `otool -L` 对 dylib 会把**它自己的 install name** 也列成第一条（缩进的）。
    # 那条不是引用，改写它只会空转：install_name_tool 报成功、字节没变，却把
    # modified 置 1 → 白重签一次，`wave transfer` 第二次跑还会报 "Relocated 1"。
    # ID 由下面那段单独处理。
    #
    # 惰性求值：只有在真要判断某条引用时才去问 filetype 与 ID。绝大多数产物
    # 引用的全是系统库（git 的 164 个 Mach-O 一个例外都没有），提前求值等于
    # 每个文件白花两次 otool。
    SELF_ID=""
    SELF_ID_KNOWN=0

    while IFS= read -r ref_line; do
        # otool -L 里只有缩进行是库引用（首行是文件名）
        if [[ "$ref_line" != [[:space:]]* ]]; then
            continue
        fi

        # 取这一行的第一个字段（= 依赖的路径）。用参数展开而不是
        # `printf | awk`：git 这类树有上千条引用，每条一个 awk 就是几千次 fork。
        old_path="${ref_line#"${ref_line%%[![:space:]]*}"}"
        old_path="${old_path%%[[:space:]]*}"
        if [[ -z "$old_path" ]]; then
            continue
        fi

        if is_system_path "$old_path"; then
            # 系统库一般不动。但有例外：`/usr/lib/libiconv.2.dylib` 有一批产物是
            # 对着 conda 的 libiconv 编的 —— 它们用 `libiconv`/`libiconv_open`
            # 这种带 lib 前缀的符号名，而 Apple 系统那份只导出 `iconv*`。
            # 真的去链系统那份，症状是装完立刻
            #   "Symbol not found: _libiconv"（2026-11-24 的 gwget / libidn2）。
            # 判据不看名字看**依赖树里有没有同名的库**：依赖记录声明了 libiconv，
            # 就说明作者要的是那一份；没声明（libSystem 这类）照旧跳过。
            # 只对这一个名字开例外，不是"所有系统库都查一遍依赖树"：
            # 全查会把整棵依赖树的索引建起来，位置无关的树就失去"零成本"这个前提
            # （transfer_test 第 4 节钉的就是这条）。
            case "$old_path" in
                /usr/lib/libiconv.2.dylib)
                    # 只有真的用 `libiconv*` 这组**带 lib 前缀**符号的产物才需要换。
                    # 反过来，用 `iconv*` 的（多数包）必须留在系统那份上：conda 的
                    # libiconv 不导出不带前缀的那组，换了就是
                    #   Symbol not found: _iconv（2026-11-24 的 git 被我这么改坏过）。
                    # 先排除"这一行其实是它自己的 ID"：文件自己就叫这个名字时，
                    # 这行不是引用，换了只会空转。
                    ensure_self_id "$file"
                    if [[ -n "$SELF_ID" && "$old_path" == "$SELF_ID" ]]; then
                        continue
                    fi
                    needs_conda_libiconv "$file" || continue
                    map_lookup "${old_path##*/}" || continue
                    ;;
                *)
                    continue
                    ;;
            esac
        else
            # 引用不是系统库：这时才值得问一次 filetype 与自己的 ID
            ensure_self_id "$file"
            if [[ -n "$SELF_ID" && "$old_path" == "$SELF_ID" ]]; then
                continue
            fi
        fi

        if is_position_independent "$old_path" "$file"; then
            # 构建时已经重定位过：不改写、不重签，只核对 @loader_path 指向的目标在不在。
            if ! position_independent_target_exists "$file" "$old_path"; then
                echo "$file|$old_path" >> "$UNRESOLVED_FILE"
            fi
            continue
        fi

        if [[ "$CHECK_ONLY" -eq 1 ]]; then
            # 检查只看"还有没有绝对路径"，不建索引（省掉整棵依赖树的扫描）。
            echo "$file|$old_path" >> "$ABSOLUTE_FILE"
            continue
        fi

        if map_lookup "${old_path##*/}"; then
            if [[ "$RELATIVE" -eq 1 ]]; then
                # 位置无关：从引用者所在目录算到目标的相对路径。
                # 这样同一份字节在任意 BASE_DIR 下都成立，装完还能整棵树搬走。
                new_path="@loader_path/$(relative_path "$(dirname "$file")" "$MAP_RESULT")"
            else
                new_path="$MAP_RESULT"
            fi
        else
            new_path=""
        fi

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
    # 判据是 Mach-O 的 filetype，不是扩展名：`libfdt.dylib.1.7.2` 这种带版本号的
    # 名字并不以 .dylib 结尾，按扩展名判断会漏掉它 —— 结果 ID 一直停在
    # `libfdt.dylib.1`（非位置无关），`wave transfer` 每次都说它 needs transfer，
    # 装完挪个位置又找不到库。
    if is_dylib_file "$file"; then
        current_id="$(otool -D "$file" 2>/dev/null | sed -n '2p' || true)"
        if [[ -n "$current_id" ]] && ! is_position_independent_id "$current_id"; then
            if [[ "$CHECK_ONLY" -eq 1 ]]; then
                echo "$file|(install name) $current_id" >> "$ABSOLUTE_FILE"
            else
                if [[ "$RELATIVE" -eq 1 ]]; then
                    # ID 是"别人加载我时用的名字"，@loader_path 会相对**加载者**
                    # 解析，语义是错的。位置无关产物的惯例是 @rpath/<文件名>；
                    # 本地引用已全部写成显式 @loader_path，ID 不参与实际加载。
                    new_id="@rpath/${file##*/}"
                else
                    new_id="$file"
                fi
                if [[ "$current_id" != "$new_id" ]]; then
                    if install_name_tool -id "$new_id" "$file" 2>"$ERROR_FILE"; then
                        modified=1
                        # 有些库把自己也当成一条依赖记着（`libfdt.dylib.1` 就是：
                        # 它有一条引用指向自己的旧 ID）。ID 换了以后那条引用就悬空，
                        # `wave transfer` 会一直说它 needs transfer。顺手改成新 ID。
                        install_name_tool -change "$current_id" "$new_id" "$file" 2>/dev/null || true
                    else
                        echo "$file|(install name)|$(head -n 1 "$ERROR_FILE")" >> "$FAILED_FILE"
                    fi
                fi
            fi
        fi
    fi

    if [[ "$modified" -eq 1 ]]; then
        if ! codesign --force --sign - "$file" >/dev/null 2>&1; then
            echo -e "${YELLOW}🌊 Warning: Failed to re-sign: $file${RESET}"
        fi
        CHANGED=$((CHANGED + 1))
    elif [[ "$CHECK_ONLY" -eq 0 ]]; then
        # 没改写 ≠ 能用。conda 的依赖库普遍**没有签名**，而 arm64 上 dyld 拒绝加载
        # 未签名的 Mach-O —— 症状是 `Symbol not found: _libiconv`，而且它会把符号
        # 解析到系统里同名的另一份库上（2026-11-24 的 gwget / libiconv 就是这样：
        # 依赖树里明明有 libiconv，dyld 却去找 /usr/lib 那份，然后找不到 `_libiconv`）。
        # 判据来自预筛选时读到的 LC_CODE_SIGNATURE，不再逐文件 fork codesign：
        #   0 → 一定没签，直接补一个 ad-hoc 签名（不动它的字节结构）
        #   1 → 已经签过（真被改写的文件在上面重签过了），跳过
        #   ? → fat 二进制各架构可能不同，退回 codesign --verify 老实问一次
        resign_needed=0
        case "$file_signed" in
            0) resign_needed=1 ;;
            \?)
                if ! codesign --verify "$file" >/dev/null 2>&1; then
                    resign_needed=1
                fi
                ;;
            *) resign_needed=0 ;;
        esac

        if [[ "$resign_needed" -eq 1 ]]; then
            if codesign --force --sign - "$file" >/dev/null 2>&1; then
                SIGNED=$((SIGNED + 1))
            else
                echo -e "${YELLOW}🌊 Warning: Failed to sign: $file${RESET}"
            fi
        fi
    fi
done < <(list_macho_files "$TARGET_DIR")

# -------------------- 输出 --------------------

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    # 只报告，不修改。$ABSOLUTE_FILE 非空就说明这个产物还是"绑死在某个前缀"的老形态。
    if [[ -s "$ABSOLUTE_FILE" ]]; then
        count="$(wc -l < "$ABSOLUTE_FILE" | tr -d ' ')"
        echo "🌊 absolute: $count reference(s)/identifier(s) still name an absolute path in ${TARGET_DIR#"$BASE_DIR"/}"
        exit 1
    fi
    echo "🌊 relative: ${TARGET_DIR#"$BASE_DIR"/}"
    exit 0
fi

if [[ "$CHANGED" -gt 0 ]]; then
    if [[ "$RELATIVE" -eq 1 ]]; then
        echo "🌊 Relocated $CHANGED Mach-O file(s) to @loader_path in ${TARGET_DIR#"$BASE_DIR"/}"
    else
        echo "🌊 Relocated $CHANGED Mach-O file(s) in ${TARGET_DIR#"$BASE_DIR"/}"
    fi
fi

if [[ "$SIGNED" -gt 0 ]]; then
    # 与"重定位"分开报：这两种动作的原因完全不同，混在一起会让人以为字节被改了。
    echo "🌊 Signed $SIGNED unsigned Mach-O file(s) in ${TARGET_DIR#"$BASE_DIR"/}"
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
            echo -e "${YELLOW}🌊   ${entry##*|}  (referenced by $(basename "${entry%%|*}"))${RESET}"
        done
    fi

    if [[ -s "$EXTERNAL_FILE" ]]; then
        external_count="$(wc -l < "$EXTERNAL_FILE" | tr -d ' ')"
        echo "🌊 Note: $external_count library reference(s) not provided by any installed dependency, left unchanged:"
        sort -u "$EXTERNAL_FILE" | head -10 | while IFS= read -r entry; do
            echo "🌊   ${entry##*|}  (referenced by $(basename "${entry%%|*}"))"
        done
    fi
fi

exit 0
