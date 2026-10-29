#!/bin/bash

# MacWave 🌊 Self Updater
# Re-downloads every MacWave code file and refreshes VERSION.json in the
# active config dir (/opt/macwave_config or ~/.config/macwave_config).
# Invoked by `wave selfupdate` through the update_command field in
# the self-update repository's macwavedata/latest.toml, or directly:
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
# 域名（4.0：每个对外地址都能用环境变量换掉）
# ==========================================
#
# 与 lib/domains.py 是同一张表，一份给 Python、一份给 shell：install.sh 是
# `curl | bash` 直接执行的，没有本地文件可以 source，只能在这里重复一遍。
# 默认值仍是 3.x 在用的地址，一个变量都不设时行为与 3.x 完全一致。
#
# 这一段必须与 lib/selfupdate.sh 逐字一致 —— scripts/domains_test.sh 有断言。

mw_domain() {
    # mw_domain <变量名> <值>：校验协议、去掉末尾斜杠，然后打印规范化后的值
    local name="$1"
    local value="$2"

    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done

    case "$value" in
        https://?*|file://?*) printf '%s\n' "$value"; return 0 ;;
        # 明文 http 只给本机镜像（离线测试、本机代理）
        http://127.0.0.1:?*|http://localhost:?*) printf '%s\n' "$value"; return 0 ;;
    esac

    echo -e "${RED_BOLD}🌊 Error: $name must be an https:// (or file://) address, got: $value${RESET}" >&2
    exit 1
}

# MacWave 自身文件（后面再拼 /<分支>/<路径>）
CORE_URL="$(mw_domain MACWAVE_CORE_DOMAIN "${MACWAVE_CORE_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/MacWave}")"
# 自更新数据：版本号、文件清单、目录迁移脚本
SELFUPDATE_URL="$(mw_domain MACWAVE_SELFUPDATE_DOMAIN "${MACWAVE_SELFUPDATE_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/main}")"
# 自带 CPython 的清单
# 解释器单独一个仓库（体积与发布节奏都和自更新数据不同）
PYTHON_DATA_URL="$(mw_domain MACWAVE_PYTHON_DOMAIN "${MACWAVE_PYTHON_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Python/main}")"

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

BRANCH="${MACWAVE_UPDATE_BRANCH:-${1:-main}}"
BASE_URL="$CORE_URL/$BRANCH"
# 由 selfupdate.py 按 `wave selfupdate --install-python-from-source` 置位
INSTALL_PYTHON_FROM_SOURCE="${MACWAVE_INSTALL_PYTHON_FROM_SOURCE:-}"
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
    # 物理路径：macOS 上 /var 是指向 /private/var 的符号链接，这里若用逻辑路径，
    # 与下面比较用的 HOME（configpaths 已经 resolve 过）对不上，前缀判断就会失效。
    SYS_ROOT="$(cd "$_mw_root" && pwd -P)"
    # 幂等：lib/configpaths.py 也会把 HOME 搬进测试根。从 wave.py 一路调用下来时
    # HOME 已经被改过一次，这里再套一层就会变成 "<根><根>/Users/<你>"，配置目录于是
    # 永远找不到。两边都取物理路径再比较，才不会被 /var 与 /private/var 骗过去。
    _mw_home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || _mw_home_real="$HOME"
    case "$_mw_home_real" in
        "$SYS_ROOT"|"$SYS_ROOT"/*) ;;
        *) export HOME="$SYS_ROOT${HOME}" ;;
    esac
    export MACWAVE_TEST_ROOT="$SYS_ROOT"
    mkdir -p "$HOME"
    echo "🌊 Test root: $SYS_ROOT"
fi

VERSION_DATA_URL="$SELFUPDATE_URL/macwavedata/latest.toml"

read_toml_string() {
    # read_toml_string <文本> <键> —— 取平铺 TOML 的字符串值，去掉引号与行尾注释。
    # 只用 sed 是因为此刻能保证存在的只有系统 sh 工具；Python 还没准备好。
    printf '%s\n' "$1" \
        | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

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
    VERSION_DATA="$(fetch_text "$VERSION_DATA_URL" "$METADATA_TIMEOUT")" || true
    VERSION="$(read_toml_string "$VERSION_DATA" version)"
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
# selfupdate.sh 都会带上它，规则自动生效，不必逐版本写死在数据里。

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
    # 跨大版本不改安装脚本去硬搬：目录结构、仓库职责都可能变，交给完整安装流程。
    # 只把人指到官网，安装命令以官网上的为准，免得印一份会过期的 curl 进来。
    echo -e "${RED_BOLD}🌊 MacWave $TARGET_MAJOR is a new major version, so it cannot be installed with selfupdate.${RESET}" >&2
    echo -e "${RED_BOLD}🌊 Your version: $CURRENT_VERSION. Please install $VERSION from the website:${RESET}" >&2
    echo -e "${YELLOW}   https://macwave.org${RESET}" >&2
    echo -e "${RED_BOLD}🌊 Your current installation has not been changed.${RESET}" >&2
    exit 1
fi

# ==========================================
# 更新脚本（macwavedata/<版本>/update_commands.sh）
# ==========================================
#
# 要下载哪些文件、放到哪里，以前是客户端读一份 files_info 自己解析。现在改成
# 由自更新数据提供一个脚本，客户端只负责取回来执行：
#
#   - 脚本知道这一版该下哪些文件，所以能只列变动的那些；
#   - 目录结构变更的迁移也写在同一个脚本里，不必再维护第二套机制；
#   - 客户端不再需要「缩进树」这种自定义格式的解析器。
#
# MACWAVE_CURRENT_VERSION 传的是本机已经装着的版本，脚本据此决定走增量还是全量。

UPDATE_COMMANDS_URL="$SELFUPDATE_URL/macwavedata/$VERSION/update_commands.sh"
UPDATE_COMMANDS_TMP="$(mktemp)"

cleanup_update_commands() {
    rm -f "$UPDATE_COMMANDS_TMP"
}
trap cleanup_update_commands EXIT

echo "🌊 Fetching the update commands..."

if ! fetch_to_file "$UPDATE_COMMANDS_URL" "$UPDATE_COMMANDS_TMP" "$FILE_TIMEOUT"; then
    echo -e "${RED_BOLD}🌊 Error: Cannot fetch the update commands ($UPDATE_COMMANDS_URL).${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was updated. Check your network or proxy, then try again.${RESET}"
    exit 1
fi

if ! bash -n "$UPDATE_COMMANDS_TMP" 2>/dev/null; then
    echo -e "${RED_BOLD}🌊 Error: the update commands for $VERSION are not valid shell.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was updated. Please report this to the administrator.${RESET}"
    exit 1
fi

# ==========================================
# 执行更新脚本
# ==========================================

export MACWAVE_INSTALL_DIR="$BASE_DIR"
export MACWAVE_CONFIG_DIR="$CONFIG_DIR"
export MACWAVE_CORE_URL="$CORE_URL"
export MACWAVE_BRANCH="$BRANCH"
export MACWAVE_TARGET_VERSION="$VERSION"
export MACWAVE_CURRENT_VERSION="$CURRENT_VERSION"
export MACWAVE_FILE_TIMEOUT="$FILE_TIMEOUT"
export MACWAVE_NEED_SUDO="$([ "$NEED_SUDO" = "true" ] && echo 1 || echo "")"
export MACWAVE_SILENT=""

if ! bash "$UPDATE_COMMANDS_TMP"; then
    echo -e "${RED_BOLD}🌊 Error: the update commands for $VERSION failed.${RESET}" >&2
    # VERSION.json 只在全部文件到位后才写，所以版本号还是旧的：
    # 网络恢复后再跑一次 wave selfupdate 就会从这里继续。
    echo -e "${RED_BOLD}🌊 Nothing was recorded as updated. Fix the cause above, then run wave selfupdate again.${RESET}" >&2
    exit 1
fi

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
# 数据来自 MACWAVE_PYTHON_DOMAIN 的 pythondata/latest.toml，换版本不用改脚本。
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
    #
    # 两种来源：
    #   默认                —— 从我们自己的 Python 仓库取（pythondata/<版本>/<文件名>）
    #   --install-python-from-source —— 按 python_url.toml 记的上游地址直接回上游取
    # 两条路径的校验值相同：字节原样搬运，所以 sha256 可以复用。
    local base_dir="$1"
    local arch="$2"
    local latest_file url_file version="" url="" sha="" filename="" archive_url
    local target current archive actual py

    [[ -n "$arch" ]] || return 1

    # ── 第一步：MacWave 现在提供哪个版本的解释器 ──
    # 这一步失败不算错：网络不好时继续用本机已有的那份，安装照常完成。
    # 但**必须先问一次**，否则「本机已有 3.14.9」会让升级到「要求 3.15」的版本时
    # 永远发现不了自己落后 —— 这正是 per-version 目录存在的理由。
    echo "🌊 Checking the bundled Python version..." >&2
    latest_file="$(mktemp -t macwave-pylatest)"
    if curl -fsSL --max-time 30 -o "$latest_file" "$PYTHON_DATA_URL/pythondata/latest.toml" 2>/dev/null; then
        version="$(read_toml_string "$(cat "$latest_file")" version)"
    fi
    rm -f "$latest_file"

    if [[ -n "$version" ]]; then
        target="$base_dir/python/$version"
        current="$base_dir/python/current"

        # 已经是最新版：直接用，一个字节都不下
        if py="$(portable_python_binary "$target" 2>/dev/null)" \
           && "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
            echo "$py"
            return 0
        fi
    else
        # 问不到最新版：退回到「本机有任何一份可用解释器就用它」
        for candidate in "$base_dir/python/current" "$base_dir"/python/*/; do
            [[ -d "$candidate" ]] || continue
            if py="$(portable_python_binary "$candidate" 2>/dev/null)" \
               && "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
                echo "$py"
                return 0
            fi
        done
        return 1
    fi

    # ── 第二步：这个版本各架构的地址与校验值 ──
    echo "🌊 Fetching the bundled Python $version definition..." >&2
    url_file="$(mktemp -t macwave-pyurl)"
    if ! curl -fsSL --max-time 30 -o "$url_file" \
         "$PYTHON_DATA_URL/pythondata/$version/python_url.toml" 2>/dev/null; then
        rm -f "$url_file"
        return 1
    fi

    url="$(sed -n "s/^[[:space:]]*${arch}_url[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$url_file" | head -n 1)"
    sha="$(sed -n "s/^[[:space:]]*${arch}_sha256[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$url_file" | head -n 1)"
    rm -f "$url_file"

    if [[ -z "$url" || -z "$sha" ]]; then
        return 1
    fi

    # 文件名取上游地址的末段：我们自己托管的那份用同一个名字，校验值才能共用
    filename="${url##*/}"
    if [[ -n "$INSTALL_PYTHON_FROM_SOURCE" ]]; then
        archive_url="$url"
    else
        archive_url="$PYTHON_DATA_URL/pythondata/$version/$filename"
    fi

    # ── 第三步：下载并校验 ──
    echo "🌊 Downloading the bundled Python $version (about 26 MB)..." >&2
    archive="$base_dir/downloads/tmp/portable-python-$version.tar.gz"
    mkdir -p "$base_dir/downloads/tmp" 2>/dev/null || true
    if ! curl -fsSL --max-time 900 -o "$archive" "$archive_url" 2>/dev/null; then
        rm -f "$archive"
        echo -e "${YELLOW}🌊 Could not download the bundled Python from ${archive_url}${RESET}" >&2
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
        echo "🌊 Creating the private Python environment..."
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
            # pip 默认会无限等下去，网络不好时看上去就是卡死。给它超时与重试，
            # 并说明这一步可能要一会儿，免得用户以为程序挂了。
            echo "🌊 Installing Python dependencies into the private environment (this can take a minute)..."
            run_cmd "$VENV_PY" -m pip install --quiet --disable-pip-version-check \
                --timeout 30 --retries 2 requests packaging rich >/dev/null 2>&1 || \
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
