#!/bin/bash

# bash 3.2 (macOS)
# 本文件最近一次更新于：2026-11-19

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
# Unattended (CI): /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)" -- --ci --dir-option=1

# 退出码要有语义
# 0 = 成功
# 1 = 用法错误
# 2 = 环境不满足（如 bash 太旧）
# 3 = 网络/下载失败

set -eE
set -u
set -o pipefail

# ==========================================
# --raw：无 🌊、无颜色、井号进度条
# ==========================================
#
# 与 `wave install --raw` 同一条规则：输出可以直接进日志、进 grep、进 diff。
#
#   * 不带行首的 🌊
#   * 不带任何 ANSI 颜色（调色板在下面定义后立刻清空）
#   * 下载进度用井号刻度，而不是光标重绘出来的东西
#
# 为什么在文件描述符（stdout/stderr）这一层做、而不是改每个调用点：这个脚本有
# 180 多处 🌊 字符串，散在 echo、mw_say、mw_say_err 三种写法里，逐个改必然漏
# 一处 —— 而漏一处就是「--raw 的输出里还有 emoji」。把 1、2 号文件描述符接到
# 一个过滤器上，是唯一能保证「一律」的地方（与 cli/silent.py 里 raw_output()
# 的做法同一条理由）。
#
# 顺带说明：这里说的是**文件描述符**，不是 `fd` 这个命令 —— 安装器只用 bash 内建
# 与 curl / tar / sed 这类 macOS 自带工具，不需要用户预先装任何东西。
#
# **装在第一条输出之前**：参数解析本身不打字，解析完立刻装过滤器，之后的测试根
# 提示、横幅、错误提示就都在过滤范围内。之前这里要先扫一遍参数才能做到「一律」，
# 那正是「版本号请求夹在解析中间」逼出来的结构 —— 现在解析在前、取版本在后，
# 一遍扫描就够。
# 注意：这里**只定义**过滤器，不安装它。参数还没解析，此刻还不知道有没有 --raw；
# 真正把它接到 1、2 号文件描述符上，是在参数解析之后（见“装上 --raw 的过滤器”）。
CLI_RAW=false

mw_raw() { [[ "${CLI_RAW:-false}" == "true" ]]; }

mw_raw_filter() {
    # 逐行读 stdin，去掉行首的 🌊 与紧跟的一个空格。
    # 🌊 用 printf 的字节写：$'\U0001F30A' 这种写法 bash 3.2 不支持。
    local line item
    item="$(printf '\xf0\x9f\x8c\x8a')"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$item "*) line="${line#"$item "}" ;;
            "$item"*) line="${line#"$item"}" ;;
        esac
        printf '%s\n' "$line"
    done
}


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

mw_mktemp() {
    # mw_mktemp <名字前缀>：可移植的临时文件。
    #
    # macOS 的 `mktemp -t 前缀` 会自动补随机后缀，GNU mktemp 则要求模板里
    # **至少三个 X** —— 同一句 `mktemp -t foo` 在 Linux 上直接报
    # "too few X's in template"。统一写成「完整路径 + 六个 X」，两边都认。
    mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}

mw_say() {
    # mw_say "<English>" "<中文>"
    #
    # 只给一句时两种语言都用它（`${2-$1}`）—— 空行、纯符号行、以及中英同文的
    # 命令行都属于这种。注意是 `-` 不是 `:-`：显式传了空串（英文有下半句、中文
    # 已经说完了）必须打空行，不能回退到英文。
    # 不给默认值时，`set -u` 下中文模式会以 "$2: unbound variable" 崩掉 —— 而那只
    # 发生在 --zh，属于「本地英文一切正常、用户用中文就炸」的典型。
    if [[ "$MW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}"
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
SELFUPDATE_URL="$(mw_domain MACWAVE_SELFUPDATE_DOMAIN "${MACWAVE_SELFUPDATE_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/HEAD}")"
# 自带 CPython 的清单
# 解释器单独一个仓库（体积与发布节奏都和自更新数据不同）
PYTHON_DOMAIN_URL="$(mw_domain MACWAVE_PYTHON_DOMAIN "${MACWAVE_PYTHON_DOMAIN:-https://raw.githubusercontent.com/MacWaveOrg/Python/HEAD}")"

# ==========================================
# 额外根证书（MACWAVE_CACERT）
# ==========================================
#
# 企业网络里 TLS 会被中间设备重签，自建镜像也可能用私有 CA。把根证书交给我们就
# 够了，不必让人为了连上而关掉校验（本脚本没有 --skip-ssl）。
#
# 设了就必须可用：静默忽略的后果是用户以为自己已经信任了那家 CA，实际还在失败，
# 于是他会去怀疑镜像、怀疑网络，唯独不会想到是路径写错了。
#
# 用 ${CURL_CACERT:+--cacert "$CURL_CACERT"} 展开，而不是把它拼进一段无引号的
# 参数串 —— 路径里带空格是常事（"~/Library/Application Support/..."）。
CURL_CACERT=""
if [[ -n "${MACWAVE_CACERT:-}" ]]; then
    _cacert="${MACWAVE_CACERT/#\~/$HOME}"
    if [[ ! -f "$_cacert" || ! -r "$_cacert" ]]; then
        echo -e "${RED_BOLD}🌊 Error: MACWAVE_CACERT is not a readable file: ${_cacert}${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Next      point it at the CA's root certificate in PEM form, e.g. export MACWAVE_CACERT=/etc/ssl/corp-root.pem${RESET}" >&2
        echo -e "${RED_BOLD}🌊           unset it to go back to the system trust store${RESET}" >&2
        exit 1
    fi
    CURL_CACERT="$_cacert"
fi


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
# 下载（--raw 时带井号刻度）
# ==========================================

mw_download() {
    # mw_download <url> <out> <max-time>
    #
    # 非 --raw 时就是原来那句 `curl -fsSL … -o <out>` —— 行为、返回值完全不变。
    # --raw 时多打一行井号刻度：**总长已知就每 10% 一个 #**（与 Python 侧
    # _RawProgress 同一条规则），未知就每 MiB 一个。不换行重绘、不带颜色，
    # 所以落进日志是一行完整的进度，而不是一串控制字符。
    local url="$1" out="$2" cap="$3" total pid rc=0 size shown=0 step
    if ! mw_raw; then
        curl -fsSL --max-time "$cap" ${CURL_CACERT:+--cacert "$CURL_CACERT"} -o "$out" "$url"
        return $?
    fi

    # 先问一次长度。HEAD 失败不算错：拿不到就按 MiB 打刻度。
    total="$(curl -fsSI --max-time "$cap" ${CURL_CACERT:+--cacert "$CURL_CACERT"} "$url" 2>/dev/null \
        | tr -d '\r' | tr 'A-Z' 'a-z' | awk -F': *' '$1=="content-length"{print $2}' | tail -n 1)"
    case "$total" in
        ''|*[!0-9]*) total=0 ;;
    esac
    if (( total > 0 )); then
        step=$(( total / 10 ))
        (( step > 0 )) || step=1
    else
        step=1048576
    fi

    rm -f "$out" 2>/dev/null || true
    curl -fsSL --max-time "$cap" ${CURL_CACERT:+--cacert "$CURL_CACERT"} -o "$out" "$url" & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        size=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
        size=${size:-0}
        while (( (shown + 1) * step <= size )); do
            printf '#'
            shown=$(( shown + 1 ))
        done
        sleep 0.2
    done
    wait "$pid" || rc=$?

    if (( rc == 0 )); then
        # 小文件可能一格都没打；补满十个 #，让每一行下载都是同一个形状
        while (( shown < 10 )); do
            printf '#'
            shown=$(( shown + 1 ))
        done
        printf '  %s\n' "$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
    else
        printf '\n'
    fi
    return $rc
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
# --skip-probe：不真写那个探针文件，提权判定只用 test -w 的静态结论。
# 见「是否需要 sudo」那一节里 mw_can_write 的说明。
CLI_SKIP_PROBE=false
# --help：打用法后**停**在这里；--print-usage：打用法后继续安装（或继续试运行）。
CLI_HELP=false
CLI_PRINT_USAGE=false
# 默认从我们自己的 Python 仓库取解释器；这个开关让它回上游取
INSTALL_PYTHON_FROM_SOURCE=""

usage() {
    # 用法一律走 mw_say —— 语言由它挑（--zh），呈现规则与其它输出一致：
    # --raw 时调色板已清空、🌊 也会被输出过滤器剥掉，所以这里不必再判断一次。
    #
    # 每一项是**一段**（段内用 \n 分行），而不是一行一次调用：中英两种语言的
    # 折行位置本来就不同，逐行成对会逼着一边凑行数，凑出来的空行在中文里就是
    # 多出来的空白。按段落给，各自折各自的。
    mw_say "MacWave installer" "MacWave 安装程序"
    mw_say ""
    mw_say "Usage:" "用法："
    mw_say "  install.sh [options]" "  install.sh [选项]"
    mw_say ""
    mw_say "Options:" "选项："
    mw_say "      --ci, --CI          No interaction at all: the directory menu and the\n\
                          agreement are answered automatically. Without\n\
                          --dir-option the default (option 1) is used.\n\
                          Requires passwordless sudo when privilege is needed." \
           "      --ci, --CI          完全不交互：目录菜单与用户协议都自动应答。不带\n\
                          --dir-option 时使用默认项（第 1 项）。\n\
                          需要提权时要求 sudo 免密。"
    mw_say "      --dry-run           Print what the installer would do and change\n\
                          nothing: no download, no sudo, no directory\n\
                          created, no file written. When the latest version\n\
                          cannot be fetched it continues with a placeholder,\n\
                          so the output can be reviewed offline." \
           "      --dry-run           只打印安装器会做什么，不做任何改动：不下载、不提权、\n\
                          不建目录、不写文件。取不到最新版本号时用占位值继续，\n\
                          因此在断网的机器上也能看完整个输出。"
    mw_say "      --raw               Plain output for logs and scripts: no emoji, no\n\
                          colours, ASCII progress bars. Interaction is\n\
                          unchanged; combine with --ci for unattended runs." \
           "      --raw               给日志和脚本用的输出：不带 🌊、不带颜色、进度条用\n\
                          井号刻度。交互不变；无人值守请再配 --ci。"
    mw_say "      --skip-probe        Do not create the temporary probe file used to decide\n\
                          whether privilege is needed; rely on the permission\n\
                          bits alone. Use it when the target must stay\n\
                          untouched -- a wrong guess only moves the failure to\n\
                          the first real write." \
           "      --skip-probe        判定是否需要提权时不在目标里建那个临时探针文件，只用\n\
                          权限位判断。适合「目标必须一点痕迹都不留」的场合 ——\n\
                          判断错了只是把失败推迟到第一次真正写入。"
    mw_say "      --dir-option=N      Pick menu entry N without prompting (1-$CUSTOM_OPTION)." \
           "      --dir-option=N      不提问，直接选菜单第 N 项（1-${CUSTOM_OPTION}）。"
    mw_say "      --dir-option=DIR    Use DIR as the installation directory (shorthand for\n\
                          --dir-option=$CUSTOM_OPTION=DIR)." \
           "      --dir-option=DIR    用 DIR 作为安装目录（等价于\n\
                          --dir-option=$CUSTOM_OPTION=DIR）。"
    mw_say "      --dir-option=N=DIR  Pick entry N and, for the custom entry ($CUSTOM_OPTION), use DIR\n\
                          as the installation directory." \
           "      --dir-option=N=DIR  选第 N 项，并在自定义项（${CUSTOM_OPTION}）时用 DIR\n\
                          作为安装目录。"
    mw_say "        --install-python-from-source\n\
                            Download the bundled CPython from its upstream URL\n\
                            (recorded in pythondata/<version>/python_url.toml)\n\
                            instead of from MacWave's own Python repository." \
           "        --install-python-from-source\n\
                            自带 CPython 改从上游 URL 下载（记录在\n\
                            pythondata/<version>/python_url.toml），\n\
                            而不是从 MacWave 自己的 Python 仓库取。"
    mw_say "        --no-noise          Also check that mw_say has not been hijacked by\n\
                            /usr/bin/say (the macOS spoken-text command).\n\
                            Off by default; --NO-NOISE and --No-Noise work too." \
           "        --no-noise          额外检查 mw_say 有没有被 /usr/bin/say（macOS 的朗读\n\
                            命令）劫持。默认不查；--NO-NOISE、--No-Noise 也认。"
    mw_say "      --zh                Print in Chinese (English by default)." \
           "      --zh                用中文输出（默认英文）。"
    mw_say "  -h, --help              Show this help and stop. May only be combined with\n\
                          --dry-run (print the usage, then walk the install)." \
           "  -h, --help              显示本帮助后停止。只能单独用，或与 --dry-run 连用\n\
                          （先打用法，再走一遍流程）。"
    mw_say "      --print-usage       Show this help, then continue (install or dry run)." \
           "      --print-usage       显示本帮助后继续（真的安装，或继续试运行）。"
    mw_say ""
    mw_say "Directory menu:" "目录菜单："
    # 菜单自己按语言输出、也不带 🌊 与颜色；这里只补缩进。
    print_dir_menu | sed 's/^/  /'
    mw_say ""
    mw_say "Examples:" "示例："
    mw_say "  install.sh --ci --dir-option=1" "  install.sh --ci --dir-option=1"
    mw_say "  install.sh --CI --dir-option=2" "  install.sh --CI --dir-option=2"
    mw_say "  install.sh --ci --dir-option=$CUSTOM_OPTION=/opt/my-macwave" \
           "  install.sh --ci --dir-option=$CUSTOM_OPTION=/opt/my-macwave"
    mw_say "  install.sh --ci --dir-option=/opt/my-macwave" \
           "  install.sh --ci --dir-option=/opt/my-macwave"
    mw_say ""
    mw_say "Running it straight from the repository (options go after '--'):" \
           "直接从仓库运行（选项放在 '--' 之后）："
    mw_say '  /bin/bash -c "$(curl -fsSL <url>)" -- --ci --dir-option=1' \
           '  /bin/bash -c "$(curl -fsSL <url>)" -- --ci --dir-option=1'
}

# 参数在这里**一次**解析完。以前要扫两遍：一遍为了让 --raw 赶在第一条输出之前
# 生效，一遍为了让 --zh/--dry-run 赶在「读版本号」之前生效 —— 那是因为取版本号的
# 网络请求被放在了解析之前。现在取版本在后面，扫一遍就够。
#
# 留一份原始参数：下面的 while 会一路 shift 把 "$@" 掏空，而 --help 的连用规则
# 要在解析之后回头检查「用户到底还给了什么」。
CLI_ARGV=("$@")
PARSE_ERROR_OPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci|--CI)
            CLI_CI=true
            ;;
        --dry-run|--DRY-RUN)
            CLI_DRY_RUN=true
            ;;
        --raw|--RAW)
            CLI_RAW=true
            ;;
        --skip-probe|--SKIP-PROBE)
            CLI_SKIP_PROBE=true
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
            CLI_HELP=true
            ;;
        --print-usage|--PRINT-USAGE)
            CLI_PRINT_USAGE=true
            ;;
        *)
            # 不在这里打印：此刻还没有装上 --raw 的过滤器、也没定语言。
            # 记下来，等输出环境就绪再报（见下面「报告解析错误」）。
            PARSE_ERROR_OPT="$1"
            break
            ;;
    esac
    shift
done

# ==========================================
# 装上 --raw 的过滤器，并确定语言
# ==========================================
#
# 到这里参数已经解析完：--raw / --zh 都有结论了，而**还没有输出过任何东西**。
# 所以过滤器只需要装一次、也只需要扫一遍参数 —— 解析在前、取版本在后，正是为此。
#
# 但解析可能在第一处未知选项就停下（那时 --raw 还没被读到）。所以这里从**原始
# 参数**再认一次呈现类旗标，保证「未知选项 + --raw」报出来的错也是干净的。
_PRESENTATION_APPLIED=false
mw_apply_presentation() {
    [[ "$_PRESENTATION_APPLIED" == "true" ]] && return 0
    local arg
    for arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
        case "$arg" in
            --raw|--RAW) CLI_RAW=true ;;
            --zh|--ZH) MW_LANG="zh" ;;
        esac
    done
    if mw_raw; then
        RED_BOLD=""; RED=""; GREEN=""; YELLOW=""; SKY_BLUE=""; RESET=""
        exec > >(mw_raw_filter) 2>&1
    fi
    _PRESENTATION_APPLIED=true
}
mw_apply_presentation

# 参数没认出来：现在才报（语言与 --raw 都已就绪）。
if [[ -n "$PARSE_ERROR_OPT" ]]; then
    mw_say_err "${RED_BOLD}🌊 Error: unknown option '$PARSE_ERROR_OPT'. Try --help.${RESET}" \
        "${RED_BOLD}🌊 错误：未知选项 '$PARSE_ERROR_OPT'。可试 --help。${RESET}"
    exit 1
fi

# ==========================================
# --help 的连用规则
# ==========================================
#
# --help 只回答「怎么用」，不安装。所以它只允许两种出现方式：
#
#   install.sh --help                 打用法，停
#   install.sh --help --dry-run       打用法，然后照 --dry-run 走一遍流程（不安装）
#
# 与其它安装参数连用一律报错：`--help --ci --dir-option=2` 读起来像是「按这些
# 参数装」，实际却只打帮助 —— 把它拦下来，比让用户以为装过了强。
# --zh / --raw 例外：它们只改呈现（语言、输出格式），不是安装参数。
#
# --print-usage 才是「打用法然后继续安装」的那个开关。
if [[ "$CLI_HELP" == "true" ]]; then
    _bad=""
    for _arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
        case "$_arg" in
            -h|--help|--dry-run|--DRY-RUN|--zh|--ZH|--raw|--RAW) ;;
            *) _bad="$_arg"; break ;;
        esac
    done
    if [[ -n "$_bad" ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: --help cannot be combined with '$_bad'.${RESET}" \
            "${RED_BOLD}🌊 错误：--help 不能和 '$_bad' 连用。${RESET}"
        mw_say_err "🌊 --help only prints the usage and stops. Two ways to go further:" \
            "🌊 --help 只打用法、不安装。想再往下走有两条路："
        mw_say_err "🌊   install.sh --help --dry-run    print the usage, then walk the install" \
            "🌊   install.sh --help --dry-run    先打用法，再走一遍流程（不安装）"
        mw_say_err "🌊   install.sh --print-usage       print the usage, then install for real" \
            "🌊   install.sh --print-usage       先打用法，再真的安装"
        exit 1
    fi
fi

if [[ "$CLI_PRINT_USAGE" == "true" ]]; then
    usage
fi

if [[ "$CLI_HELP" == "true" ]]; then
    usage
    # 与 --dry-run 连用时继续往下走；单独出现时到此为止。
    [[ "$CLI_DRY_RUN" == "true" ]] || exit 0
fi

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

# -------------------- 平台守卫：MacWave 只装 macOS 软件 --------------------
#
# 再往下就会撞上 macOS 专属的东西：目录菜单里的 /usr/local、SIP 与系统卷密封的
# 判定、csrutil、Xcode 命令行工具检查。与其装到一半报「csrutil: command not
# found」，不如第一句就说清楚该去哪 —— Linux 由兄弟项目 LinuxWave 覆盖，两边的
# 安装命令是同一个形状（releases/latest/download/install.sh）。
#
# 平台判断分两层：
#
#   1. uname -s —— Darwin / Linux / 其它（FreeBSD、MSYS 之类）；
#   2. Darwin 之上再分 macOS 与 iOS：iOS 也报 Darwin，光看内核分不出来。这里只认
#      **不可伪造**的三条线索 —— 内核给的 `hw.model` 前缀（Mac* / iPhone* / iPad*），
#      `sw_vers -productName`，以及密封卷上 SystemVersion.plist 里的 ProductName。
#
# **不看越狱痕迹**（/var/jb、/private/var/mobile 之类），两条理由都成立才做得下去：
#   · RootHide 那类反检测工具的工作方式就是把痕迹藏起来/重定向，认它等于留一个
#     一按就过的后门；
#   · 老式**有根**越狱（checkra1n / unc0ver）压根没有 /var/jb，认它又会漏判。
# 换成内核与密封卷上的信息，rootful / rootless 一视同仁，也绕不过去。
#
# 为什么值得为 iPhone 单独写一段：本项目的作者有个朋友真的这么干过 —— 在越狱的
# iPhone 上跑了这个安装脚本，一路装到 /var/jb/macwave，看起来像成功了；随后每条
# wave 命令都死在 macOS 有、iOS 没有的东西上（csrutil、Xcode 的命令行工具、
# /usr/local），排查了半天才发现「这个包管理器本来就不该在这台设备上」。
# 所以认出 iOS 时不但要拒绝，还要把话说得让人不必再试第二次。
#
# MACWAVE_TEST 下不判：那是在「把某个目录当作 /」的沙箱里跑同一份脚本，宿主是
# Linux 完全正常（CircleCI 的 Linux 容器就是这么跑的）。
mw_platform() {
    # macos / ios / linux / android / chromeos / unknown
    local kernel sysctl_bin sw_vers_bin product model machine version_plist chromeos_release jb_root
    chromeos_release="${MACWAVE_CHROMEOS_RELEASE:-/etc/lsb-release}"
    kernel="$(uname -s 2>/dev/null || true)"
    case "$kernel" in
        Darwin)
            # 认 macOS 与 iOS 只看**不可伪造**的信息，不看越狱痕迹：
            #
            #   · hw.model 由内核给出 —— Mac 是 MacBookPro18,3 这种，iOS 是
            #     iPhone15,3 / iPad13,4 这种，两类前缀不重叠；
            #   · sw_vers -productName 与 SystemVersion.plist 内的 ProductName
            #     都在密封系统卷（SSV）上，写不进去。
            #
            # 为什么不用 /var/jb、/private/var/mobile 这些：RootHide 那类反检测
            # 工具的工作方式就是把越狱痕迹藏起来 / 重定向，认它等于给自己留一个
            # 一按就过的后门；而且老式**有根**越狱（checkra1n / unc0ver）根本
            # 没有 /var/jb，认它又会漏判。两代越狱在这三条线索面前是一样的。
            sysctl_bin="${MACWAVE_SYSCTL:-/usr/sbin/sysctl}"
            model="$("$sysctl_bin" -n hw.model 2>/dev/null || true)"
            case "$model" in
                iPhone*|iPad*|iPod*) echo ios; return 0 ;;
                Mac*) echo macos; return 0 ;;
            esac
            # hw.machine 只当补充线索：macOS 与 iOS 的 shell 都可能把它报成 arm64
            # （本机 macOS 就是 arm64），所以 arm64 / x86_64 **不能**用来证明是 Mac，
            # 否则等于把 iOS 全放行；反过来，它若报出 iPhone*/iPad* 就是 iOS 的直接
            # 证据，可以立刻结束。
            machine="$("$sysctl_bin" -n hw.machine 2>/dev/null || true)"
            case "$machine" in
                iPhone*|iPad*|iPod*) echo ios; return 0 ;;
            esac
            # 快速命中：rootless 越狱的根前缀。放在 hw.model 之后是有意的 —— 真 Mac
            # 上 hw.model 一定答 Mac*，所以有人故意在 macOS 建一个 /var/jb 也绝不会
            # 让它被误判；反过来，sysctl 被挡、sw_vers 被删的极端情况下，这条能让
            # 判定提前结束，不必再往下试。
            #
            # 只当线索、不当证据，两个理由：
            #   · 一台 Mac 上也可能有人自己 mkdir 一个 /var/jb（就想看看会怎样），
            #     所以还要求它长得像一棵越狱根（有 usr/ 或 Library/）才算数；
            #   · 'jb' 本身没有权威含义，别的工具占了这个名字也不该影响判断 ——
            #     因此它只用来**提前结束**，绝不用来单独下结论。
            jb_root="${MACWAVE_JB_ROOT:-/var/jb}"
            if [[ -d "$jb_root" ]] && { [[ -e "$jb_root/usr" ]] || [[ -e "$jb_root/Library" ]]; }; then
                echo ios
                return 0
            fi
            sw_vers_bin="${MACWAVE_SW_VERS:-/usr/bin/sw_vers}"
            product="$("$sw_vers_bin" -productName 2>/dev/null || true)"
            case "$product" in
                *iOS*|*iPhone*|*iPad*) echo ios; return 0 ;;
                *macOS*|*Mac*) echo macos; return 0 ;;
            esac
            version_plist="${MACWAVE_SYSTEM_VERSION_PLIST:-/System/Library/CoreServices/SystemVersion.plist}"
            if [[ -r "$version_plist" ]] && grep -q "iPhone OS\|<string>iOS" "$version_plist" 2>/dev/null; then
                echo ios
                return 0
            fi
            # 三条线索都给不出结论时按 macOS 处理：误拦一台真的 Mac 比漏判更糟，
            # 而漏判的代价只是这人之后会撞上一串「iOS 没有这东西」的报错。
            echo macos
            ;;
        Linux)
            # Linux 内核之上还要分三种：Android（bionic、没有 /usr/local、没有
            # 桌面发行版那套）、ChromeOS（Crostini 容器确实是 Linux）、以及普通
            # 桌面 Linux。判据都只读环境与现成的文件，不装任何新工具。
            #
            # 大胆想象一下：iOS 那位朋友总有一天也会在 ChromeOS 或 Android 上试一遍。
            # 先防他一手 —— 这两种都能跑 bash，看起来「有终端就能装」，而 Android 上
            # 连 glibc 都没有，ChromeOS 的终端只是个容器。早点把话说清楚，我省一次
            # 排查，他省一次白装。
            #
            # ANDROID_ROOT / ANDROID_DATA 由 Android 的 init 设，Termux 与 adb
            # shell 里都有；getprop 是 Android 独有的系统命令。
            if [[ -n "${ANDROID_ROOT:-}${ANDROID_DATA:-}" ]] \
               || [[ -d /system/app && -d /data/data ]] \
               || command -v getprop >/dev/null 2>&1; then
                echo android
            # ChromeOS 的容器里 /etc/lsb-release 带一串 CHROMEOS_* 变量；
            # crossystem 是 Chromebook 上的固件查询命令。
            elif [[ -r "$chromeos_release" ]] && grep -q "CHROMEOS" "$chromeos_release" 2>/dev/null; then
                echo chromeos
            elif command -v crossystem >/dev/null 2>&1; then
                echo chromeos
            else
                echo linux
            fi
            ;;
        *) echo unknown ;;
    esac
}

mw_require_macos() {
    local platform linuxwave_cmd
    # 指路用的命令只写一份。超时也一起带上：这条是打印给用户抄去执行的，
    # 没有超时就会一直挂着 —— 与 lib/selfupdate.py 里那条重装命令同一个理由，
    # net_policy_test 也是逐条检查 curl 的。
    linuxwave_cmd='🌊   /bin/bash -c "$(curl -fsSL --max-time 60 https://github.com/LinuxWaveOrg/LinuxWave/releases/latest/download/install.sh)"'
    if [[ -n "${MACWAVE_TEST:-}" ]]; then
        return 0
    fi
    platform="$(mw_platform)"
    if [[ "$platform" == "macos" ]]; then
        return 0
    fi

    case "$platform" in
        ios)
            # 全部英文：越狱设备的终端 locale 不可预期。
            mw_say "🌊 An iPhone or iPad — jailbroken, and running a macOS package manager on it."
            mw_say "🌊 That has been tried before: the install went through to /var/jb/macwave and looked fine,"
            mw_say "🌊 then every 'wave' command died on things iOS does not have — csrutil, Xcode's"
            mw_say "🌊 command line tools, /usr/local. Nothing here is a step towards a working install."
            mw_say "🌊 MacWave targets macOS only. Nothing was changed on this device."
            mw_say "🌊 Set MACWAVE_TEST=<dir> only if you meant to run this in a sandbox."
            exit 2
            ;;
        android)
            # 手机终端里的 locale 不可预期，这段也全部英文。
            mw_say "🌊 Android. That shell is Linux, but a different Linux: bionic libc, no /usr/local,"
            mw_say "🌊 no Xcode tooling, and nothing MacWave would look for."
            mw_say "🌊 MacWave targets macOS; LinuxWave targets desktop Linux. Neither installs here."
            mw_say "🌊 Nothing was changed on this device."
            exit 2
            ;;
        chromeos)
            mw_say "🌊 ChromeOS — the terminal here is a Linux container, but not a desktop Linux." \
                   "🌊 ChromeOS —— 这里的终端是个 Linux 容器，但不是桌面 Linux。"
            mw_say "🌊 MacWave is macOS-only. For Linux (this container included), use LinuxWave:" \
                   "🌊 MacWave 只装 macOS 软件。Linux（包括这个容器）请用 LinuxWave："
            mw_say "🌊   https://linuxwave.org"
            mw_say "$linuxwave_cmd"
            exit 2
            ;;
        linux)
            mw_say "🌊 MacWave installs macOS software; this machine is Linux." \
                   "🌊 MacWave 装的是 macOS 软件 —— 这台机器是 Linux。"
            mw_say "🌊 For Linux, use LinuxWave: https://linuxwave.org" \
                   "🌊 Linux 请改用 LinuxWave：https://linuxwave.org"
            mw_say "$linuxwave_cmd"
            ;;
        *)
            mw_say "🌊 MacWave installs macOS software; this platform was not recognised." \
                   "🌊 MacWave 装的是 macOS 软件 —— 认不出这个平台。"
            mw_say "🌊 uname -s says: $(uname -s 2>/dev/null || echo unknown)" \
                   "🌊 uname -s 报的是：$(uname -s 2>/dev/null || echo unknown)"
            mw_say "🌊 On Linux use LinuxWave: https://linuxwave.org" \
                   "🌊 在 Linux 上用 LinuxWave：https://linuxwave.org"
            mw_say "$linuxwave_cmd"
            ;;
    esac
    mw_say "🌊 Nothing was changed on this machine; this is an environment mismatch, not a half-install." \
           "🌊 这台机器上什么都没改 —— 这是环境不对，不是装了一半。"
    mw_say "🌊 Set MACWAVE_TEST=<dir> if you meant to run this in a sandbox." \
           "🌊 如果是想在沙箱里跑，设置 MACWAVE_TEST=<目录>。"
    # 2 = 环境不满足，见文件头的退出码说明
    exit 2
}

mw_require_macos

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
    # 幂等：config/configpaths.py 也会把 HOME 搬进测试根。从 wave.py 一路调用下来时
    # HOME 已经被改过一次，这里再套一层就会变成 "<根><根>/Users/<你>"，配置目录于是
    # 永远找不到。两边都取物理路径再比较，才不会被 /var 与 /private/var 骗过去。
    _mw_home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || _mw_home_real="$HOME"
    case "$_mw_home_real" in
        "$SYS_ROOT"|"$SYS_ROOT"/*) ;;
        *) export HOME="$SYS_ROOT${HOME}" ;;
    esac
    mkdir -p "$HOME"
    # 用 mw_say：现在它已经定义好了（参数解析更早），并行输出也走同一个闸门。
    # 这行带 🌊，--raw 时会被过滤器剥掉。
    mw_say "🌊 Test root: $SYS_ROOT" "🌊 测试根：$SYS_ROOT"
fi

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
LATEST_VERSION_DATA="$(curl -fsSL --max-time 30 ${CURL_CACERT:+--cacert "$CURL_CACERT"} "$LATEST_DATA_URL" 2>/dev/null || true)"

read_toml_string() {
    # read_toml_string <文本> <键> —— 取平铺的字符串值，去掉引号与行尾注释
    printf '%s\n' "$1" \
        | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

# pre-release 的安装口：调用方可以用环境变量显式指定要装的版本与分支，
# 覆盖上面从 configdata 读到的「最新正式版」。
#
# 为什么必须留这个口子：configdata 是 `wave selfupdate` 的唯一依据，beta 绝不能
# 写进去 —— 一旦写进去，所有人的常规更新都会跳上 beta。所以「装 beta」只能由
# 调用方显式指定，而这正是 beta Release 正文里那条命令做的事。
#
# 指向 releases/latest 的安装命令**不带**这两个变量，所以走那条路的人永远得到正式版。
# 两个必须同时给：只给版本不给分支，会去取一条不含该版本文件的代码线。
#
# 名字被收成局部变量是必要的 —— 下面那两行赋值会直接覆盖同名环境变量。
ENV_VERSION="${MACWAVE_VERSION:-}"
ENV_BRANCH="${MACWAVE_BRANCH:-}"

MACWAVE_VERSION="$(read_toml_string "$LATEST_VERSION_DATA" version)"
LATEST_BRANCH="$(read_toml_string "$LATEST_VERSION_DATA" branch)"

if [[ -n "$ENV_VERSION" && -n "$ENV_BRANCH" ]]; then
    # 版本号会进 URL 与 JSON，只接受安全的字符 —— 不给「拼个奇怪的值让后面的
    # 拼接变成别的东西」留余地。分支名同理由 git 的规则限制（不能有空格等）。
    if [[ ! "$ENV_VERSION" =~ ^[A-Za-z0-9._-]+$ || ! "$ENV_BRANCH" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo -e "${RED_BOLD}🌊 Error: refusing to install '$ENV_VERSION' from branch '$ENV_BRANCH'.${RESET}" >&2
        echo -e "${YELLOW}🌊 Version and branch may only contain letters, digits, dot, dash and underscore.${RESET}" >&2
        exit 1
    fi
    MACWAVE_VERSION="$ENV_VERSION"
    LATEST_BRANCH="$ENV_BRANCH"
    mw_say "${YELLOW}🌊 Installing $MACWAVE_VERSION from branch $LATEST_BRANCH (explicitly requested, not the latest stable release)." \
        "${YELLOW}🌊 将安装 ${MACWAVE_VERSION}（分支 ${LATEST_BRANCH}）—— 这是显式指定的版本，不是最新正式版。"
fi

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
# 显示欢迎信息
# ==========================================
# WAVE 艺术字。与语言无关，两种语言都打 —— 它只是装饰，不值得为它写两份。
#
# --raw 时整段跳过：那是给日志和 grep 看的输出，六行全是块字符，只会把真正的
# 内容顶出屏幕、把日志撑满。装饰不参与「装得成不成」这件事，去掉它不影响任何断言。
if ! mw_raw; then
    echo ""
    echo -e "${SKY_BLUE}██╗    ██╗ █████╗ ██╗   ██╗███████╗${RESET}"
    echo -e "${SKY_BLUE}██║    ██║██╔══██╗██║   ██║██╔════╝${RESET}"
    echo -e "${SKY_BLUE}██║ █╗ ██║███████║██║   ██║█████╗  ${RESET}"
    echo -e "${SKY_BLUE}██║███╗██║██╔══██║╚██╗ ██╔╝██╔══╝  ${RESET}"
    echo -e "${SKY_BLUE}╚███╔███╔╝██║  ██║ ╚████╔╝ ███████╗${RESET}"
    echo -e "${SKY_BLUE} ╚══╝╚══╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝${RESET}"
    echo ""
fi
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
# SIP（系统完整性保护）
# ==========================================
#
# 提权之前先看 SIP：它决定「sudo 到底能不能写这里」，而「要不要 sudo」是下一问。
# 顺序反了会把用户送去输密码，然后在写文件时才失败 —— 报错还只是 permission denied。
#
# 光看 `csrutil status` 不够，它只回答「SIP 主开关」：
#
#   enabled                        正常 macOS
#   disabled                       SIP 完全关闭
#   enabled (Custom Configuration) SIP 被降级（自定义配置，部分保护关掉）
#
# 后两种多见于 **OCLP（OpenCore Legacy Patcher）** 打过补丁的老 Mac：为了让新系统
# 在旧硬件上能跑，OCLP 会关闭或削弱 SIP。**但「SIP 关了」不等于「系统盘能写」** ——
# macOS 11 起系统卷是密封的（Signed System Volume/SSV），它是另一道独立的锁：
# 即使 `csrutil disable`，往 /System、/usr、/bin 写文件照样失败，还必须
# `csrutil authenticated-root disable` 再重启（OCLP 打根补丁正是两步都做）。
#
# 所以判定分两层，顺序不能反：
#
#   1. 目标在不在 SIP 保护范围（/System、/usr（/usr/local 除外）、/bin、/sbin、
#      /Library/Apple）；
#   2. 在范围内时，**先看 SSV**：密封着就写不进去，与 SIP 主开关无关；
#      SSV 未密封（老系统没有这个命令）再看 SIP 主开关：
#        enabled  → 同样写不进去，拒绝；
#        disabled / reduced → 这次写入可行，警告后继续 —— 但「写得进去」不等于
#        「应该装进去」：写进系统位置的东西会随一次系统更新消失，也可能直接把
#        机器弄到起不来。这里只警告，不替用户拿主意。
#
# 非 macOS、或读不到 csrutil 时状态是 unknown，此时**不做**判断：不能因为
# 「读不到」就拒绝安装，那会把正常的 Linux 与容器环境挡在门外。
#
# MACWAVE_CSRUTIL 只是测试钩子（把替身脚本指进来），生产路径永远是 /usr/bin/csrutil。
mw_sip_status() {
    local out csrutil
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo unknown
        return 0
    fi
    csrutil="${MACWAVE_CSRUTIL:-/usr/bin/csrutil}"
    out="$("$csrutil" status 2>/dev/null || true)"
    case "$out" in
        *"status: disabled"*) echo disabled ;;
        *"Custom Configuration"*) echo reduced ;;
        *"status: enabled"*) echo enabled ;;
        *) echo unknown ;;
    esac
}

mw_ssv_status() {
    # Signed System Volume（macOS 11+）：系统卷是密封的快照，写入会被内核拒绝，
    # 与 SIP 主开关是两个独立的锁。`csrutil authenticated-root status` 的
    # enabled 表示密封着；老系统（10.x）没有这条命令，返回 unknown。
    local out csrutil
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo unknown
        return 0
    fi
    csrutil="${MACWAVE_CSRUTIL:-/usr/bin/csrutil}"
    out="$("$csrutil" authenticated-root status 2>/dev/null || true)"
    case "$out" in
        *"status: enabled"*) echo enabled ;;
        *"status: disabled"*) echo disabled ;;
        *) echo unknown ;;
    esac
}

mw_sip_protected() {
    # 这个**逻辑**路径在不在 SIP 保护范围？/usr/local 是明确的例外（Homebrew 就在
    # 那里，SIP 不保护它），其余 /usr 都在范围内。
    #
    # 与 config/configpaths.py 的 SYSTEM_LINK_PREFIXES 是同一批位置：那份用于
    # 「符号链接不得跳出 base_dir」的豁免，这份用于「能不能把安装根放这里」。
    # 两边都改时一起看 —— 否则会出现「这里允许装、产物里的链接却被判越界」。
    case "$1" in
        /usr/local|/usr/local/*) return 1 ;;
        /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/System|/System/*|/Library/Apple|/Library/Apple/*)
            return 0 ;;
    esac
    return 1
}

mw_logical_path() {
    # 去掉测试根的映射：SIP 判断看的是「真实系统里会落在哪」，而 MACWAVE_TEST
    # 把整棵树挂到了临时目录下，那个前缀不属于任何受保护位置。
    local path="$1"
    if [[ -n "$SYS_ROOT" && "$path" == "$SYS_ROOT"/* ]]; then
        path="${path#"$SYS_ROOT"}"
    fi
    echo "$path"
}

SIP_STATUS="$(mw_sip_status)"
SSV_STATUS="$(mw_ssv_status)"
SIP_TARGET="$(mw_logical_path "$BASE_DIR")"
if mw_sip_protected "$SIP_TARGET"; then
    case "$SSV_STATUS" in
        enabled)
            # 密封的系统卷：与 SIP 主开关无关，写不进去就是写不进去。
            # 常见于「SIP 已关闭/降级、但没关 authenticated-root」的机器 ——
            # 那些机器的用户会在写文件那一步收到一句 permission denied，
            # 而真正的原因是密封，不是权限。
            mw_say_err "${RED_BOLD}🌊 Error: '$SIP_TARGET' is on the sealed system volume, so it cannot be an installation directory.${RESET}" \
                "${RED_BOLD}🌊 错误：'$SIP_TARGET' 在密封的系统卷上，不能作为安装目录。${RESET}"
            mw_say_err "🌊 The Signed System Volume is a separate lock from SIP: even with SIP" \
                "🌊 系统卷密封（Signed System Volume）与 SIP 是两道独立的锁：即使 SIP 关了，"
            mw_say_err "🌊 disabled, writing there fails until 'csrutil authenticated-root disable'" \
                "🌊 往那里写仍会失败，要另外关掉它（csrutil authenticated-root disable）并重启。"
            mw_say_err "🌊 is applied and the Mac reboots. That is not something an installer" \
                "🌊 那不是安装器该替你做的事。"
            mw_say_err "🌊 should do for you. Choose a directory outside the protected set:" \
                "🌊 请换一个不在保护范围内的目录，例如："
            echo -e "${YELLOW}    /usr/local/macwave   /opt/macwave   ~/.local/macwave${RESET}"
            exit 1
            ;;
        *)
            case "$SIP_STATUS" in
                enabled)
                    mw_say_err "${RED_BOLD}🌊 Error: '$SIP_TARGET' is inside SIP-protected scope, so it cannot be an installation directory.${RESET}" \
                        "${RED_BOLD}🌊 错误：'$SIP_TARGET' 在 SIP 保护范围内，不能作为安装目录。${RESET}"
                    mw_say_err "🌊 While SIP is enabled, even sudo cannot write there." \
                        "🌊 SIP 开启时，sudo 也写不进去。"
                    mw_say_err "🌊 Choose a directory outside the protected set, for example:" \
                        "🌊 请换一个不在保护范围内的目录，例如："
                    echo -e "${YELLOW}    /usr/local/macwave   /opt/macwave   ~/.local/macwave${RESET}"
                    exit 1
                    ;;
                disabled|reduced)
                    # 走到这里说明 SSV 已查明「未密封」（或老系统没有这道锁），
                    # 于是 SIP 主开关是唯一剩下的保护 —— 而它是关着的。
                    if [[ "$SIP_STATUS" == "disabled" ]]; then
                        mw_say "${YELLOW}🌊 Warning: SIP is disabled and the system volume is not sealed,${RESET}" \
                            "${YELLOW}🌊 警告：本机 SIP 已关闭，且系统卷未密封，"
                        mw_say "${YELLOW}🌊 so sudo really can write into '$SIP_TARGET'.${RESET}" \
                            "${YELLOW}🌊 所以 sudo 确实能写进 '$SIP_TARGET'。"
                    else
                        mw_say "${YELLOW}🌊 Warning: SIP is reduced (custom configuration) and the system${RESET}" \
                            "${YELLOW}🌊 警告：本机 SIP 已降级（自定义配置），且系统卷未密封，"
                        mw_say "${YELLOW}🌊 volume is not sealed, so sudo really can write into '$SIP_TARGET'.${RESET}" \
                            "${YELLOW}🌊 所以 sudo 确实能写进 '$SIP_TARGET'。"
                    fi
                    mw_say "🌊 That is common on machines patched by OCLP. Installing there touches" \
                        "🌊 这在 OCLP 打过补丁的机器上很常见。装到那里会改动系统自带的位置："
                    mw_say "🌊 system territory: it may vanish after a macOS update, and it is not" \
                        "🌊 升级 macOS 后可能被清除，而且这不是 MacWave 推荐的安装位置。"
                    mw_say "${YELLOW}🌊 Continuing because you chose this directory explicitly.${RESET}" \
                        "${YELLOW}🌊 因为这是你显式选择的目录，继续。${RESET}"
                    ;;
            esac
            ;;
    esac
fi

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
# 采用的模型：root:<管理员组> 775，目录带 setgid。把写权限收窄到「管理员」这一层，
# 与「谁能 sudo」是同一个人群 —— 组可写并不会让权限变大（管理员本来就能 sudo 成
# root），却换掉了一整类日常摩擦：
#
#   所有人              可读、可执行（能运行已装的包）
#   管理员组（admin）   可写（wave install / 升级**不需要 sudo**）
#   其他人              只读
#
# 4.3.0 / 4.3.1 用的是 755（只有 root 可写），代价是每次装包都要 `sudo wave
# install`。那条路要求用户亲手提权，而且 `sudo` 有自己的 PATH、HOME 也变成
# /var/root；对一个「系统级共享安装」来说，摩擦与收益不成比例。
#
# setgid 必须加在目录上：否则组员（管理员）新建的文件会落回他自己的主组，
# 下一个管理员就写不进去了 —— 与 LinuxWave 的共享安装同一条理由。
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

lend_tree_to_user() {
    # 安装期间把树**暂时**交给调用者。**这不是最终属主**：装完由
    # hand_over_system_install 收回去，变成 root:<管理员组> 775（目录带 setgid）。
    #
    # 为什么需要它：自带 Python 与私有 venv 都是以**普通用户**身份写的
    # （ensure_portable_python 里的 mkdir/curl/tar、以及 `python -m venv`），
    # 树若已经是 root 所有，这些步骤会全部失败 —— 而且失败得很安静：自带
    # Python 只打一句「可能是网络」，venv 只打一句警告，最后依赖被 pip --user
    # 装进安装者自己的 site-packages，别的用户就用不了这套安装。
    #
    # 4.3.0 之前这两处是 `chown -R "$CURRENT_USER"`，语义正确；改成本函数之前
    # 请确认「还有没有以用户身份写树的步骤」，否则会重演上面那次退化。
    local dir="$1"
    [[ "$NEED_SUDO" == "true" ]] || return 0
    [[ -n "$dir" ]] || return 0
    if mw_dry_run; then
        mw_plan "🌊 Dry run: would lend $dir to $CURRENT_USER while the bundled Python and the venv are written." \
            "🌊 试运行：写自带 Python 与 venv 期间，将把 ${dir} 暂时交给 ${CURRENT_USER}。"
        return 0
    fi
    [[ -d "$dir" ]] || return 0
    sudo chown -R "$CURRENT_USER": "$dir" || return 1
    return 0
}

hand_over_system_install() {
    # 系统级安装（$BASE_DIR 不在家目录下）才需要动手；用户级本来就是自己的。
    #
    # mode：u+rwX,g+rwX,o+rX,o-w = 目录 2775（含 setgid）、普通文件 664、
    # 原有的可执行文件 775。o-w 不能省 —— 少了它就回到「任何本地用户都能替换
    # links/ 里的二进制」。
    local dir="$1" group
    [[ -n "$dir" ]] || return 0
    if mw_dry_run; then
        # 目录此刻还不存在（试运行不建），所以判断要放在 -d 检查之前。
        mw_plan "🌊 Dry run: would hand $dir over to root:$(admin_group) with mode 775 (directory setgid)." \
            "🌊 试运行：将把 ${dir} 交给 root:$(admin_group)，权限 775（目录带 setgid）。"
        return 0
    fi
    [[ -d "$dir" ]] || return 0
    group="$(admin_group)"
    # 调用方（NEED_HANDOVER）已经确保「要么需要提权、要么本来就是 root」。
    as_privileged chown -R "root:$group" "$dir" || return 1
    as_privileged chmod -R u+rwX,g+rwX,o+rX,o-w "$dir" || return 1
    # 只给目录加 setgid：文件上的 setgid 是另一种含义（强制锁），不该乱设。
    as_privileged find "$dir" -type d -exec chmod g+s {} + || return 1
    return 0
}

# 「系统级安装」与「这次要不要提权」是**两件事**，这里分开存。
#
#   SYSTEM_INSTALL  语义：目标在 $HOME 之外 → 共享安装。决定配置目录放哪
#                   （系统级用 /opt/macwave_config）、要不要把树收尾成
#                   root:<管理员组> 775、结尾那段「其他用户可运行」的提示。
#   NEED_SUDO       本次能不能直接写：目标树与配置目录**都**可写时不用提权。
#
# 合成一个变量的症状（4.4 之前就是这样）：
#   * 装到 /Volumes/SSD/macwave 这种自己可写的外置卷，明明不需要密码却要密码；
#   * 反过来，~/.local/macwave 被上一次 `sudo` 装成了 root 所有，安装器认为
#     用户目录无需提权，然后一路 Permission denied，报错还指不到原因。
#
# 判据只有一条：**写不了才提权**。不用「是不是在家目录下」猜。
if [[ "$BASE_DIR" == "$HOME"/* ]]; then
    SYSTEM_INSTALL=false
else
    SYSTEM_INSTALL=true
fi

# 配置目录跟着语义走：读取时系统级优先，所以系统级 MacWave 总是盖过用户级的。
if [[ "$SYSTEM_INSTALL" == "true" ]]; then
    CONFIG_DIR="$SYS_ROOT/opt/macwave_config"
else
    CONFIG_DIR="$HOME/.config/macwave_config"
fi

mw_can_write() {
    # 能写这个路径吗？返回 0 可写 / 1 需要提权 / 2 写不进去但不是权限问题。
    #
    # 两步，先「猜」再「问」：
    #   1. `test -w` —— 权限位与 ACL 的静态判断，够快，也够挡住「/opt 属于 root」
    #      这类绝大多数情形；
    #   2. 真写一个空文件再删掉 —— `test -w` 只是读权限位，遇到目录上带 uchg 之类的
    #      标志、或者 ACL 与位掩码不一致时，它说能写而实际写不进去。既然安装的第一件
    #      事就是往里写，那就先写一次试试：探针失败与真安装失败是同一件事，只是早了几步。
    #
    # 探针失败要分两类，不能一律当成「需要提权」：
    #   Permission denied   → 提权能解决，返回 1；
    #   其它（只读文件系统、磁盘满、路径太深…）→ 提权也没用，返回 2 并留下原因，
    #   由调用方当场报出来。否则用户会先被要一次密码，然后在同一条路上再失败一次。
    #
    # 不存在的路径沿祖先往上找第一个存在的目录 —— 直接对不存在的路径 test -w 恒为假，
    # 会让每一次新装都判定成需要提权。
    local path="$1" probe errfile reason
    MW_WRITE_ERROR=""
    MW_WRITE_ERROR_PATH=""
    [[ -n "$path" ]] || return 1
    while [[ ! -e "$path" && "$path" != "/" ]]; do
        path="$(dirname "$path")"
    done
    [[ -d "$path" ]] || return 1
    [[ -w "$path" ]] || return 1

    # --dry-run 的承诺是「不写文件」，所以试运行只用上面那步静态判断；
    # --skip-probe 是用户显式要求跳过这次写探针（例如目标目录在别人的地盘上，
    # 不想留下任何痕迹，宁可事后由真正的写入报错）。
    if mw_dry_run || [[ "${CLI_SKIP_PROBE:-false}" == "true" ]]; then
        return 0
    fi

    errfile="$(mw_mktemp macwave-write-probe)"
    if probe="$(mktemp "$path/.macwave-write-probe.XXXXXX" 2>"$errfile")"; then
        rm -f "$probe" "$errfile"
        return 0
    fi
    reason="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
    case "$reason" in
        *"Permission denied"*) return 1 ;;
    esac
    MW_WRITE_ERROR="$reason"
    MW_WRITE_ERROR_PATH="$path"
    return 2
}

mw_write_state() {
    # 两个目标都要能写；任何一处返回 2 都直接报错退出（提权解决不了）。
    local status=0
    mw_can_write "$1" || status=$?
    if [[ "$status" -eq 2 ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: cannot create files in '$MW_WRITE_ERROR_PATH'.${RESET}" \
            "${RED_BOLD}🌊 错误：无法在 '$MW_WRITE_ERROR_PATH' 里创建文件。${RESET}"
        mw_say_err "🌊 ${MW_WRITE_ERROR}" "🌊 ${MW_WRITE_ERROR}"
        mw_say_err "🌊 This is not a privilege problem: sudo would fail the same way." \
            "🌊 这不是权限问题：提权也会一样失败。"
        mw_say_err "🌊 Fix the filesystem (read-only mount, full disk, …) or choose another directory." \
            "🌊 请处理文件系统本身（只读挂载、磁盘已满等），或者换一个目录。"
        exit 1
    fi
    return "$status"
}

# `|| var=$?` 而不是直接取 $?：set -e 下裸调一个返回非零的函数会当场退出。
base_state=0
mw_write_state "$BASE_DIR" || base_state=$?
config_state=0
mw_write_state "$CONFIG_DIR" || config_state=$?
if [[ "$base_state" -eq 0 && "$config_state" -eq 0 ]]; then
    NEED_SUDO=false
else
    NEED_SUDO=true
fi

# 以 root 身份跑（`sudo bash install.sh`、容器里的 `--ci`）时 NEED_SUDO 为假 ——
# 但系统级安装仍要把属主/权限收尾成 root:<管理员组> 775，否则别的管理员就不能
# `wave install` 了（那正是 4.3.2 起采用的共享安装模型）。
IS_ROOT=false
[[ "$(id -u)" == "0" ]] && IS_ROOT=true

NEED_HANDOVER=false
if [[ "$SYSTEM_INSTALL" == "true" ]] \
   && { [[ "$NEED_SUDO" == "true" ]] || [[ "$IS_ROOT" == "true" ]]; }; then
    NEED_HANDOVER=true
fi

# 需要动属主/权限时用它：普通用户走 sudo，本来就以 root 跑就直接执行
# （容器里未必装了 sudo）。**不要**在别处硬写 sudo —— 那会让 root 场景也依赖它。
as_privileged() {
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

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
        if mw_download "$UPDATE_COMMANDS_URL" "$UPDATE_COMMANDS_TMP" 60; then
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

    if ! /bin/bash -n "$UPDATE_COMMANDS_TMP" 2>/dev/null; then
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
CLI_DIR="$BASE_DIR/cli"
# 程序代码目录，与下面的 CONFIG_DIR（**配置文件**目录，/opt/macwave_config）不是
# 一回事。两个名字只差一个词，变量名必须能一眼分开。
CONFIG_CODE_DIR="$BASE_DIR/config"
# 文档资源：装进安装树，但不进 sys.path（见 scripts/assets.txt）
MAN_DIR="$BASE_DIR/man"
INFO_DIR="$BASE_DIR/info"
DEPS_DIR="$BASE_DIR/deps"
DOWNLOAD_DIR="$BASE_DIR/downloads/tmp"

# CONFIG_DIR 在「判断是否需要 sudo」那一节就算好了：它跟着 SYSTEM_INSTALL 走
# （系统级 → /opt/macwave_config，用户级 → ~/.config/macwave_config），而不是
# 跟着「这次要不要提权」—— 后者的判据是**写权限**，与目录语义无关。
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"
# 同意记录。selfupdate.py 读的就是这个文件（AGREEMENT_FILE_NAME）；
# 这里不写的话，「已记录你的同意」是句假话，而且下次自更新会再问一遍。
AGREEMENT_FILE="$CONFIG_DIR/AGREEMENT.json"

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

# 回滚（拒绝协议时）要不要删这棵树，取决于它是不是**本次**安装建出来的：
# 覆盖升级时 BASE_DIR 本来就在，删掉它等于毁掉用户已有的安装。
# 必须在第一条 mkdir 之前判断。
TREE_PREEXISTED=0
if [[ -d "$BASE_DIR" || -d "$CONFIG_DIR" ]]; then
    TREE_PREEXISTED=1
fi

run_cmd mkdir -p "$INSTALL_DIR"
run_cmd mkdir -p "$LINKS_DIR"
run_cmd mkdir -p "$REPO_DIR"
run_cmd mkdir -p "$SURFBOARD_DIR"
run_cmd mkdir -p "$LIB_DIR"
run_cmd mkdir -p "$NET_DIR"
run_cmd mkdir -p "$CLI_DIR"
run_cmd mkdir -p "$CONFIG_CODE_DIR"
run_cmd mkdir -p "$MAN_DIR/man1"
run_cmd mkdir -p "$INFO_DIR"
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
# 安装期间：树暂时交给当前用户
# ==========================================
# 后面还有以用户身份写树的步骤（自带 Python、私有 venv），见 lend_tree_to_user。
# 最终属主由文件末尾的 hand_over_system_install 决定。

if [[ "$NEED_SUDO" == "true" ]]; then
    lend_tree_to_user "$BASE_DIR"
fi

if [[ "$NEED_HANDOVER" == "true" ]]; then
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
#
# MACWAVE_CURRENT_VERSION 留空只是「我不知道你装的是哪版」，**不等于**全量安装 ——
# 走全量还是增量由更新脚本自己按安装树判断（lib/wave.py 在不在、清单里的文件齐不齐）。
# 以前这里写着「留空 → 下载全部文件」，与脚本的实际行为不符：既有安装树照样走增量，
# 于是 install.sh 在「树坏了」时什么都没修（2026-11-15 实测只下了 pkg/pkginstaller.py）。

export MACWAVE_INSTALL_DIR="$BASE_DIR"
# 语言一路传到底下的更新脚本，否则安装过程会中英混杂。
export MACWAVE_LANG="$MW_LANG"
export MACWAVE_CORE_URL="$CORE_URL"
export MACWAVE_BRANCH="$BRANCH"
export MACWAVE_CURRENT_VERSION=""
export MACWAVE_FILE_TIMEOUT=60
MACWAVE_NEED_SUDO="$([ "$NEED_SUDO" = "true" ] && echo 1 || echo "")"
MACWAVE_SILENT="$([ "$CLI_CI" = "true" ] && echo 1 || echo "")"
# 更新脚本（update_commands.sh）自己也在打印，靠这个变量把 --raw 传下去。
# 老版本的更新脚本不认识它 —— 那时只是更新脚本自己带 🌊，不影响安装结果。
MACWAVE_RAW="$([ "$CLI_RAW" = "true" ] && echo 1 || echo "")"
export MACWAVE_NEED_SUDO MACWAVE_SILENT MACWAVE_RAW

if mw_dry_run; then
    mw_plan "🌊 Dry run: the update commands would run now and download the program files." \
        "🌊 试运行：更新命令本该在此执行并下载程序文件，实际未执行。"
elif ! /bin/bash "$UPDATE_COMMANDS_TMP"; then
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

# 再交一次：上面那段更新脚本是带 sudo 跑的，可能又留下 root 属主的文件。
if [[ "$NEED_SUDO" == "true" ]]; then
    lend_tree_to_user "$BASE_DIR"
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
    latest_file="$(mw_mktemp macwave-pylatest)"
    if mw_download "$PYTHON_DOMAIN_URL/pythondata/latest.toml" "$latest_file" 30 2>/dev/null; then
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
    url_file="$(mw_mktemp macwave-pyurl)"
    if ! mw_download "$PYTHON_DOMAIN_URL/pythondata/$version/python_url.toml" "$url_file" 30 2>/dev/null; then
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
    if ! mw_download "$archive_url" "$archive" 900 2>/dev/null; then
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

    tmp="$(mw_mktemp macwave-launcher)"

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
    printf 'case ":${MANPATH:-}:" in\n  *":%s:"*) ;;\n  *) export MANPATH="%s${MANPATH:+:$MANPATH}" ;;\nesac\n' \
        "$root_dir/man" "$root_dir/man"
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
    rendered="$(mw_mktemp macwave-launcher-out)"
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

if [[ "$NEED_HANDOVER" == "true" ]]; then
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

# 协议标识的唯一来源是装好的 lib/selfupdate.py（AGREEMENT_ID），这里不再抄一份日期：
# 两边走散的后果是「问的是新协议、记下的是旧标识」，于是下次再问一遍。
agreement_id() {
    local source="$LIB_DIR/selfupdate.py"
    [[ -f "$source" ]] || return 1
    sed -n 's/^AGREEMENT_ID = "\([^"]*\)"$/\1/p' "$source" | head -n 1
}

# 把同意记进配置目录。记不下来不算安装失败 —— 代价只是下次自更新再问一遍，
# 比「装到一半退出」轻得多。
record_agreement() {
    local id
    id="$(agreement_id || true)"
    if [[ -z "$id" ]]; then
        mw_say "${YELLOW}🌊 Note: cannot read AGREEMENT_ID from $LIB_DIR/selfupdate.py; the acceptance was not recorded.${RESET}" \
            "${YELLOW}🌊 注意：读不到 ${LIB_DIR}/selfupdate.py 里的 AGREEMENT_ID，本次同意未被记录。${RESET}"
        return 0
    fi
    if ! printf '{\n  "agreement": "%s"\n}\n' "$id" | run_cmd tee "$AGREEMENT_FILE" > /dev/null 2>&1; then
        mw_say "${YELLOW}🌊 Note: could not record the agreement in $AGREEMENT_FILE.${RESET}" \
            "${YELLOW}🌊 注意：未能把同意写进 ${AGREEMENT_FILE}。${RESET}"
    fi
    run_cmd chmod 644 "$AGREEMENT_FILE" > /dev/null 2>&1 || true
    return 0
}

# 必须放在「安装完成」之前：否则先告诉用户已经装好，随后又因为不同意而全部删除。

echo ""
mw_say "${YELLOW}Please read the agreement before use (see bottom of https://macwave.org).${RESET}" "${YELLOW}使用前请先阅读用户协议（见 https://macwave.org 页面底部）。${RESET}"
if mw_dry_run; then
    # 试运行不碰终端：否则 `install.sh --dry-run` 会停在协议提问上，
    # 只想看输出的人反而被卡住。真实安装仍然要求回答。
    agreement="yes"
    mw_plan "🌊 Dry run: the agreement is not asked and nothing is recorded." \
        "🌊 试运行：不询问用户协议，也不记录任何同意。"
elif [[ "$CLI_CI" == "true" ]]; then
    mw_say "🌊 --ci: the agreement is accepted automatically." "🌊 --ci：自动接受用户协议。"
    agreement="yes"
else
    # 回答归一化：去空白、转小写后再判断。空 / y / yes → 同意，n / no → 拒绝，
    # 其它输入重新提问，连续 3 次无法识别就按拒绝处理。
    # 不用 ${var,,}：macOS 自带 bash 3.2 没有这个展开。
    agreement=""
    _agreement_tries=0
    while [[ -z "$agreement" ]]; do
        _agreement_tries=$((_agreement_tries + 1))
        mw_say "${YELLOW}Have you read and agreed to the agreement? [Y/n]${RESET}" "${YELLOW}你是否已阅读并同意该协议？[Y/n]${RESET}"
        _answer=""
        read -r _answer < /dev/tty || _answer=""
        _answer=$(printf '%s' "$_answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$_answer" in
            ""|y|yes)
                agreement="yes"
                ;;
            n|no)
                agreement="no"
                ;;
            *)
                if [[ "$_agreement_tries" -ge 3 ]]; then
                    mw_say "${YELLOW}Unrecognized answer, treating it as \"no\".${RESET}" \
                        "${YELLOW}无法识别的回答，按「不同意」处理。${RESET}"
                    agreement="no"
                else
                    mw_say "${YELLOW}Please answer y (agree) or n (do not agree).${RESET}" \
                        "${YELLOW}请回答 y（同意）或 n（不同意）。${RESET}"
                fi
                ;;
        esac
    done
fi
if [[ "$agreement" == "yes" ]]; then
    if ! mw_dry_run; then
        # --ci 的自动同意也记下来：否则 CI 装完再跑 selfupdate 会卡在协议询问上
        record_agreement
        mw_say "${GREEN}You have agreed to the agreement.${RESET}" "${GREEN}已记录你的同意。${RESET}"
    fi
else
    mw_say "${RED_BOLD}You do not agree to the agreement. Installation stopped.${RESET}" "${RED_BOLD}你未同意该协议，安装已停止。${RESET}"
    # 回滚只清本次安装建出来的东西。升级覆盖时 BASE_DIR 早就存在，
    # 删掉它就是毁掉用户已有的安装。
    _cleanup_rc="$RC_FILE"
    if [[ -n "${EXISTING_RC:-}" ]]; then
        _cleanup_rc="$EXISTING_RC"
    fi
    if [[ "$TREE_PREEXISTED" == "0" ]]; then
        mw_say "${RED_BOLD}🌊 Cleaning up downloaded files...${RESET}" "${RED_BOLD}🌊 正在清理已下载的文件……${RESET}"
        run_cmd rm -rf "$BASE_DIR"
        run_cmd rm -rf "$CONFIG_DIR"
        # 回滚要连 rc 里的 PATH 一起清掉，否则会留下指向已删除目录的一行。
        # 这里不写死 sudo：用户级安装全程无需提权，回滚也不该突然要密码。
        remove_lw_path_entries "$_cleanup_rc"
        mw_say "${RED_BOLD}🌊 All files have been deleted.${RESET}" "${RED_BOLD}🌊 所有文件已删除。${RESET}"
    else
        mw_say "${YELLOW}🌊 Existing installation left untouched; run the installer again to continue.${RESET}" \
            "${YELLOW}🌊 已有安装保持原样，重新运行安装器可继续。${RESET}"
    fi
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
    # 装饰与艺术字同一条规矩：--raw 是给日志和 grep 看的，逐字去掉。
    if ! mw_raw; then
        echo ""
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo ""
        echo -e "${SKY_BLUE}                  (DRY_RUN)The tide rises, the tide falls...                    ${RESET}"
        echo ""
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
    fi
else
    mw_say "🌊 Installation complete!" "🌊 安装完成！"
    mw_say "🌊 MacWave installed to: $DISPLAY_DIR" "🌊 MacWave 已安装到：$DISPLAY_DIR"
    # 打印诗句（--raw 时同样跳过）
    if ! mw_raw; then
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo ""
        echo -e "${SKY_BLUE}                       The tide rises, the tide falls...                        ${RESET}"
        echo ""
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
    fi
fi

echo
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
    "🌊 如果提示「找不到命令」，执行下列命令或打开新的终端窗口。"
echo ""
# 必须 source **刚追加进去的那个文件**（${RC_FILE}），不是「碰巧存在的」那个：
# zsh 的行加在 ~/.zprofile，此时 source ~/.zshrc 并不会把它加载进来。
echo -e "${YELLOW}    source $RC_DISPLAY${RESET}"
echo ""

# 系统级安装是共享的：管理员（admin 组）直接管理，其他用户只能运行。
# PATH 那行现在由用户自己加 —— 别人不加就找不到 wave，只能靠绝对路径执行。
# 这里说清楚，否则「其他人可运行」只对了一半。
#
# 判据是 SYSTEM_INSTALL（装的是一棵共享的树），不是 NEED_SUDO（这次有没有提权）：
# 目标可写时不需要 sudo，但它依然是一棵共享的树。
if [[ "$SYSTEM_INSTALL" == "true" ]]; then
    mw_say "🌊 Other users on this machine can run the installed packages," \
        "🌊 本机的其他用户可运行已装的软件包，"
    mw_say "🌊 but each of them needs to run this once:" \
        "🌊 但每个用户需要执行："
    echo -e "${YELLOW}    $SHELLENV_DISPLAY${RESET}"
    mw_say "🌊 Administrators can install and remove packages without sudo:" \
        "🌊 管理员装包、卸包都不需要 sudo："
    echo -e "${YELLOW}    wave install <package>${RESET}"
    mw_say "🌊 A user who is not in the '$(admin_group)' group can still run the packages," \
        "🌊 不在 '$(admin_group)' 组里的用户仍然能运行已装的包，"
    mw_say "🌊 but changing them needs the full path (sudo has its own PATH):" \
        "🌊 但改动它们要用全路径（sudo 用的是它自己的 PATH）："
    echo -e "${YELLOW}    sudo $BASE_DIR/lib/wave install <package>${RESET}"
    echo ""
fi

if mw_dry_run; then
    mw_say "🌊 Drop --dry-run and run the installer again to install for real." \
        "🌊 去掉 --dry-run 再运行一次，才会真正安装。"
fi
