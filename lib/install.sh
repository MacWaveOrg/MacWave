#!/bin/bash

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/lib/install.sh)"
# Unattended (CI): /bin/bash -c "$(curl -fsSL .../main/lib/install.sh)" -- --ci --dir-option=1

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
    # mw_say 到这里还没定义（它与 MW_LANG 都在下面），所以直接 echo：
    # 以前这里调用 mw_say，隔离运行时第一行永远是 "mw_say: command not found"。
    echo "🌊 Test root: $SYS_ROOT"
fi

set -eE
set -u
set -o pipefail

# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'
SKY_BLUE='\033[38;5;74m'
RED='\033[1;31m'

# ==========================================
# 语言
# ==========================================
# 不做 gettext、不依赖外部工具 —— 这个脚本要在裸 macOS 上跑，多一个依赖就多一处
# 装不上。文案直接写两份，由 mw_say() 按 --zh 选。默认英文：终端不一定有中文
# locale，反过来会让英文用户看到乱码或问号。
MW_LANG="en"

# ⚠️⚠️⚠️=====================================
# 一次调试时作者在会议室不小心把含有 say 部分的代码粘贴到 bash 终端，他的 Mac 开始大声播报命令：
# “波浪（🌊）执行下列命令将 MacWave 添加到 PATH，eval（还念成了 evil）…………（此处省略若干字）”
# 以后谁也不许把函数命名为 say！
# 甚至 Siri 把 eval 念成 evil，导致作者获得外号“Evil哥”！
# 谁敢让我的 Mac 发出一点声音，我跟他拼了！ ———— Sha0huaZhang，2026
#
# During one debugging session, the author accidentally pasted code containing the say part into a bash terminal in the meeting room, and his Mac started loudly announcing the commands:
# "Wave (🌊) Execute the following command to add MacWave to PATH, eval (which was also pronounced as evil) ………… (several words omitted here)"
# From now on, no one is allowed to name a function say!
# Even Siri pronounced eval as evil, which earned the author the nickname "Brother Evil"!
# Whoever dares to make my Mac emit even a single sound—I'll fight them to the death! ———— Sha0huaZhang, 2026

# ⚠️⚠️⚠️-------------------------------------
# 原因很简单：macOS 自带 /usr/bin/say —— 一个把参数念出来的朗读命令。函数一旦
# 也叫 say，任何一行 `say "…" "…"` 被粘进终端（从文档、从源码、从聊天记录里）
# 都不会报 command not found，而是把参数念给整个房间听。改成 mw_say 之后，同样的
# 误粘贴只会得到一句 command not found，安静且无副作用。
# ⚠️⚠️⚠️=====================================

# ==========================================
# 安全检查：mw_say 绝不能变成 /usr/bin/say
# ==========================================
# /usr/bin/say 是 macOS 的朗读命令。如果 mw_say 被劫持成它，
# 任何 `mw_say "..."` 都会把参数念给整个房间听。
# 三条路径都查：PATH 上的可执行文件、它的软链接目标、当前 shell profile 里的 alias/函数/export。


# 💀💀💀=====================================

mw_check_say_hijack() {
    local bad=0 reason=""

    # ---- 1) PATH 上的可执行文件 ----
    # 用 type -P 强制只看 PATH 上的文件，忽略 shell 函数（此刻 mw_say 函数还没定义，
    # 但如果用户 .zshrc 里定义了同名函数，type -P 也不会被骗）。
    local found
    found="$(type -P mw_say 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
        # ---- 2) 软链接 ----
        # -ef 比较 inode：即使中间有多层链接也能穿透。
        if [ "$found" -ef /usr/bin/say ]; then
            bad=1
            reason="PATH entry '$found' is a symlink to /usr/bin/say"
        fi
        # 再补一道：直接 readlink 看是不是字面指向 /usr/bin/say（捕获 -ef 因权限/不存在失效的情况）
        if [ "$bad" -eq 0 ] && [ -L "$found" ] && [ "$(readlink "$found")" = "/usr/bin/say" ]; then
            bad=1
            reason="PATH entry '$found' links directly to /usr/bin/say"
        fi
    fi

    # ---- 3) 当前 shell 的 profile ----
    # 检查用户 shell 配置里有没有把 mw_say 指向 say 的 alias / 函数 / export。
    # 只看**当前** shell 对应的文件，避免误报别的 shell 的配置。
    local rc candidates=()
    case "${SHELL:-}" in
        *zsh*)  candidates=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv") ;;
        *bash*) candidates=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile") ;;
        *)      candidates=("$HOME/.profile") ;;
    esac
    for rc in "${candidates[@]}"; do
        [ -f "$rc" ] || continue
        # alias mw_say=...  或  alias mw_say = '...'（宽松匹配）
        if grep -Eq "^[[:space:]]*alias[[:space:]]+mw_say[[:space:]]*=" "$rc" 2>/dev/null; then
            # 只要 alias 值里出现 say 就拦（可以是 say、/usr/bin/say、say -v ...）
            if grep -Eq "^[[:space:]]*alias[[:space:]]+mw_say[[:space:]]*=.*\bsay\b" "$rc" 2>/dev/null; then
                bad=1
                reason="$rc aliases mw_say to say"
            fi
        fi
        # mw_say() { ... say ... }  函数定义里调用 say
        if grep -Eq "^[[:space:]]*mw_say[[:space:]]*\(\)" "$rc" 2>/dev/null; then
            bad=1
            reason="$rc defines a mw_say shell function"
        fi
        # export PATH=... 把 /usr/bin 前置（极端情况，几乎不会有人这么干，但查一下）
        # 只报「PATH 里显式把 /usr/bin 放在最前且同时提到 mw_say」这种，避免误报
        if grep -Eq "^[[:space:]]*export[[:space:]]+PATH=.*/usr/bin" "$rc" 2>/dev/null \
           && grep -q "mw_say" "$rc" 2>/dev/null; then
            bad=1
            reason="$rc prepends /usr/bin to PATH and mentions mw_say"
        fi
    done

    if [ "$bad" -eq 1 ]; then
    echo "" >&2
    echo -e "${RED}██████╗  █████╗ ██████╗ ██╗${RESET}" >&2
    echo -e "${RED}██╔══██╗██╔══██╗██╔══██╗██║${RESET}" >&2
    echo -e "${RED}██████╔╝███████║██║  ██║██║${RESET}" >&2
    echo -e "${RED}██╔══██╗██╔══██║██║  ██║╚═╝${RESET}" >&2
    echo -e "${RED}██████╔╝██║  ██║██████╔╝██╗${RESET}" >&2
    echo -e "${RED}╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝${RESET}" >&2
    echo "" >&2
    echo -e "${RED_BOLD}YOU, FAILED!${RESET}" >&2
        exit 1
    fi
}

# 调用点不在这里：这段代码跑在参数解析**之前**，那时还不知道有没有 --no-noise。
# 见下面参数解析之后的调用。函数定义先留着。

# 💀💀💀=====================================

mw_say() {
    # mw_say "<English>" "<中文>"
    if [[ "$MW_LANG" == "zh" ]]; then
        printf '%b\n' "$2"
    else
        printf '%b\n' "$1"
    fi
}

mw_say_err() {
    if [[ "$MW_LANG" == "zh" ]]; then
        printf '%b\n' "$2" >&2
    else
        printf '%b\n' "$1" >&2
    fi
}

# ==========================================
# 试运行（--dry-run）
# ==========================================
#
# 走完整条流程、把每一步会做什么打出来，但不下载、不提权、不建目录、不写文件。
# 用来看安装时终端会输出什么 —— 菜单、校验、PATH 提示都在，唯独没有副作用。
#
# 定义必须放在版本读取之前：默认源取不到版本号时，试运行要靠它继续往下走，
# 否则在断网的机器上永远只能看到第一行报错。
CLI_DRY_RUN=false

mw_dry_run() {
    [[ "${CLI_DRY_RUN:-false}" == "true" ]]
}

mw_plan() {
    # mw_plan <English> <中文>：试运行时把「本来会发生什么」打出来。
    # 不在试运行时一个字都不输出，调用点因此不必套 if。
    mw_dry_run || return 0
    if [[ "$MW_LANG" == "zh" ]]; then
        printf '%b\n' "$2"
    else
        printf '%b\n' "$1"
    fi
}

# 先扫一遍参数里的两个流程开关，不消费参数（真正的解析在下面）：
#   --zh      —— 否则 `--help --zh` 会因为 --help 先被处理而输出英文；
#   --dry-run —— 版本号在解析参数**之前**就要读，试运行必须在那之前生效，
#                否则断网的机器上第一步就退出了，看不到后面任何输出。
for _mw_arg in "$@"; do
    case "$_mw_arg" in
        --zh|--ZH) MW_LANG="zh" ;;
        --dry-run|--DRY-RUN) CLI_DRY_RUN=true ;;
    esac
done


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

mw_redact() {
    # mw_redact <url>：把 URL 里的口令换成 ***，日志与报错里不能出现明文。
    # 只在 host 段找 @ —— path 里的 @ 是合法文件名（jq@1.7.1.arm64）。
    local url="$1"
    local scheme rest authority path userinfo host user

    case "$url" in
        *://*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    scheme="${url%%://*}"
    rest="${url#*://}"
    authority="${rest%%/*}"
    if [[ "$rest" == */* ]]; then path="/${rest#*/}"; else path=""; fi

    case "$authority" in
        *@*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    userinfo="${authority%@*}"
    host="${authority##*@}"
    user="${userinfo%%:*}"
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s\n' "$scheme" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s\n' "$scheme" "$host" "$path"
    fi
}

# pip 依赖（requests / packaging / rich）不在我们自己的存储里，仍走 PyPI。
# 国内直连 pypi.org 常超时，所以留一个可覆盖的索引地址：默认官方，设了就换。
#
# 与上面六个变量的差别：它不参与「MacWave 从哪取文件」的判断，只影响 pip 一次调用，
# 所以校验规则更松（允许 https 与 http 回环，与 mw_domain 同）。
PIP_INDEX_URL="$(mw_domain MACWAVE_PIP_INDEX "${MACWAVE_PIP_INDEX:-https://pypi.org/simple}")"

# MacWave 自身文件（后面再拼 /<分支>/<路径>）
CORE_URL="$(mw_domain MACWAVE_CORE_DOMAIN "${MACWAVE_CORE_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/MacWave}")"
# 自更新数据：版本号、文件清单、目录迁移脚本
SELFUPDATE_URL="$(mw_domain MACWAVE_SELFUPDATE_DOMAIN "${MACWAVE_SELFUPDATE_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/main}")"
# 自带 CPython 的清单
# 解释器单独一个仓库（体积与发布节奏都和自更新数据不同）
PYTHON_DOMAIN_URL="$(mw_domain MACWAVE_PYTHON_DOMAIN "${MACWAVE_PYTHON_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Python/main}")"

# ==========================================
# 版本号与代码分支（从自更新数据读取，不写死在脚本里）
# ==========================================
#
# macwavedata/latest.toml 里的 version 是这次要安装的版本，branch 是配套的代码分支：
# 两者一起读，保证「下载的代码」和「写进 VERSION.json 的版本号」对应同一个版本。
#
# 格式是 TOML 的一个子集：平铺的 `key = "value"`，允许行尾 # 注释。
# 这里用 sed 而不是引 TOML 解析器，因为此刻客户端还没有可用的 Python 环境。

LATEST_DATA_URL="$SELFUPDATE_URL/macwavedata/latest.toml"
# `|| true` 不能省：赋值语句的退出码就是 curl 的退出码，在 `set -e` 下取不到
# 版本会直接静默退出（实测 exit 7，下面那段「读不到版本」的提示一个字都打不出来）。
LATEST_VERSION_DATA="$(curl -fsSL --max-time 30 "$LATEST_DATA_URL" 2>/dev/null || true)"

read_toml_string() {
    # read_toml_string <文本> <键> —— 取平铺的字符串值，去掉引号与行尾注释
    printf '%s\n' "$1" \
        | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

MACWAVE_VERSION="$(read_toml_string "$LATEST_VERSION_DATA" version)"
LATEST_BRANCH="$(read_toml_string "$LATEST_VERSION_DATA" branch)"

if [[ -z "$MACWAVE_VERSION" || -z "$LATEST_BRANCH" ]]; then
    if mw_dry_run; then
        # 试运行可能只是想看输出，不该因为断网就断在第一行：用占位值把流程
        # 走完，后面每一处都只打印、不落地。真实安装仍然在这里退出。
        MACWAVE_VERSION="${MACWAVE_VERSION:-unknown}"
        LATEST_BRANCH="${LATEST_BRANCH:-unknown}"
        mw_say "${YELLOW}🌊 Dry run: could not read the latest version; using '$MACWAVE_VERSION'." \
            "${YELLOW}🌊 试运行：读不到最新版本号，用占位值 '$MACWAVE_VERSION'。"
        mw_say "${YELLOW}🌊   $(mw_redact "$LATEST_DATA_URL")" \
            "${YELLOW}🌊   $(mw_redact "$LATEST_DATA_URL")"
    else
        echo -e "${RED_BOLD}🌊 Error: Cannot read the latest version from the self-update data.${RESET}" >&2
        echo -e "${RED_BOLD}🌊   $(mw_redact "$LATEST_DATA_URL")${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Check your network or proxy, then run the installer again.${RESET}" >&2
        exit 1
    fi
fi

BRANCH="$LATEST_BRANCH"
BASE_URL="$CORE_URL/$BRANCH"

# ==========================================
# 辅助函数：将路径中的 $HOME 替换为 ~
# ==========================================

home_to_tilde() {
    local path="$1"
    if [[ "$path" == "$HOME"* ]]; then
        echo "~${path#$HOME}"
    else
        echo "$path"
    fi
}

# 同上，但结果会**原样交给用户复制执行**，所以要照顾 shell 的展开规则：
#   - `~` 只在引号外展开，`"~/a b/x"` 展开不了；含空格的片段写成 `~/"a b"/x`，
#     bash、zsh 与 csh 都实测可用。
#   - 路径不在家目录下且含空格时，整段加引号。
home_to_tilde_arg() {
    local path="$1"
    local prefix="" rest="$path"
    if [[ "$path" == "$HOME" || "$path" == "$HOME"/* ]]; then
        prefix="~"
        rest="${path#"$HOME"}"
        rest="${rest#/}"
        [[ -z "$rest" ]] && { printf '~'; return; }
    fi
    if [[ "$rest" == *" "* || "$rest" == *'"'* ]]; then
        rest="${rest//\"/\\\"}"
        printf '%s"%s"' "${prefix:+$prefix/}" "$rest"
    else
        printf '%s%s' "${prefix:+$prefix/}" "$rest"
    fi
}

# 必须让 shell 自己展开的场合（grep 的匹配模式、csh 的双引号里）改用 $HOME/…：
# 它在双引号内也会展开，而 ~ 不会。
home_to_homevar() {
    local path="$1"
    if [[ "$path" == "$HOME" || "$path" == "$HOME"/* ]]; then
        local rest="${path#"$HOME"}"
        rest="${rest#/}"
        [[ -z "$rest" ]] && { printf '$HOME'; return; }
        printf '$HOME/%s' "$rest"
    else
        printf '%s' "$path"
    fi
}

# ==========================================
# 辅助函数：校验自定义目录，防止路径穿越
# ==========================================

validate_custom_dir() {
    local dir="$1"

    if [[ -z "$dir" ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: Empty path is not allowed.${RESET}" "${RED_BOLD}🌊 错误：路径不能为空。${RESET}"
        return 1
    fi

    if [[ "$dir" == *".."* ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: Path traversal ('..') is not allowed.${RESET}" "${RED_BOLD}🌊 错误：路径中不允许出现 '..'。${RESET}"
        return 1
    fi

    if [[ "$dir" == *$'\n'* ]] || [[ "$dir" == *$'\r'* ]] || [[ "$dir" == *$'\t'* ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: Invalid control characters in path.${RESET}" "${RED_BOLD}🌊 错误：路径中包含非法控制字符。${RESET}"
        return 1
    fi

    if LC_ALL=C grep -q '[^a-zA-Z0-9/_.~ -]' <<< "$dir"; then
        mw_say_err "${RED_BOLD}🌊 Error: Path contains non-ASCII or invalid characters.${RESET}" "${RED_BOLD}🌊 错误：路径包含非 ASCII 字符或非法字符。${RESET}"
        echo -e "${RED_BOLD}🌊 Only ASCII letters, digits, '/', '-', '_', '.', '~', and spaces are allowed.${RESET}" >&2
        return 1
    fi

    local expanded="${dir/#\~/$HOME}"

    if [[ "$expanded" != /* ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: Please use an absolute path (starting with / or ~).${RESET}" "${RED_BOLD}🌊 错误：请使用绝对路径（以 / 或 ~ 开头）。${RESET}"
        return 1
    fi

    if [[ "$expanded" == *"//"* ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: Path contains consecutive slashes.${RESET}" "${RED_BOLD}🌊 错误：路径中包含连续的斜杠。${RESET}"
        return 1
    fi

    if [[ "$expanded" == "/" ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: Cannot install to root directory.${RESET}" "${RED_BOLD}🌊 错误：不能安装到根目录。${RESET}"
        return 1
    fi

    # 下面两条是这个函数最要紧的部分。
    #
    # 装到系统目录时安装脚本会 `sudo chown -R $CURRENT_USER: $BASE_DIR`（让之后
    # `wave install` 不必每次提权），而拒绝协议时还会 `rm -rf "$BASE_DIR"`。
    # 如果 BASE_DIR 是 /usr/local 这种「别的软件的家」，这两件事分别是
    # **把整个 Homebrew 变成当前用户的** 和 **删掉它**。
    #
    # 这不是假想：`--dir-option=3=/usr/local` 以前能一路通过校验。

    # 1) 这些目录本身绝不能被当作安装根目录。它们的子目录可以（/opt/macwave、
    #    /usr/local/macwave），正因为如此才要按「完全相等」判，不能用前缀。
    local _forbidden
    for _forbidden in /bin /sbin /usr /usr/bin /usr/sbin /usr/lib /usr/libexec \
                     /usr/local /usr/share /opt /etc /var /tmp /private \
                     /System /Library /Applications /Users /Volumes /Network; do
        if [[ "$expanded" == "$_forbidden" ]]; then
            mw_say_err "${RED_BOLD}🌊 Error: '$expanded' is a system directory, not an install directory.${RESET}" \
                    "${RED_BOLD}🌊 错误：'$expanded' 是系统目录，不能当作安装目录。${RESET}"
            mw_say_err "🌊 Pick a directory of its own, for example ${_forbidden}/macwave" \
                    "🌊 请用一个专属目录，例如 ${_forbidden}/macwave"
            return 1
        fi
    done

    # 2) 家目录本身同理。装进去会把 MacWave 的文件撒得到处都是，回滚时还会
    #    rm -rf 整个家目录。
    if [[ "$expanded" == "$HOME" ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: Cannot install directly into your home directory.${RESET}" \
                "${RED_BOLD}🌊 错误：不能直接装到家目录里。${RESET}"
        mw_say_err "🌊 Use a subdirectory such as ~/macwave" "🌊 请用一个子目录，例如 ~/macwave"
        return 1
    fi

    # 3) 已存在且非空、又不是 MacWave 安装的目录：拒绝。
    #    这一条覆盖上面清单之外的所有情况 —— 任何「别的软件已经在用」的目录都
    #    落到这里。判据是 lib/wave.py：只有 MacWave 自己的安装树有它，所以重装
    #    与升级仍然放行，占用别人的目录则被挡住。
    if [[ -d "$expanded" && ! -f "$expanded/lib/wave.py" ]]; then
        if [[ -n "$(ls -A "$expanded" 2>/dev/null)" ]]; then
            mw_say_err "${RED_BOLD}🌊 Error: '$expanded' already exists and is not empty.${RESET}" \
                    "${RED_BOLD}🌊 错误：'$expanded' 已存在且非空。${RESET}"
            mw_say_err "🌊 Installing here would take ownership of files MacWave did not create;" \
                    "🌊 装在这里会把 MacWave 没创建过的文件一并接管；"
            mw_say_err "🌊 pick a new or empty directory instead." \
                    "🌊 请改用一个新的或空的目录。"
            return 1
        fi
    fi

    echo "$expanded"
    return 0
}

# ==========================================
# 系统架构与目录菜单
# ==========================================
#
# 菜单项数随架构变化：Intel 机器多提供一个 /usr/local/macwave
# （Apple 芯片上不建议写入 /usr/local，因此只对 Intel 提供），
# 自定义目录的编号也随之变化，所以这里统一算好。

ARCH=$(uname -m)

if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
    CUSTOM_OPTION=4
else
    CUSTOM_OPTION=3
fi

print_dir_menu() {
    echo "1. ~/.local/macwave"
    echo "2. /opt/macwave"
    if [[ "$CUSTOM_OPTION" == "4" ]]; then
        echo "3. /usr/local/macwave"
    fi
    mw_say "$CUSTOM_OPTION. other (enter custom directory)" "$CUSTOM_OPTION. 其他（输入自定义目录）"
}

# ==========================================
# 命令行参数（批量 / 脚本化安装）
# ==========================================

CLI_CI=false
# --no-noise：额外做一次「mw_say 有没有被劫持成 /usr/bin/say」的检查。
# 默认不查：那件事只影响开发机，普通人装个包不该被前置闸门挡住拦下。
NO_NOISE=false
CLI_DIR_OPTION=""
CLI_CUSTOM_DIR=""
# 默认从我们自己的 Python 仓库取解释器；这个开关让它回上游取
INSTALL_PYTHON_FROM_SOURCE=""

usage() {
    if [[ "$MW_LANG" == "zh" ]]; then
        usage_zh
    else
        usage_en
    fi
}

usage_en() {
    cat <<USAGE_EOF
MacWave installer

Usage:
  install.sh [options]

Options:
      --ci, --CI          No interaction at all: the directory menu and the
                          agreement are answered automatically. Without
                          --dir-option the default (option 1) is used.
                          Requires passwordless sudo when privilege is needed.
      --dry-run           Print what the installer would do and change
                          nothing: no download, no sudo, no directory
                          created, no file written. When the latest version
                          cannot be fetched it continues with a placeholder,
                          so the output can be reviewed offline.
      --dir-option=N      Pick menu entry N without prompting (1-$CUSTOM_OPTION).
      --dir-option=DIR    Use DIR as the installation directory (shorthand for
                          --dir-option=$CUSTOM_OPTION=DIR).
      --dir-option=N=DIR  Pick entry N and, for the custom entry ($CUSTOM_OPTION), use DIR
                          as the installation directory.
        --install-python-from-source
                            Download the bundled CPython from its upstream URL
                            (recorded in pythondata/<version>/python_url.toml)
                            instead of from MacWave's own Python repository.
        --no-noise          Also check that mw_say has not been hijacked by
                            /usr/bin/say (the macOS spoken-text command).
                            Off by default; --NO-NOISE and --No-Noise work too.
      --zh                Print in Chinese (English by default).
  -h, --help              Show this help.

Directory menu:
$(print_dir_menu | sed 's/^/  /')

Examples:
  install.sh --ci --dir-option=1
  install.sh --CI --dir-option=2
  install.sh --ci --dir-option=$CUSTOM_OPTION=/opt/my-macwave
  install.sh --ci --dir-option=/opt/my-macwave

Running it straight from the repository (options go after '--'):
  /bin/bash -c "\$(curl -fsSL <url>)" -- --ci --dir-option=1
USAGE_EOF
}

usage_zh() {
    cat <<USAGE_EOF
MacWave 安装程序

用法：
  install.sh [选项]

选项：
      --ci, --CI          完全不交互：目录菜单与用户协议都自动应答。不带
                          --dir-option 时使用默认项（第 1 项）。
                          需要提权时要求 sudo 免密。
      --dry-run           只打印安装器会做什么，不做任何改动：不下载、不提权、
                          不建目录、不写文件。取不到最新版本号时用占位值继续，
                          因此在断网的机器上也能看完整个输出。
      --dir-option=N      不提问，直接选菜单第 N 项（1-${CUSTOM_OPTION}）。
      --dir-option=DIR    用 DIR 作为安装目录（等价于
                          --dir-option=$CUSTOM_OPTION=DIR）。
      --dir-option=N=DIR  选第 N 项，并在自定义项（${CUSTOM_OPTION}）时用 DIR
                          作为安装目录。
        --install-python-from-source
                            自带 CPython 改从上游 URL 下载（记录在
                            pythondata/<version>/python_url.toml），
                            而不是从 MacWave 自己的 Python 仓库取。
        --no-noise          额外检查 mw_say 有没有被 /usr/bin/say（macOS 的朗读
                            命令）劫持。默认不查；--NO-NOISE、--No-Noise 也认。
      --zh                用中文输出（默认英文）。
  -h, --help              显示本帮助。

目录菜单：
$(print_dir_menu | sed 's/^/  /')

示例：
  install.sh --ci --dir-option=1
  install.sh --CI --dir-option=2
  install.sh --ci --dir-option=$CUSTOM_OPTION=/opt/my-macwave
  install.sh --ci --dir-option=/opt/my-macwave

直接从仓库运行（选项放在 '--' 之后）：
  /bin/bash -c "\$(curl -fsSL <url>)" -- --ci --dir-option=1
USAGE_EOF
}

# 语言与 --dry-run 的预扫已在文件上方完成（版本号要在解析之前就用到），
# 这里只做真正的参数解析。

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci|--CI)
            CLI_CI=true
            ;;
        --dry-run|--DRY-RUN)
            CLI_DRY_RUN=true
            ;;
        --dir-option=*)
            _value="${1#--dir-option=}"
            # 只有 N=DIR（前缀是数字）才拆分；--dir-option=<路径> 里若本身带 '='，
            # 整条按路径处理，不会被误拆。
            if [[ "$_value" == *=* && "${_value%%=*}" =~ ^[0-9]+$ ]]; then
                CLI_DIR_OPTION="${_value%%=*}"
                CLI_CUSTOM_DIR="${_value#*=}"
            else
                CLI_DIR_OPTION="$_value"
            fi
            ;;
        --install-python-from-source)
            INSTALL_PYTHON_FROM_SOURCE=1
            ;;
        # --no-noise / --NO-NOISE / --No-Noise 都认：这是给自己人用的开关，
        # 强求统一大小写只会浪费一次重敲。
        --[Nn][Oo]-[Nn][Oo][Ii][Ss][Ee])
            NO_NOISE=true
            ;;
        --zh|--ZH)
            MW_LANG="zh"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            mw_say_err "${RED_BOLD}🌊 Error: unknown option '$1'. Try --help.${RESET}" "${RED_BOLD}🌊 错误：未知选项 '$1'。可试 --help。${RESET}"
            exit 1
            ;;
    esac
    shift
done

# --no-noise 的正事。必须放在解析之后 —— 放前面的话 NO_NOISE 还是默认值 false，
# 旗标永远不会生效（第一版就是这么错的，实测三种写法全都没触发）。
#
# 默认不查的理由：这个检查防的是「开发机上的 mw_say 被劫持成朗读命令」，
# 与普通人装包无关；默认拦下来只会让人一脸问号地装不上。
if [[ "$NO_NOISE" == "true" ]]; then
    mw_check_say_hijack
fi
unset -f mw_check_say_hijack   # 用完即删，避免污染后面的函数命名空间

# 通过管道安装时，选项很容易被当成脚本名传进来：
#   bash -c "$(curl ...)" --ci         ← --ci 变成 $0，被静默丢掉
# 这里明确提示，避免「静默模式没生效、脚本却卡在交互上」。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        echo -e "${YELLOW}🌊 Warning: '$0' was treated as the script name, not as an option.${RESET}" >&2
        echo -e "${YELLOW}🌊 Put installer options after '--', which ends bash's own options.${RESET}" >&2
        echo "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" >&2
        ;;
esac

# --dir-option=<路径> 是 --dir-option=<自定义项>=<路径> 的简写：值不是数字时，
# 直接把该值当作自定义安装目录。
if [[ -n "$CLI_DIR_OPTION" && ! "$CLI_DIR_OPTION" =~ ^[0-9]+$ ]]; then
    CLI_CUSTOM_DIR="$CLI_DIR_OPTION"
    CLI_DIR_OPTION="$CUSTOM_OPTION"
fi

if [[ -n "$CLI_DIR_OPTION" ]] && [[ "$CLI_DIR_OPTION" -lt 1 || "$CLI_DIR_OPTION" -gt "$CUSTOM_OPTION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option must be 1-$CUSTOM_OPTION on this architecture, got '$CLI_DIR_OPTION'.${RESET}" >&2
    exit 1
fi

if [[ -n "$CLI_CUSTOM_DIR" && "$CLI_DIR_OPTION" != "$CUSTOM_OPTION" ]]; then
    echo -e "${RED_BOLD}🌊 Error: only --dir-option=$CUSTOM_OPTION takes a directory (this architecture has $CUSTOM_OPTION entries).${RESET}" >&2
    exit 1
fi

if [[ "$CLI_DIR_OPTION" == "$CUSTOM_OPTION" && -z "$CLI_CUSTOM_DIR" && "$CLI_CI" == "true" ]]; then
    echo -e "${RED_BOLD}🌊 Error: --dir-option=$CUSTOM_OPTION needs a directory in --ci mode.${RESET}" >&2
    echo -e "${RED_BOLD}🌊 Use --dir-option=$CUSTOM_OPTION=/some/dir${RESET}" >&2
    exit 1
fi

# 解析自定义安装目录：命令行给了就直接用，否则提示输入
resolve_custom_dir() {
    local custom_dir validated
    if [[ -n "$CLI_CUSTOM_DIR" ]]; then
        custom_dir="$CLI_CUSTOM_DIR"
        mw_say "🌊 Installation directory: $custom_dir (from --dir-option)" "🌊 安装目录：${custom_dir}（来自 --dir-option）"
    else
        mw_say "${YELLOW}Please enter the installation directory:${RESET}" "${YELLOW}请输入安装目录：${RESET}"
        read -r custom_dir < /dev/tty
    fi
    validated=$(validate_custom_dir "$custom_dir") || exit 1
    BASE_DIR="$validated"
}

# ==========================================
# 显示欢迎信息
# ==========================================
# WAVE 艺术字。与语言无关，两种语言都打 —— 它只是装饰，不值得为它写两份。
echo ""
echo -e "${SKY_BLUE}██╗    ██╗ █████╗ ██╗   ██╗███████╗${RESET}"
echo -e "${SKY_BLUE}██║    ██║██╔══██╗██║   ██║██╔════╝${RESET}"
echo -e "${SKY_BLUE}██║ █╗ ██║███████║██║   ██║█████╗  ${RESET}"
echo -e "${SKY_BLUE}██║███╗██║██╔══██║╚██╗ ██╔╝██╔══╝  ${RESET}"
echo -e "${SKY_BLUE}╚███╔███╔╝██║  ██║ ╚████╔╝ ███████╗${RESET}"
echo -e "${SKY_BLUE} ╚══╝╚══╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝${RESET}"
echo ""
mw_say "🌊 Welcome to MacWave $MACWAVE_VERSION!" "🌊 欢迎使用 MacWave ${MACWAVE_VERSION}！"

if mw_dry_run; then
    echo ""
    mw_say "${YELLOW}🌊 Dry run: the whole install is walked through, nothing is changed.${RESET}" \
        "${YELLOW}🌊 试运行：完整走一遍安装流程，但不做任何改动。${RESET}"
fi

if [[ "$CORE_URL" != "https://raw.githubusercontent.com/MacWaveOrg/MacWave" ]]; then
    mw_say "🌊 Install from mirror: $(mw_redact "$CORE_URL")" "🌊 从镜像安装：$(mw_redact "$CORE_URL")"
fi

echo ""

mw_say "🌊 Detected architecture: $ARCH" "🌊 检测到架构：$ARCH"

# ==========================================
# 选择安装目录（交互式 / --dir-option / --ci 默认）
# ==========================================

if [[ -n "$CLI_DIR_OPTION" ]]; then
    choice="$CLI_DIR_OPTION"
    mw_say "🌊 Directory option: $choice (from --dir-option)" "🌊 目录选项：${choice}（来自 --dir-option）"
elif [[ "$CLI_CI" == "true" ]]; then
    choice="1"
    mw_say "🌊 --ci: using the default directory option 1." "🌊 --ci：使用默认目录选项 1。"
else
    mw_say "${YELLOW}Where do you want to install MacWave? (Enter the number)${RESET}" "${YELLOW}要把 MacWave 安装到哪里？（输入编号）${RESET}"
    print_dir_menu
    echo ""
    mw_say "${YELLOW}Enter your choice:${RESET}" "${YELLOW}请输入选择：${RESET}"

    read -r choice < /dev/tty
fi

case "$choice" in
    1)
        BASE_DIR="$HOME/.local/macwave"
        ;;
    2)
        BASE_DIR="$SYS_ROOT/opt/macwave"
        ;;
    3)
        if [[ "$CUSTOM_OPTION" == "3" ]]; then
            resolve_custom_dir
        else
            BASE_DIR="$SYS_ROOT/usr/local/macwave"
        fi
        ;;
    4)
        resolve_custom_dir
        ;;
    *)
        mw_say "${RED_BOLD}🌊 Invalid choice. Using default: ~/.local/macwave${RESET}" "${RED_BOLD}🌊 选择无效，改用默认目录：~/.local/macwave${RESET}"
        BASE_DIR="$HOME/.local/macwave"
        ;;
esac

DISPLAY_DIR=$(home_to_tilde "$BASE_DIR")

# ==========================================
# 判断是否需要 sudo
# ==========================================

CURRENT_USER=$(whoami)

# ==========================================
# 系统级安装的所有权
# ==========================================
#
# 为什么不是 chown -R 给当前用户：那会把 /opt/macwave 变成「第一个安装者私有」的，
# 同一台机器上别的管理员 `wave install` 会 Permission denied —— 而 /opt 这类目录的
# 本意恰恰是共享安装。
#
# 为什么不是 chmod -R 777：任何本地用户都能替换 /opt/macwave/links/jq，而它可能
# 被别的用户、脚本甚至 root 执行 —— 那是教科书式的本地提权路径。
#
# 采用的模型：root:<管理员组> 755。管理员本来就知道密码、本来就能 sudo，
# 所以不需要「组可写 + setgid + ACL 继承」那一套 —— 那是为了让非 root 写共享目录，
# 代价是把系统 PATH 里的二进制变成组可写，收益不抵风险。
#
#   所有人    可读、可执行（能用已装的包）
#   root     可写（wave install / 升级需要 sudo）
#
# 代价是系统级安装下 `wave install` 要 sudo。这一条在 pkg/pkginstaller.py 里
# 有对应的检测与提示，不要只改这里。
admin_group() {
    # 只在「当前用户确实是这个组的成员」时才用它。
    #
    # 走到这里说明安装已经成功 sudo 过（写 /opt、/usr/local 都要密码），所以当前
    # 用户是管理员这一点无需怀疑；把组设成管理员组，等于把「谁能改这个安装树」
    # 定义为「所有管理员」，而不是「当初装它的那个人」。
    #
    # 但仍要验证成员资格：有些环境（root 直接跑、容器里的非标准用户）不在这几个
    # 组里，那时退回当前用户的主组，免得 chown 到一个自己都不属于的组。
    local candidate
    for candidate in admin sudo wheel; do
        if ! id -Gn "$CURRENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$candidate"; then
            continue
        fi
        if dscl . -read "/Groups/$candidate" >/dev/null 2>&1 \
           || grep -qE "^${candidate}:" /etc/group 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    id -gn "$CURRENT_USER"
}

hand_over_system_install() {
    # 系统级安装（$BASE_DIR 不在家目录下）才需要动手；用户级本来就是自己的。
    local dir="$1" group
    [[ -n "$dir" ]] || return 0
    if mw_dry_run; then
        # 目录此刻还不存在（试运行不建），所以判断要放在 -d 检查之前。
        mw_plan "🌊 Dry run: would hand $dir over to root:$(admin_group) with mode 755." \
            "🌊 试运行：将把 ${dir} 交给 root:$(admin_group)，权限 755。"
        return 0
    fi
    [[ -d "$dir" ]] || return 0
    group="$(admin_group)"
    sudo chown -R "root:$group" "$dir" || return 1
    sudo chmod -R u+rwX,go+rX,go-w "$dir" || return 1
    return 0
}

if [[ "$BASE_DIR" == "$HOME"* ]]; then
    NEED_SUDO=false
else
    NEED_SUDO=true
fi

run_cmd() {
    # 试运行只把命令打出来：建目录、写配置、删旧文件都经由这里。
    if mw_dry_run; then
        if [[ "$NEED_SUDO" == "true" ]]; then
            echo -e "${YELLOW}    sudo $*${RESET}"
        else
            echo -e "${YELLOW}    $*${RESET}"
        fi
        return 0
    fi
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

if [[ "$NEED_SUDO" == "true" ]]; then
    if mw_dry_run; then
        mw_plan "${YELLOW}🌊 Dry run: installing to $BASE_DIR needs administrator access; no password is asked now.${RESET}" \
            "${YELLOW}🌊 试运行：装到 ${BASE_DIR} 需要管理员权限，现在不会索取密码。${RESET}"
    elif [[ "$CLI_CI" == "true" ]]; then
        # --ci 不能停下来等密码：要么已经是 root，要么已有免密 sudo
        if ! sudo -n true 2> /dev/null; then
            echo -e "${RED_BOLD}🌊 Error: this install needs privilege, but --ci cannot ask for a password.${RESET}" >&2
            echo -e "${RED_BOLD}🌊 Run as root, or configure passwordless sudo for the install user.${RESET}" >&2
            exit 1
        fi
    else
        mw_say "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}" "${YELLOW}🌊 正在申请临时管理员权限以完成安装……${RESET}"
        sudo -v
    fi
fi

# ==========================================
# 更新脚本（macwavedata/<版本>/update_commands.sh）
# ==========================================
#
# 要下载哪些文件、放到哪里，以前是客户端读一份 files_info 自己解析。现在改成
# 由自更新数据提供一个脚本，客户端只负责取回来执行：
#
#   - 脚本自己知道这一版该下哪些文件，所以能只列变动的那些（没碰过的文件不必重下）；
#   - 目录结构变更的迁移也写在同一个脚本里，不必再维护第二套机制；
#   - 客户端不再需要「缩进树」这种自定义格式的解析器。
#
# 这一步刻意放在「建目录 / 写配置 / 清旧版」之前：连不上自更新数据就直接退出，
# 不会留下一个配置已写好、文件却一个都没下的半成品安装。

UPDATE_COMMANDS_URL="$SELFUPDATE_URL/macwavedata/$MACWAVE_VERSION/update_commands.sh"
UPDATE_COMMANDS_TMP=""

cleanup_update_commands() {
    if [[ -n "$UPDATE_COMMANDS_TMP" ]]; then
        rm -f "$UPDATE_COMMANDS_TMP"
    fi
}
trap cleanup_update_commands EXIT

fetch_update_commands() {
    # 取回并校验这一版的更新命令。失败时此时还没动过任何东西，直接退出是安全的。
    local attempt ok=false

    UPDATE_COMMANDS_TMP="$(mktemp)"
    mw_say "🌊 Fetching the update commands..." "🌊 正在获取更新命令……"

    for attempt in 1 2 3; do
        if curl -fsSL --max-time 60 -o "$UPDATE_COMMANDS_TMP" "$UPDATE_COMMANDS_URL"; then
            ok=true
            break
        fi
        if [[ "$attempt" -lt 3 ]]; then
            mw_say "${YELLOW}🌊 Retrying the update commands ($((attempt + 1))/3)...${RESET}" "${YELLOW}🌊 正在重试获取更新命令（$((attempt + 1))/3）……${RESET}"
        fi
    done

    if [[ "$ok" != "true" ]]; then
        echo -e "${RED_BOLD}🌊 Error: Cannot fetch the update commands.${RESET}"
        echo -e "${RED_BOLD}🌊   $(mw_redact "$UPDATE_COMMANDS_URL")${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was installed. Check your network or proxy, then run the installer again.${RESET}"
        exit 1
    fi

    if ! bash -n "$UPDATE_COMMANDS_TMP" 2>/dev/null; then
        echo -e "${RED_BOLD}🌊 Error: the update commands for $MACWAVE_VERSION are not valid shell.${RESET}"
        echo -e "${RED_BOLD}🌊 Nothing was installed. Please report this to the administrator.${RESET}"
        exit 1
    fi
}

if mw_dry_run; then
    mw_plan "🌊 Dry run: would fetch the update commands for $MACWAVE_VERSION and run them." \
        "🌊 试运行：将获取 $MACWAVE_VERSION 的更新命令并执行："
    echo -e "${YELLOW}    $(mw_redact "$UPDATE_COMMANDS_URL")${RESET}"
    mw_plan "🌊   They download the program files into $BASE_DIR and apply directory migrations." \
        "🌊   它会把程序文件下载到 ${BASE_DIR}，并执行目录结构迁移。"
else
    fetch_update_commands
fi

# ==========================================
# 创建目录
# ==========================================

INSTALL_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"
REPO_DIR="$BASE_DIR/pkg"
SURFBOARD_DIR="$BASE_DIR/surfboard"
LIB_DIR="$BASE_DIR/lib"
NET_DIR="$BASE_DIR/net"
DEPS_DIR="$BASE_DIR/deps"
DOWNLOAD_DIR="$BASE_DIR/downloads/tmp"

# 配置文件目录：装到系统目录（需要 sudo）时用 /opt/macwave_config，
# 装到用户目录（无需 sudo）时用 ~/.config/macwave_config。
# 读取时系统级优先，所以系统级 MacWave 总是盖过用户级的。
if [[ "$NEED_SUDO" == "true" ]]; then
    CONFIG_DIR="$SYS_ROOT/opt/macwave_config"
else
    CONFIG_DIR="$HOME/.config/macwave_config"
fi
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

MW_OPTIONAL_RESULT=""

mw_try() {
    # mw_try <命令...>：跑一个「失败也无所谓」的命令，stdout 存进 MW_OPTIONAL_RESULT。
    # 失败时不惊动 ERR trap —— 否则用户会先看到「Installation did not finish」，
    # 几百行之后再看到「Installation complete!」，比不提示更糟。
    #
    # 旗标必须在**命令替换的整个生命周期内**保持设置：`set -E` 让 ERR trap 传进
    # 子 shell，而子 shell 退出时如果那条命令返回非零，trap 照样会响。所以赋值写进
    # 本函数内部，而不是让调用方写 `X="$(mw_try ...)"`。
    local output
    MW_FAILURE_HANDLED=1
    output="$("$@")" && MW_OPTIONAL_RESULT="$output" || MW_OPTIONAL_RESULT=""
    unset MW_FAILURE_HANDLED
    return 0
}

# 中途失败时给出明确指引。刻意**不自动删除**已下载的内容：升级安装时
# 删掉安装树会把用户原有的可用安装一起毁掉，重跑安装器才是安全的做法。
install_failed() {
    local code=$?

    # 有些失败是**预期之内**的：自带解释器取不到时会回落到系统 python3，
    # 安装照常完成。那些地方用 mw_optional 包着，会临时立这个旗标，
    # 于是这里不报「安装未完成」—— 否则用户看到的是「安装失败」接着
    # 「Installation complete!」，比没有提示更糟。
    if [[ -n "${MW_FAILURE_HANDLED:-}" ]]; then
        return 0
    fi

    echo "" >&2
    echo -e "${RED_BOLD}🌊 Installation did not finish (exit $code).${RESET}" >&2
    mw_say_err "🌊 Nothing was removed. Files already downloaded may be left in:" "🌊 没有删除任何内容。已下载的文件可能留在："
    echo "     ${BASE_DIR:-<not chosen yet>}" >&2
    echo "     ${CONFIG_DIR:-<not chosen yet>}" >&2
    mw_say_err "🌊 Fix the cause (network, permissions, disk space) and run the installer again;" "🌊 请排除原因（网络、权限、磁盘空间）后重新运行安装程序；"
    mw_say_err "🌊 a repeated install overwrites what it downloaded and is safe to rerun." "🌊 重复安装会覆盖已下载的内容，可以安全重跑。"
}
trap install_failed ERR

run_cmd mkdir -p "$INSTALL_DIR"
run_cmd mkdir -p "$LINKS_DIR"
run_cmd mkdir -p "$REPO_DIR"
run_cmd mkdir -p "$SURFBOARD_DIR"
run_cmd mkdir -p "$LIB_DIR"
run_cmd mkdir -p "$NET_DIR"
run_cmd mkdir -p "$DEPS_DIR"
run_cmd mkdir -p "$DOWNLOAD_DIR"
run_cmd mkdir -p "$CONFIG_DIR"
run_cmd chmod 755 "$CONFIG_DIR"

# ==========================================
# 写入配置文件
# ==========================================

run_cmd tee "$CONFIG_FILE" > /dev/null << EOF
{
  "base_dir": "$BASE_DIR"
}
EOF

run_cmd tee "$VERSION_FILE" > /dev/null << EOF
{
  "version": "$MACWAVE_VERSION",
  "components": {
    "installer": "$MACWAVE_VERSION",
    "parser": "$MACWAVE_VERSION"
  }
}
EOF

# ==========================================
# 把所有权交还给当前真实用户
# ==========================================

if [[ "$NEED_SUDO" == "true" ]]; then
    hand_over_system_install "$BASE_DIR"
fi

if [[ "$NEED_SUDO" == "true" ]]; then
    hand_over_system_install "$CONFIG_DIR"
fi
run_cmd chmod 755 "$CONFIG_DIR"
run_cmd chmod 644 "$CONFIG_FILE"
run_cmd chmod 644 "$VERSION_FILE"

if mw_dry_run; then
    mw_plan "🌊 Dry run: would write $CONFIG_FILE (base_dir) and $VERSION_FILE (version $MACWAVE_VERSION)." \
        "🌊 试运行：将写入 ${CONFIG_FILE}（base_dir）与 ${VERSION_FILE}（版本 ${MACWAVE_VERSION}）。"
else
    mw_say "🌊 Configuration saved to $CONFIG_FILE" "🌊 配置已保存到 $CONFIG_FILE"
    mw_say "🌊 Version saved to $VERSION_FILE" "🌊 版本信息已保存到 $VERSION_FILE"
fi

# ==========================================
# 删除1.x旧版 repo.json，软件包索引现已网络实时拉取，不再依赖需要记得刷新（否则安装不到新版）、冗余（用户还得下载且没什么用）的本地索引
# ==========================================

OLD_JSON="$REPO_DIR/repo.json"
if [ -f "$OLD_JSON" ]; then
    mw_say "🌊 Removing old repo.json (legacy format)..." "🌊 正在删除旧格式的 repo.json……"
    run_cmd rm -f "$OLD_JSON"
fi

# ==========================================
# 清理旧版（2.1.0）遗留的平铺 bin/ 文件
# ==========================================

LEGACY_BINS=$(find "$INSTALL_DIR" -maxdepth 1 -type f 2>/dev/null || true)
if [[ -n "$LEGACY_BINS" ]]; then
    if mw_dry_run; then
        echo -e "${YELLOW}🌊 Dry run: files from an older version would be removed from $DISPLAY_DIR/bin:${RESET}"
    else
        echo -e "${YELLOW}🌊 Removing files installed by an older version in $DISPLAY_DIR/bin:${RESET}"
    fi
    while IFS= read -r legacy_file; do
        echo -e "${YELLOW}    $(basename "$legacy_file")${RESET}"
    done <<< "$LEGACY_BINS"
    while IFS= read -r legacy_file; do
        run_cmd rm -f "$legacy_file"
    done <<< "$LEGACY_BINS"
    echo -e "${YELLOW}🌊 ${BRANCH} keeps packages in bin/{name}@{version}/ directories.${RESET}"
    echo -e "${YELLOW}🌊 Please reinstall the packages: wave install {name}${RESET}"
fi

# ==========================================
# 检查动态库路径替换所需的工具
# ==========================================

if command -v otool > /dev/null 2>&1 && command -v install_name_tool > /dev/null 2>&1 && command -v codesign > /dev/null 2>&1; then
    mw_say "🌊 Xcode Command Line Tools detected (otool / install_name_tool / codesign)." "🌊 已检测到 Xcode Command Line Tools（otool / install_name_tool / codesign）。"
else
    mw_say "${YELLOW}🌊 Warning: Xcode Command Line Tools not found.${RESET}" "${YELLOW}🌊 警告：未检测到 Xcode Command Line Tools。${RESET}"
    mw_say "${YELLOW}🌊 Dependency libraries cannot be relocated, so some packages may fail to run.${RESET}" "${YELLOW}🌊 依赖库无法重定位，部分软件包可能运行不起来。${RESET}"
    mw_say "🌊 You can install them later with: xcode-select --install" "🌊 之后可用这条命令安装：xcode-select --install"
fi

# ==========================================
# 执行更新脚本
# ==========================================
#
# 环境变量就是它与客户端之间的全部契约（见脚本头部注释）。
# MACWAVE_CURRENT_VERSION 留空 → 脚本走「首次安装」那条路，下载全部文件。

export MACWAVE_INSTALL_DIR="$BASE_DIR"
# 语言一路传到底下的更新脚本，否则安装过程会中英混杂。
export MACWAVE_LANG="$MW_LANG"
export MACWAVE_CONFIG_DIR="$CONFIG_DIR"
export MACWAVE_CORE_URL="$CORE_URL"
export MACWAVE_BRANCH="$BRANCH"
export MACWAVE_TARGET_VERSION="$MACWAVE_VERSION"
export MACWAVE_CURRENT_VERSION=""
export MACWAVE_FILE_TIMEOUT=60
MACWAVE_NEED_SUDO="$([ "$NEED_SUDO" = "true" ] && echo 1 || echo "")"
MACWAVE_SILENT="$([ "$CLI_CI" = "true" ] && echo 1 || echo "")"
export MACWAVE_NEED_SUDO MACWAVE_SILENT

if mw_dry_run; then
    mw_plan "🌊 Dry run: the update commands would run now and download the program files." \
        "🌊 试运行：更新命令本该在此执行并下载程序文件，实际未执行。"
elif ! bash "$UPDATE_COMMANDS_TMP"; then
    echo -e "${RED_BOLD}🌊 Error: the update commands for $MACWAVE_VERSION failed.${RESET}"
    echo -e "${RED_BOLD}🌊 Nothing was recorded as installed. Fix the cause above, then run the installer again.${RESET}"
    exit 1
fi

# ==========================================
# Python 运行环境（私有 venv + 启动器）
# ==========================================

# 为什么不用 PATH 上的 python3 直接当入口：
#   macOS 上 `python3` 可能指向 Homebrew 管理的版本，升级一次就换了路径，
#   而第三方依赖仍留在旧版本的 site-packages 里。入口写死 `#!/usr/bin/env python3`
#   就会在升级后全线报错（3.0.5 之前真实发生过）。
#
# 做法：
#   1. 在安装根目录建私有 venv，把 requests / packaging / rich 装进去；
#   2. lib/wave 变成一个 sh 启动器，按「venv → 安装时的解释器 → PATH」顺序挑选，
#      并且只有能真正 import 到三个依赖时才使用。
#
# 这样系统 Python 怎么升都不会影响已安装的 MacWave。

# 先确保安装树归当前用户所有：venv 与依赖都要以用户身份写入。
if [[ "$NEED_SUDO" == "true" ]]; then
    hand_over_system_install "$BASE_DIR"
fi

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
    mw_say_err "🌊 Checking the bundled Python version..." "🌊 正在检查自带 Python 版本……"
    latest_file="$(mktemp -t macwave-pylatest)"
    if curl -fsSL --max-time 30 -o "$latest_file" "$PYTHON_DOMAIN_URL/pythondata/latest.toml" 2>/dev/null; then
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
    mw_say_err "🌊 Fetching the bundled Python $version definition..." "🌊 正在获取自带 Python $version 的定义……"
    url_file="$(mktemp -t macwave-pyurl)"
    if ! curl -fsSL --max-time 30 -o "$url_file" \
         "$PYTHON_DOMAIN_URL/pythondata/$version/python_url.toml" 2>/dev/null; then
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
        archive_url="$PYTHON_DOMAIN_URL/pythondata/$version/$filename"
    fi

    # ── 第三步：下载并校验 ──
    mw_say_err "🌊 Downloading the bundled Python $version (about 26 MB)..." "🌊 正在下载自带 Python ${version}（约 26 MB）……"
    archive="$base_dir/downloads/tmp/portable-python-$version.tar.gz"
    mkdir -p "$base_dir/downloads/tmp" 2>/dev/null || true
    if ! curl -fsSL --max-time 900 -o "$archive" "$archive_url" 2>/dev/null; then
        rm -f "$archive"
        echo -e "${YELLOW}🌊 Could not download the bundled Python from $(mw_redact "$archive_url")${RESET}" >&2
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

if mw_dry_run; then
    # 试运行不联网：直接给出「本该由哪一份解释器来跑」，让输出与真实安装同形。
    PYTHON_BIN="<bundled python>"
    PYTHON_SOURCE="bundled"
    mw_plan "🌊 Dry run: would check the bundled Python and download it when missing (about 26 MB)." \
        "🌊 试运行：将检查自带 Python，缺失时下载（约 26 MB）。"
    mw_plan "🌊   Destination: $BASE_DIR/python/<version>/bin/python3" \
        "🌊   目标位置：${BASE_DIR}/python/<版本>/bin/python3"
else
    mw_try ensure_portable_python "$BASE_DIR" "$(portable_python_arch)"
    BUNDLED_PY="$MW_OPTIONAL_RESULT"
    if [[ -n "$BUNDLED_PY" ]]; then
        PYTHON_BIN="$BUNDLED_PY"
        PYTHON_SOURCE="bundled"
        mw_say "🌊 Using the bundled Python: ${BUNDLED_PY#"$BASE_DIR"/}" "🌊 使用自带的 Python：${BUNDLED_PY#"$BASE_DIR"/}"
    else
        PYTHON_BIN="$(command -v python3 || true)"
        PYTHON_SOURCE="system"
        if [[ -z "$PYTHON_BIN" ]]; then
            echo -e "${RED_BOLD}🌊 Error: no Python 3 interpreter is available.${RESET}"
            echo -e "${RED_BOLD}🌊 The bundled Python could not be downloaded and python3 is not in PATH.${RESET}"
            exit 1
        fi
        echo -e "${YELLOW}🌊 Warning: could not prepare the bundled Python; using $PYTHON_BIN instead.${RESET}"
        echo -e "${YELLOW}🌊 Re-run the installer when the network is available to make this installation self-contained.${RESET}"
    fi
fi

if mw_dry_run; then
    mw_plan "🌊 Dry run: would create the private Python environment at $VENV_DIR." \
        "🌊 试运行：将在 ${VENV_DIR} 创建独立的 Python 环境。"
else
    mw_say "🌊 Creating the private Python environment..." "🌊 正在创建独立的 Python 环境……"
    mkdir -p "$VENV_DIR" 2>/dev/null || true

    if "$PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1; then
        VENV_PY="$VENV_DIR/bin/python3"
        [[ -x "$VENV_PY" ]] || VENV_PY="$VENV_DIR/bin/python"
        mw_say "🌊 Private Python environment ready: ${VENV_DIR#"$BASE_DIR"/}" "🌊 独立 Python 环境已就绪：${VENV_DIR#"$BASE_DIR"/}"
    else
        echo -e "${YELLOW}🌊 Warning: could not create a private virtualenv; using the ${PYTHON_SOURCE} interpreter directly.${RESET}"
    fi
fi

# pip 的公共参数。--index-url 指向 MACWAVE_PIP_INDEX（默认官方 PyPI）；
# 国内直连 pypi.org 常超时，用户可以把它换成本地镜像。
PIP_DEPS=(requests packaging urllib3 rich)
PIP_FLAGS=(--quiet --disable-pip-version-check --timeout 30 --retries 2
           --index-url "$PIP_INDEX_URL")

if mw_dry_run; then
    mw_plan "🌊 Dry run: would install ${PIP_DEPS[*]} into the private environment (index: $PIP_INDEX_URL)." \
        "🌊 试运行：将把 ${PIP_DEPS[*]} 装进独立环境（索引：${PIP_INDEX_URL}）。"
elif [[ -n "$VENV_PY" && -x "$VENV_PY" ]]; then
    mw_say "🌊 Installing Python dependencies into the private environment..." "🌊 正在向独立环境安装 Python 依赖……"
    # pip 默认会无限等下去，网络不好时看上去就是卡死。给它超时与重试，
    # 并说明这一步可能要一会儿，免得用户以为程序挂了。
    mw_say "🌊 Installing Python dependencies into the private environment (this can take a minute)..." "🌊 正在向独立环境安装 Python 依赖（可能需要一分钟）……"
    "$VENV_PY" -m pip install "${PIP_FLAGS[@]}" --upgrade pip >/dev/null 2>&1 || true
    if ! "$VENV_PY" -m pip install "${PIP_FLAGS[@]}" "${PIP_DEPS[@]}"; then
        echo -e "${RED_BOLD}🌊 Error: failed to install the Python dependencies.${RESET}"
        echo -e "${RED_BOLD}🌊 Index used: $PIP_INDEX_URL${RESET}"
        echo -e "${RED_BOLD}🌊 Set MACWAVE_PIP_INDEX to a reachable mirror and try again,${RESET}"
        echo -e "${RED_BOLD}🌊 or install them manually into $VENV_PY.${RESET}"
        exit 1
    fi
else
    mw_say "🌊 Installing Python dependencies into $PYTHON_BIN..." "🌊 正在向 $PYTHON_BIN 安装 Python 依赖……"
    if ! "$PYTHON_BIN" -m pip install "${PIP_FLAGS[@]}" "${PIP_DEPS[@]}" 2>/dev/null; then
        if ! "$PYTHON_BIN" -m pip install "${PIP_FLAGS[@]}" --user --break-system-packages "${PIP_DEPS[@]}"; then
            echo -e "${RED_BOLD}🌊 Error: failed to install the Python dependencies.${RESET}"
            echo -e "${RED_BOLD}🌊 Index used: $PIP_INDEX_URL${RESET}"
            echo -e "${RED_BOLD}🌊 Set MACWAVE_PIP_INDEX to a reachable mirror and try again.${RESET}"
            exit 1
        fi
    fi
fi

# 生成入口启动器：把当前解释器路径烘进去，作为 venv 失效时的第二选择。
write_launcher() {
    local base_dir="$1"
    local recorded="$2"
    local target="$base_dir/lib/wave"
    local tmp

    if mw_dry_run; then
        mw_plan "🌊 Dry run: would write the launcher $target." \
            "🌊 试运行：将写入启动器 ${target}。"
        return 0
    fi

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

# `wave shellenv` 由 shell 直接回答，不启动 Python：这一行会被写进 ~/.zprofile，
# 每次开终端都要跑（走 Python 那条路实测 160ms，这里 2ms）。
# 输出必须与 lib/shellenv.py **逐字一致** —— scripts/shellenv_test.sh 会比对两份。
if [ "$#" -eq 1 ] && [ "$1" = "shellenv" ]; then
    printf 'case ":$PATH:" in\n  *":%s:"*) ;;\n  *) export PATH="%s:%s:%s${PATH:+:$PATH}" ;;\nesac\n' \
        "$root_dir/lib" "$root_dir/bin" "$root_dir/links" "$root_dir/lib"
    exit 0
fi

# 双语错误输出。启动器里没有 install.sh 的 mw_say/mw_say_err，所以自带一个最小实现：
# 之前 install.sh 生成的启动器直接调用 mw_say_err，一旦真的落到这个分支就是
# 「mw_say_err: command not found」，真正的错误信息反而看不见。
mw_say_err() {
    printf '%s\n' "$1" >&2
    printf '%s\n' "$2" >&2
}

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

mw_say_err "🌊 Error: no usable Python 3 interpreter was found." "🌊 错误：找不到可用的 Python 3 解释器。"
mw_say_err "🌊 Reinstall MacWave with lib/install.sh." "🌊 请用 lib/install.sh 重新安装 MacWave。"
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

write_launcher "$BASE_DIR" "$PYTHON_BIN"

# ==========================================
# 把所有权交还给用户（下载后再次确保）
# ==========================================

if [[ "$NEED_SUDO" == "true" ]]; then
    hand_over_system_install "$BASE_DIR"
fi

# ==========================================
# PATH：只给方法，不改用户的 shell 配置
# ==========================================
#
# 以前这里是直接把 PATH 行 append 进 rc 文件。改成「只打印、不动手」，理由：
#   - 卸载要把它摘掉，只能靠字符串匹配去猜，猜错就是删掉别人的行；
#   - 安装目录变了、版本升级了，用户文件里留的是旧路径，而安装器没法判断
#     那一行还是不是自己写的；
#   - Homebrew / MacPorts 都是「一行 eval 归用户自己管」，升级与卸载都不用碰
#     别人的文件。
#
# 推荐写 ~/.zprofile 而不是 ~/.zshrc：PATH 是**登录**级的东西。.zprofile 每个
# 登录 shell 跑一次（新开一个终端窗口就是一次），.zshrc 每个交互 shell 都跑
# 一次 —— 套一层 `zsh -l` 就会再 prepend 一遍，PATH 一路堆叠。而且 .zshrc 在
# 非交互 shell 里根本不读，所以只写 .zshrc 的 PATH 对 `ssh host cmd`、
# cron、部分编辑器/IDE 起的子进程是看不见的。
# bash 的对应文件是 ~/.bash_profile —— 注意**不是** ~/.bashrc：
# macOS 的 bash 登录 shell 从不读 .bashrc（旧版这里写的就是 .bashrc，等于没写）。

# 按**登录** shell 选择它真正会读的那个文件（macOS 终端默认起登录 shell）：
#
#   zsh             → ~/.zprofile
#   bash            → ~/.bash_profile
#   sh/dash/ksh     → ~/.profile
#   csh/tcsh        → ~/.login
#
# 这四条都在本机逐壳实测过（`<shell> -l -c true` 看它读了哪个文件）。
# csh 系绝不能落到 ~/.profile —— 它根本不读那个文件，写了等于没写。
SHELL_FAMILY=posix
case "${SHELL:-}" in
    *zsh*)  RC_FILE="$HOME/.zprofile" ;;
    *bash*) RC_FILE="$HOME/.bash_profile" ;;
    *csh*)
        # macOS 的 /bin/csh 其实是 tcsh，登录时读 ~/.tcshrc 再读 ~/.login
        RC_FILE="$HOME/.login"
        SHELL_FAMILY="csh"
        ;;
    *)      RC_FILE="$HOME/.profile" ;;
esac

# 旧版本写进 rc 的完整 PATH 行；现在只用于两件事：识别用户文件里是否已有旧写法，
# 以及回滚时把指向已删除目录的那一行摘掉。
PATH_LINE="export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\""

# 建议用户自己加进 rc 的那一行 —— 与 Homebrew 同形：
#
#   eval "$(/opt/homebrew/bin/brew shellenv)"
#
# 路径里没有空格时**不加内层引号**，与 Homebrew 逐字同形；含空格（自定义目录
# 允许空格）时才加，否则那一行会被拆成两条命令。
#
# 家目录写成 ~（安装到 $HOME/.local/macwave 时）。`$( )` 里是新的引号上下文，
# 所以 `eval "$(~/…/wave shellenv)"` 里的 ~ 会正常展开；写成 `"~/…"` 则不会。
#
# 去掉 4.3 之前的 `test -r ... &&` 守卫：代价是安装目录被删掉后每次登录报一次
# "no such file or directory"，Homebrew 一直如此，换来的是用户只需照抄一行。
#
# csh/tcsh 走另一条分支：它们没有 `$(...)`，也没有 POSIX 的 case…esac，
# `wave shellenv` 的输出它们吃不下（实测报 "Too many )'s"），所以给等价的
# csh 写法。守卫改成 `!~` 模式匹配，作用相同 —— 已在 csh 与 tcsh 上实测连跑
# 三次不堆叠。
#
# 这里的字符串会被用户原样复制，所以 ~ 后面含空格的片段要写成 ~/"a b"。
INSTALL_DIR_DISPLAY=$(home_to_tilde_arg "$INSTALL_DIR")
LINKS_DIR_DISPLAY=$(home_to_tilde_arg "$LINKS_DIR")
LIB_DIR_DISPLAY=$(home_to_tilde_arg "$LIB_DIR")
if [[ "$SHELL_FAMILY" == "csh" ]]; then
    # csh 的双引号里 ~ 不展开，而守卫模式又必须对展开后的 $PATH 生效，只能写 $HOME
    # （它在双引号内会展开）：输出里没有绝对家目录，只是用 $HOME 代替了 ~。
    SHELLENV_DISPLAY="if ( \"\$PATH\" !~ *\"$(home_to_homevar "$LIB_DIR")\"* ) setenv PATH \"$(home_to_homevar "$INSTALL_DIR"):$(home_to_homevar "$LINKS_DIR"):$(home_to_homevar "$LIB_DIR"):\$PATH\""
else
    SHELLENV_DISPLAY="eval \"\$($LIB_DIR_DISPLAY/wave shellenv)\""
fi

# 从 rc 文件里摘掉**旧版本**写进去的 PATH 行（连同标记行）。
# 现在安装不再写 rc，这个函数只剩两个用途：升级时清理旧写法、回滚时清掉
# 指向已删除目录的那一行。
#
# 标记行必须**整行相等**才算：旧实现用 `grep -F "# MacWave"` 做子串匹配，
# 会把用户自己的 `# MacWave mirror` 注释行一起删掉 —— 那是读者的配置，不是我们的。
remove_lw_path_entries() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    grep -qF -e "$PATH_LINE" -e "# MacWave" "$rc" 2>/dev/null || return 0
    grep -v -F -e "$PATH_LINE" "$rc" | grep -v -x -F -e "# MacWave" > "$rc.macwave.tmp" || true
    cat "$rc.macwave.tmp" > "$rc"
    rm -f "$rc.macwave.tmp"
    mw_say "🌊 Removed old MacWave PATH entries from $rc" "🌊 已从 $rc 移除旧版 MacWave 的 PATH 条目"
}

# 当前进程的 PATH 里是否已经有 MacWave。看运行环境而不是解析 rc 文件：
# rc 里的写法五花八门（手写 export、shellenv、别名），解析必然漏。
path_has_macwave() {
    case ":$PATH:" in
        *":$LIB_DIR:"*|*":$LINKS_DIR:"*) return 0 ;;
    esac
    return 1
}

# 用户自己的 shell 配置里是否还留着**旧版本**写进去的条目。
#
# 只认两行：整行等于 `# MacWave` 标记行，或整行等于旧写法的那条 export。
# 不能拿 `$LIB_DIR` 做子串匹配 —— 新的 `eval "$(... shellenv)"` 里也有这个路径，
# 那会把「已经迁移好的用户」误判成「还需要迁移」。
#
# 找到只用于**生成一条迁移命令**，安装器自己不动那个文件。
EXISTING_RC=""
for _rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile"; do
    [[ -f "$_rc" ]] || continue
    if grep -qxF -e "# MacWave" -e "$PATH_LINE" "$_rc" 2>/dev/null; then
        EXISTING_RC="$_rc"
        break
    fi
done

# ==========================================
# 许可协议确认
# ==========================================
# 必须放在「安装完成」之前：否则先告诉用户已经装好，随后又因为不同意而全部删除。

echo ""
mw_say "${YELLOW}Please read the agreement before use (see bottom of https://macwave.org).${RESET}" "${YELLOW}使用前请先阅读用户协议（见 https://macwave.org 页面底部）。${RESET}"
if mw_dry_run; then
    # 试运行不碰终端：否则 `install.sh --dry-run` 会停在协议提问上，
    # 只想看输出的人反而被卡住。真实安装仍然要求回答。
    agreement="y"
    mw_plan "🌊 Dry run: the agreement is not asked and nothing is recorded." \
        "🌊 试运行：不询问用户协议，也不记录任何同意。"
elif [[ "$CLI_CI" == "true" ]]; then
    mw_say "🌊 --ci: the agreement is accepted automatically." "🌊 --ci：自动接受用户协议。"
    agreement="y"
else
    mw_say "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}" "${YELLOW}你是否已阅读并同意该协议？[Y/n]${RESET}"
    read -r agreement < /dev/tty
fi
if [[ -z "$agreement" || "$agreement" =~ ^[Yy]$ ]]; then
    if ! mw_dry_run; then
        mw_say "${GREEN}You have agreed to the agreement.${RESET}" "${GREEN}已记录你的同意。${RESET}"
    fi
else
    # 回滚要连 rc 里的 PATH 一起清掉，否则会留下指向已删除目录的一行。
    # 这里不写死 sudo：用户级安装全程无需提权，回滚也不该突然要密码。
    mw_say "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}" "${RED_BOLD}你未同意该协议，安装已停止。${RESET}"
    mw_say "${RED_BOLD}🌊 Cleaning up downloaded files...${RESET}" "${RED_BOLD}🌊 正在清理已下载的文件……${RESET}"
    run_cmd rm -rf "$BASE_DIR"
    run_cmd rm -rf "$CONFIG_DIR"
    remove_lw_path_entries "$RC_FILE"
    mw_say "${RED_BOLD}🌊 All files have been deleted.${RESET}" "${RED_BOLD}🌊 所有文件已删除。${RESET}"
    exit 1
fi

# ==========================================
# 完成信息
# ==========================================

echo ""
if mw_dry_run; then
    mw_say "${GREEN}🌊 Dry run finished. Nothing was installed or changed.${RESET}" \
        "${GREEN}🌊 试运行结束。没有安装或修改任何内容。${RESET}"
    mw_say "🌊 MacWave would be installed to: $DISPLAY_DIR" "🌊 MacWave 将被安装到：$DISPLAY_DIR"
else
    mw_say "🌊 Installation complete!" "🌊 安装完成！"
    mw_say "🌊 MacWave installed to: $DISPLAY_DIR" "🌊 MacWave 已安装到：$DISPLAY_DIR"
fi
mw_say "🌊 Architecture: $ARCH" "🌊 架构：$ARCH"
echo ""
RC_DISPLAY=$(home_to_tilde_arg "$RC_FILE")
APPEND_CMD="echo '$SHELLENV_DISPLAY' >> $RC_DISPLAY"

# 有旧条目时，把「删旧」和「追加新行」拼成**一条**命令：用户复制一次就够。
#
# 删旧的判据与 remove_lw_path_entries 一致 —— 整行相等（-x -F），不是子串匹配；
# 旧实现用 `grep -F "# MacWave"` 做子串，会把用户自己写的 `# MacWave mirror`
# 注释一并删掉。
#
# 先写临时文件再 `cat >` 回写，而不是 `mv` 或 `sed -i`：~/.zshrc 常是指向
# dotfiles 仓库的符号链接，rename 会把它变成普通文件，链接就断了。
MIGRATE_CMD=""
if [[ -n "$EXISTING_RC" ]]; then
    EXISTING_DISPLAY=$(home_to_tilde_arg "$EXISTING_RC")
    # 这一条里的旧 PATH 行是 **grep 的匹配模式**，必须与 rc 文件里那行逐字相等，
    # 所以不能写 ~（引号内不展开），改用双引号包起来让 $HOME 自己展开。
    PATH_LINE_DISPLAY=$(printf 'export PATH=\\"%s:%s:%s:\\$PATH\\"' \
        "$(home_to_homevar "$INSTALL_DIR")" "$(home_to_homevar "$LINKS_DIR")" "$(home_to_homevar "$LIB_DIR")")
    MIGRATE_CMD="grep -vxF -e '# MacWave' -e \"$PATH_LINE_DISPLAY\" $EXISTING_DISPLAY > $EXISTING_DISPLAY.macwave && cat $EXISTING_DISPLAY.macwave > $EXISTING_DISPLAY && rm -f $EXISTING_DISPLAY.macwave && $APPEND_CMD"
fi

# ==========================================
# 下一步：PATH 由用户自己加
# ==========================================
# 安装器不写 rc 文件。这里只给一条命令，别的不说。

echo ""
mw_say "🌊 Run this once to add wave to your PATH:" \
    "🌊 执行下面这一行，把 wave 加进 PATH："
echo ""
if [[ -n "$MIGRATE_CMD" ]]; then
    # 一行做完两件事：删掉旧版写进去的两行，再追加新的 eval 行。
    echo -e "${YELLOW}    $MIGRATE_CMD${RESET}"
else
    echo -e "${YELLOW}    $APPEND_CMD${RESET}"
fi
echo ""

mw_say "🌊 If prompted 'Command not found', run the following command or open a new terminal window." \
    "🌊 如果提示“找不到命令”，执行下列命令或打开新的终端窗口。"
echo ""
# 必须 source **刚追加进去的那个文件**（${RC_FILE}），不是「碰巧存在的」那个：
# zsh 的行加在 ~/.zprofile，此时 source ~/.zshrc 并不会把它加载进来。
echo -e "${YELLOW}    source $RC_DISPLAY${RESET}"
echo ""

# 系统级安装是共享的：管理员用 sudo 管理，其他用户只能运行。
# PATH 那行现在由用户自己加 —— 别人不加就找不到 wave，只能靠绝对路径执行。
# 这里说清楚，否则「其他人可运行」只对了一半。
if [[ "$NEED_SUDO" == "true" ]]; then
    mw_say "🌊 Other users on this machine can run the installed packages," \
        "🌊 本机的其他用户可运行已装的软件包，"
    mw_say "🌊 but each of them needs to run this once:" \
        "🌊 但每个用户需要执行："
    echo -e "${YELLOW}    $SHELLENV_DISPLAY${RESET}"
    mw_say "🌊 Changing packages (install / uninstall / upgrade) needs sudo:" \
        "🌊 改动软件包（安装 / 卸载 / 升级）需要 sudo："
    echo -e "${YELLOW}    sudo wave install <package>${RESET}"
    echo ""
fi

if mw_dry_run; then
    mw_say "🌊 Drop --dry-run and run the installer again to install for real." \
        "🌊 去掉 --dry-run 再运行一次，才会真正安装。"
fi
