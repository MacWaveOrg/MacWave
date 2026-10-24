#!/bin/bash

# MacWave 🌊 Self Updater
# Re-downloads every MacWave code file and refreshes VERSION.json in the
# active config dir (/opt/macwave_config or ~/.config/macwave_config).
# Invoked by `wave selfupdate` through the update_command field in
# the configdata repository's versiondata/latest_version, or directly:
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
# 每个请求的超时
# ==========================================
#
# `wave selfupdate --max-time=1min` 把这个值原样传下来（MACWAVE_MAX_TIME），
# 本脚本自己解析 —— 中间任何一层都不替我们算好，规则只有一套。
# 没给时按请求类型取默认值：元数据 30 秒、文件清单与单个文件 60 秒、Python 归档 900 秒。
#
# 为什么必须有超时：没有它，一次「连上了但不再有数据」的抖动会让自更新无限挂住，
# 用户看到的就是一个永远不动的界面。

METADATA_TIMEOUT=30
FILE_TIMEOUT=60
ARCHIVE_TIMEOUT=900

mw_seconds() {
    # 与 pkg/pkginstaller.py 的 _parse_duration 同一套规则：
    # 40 / 40s / 1min / 1min20s / 2h / 1m30s / 250ms 都行，无单位按秒。
    # 成功时打印整数秒（向上取整，至少 1 秒），格式不合法返回 1。
    awk -v raw="$1" 'BEGIN {
        text = tolower(raw)
        gsub(/[ \t]/, "", text)
        if (text == "") exit 1
        total = 0
        while (length(text) > 0) {
            # 单位必须长优先：`1min` 若先匹配到单字母 `m`，剩下的 `in` 就无解了
            if (!match(text, /^[0-9]+(\.[0-9]+)?/)) exit 1
            number = substr(text, 1, RLENGTH)
            text = substr(text, RLENGTH + 1)
            if (match(text, /^(hrs|hr|h|mins|min|ms|secs|sec|s|m)/)) {
                unit = substr(text, 1, RLENGTH)
                text = substr(text, RLENGTH + 1)
            } else {
                unit = ""
            }
            if (unit == "" || unit == "s" || unit == "sec" || unit == "secs") factor = 1
            else if (unit == "m" || unit == "min" || unit == "mins") factor = 60
            else if (unit == "h" || unit == "hr" || unit == "hrs") factor = 3600
            else if (unit == "ms") factor = 0.001
            else exit 1
            total += number * factor
        }
        if (total <= 0) exit 1
        seconds = int(total)
        if (seconds < total) seconds++
        if (seconds < 1) seconds = 1
        printf "%d\n", seconds
    }'
}

if [[ -n "${MACWAVE_MAX_TIME:-}" ]]; then
    if ! _user_timeout="$(mw_seconds "$MACWAVE_MAX_TIME")"; then
        echo -e "${RED_BOLD}🌊 Error: cannot parse --max-time value '$MACWAVE_MAX_TIME'.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.${RESET}" >&2
        exit 1
    fi
    METADATA_TIMEOUT="$_user_timeout"
    FILE_TIMEOUT="$_user_timeout"
    ARCHIVE_TIMEOUT="$_user_timeout"
fi

# ==========================================
# 目标仓库、分支与版本
# ==========================================

REPO="MacWaveOrg/MacWave"
BRANCH="${MACWAVE_UPDATE_BRANCH:-${1:-main}}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
# -------------------- 测试根（隔离） --------------------
# MACWAVE_TEST 指向一个目录时，把它当作 /：HOME 和所有系统路径都挂到它下面，
# 整条链路都落在那个目录里，完全不碰真实系统。
# 没设置时 SYS_ROOT 为空，下面 "$SYS_ROOT/opt/..." 就还是 "/opt/..."，行为不变。
SYS_ROOT=""
if [[ -n "${MACWAVE_TEST:-}" ]]; then
    _mw_root="$MACWAVE_TEST"
    if [[ "$_mw_root" == "~"* ]]; then
        _mw_root="${HOME}${_mw_root#\~}"
    fi
    mkdir -p "$_mw_root"
    SYS_ROOT="$(cd "$_mw_root" && pwd)"
    # 幂等：lib/configpaths.py 也会把 HOME 搬进测试根（而且先把 $MACWAVE_TEST 解析成
    # 真实路径，所以 /var → /private/var 这类链接会被展开）。从 wave.py 一路调用下来时
    # HOME 已经被改过一次，这里再套一层就会变成 "<根>/private/var/.../Users/<你我>"，
    # 配置目录于是永远找不到。只在还没搬过的时候搬。
    case "$HOME" in
        "$SYS_ROOT"*) ;;
        *) export HOME="$SYS_ROOT${HOME}" ;;
    esac
    export MACWAVE_TEST_ROOT="$SYS_ROOT"
    mkdir -p "$HOME"
    echo "🌊 Test root: $SYS_ROOT"
fi

CONFIGDATA_URL="https://raw.githubusercontent.com/MacWaveOrg/configdata/main"
VERSION_DATA_URL="$CONFIGDATA_URL/versiondata/latest_version"

# 配置目录：系统级优先，其次用户级（与 lib/configpaths.py 的规则一致）
# 迁移可能把配置搬到用户级位置，所以做成函数，迁移之后要再解析一次。
SYSTEM_CONFIG_DIR="$SYS_ROOT/opt/macwave_config"
USER_CONFIG_DIR="$HOME/.config/macwave_config"

resolve_config_dir() {
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
}

resolve_config_dir

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

direct() {
    "$@"
}

# ==========================================
# 带超时与重试的下载
# ==========================================
#
# 一次网络抖动不该让整个自更新前功尽弃：每个请求都有超时，失败按 curl 的退出码
# 判断值不值得重试，并且先写 <目标>.macwave-part 再 mv ——
# 重试期间目标位置不会出现半个文件，全部失败时原地那份好文件也不受影响。

FETCH_ATTEMPTS=3
RETRY_DELAY=2

fetch_to_file() {
    # fetch_to_file <url> <目标文件> <超时秒> [runner] [尝试次数]
    # runner 为 run_cmd 时按安装目录的权限决定要不要 sudo。
    local url="$1"
    local destination="$2"
    local timeout="$3"
    local runner="${4:-direct}"
    local attempts="${5:-$FETCH_ATTEMPTS}"
    local partial="$destination.macwave-part"
    local attempt status code

    "$runner" mkdir -p "$(dirname "$destination")"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        status=0
        # 同时取 HTTP 状态码：curl 的退出码并不总能反映「404」。
        # raw.githubusercontent 在 404 时常常报 (56) 收数据失败而不是 (22)，
        # 只看退出码会把「这个文件不存在」当成网络抖动重试三次。
        code="$("$runner" curl -fsSL --max-time "$timeout" -w '%{http_code}' \
            -o "$partial" "$url" 2>/dev/null)" || status=$?
        if [[ "$status" -eq 0 ]]; then
            "$runner" mv -f "$partial" "$destination"
            return 0
        fi
        "$runner" rm -f "$partial" 2>/dev/null || true

        case "$code" in
            4??)
                # 4xx 是「请求本身不对」，重试不会变好：404 就是没有这个文件。
                return 1
                ;;
        esac

        case "$status" in
            22|23|1|2|3)
                # 22=HTTP 错误、23=写盘失败、1~3=用法错误。同样不值得重试。
                return 1
                ;;
        esac

        if ((attempt < attempts)); then
            echo -e "${YELLOW}🌊 Retrying ($((attempt + 1))/$attempts): $url${RESET}" >&2
            sleep "$RETRY_DELAY"
        fi
    done

    return 1
}

fetch_text() {
    # fetch_text <url> <超时秒>：成功时把内容打到 stdout。
    # 先落盘再输出，重试期间不会把半截内容漏给调用方。
    local url="$1"
    local timeout="$2"
    local tmp status=1

    tmp="$(mktemp -t macwave-fetch)"
    if fetch_to_file "$url" "$tmp" "$timeout"; then
        cat "$tmp"
        status=0
    fi
    rm -f "$tmp"
    return "$status"
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
    VERSION="$(fetch_text "$VERSION_DATA_URL" "$METADATA_TIMEOUT" \
        | sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' \
        | head -n 1)" || true
fi

if [[ -z "$VERSION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Cannot determine the target version.${RESET}"
    exit 1
fi

echo "🌊 Updating MacWave to $VERSION"

# ==========================================
# 大版本守卫（跨大版本不允许 selfupdate）
# ==========================================
#
# 每个大版本的第一个版本、以及任何跨大版本升级，都必须用 install.sh 完整安装：
# 这类升级通常同时改仓库与目录结构，selfupdate 只适合同大版本内的小版本升级。
# selfupdate.sh 是从「目标分支」拉下来执行的，守卫放在这里，以后每个大版本自带的
# selfupdate.sh 都会带上它，规则自动生效，不必逐版本写死在 configdata 里。

CURRENT_VERSION="$(python3 - "$VERSION_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        print(json.load(handle).get("version", ""))
except Exception:
    print("")
PY
)"

major_of() {
    # 取版本号里第一段数字当大版本号："2.6.1" -> "2"，"3.0" -> "3"
    python3 -c 'import re, sys
match = re.search(r"[0-9]+", sys.argv[1])
print(match.group(0) if match else "")' "$1"
}

CURRENT_MAJOR="$(major_of "$CURRENT_VERSION")"
TARGET_MAJOR="$(major_of "$VERSION")"

if [[ -n "$CURRENT_MAJOR" && -n "$TARGET_MAJOR" && "$CURRENT_MAJOR" != "$TARGET_MAJOR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: selfupdate cannot cross major versions ($CURRENT_VERSION -> $VERSION).${RESET}" >&2
    echo -e "${RED_BOLD}🌊 A new major version must be installed with install.sh:${RESET}" >&2
    echo -e "${YELLOW}   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)\"${RESET}" >&2
    exit 1
fi

# ==========================================
# 版本目录结构变更迁移（configdata/updatedata/{版本号}）
# ==========================================
#
# configdata 仓库的 updatedata/{版本号}/dir_structure_change 只有**一个字符**：
#     Y/y → 该版本改变了目录结构，执行同目录下的 transfer_commands 完成迁移
#     N/n → 没有改变，跳过（文件不存在也按「没有改变」处理）
# 目标版本号用这次要升级到的版本（上面刚确定的 $VERSION）。
# 迁移可能把配置搬到用户级位置，所以执行完要重新解析一次配置目录。

UPDATEDATA_URL="$CONFIGDATA_URL/updatedata/$VERSION"

DIR_STRUCTURE_CHANGE="$(fetch_text "$UPDATEDATA_URL/dir_structure_change" "$METADATA_TIMEOUT" 2>/dev/null | tr -d '[:space:]')" || DIR_STRUCTURE_CHANGE=""

if [[ "$DIR_STRUCTURE_CHANGE" == "Y" || "$DIR_STRUCTURE_CHANGE" == "y" ]]; then
    echo -e "${YELLOW}🌊 Directory structure changed in $VERSION, running migration...${RESET}"

    TRANSFER_COMMANDS="$(fetch_text "$UPDATEDATA_URL/transfer_commands" "$FILE_TIMEOUT" 2>/dev/null)" || TRANSFER_COMMANDS=""
    if [[ -z "$TRANSFER_COMMANDS" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot fetch the migration script for $VERSION.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was updated. Check your network, then try again.${RESET}"
        exit 1
    fi

    # 把当前安装的位置与配置目录告诉迁移脚本，由它自己判断该不该搬
    export MACWAVE_INSTALL_DIR="$BASE_DIR"
    export MACWAVE_CONFIG_DIR="$CONFIG_DIR"
    export MACWAVE_TARGET_VERSION="$VERSION"

    if ! bash -c "$TRANSFER_COMMANDS"; then
        echo -e "${RED_BOLD}🌊 Error: The migration for $VERSION failed.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was updated. Fix the issue above, then try again.${RESET}"
        exit 1
    fi

    resolve_config_dir    # 配置可能已经搬到用户级位置
    echo ""
fi

# ==========================================
# 文件清单（configdata/versiondata/files_info）
# ==========================================
#
# 要更新哪些文件不再写死在本脚本里，而是去 configdata 仓库读一份清单。
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
# lib/wave.py 按原名下载；PATH 上的入口 lib/wave 由 write_launcher 生成
# （它要按私有 venv 与解释器路径决定怎么启动，不能直接复制脚本本体）。
# 以后新增文件只要改 configdata 的这份清单，不用再动本脚本。

FILES_INFO_URL="$CONFIGDATA_URL/versiondata/files_info"
FILES_INFO_TMP="$(mktemp)"

cleanup_files_info() {
    rm -f "$FILES_INFO_TMP"
}
trap cleanup_files_info EXIT

echo "🌊 Fetching the file list..."

if ! fetch_to_file "$FILES_INFO_URL" "$FILES_INFO_TMP" "$FILE_TIMEOUT"; then
    echo -e "${RED_BOLD}🌊 Error: Cannot fetch versiondata/files_info from the configdata repository.${RESET}"
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
    if ! fetch_to_file "$BASE_URL/$repo_path" "$BASE_DIR/$local_path" "$FILE_TIMEOUT" run_cmd; then
        echo -e "${RED_BOLD}🌊 Error: Cannot download $repo_path.${RESET}" >&2
        # VERSION.json 只在全部文件到位后才写，所以版本号还是旧的：
        # 网络恢复后再跑一次 wave selfupdate 就会从这里继续。
        echo -e "${RED_BOLD}🌊 Nothing was recorded as updated. Check your network, then run wave selfupdate again.${RESET}" >&2
        exit 1
    fi

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
# Python 运行环境（私有 venv + 启动器）
# ==========================================
#
# 每次自更新都重新确认一遍：老版本装出来的树里没有 venv，入口也还是
# `#!/usr/bin/env python3`，一旦系统 Python 升级就会全线报错。这里补齐。

# ==========================================
# 便携 Python（自带解释器）
# ==========================================
#
# 为什么自带：用户机器上的 python3 由 Homebrew / pyenv / 系统自带的版本轮流接管，
# 升级一次就可能换掉解释器，而第三方依赖仍留在旧版本里 —— 3.0.5 之前真实发生过
# 一次「系统 Python 从 3.14 升到 3.15，所有命令都报模块缺失」。
#
# 自带之后，「用哪个解释器」由 MacWave 自己决定，报错也就能稳定复现。
# 数据来自 configdata 的 pythondata/latest_python，换版本不用改脚本。
# 下载失败（网络问题）时回退到系统 python3，安装不会因此中断。

portable_python_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "" ;;
    esac
}

portable_python_binary() {
    # 不同构建产物的目录布局不同，这里按常见位置逐个试探。
    local root="$1" candidate
    for candidate in \
        "$root/install/bin/python3" \
        "$root/bin/python3" \
        "$root/python/install/bin/python3" \
        "$root/python/bin/python3"
    do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    candidate="$(find "$root" -maxdepth 4 -type f \( -name 'python3' -o -name 'python3.*' \) -perm -u+x 2>/dev/null | head -n 1)"
    if [[ -n "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

normalize_portable_python() {
    # 把各种布局归一化成 <target>/bin/python3。
    #
    # 启动器只认 python/current/bin/python3，而上游 install_only 产物把解释器放在
    # python/install/bin/python3 —— 不归一化的话，自带解释器在启动器第 2 层永远命中不了，
    # 只有第 1 层的私有 venv 能救场；venv 一旦坏掉就等于没有自带解释器。
    local target="$1"
    local py="$2"
    local link="$target/bin/python3"
    local relative

    mkdir -p "$target/bin" 2>/dev/null || return 0
    if [[ "$py" == "$link" ]]; then
        return 0
    fi
    if [[ "$py" != "$target"/* ]]; then
        return 0
    fi

    # 用相对链接：整个 python/ 目录搬走以后仍然有效
    relative="../${py#"$target"/}"
    ln -sfn "$relative" "$link" 2>/dev/null || true
    return 0
}

ensure_portable_python() {
    # 成功时把解释器路径打到 stdout，失败返回 1（调用方回退系统 python3）。
    local base_dir="$1"
    local arch="$2"
    local data_url="$CONFIGDATA_URL/pythondata/latest_python"
    local data_file version url sha target current archive actual py

    [[ -n "$arch" ]] || return 1

    data_file="$(mktemp -t macwave-pyver)"
    # 超时与重试同其他请求；install.sh 里的同名步骤固定用 30/900 秒，
    # 因为引导安装没有命令行旗标可依。
    if ! fetch_to_file "$data_url" "$data_file" "$METADATA_TIMEOUT"; then
        rm -f "$data_file"
        return 1
    fi
    version="$(sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' "$data_file" | head -n 1)"
    url="$(sed -n "s/^${arch}_url:[[:space:]]*\"\(.*\)\"/\1/p" "$data_file" | head -n 1)"
    sha="$(sed -n "s/^${arch}_sha256:[[:space:]]*\"\(.*\)\"/\1/p" "$data_file" | head -n 1)"
    rm -f "$data_file"

    if [[ -z "$version" || -z "$url" || -z "$sha" ]]; then
        return 1
    fi

    target="$base_dir/python/$version"
    current="$base_dir/python/current"

    if py="$(portable_python_binary "$target" 2>/dev/null)"; then
        :
    else
        archive="$base_dir/downloads/tmp/portable-python-$version.tar.gz"
        # 归档几十 MB，重试一次就够，再多次也只是拖长等待
        if ! fetch_to_file "$url" "$archive" "$ARCHIVE_TIMEOUT" direct 2; then
            rm -f "$archive" "$archive.macwave-part"
            return 1
        fi
        actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
        if [[ "$actual" != "$sha" ]]; then
            rm -f "$archive"
            echo -e "${RED_BOLD}🌊 Error: the bundled Python download failed its checksum check.${RESET}" >&2
            return 1
        fi
        mkdir -p "$target" 2>/dev/null || true
        if ! tar -xzf "$archive" -C "$target" 2>/dev/null; then
            rm -f "$archive"
            return 1
        fi
        rm -f "$archive"
        py="$(portable_python_binary "$target" 2>/dev/null)" || return 1
    fi

    if ! "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        return 1
    fi

    normalize_portable_python "$target" "$py"

    mkdir -p "$base_dir/python" 2>/dev/null || true
    ln -sfn "$version" "$current" 2>/dev/null || true
    echo "$py"
    return 0
}

VENV_DIR="$BASE_DIR/venv"
VENV_PY=""
PYTHON_BIN=""
PYTHON_SOURCE=""

BUNDLED_PY="$(ensure_portable_python "$BASE_DIR" "$(portable_python_arch)")" || BUNDLED_PY=""
if [[ -n "$BUNDLED_PY" ]]; then
    PYTHON_BIN="$BUNDLED_PY"
    PYTHON_SOURCE="bundled"
    echo "🌊 Using the bundled Python: ${BUNDLED_PY#"$BASE_DIR"/}"
else
    PYTHON_BIN="$(command -v python3 || true)"
    PYTHON_SOURCE="system"
    if [[ -n "$PYTHON_BIN" ]]; then
        echo -e "${YELLOW}🌊 Warning: could not prepare the bundled Python; using $PYTHON_BIN instead.${RESET}"
    fi
fi

if [[ -n "$PYTHON_BIN" ]]; then
    if [[ ! -x "$VENV_DIR/bin/python3" && ! -x "$VENV_DIR/bin/python" ]]; then
        mkdir -p "$VENV_DIR" 2>/dev/null || true
        if run_cmd "$PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1; then
            echo "🌊 Private Python environment created: ${VENV_DIR#"$BASE_DIR"/}"
        fi
    fi

    if [[ -x "$VENV_DIR/bin/python3" ]]; then
        VENV_PY="$VENV_DIR/bin/python3"
    elif [[ -x "$VENV_DIR/bin/python" ]]; then
        VENV_PY="$VENV_DIR/bin/python"
    fi

    if [[ -n "$VENV_PY" ]]; then
        if ! "$VENV_PY" -c 'import requests, packaging, rich' >/dev/null 2>&1; then
            echo "🌊 Installing Python dependencies into the private environment..."
            run_cmd "$VENV_PY" -m pip install --quiet requests packaging rich >/dev/null 2>&1 || \
                echo -e "${YELLOW}🌊 Warning: the private environment is incomplete; the launcher will fall back.${RESET}"
        fi
    fi
fi

write_launcher() {
    local base_dir="$1"
    local recorded="$2"
    local target="$base_dir/lib/wave"
    local tmp
    tmp="$(mktemp -t macwave-launcher)"

    cat > "$tmp" <<'LAUNCHER'
#!/bin/sh
# MacWave launcher
# 由 install.sh / selfupdate.sh 生成，会被覆盖，请不要手工编辑。
#
# 选择一个**真正能 import 到依赖**的解释器来运行 lib/wave.py：
#   1. 安装根目录下的私有 venv（与系统 Python 升级完全解耦）
#   2. 生成这个启动器时的解释器路径
#   3. PATH 上的 python3（最后兜底，wave.py 会给出缺少哪个依赖）

set -u

# 解析自身真实路径（可能经由 PATH 上的符号链接调用）
self="$0"
while [ -L "$self" ]; do
    link="$(readlink "$self")"
    case "$link" in
        /*) self="$link" ;;
        *)  self="$(dirname "$self")/$link" ;;
    esac
done
lib_dir="$(cd -- "$(dirname -- "$self")" && pwd)" || exit 1
root_dir="$(cd -- "$lib_dir/.." && pwd)" || exit 1
entry="$lib_dir/wave.py"

#__MACWAVE_PYTHON__

deps_ok() {
    [ -x "$1" ] || return 1
    "$1" -c 'import requests, packaging, rich' >/dev/null 2>&1
}

# 1. 私有 venv（正常情况下就是它；由自带 Python 创建）
if deps_ok "$root_dir/venv/bin/python3"; then
    exec "$root_dir/venv/bin/python3" "$entry" "$@"
fi
if deps_ok "$root_dir/venv/bin/python"; then
    exec "$root_dir/venv/bin/python" "$entry" "$@"
fi

# 2. 自带的便携 Python（venv 坏掉时的第一选择；它自己也可以带依赖）
if [ -x "$root_dir/python/current/bin/python3" ] && deps_ok "$root_dir/python/current/bin/python3"; then
    exec "$root_dir/python/current/bin/python3" "$entry" "$@"
fi

# 3. 安装时记录的系统解释器
if [ -n "${MACWAVE_PYTHON:-}" ] && deps_ok "$MACWAVE_PYTHON"; then
    exec "$MACWAVE_PYTHON" "$entry" "$@"
fi

# 4. 最后才用 PATH 上的 python3（wave.py 会明确指出缺哪个依赖）
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$entry" "$@"
fi

echo "🌊 Error: no usable Python 3 interpreter was found." >&2
echo "🌊 Reinstall MacWave with lib/install.sh." >&2
exit 1
LAUNCHER

    local escaped rendered
    escaped="$(printf '%s' "$recorded" | sed 's/[\\"`$]/\\&/g')"

    # 内容先在普通权限下生成，只有落地那几步才可能需要提权。
    # 调用本函数时**不能**写 run_cmd write_launcher：sudo 无法执行 shell 函数，
    # 会遇到 "sudo: write_launcher: command not found"。
    rendered="$(mktemp -t macwave-launcher-out)"
    sed "s|#__MACWAVE_PYTHON__|MACWAVE_PYTHON=\"$escaped\"|" "$tmp" > "$rendered"
    rm -f "$tmp"

    run_cmd mkdir -p "$(dirname "$target")"
    run_cmd cp "$rendered" "$target"
    run_cmd chmod 755 "$target"
    rm -f "$rendered"
}

if [[ -n "$PYTHON_BIN" ]]; then
    write_launcher "$BASE_DIR" "$PYTHON_BIN"
fi

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
