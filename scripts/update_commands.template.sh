#!/bin/bash

# MacWave update commands — @@VERSION@@
#
# 这个文件由 MacWave 仓库的 scripts/build_update_commands.py 生成，请勿手工编辑。
# 它取代了以前的 files_info：不再由客户端解析「要下载哪些文件」，而是由这里自己
# 完成下载与落盘。好处是只列出真正变动的文件 —— 这次没碰 help.py，就不必再下一遍。
# 目录结构变更的迁移也写在这个脚本里。
#
# 客户端保证以下环境变量：
#
#   MACWAVE_INSTALL_DIR      安装根目录
#   MACWAVE_CONFIG_DIR       配置目录
#   MACWAVE_CORE_URL         MacWave 代码的地址前缀（不含分支）
#   MACWAVE_BRANCH           代码分支
#   MACWAVE_TARGET_VERSION   目标版本（本脚本所属的版本）
#   MACWAVE_CURRENT_VERSION  当前已装版本；首次安装时为空
#   MACWAVE_FILE_TIMEOUT     单个文件的超时秒数
#   MACWAVE_NEED_SUDO        1 = 安装目录需要 sudo 才能写
#   MACWAVE_LANG             zh = 中文输出；未设置或其它值 = 英文
#   MACWAVE_DRY_RUN          1 = 只报告将要做什么，不落盘
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${MACWAVE_INSTALL_DIR:?MACWAVE_INSTALL_DIR is required}"
: "${MACWAVE_CORE_URL:?MACWAVE_CORE_URL is required}"

# 语言：install.sh 通过 MACWAVE_LANG 传进来。老版本客户端不会传，所以默认英文。
# 与 lib/install.sh 用同一套约定（say "<English>" "<中文>"），不引 gettext。
MW_LANG="${MACWAVE_LANG:-en}"
say() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$2"; else printf '%b\n' "$1"; fi
}
say_err() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$2" >&2; else printf '%b\n' "$1" >&2; fi
}
: "${MACWAVE_BRANCH:?MACWAVE_BRANCH is required}"

VERSION="@@VERSION@@"
BRANCH="@@BRANCH@@"
FILE_TIMEOUT="${MACWAVE_FILE_TIMEOUT:-60}"
ATTEMPTS=3

run() {
    if [ "${MACWAVE_NEED_SUDO:-}" = "1" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

redact_url() {
    # 报错里的地址要打码：用镜像时 MACWAVE_CORE_URL 是
    # https://<用户>:<密码>@mirror/...，原样打印等于把密码写进终端滚屏、
    # CI 日志和用户贴出来的求助截图。
    #
    # 只在 // 之后、第一个 / 之前找最后一个 @ —— 路径里带 @ 是正常的
    # （jq@1.8.2.arm64），拿整条串找 @ 会把包名当成密码位置，地址就改坏了。
    local url="$1" rest authority path userinfo host user
    rest=${url#*://}
    [ "$rest" = "$url" ] && { printf '%s' "$url"; return; }
    authority=${rest%%/*}
    case "$rest" in
        */*) path="/${rest#*/}" ;;
        *)   path="" ;;
    esac
    if [[ "$authority" != *@* ]]; then
        printf '%s' "$url"
        return
    fi
    userinfo=${authority%@*}
    host=${authority##*@}
    user=${userinfo%%:*}
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s' "${url%%://*}" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s' "${url%%://*}" "$host" "$path"
    fi
}

fetch() {
    # fetch <url> <目标>：先写 .macwave-part 再 mv，重试期间目标位置不会出现半个文件
    local url="$1" destination="$2" attempt status partial
    partial="$destination.macwave-part"

    run mkdir -p "$(dirname "$destination")"
    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        status=0
        run curl -fsSL --max-time "$FILE_TIMEOUT" -o "$partial" "$url" || status=$?
        if [ "$status" -eq 0 ]; then
            # mv 失败也要报：权限不足（sudo 没拿到）时文件还在 .macwave-part 里，
            # 目标位置是旧的甚至不存在。以前这里不看返回值，于是「下载成功但没就位」
            # 会被当成这一步成功 —— 和 want 里那个 return/exit 是同一类问题。
            if ! run mv -f "$partial" "$destination"; then
                say_err "🌊 Error: cannot move $partial into place" "🌊 错误：无法把 $partial 移动到目标位置"
                run rm -f "$partial" 2>/dev/null || true
                return 1
            fi
            return 0
        fi
        run rm -f "$partial" 2>/dev/null || true
        if ((attempt < ATTEMPTS)); then
            sleep 2
        fi
    done
    return 1
}

want() {
    # want <仓库内路径> <是否 +x>
    local repo_path="$1" exec_flag="${2:-0}"
    local destination="$MACWAVE_INSTALL_DIR/$repo_path"
    local url="$MACWAVE_CORE_URL/$MACWAVE_BRANCH/$repo_path"

    if [ "${MACWAVE_DRY_RUN:-}" = "1" ]; then
        say "would fetch $repo_path" "将获取 $repo_path"
        return 0
    fi

    if [ "${MACWAVE_SILENT:-}" != "1" ]; then
        say "🌊 Downloading $repo_path..." "🌊 正在下载 $repo_path……"
    fi
    if ! fetch "$url" "$destination"; then
        say_err "🌊 Error: cannot download $repo_path" "🌊 错误：无法下载 $repo_path"
        echo "🌊   $(redact_url "$url")" >&2
        # 必须 exit 而不是 return：install_fresh / install_delta 是一串裸的
        # `want ...`，没有 `|| exit`，脚本也没有 set -e。用 return 1 的话
        # 调用方不看返回值，于是「有文件没下到」会被当成更新成功，客户端照旧
        # 写 VERSION.json —— 安装树缺文件但版本号已经前进了，这种状态最难查。
        # 2026-10-30 的 4.1.1 就是这样：两个 __pycache__ 路径 404 之后，
        # 那一步仍然打印了 "MacWave has been updated to 4.1.1!"。
        exit 1
    fi
    if [ "$exec_flag" = "1" ]; then
        # 加不上 +x 的后果是「命令找不到」，比下载失败更难懂，所以这里也要拦住
        if ! run chmod +x "$destination"; then
            say_err "🌊 Error: cannot make $repo_path executable" "🌊 错误：无法把 $repo_path 设为可执行"
            exit 1
        fi
    fi
    return 0
}

install_fresh() {
    # 首次安装（或修复一棵不完整的安装树）：所有文件都要。
@@FULL@@
}

install_delta() {
    # 从上一版升级：只取这一版变动过的文件。
    # 没列出的文件保持不变 —— 它们的字节和上一版相同。
@@DELTA@@
}

main() {
    if [ "${MACWAVE_CURRENT_VERSION:-}" = "$VERSION" ]; then
        say "🌊 Already at $VERSION; nothing to download." "🌊 已经是 $VERSION，无需下载。"
        return 0
    fi

    if [ -f "$MACWAVE_INSTALL_DIR/lib/wave.py" ]; then
        say "🌊 Updating MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION" "🌊 正在更新 MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION"
        install_delta || return 1
    else
        say "🌊 Installing MacWave $VERSION" "🌊 正在安装 MacWave $VERSION"
        install_fresh || return 1
    fi

    # ── 目录结构变更的迁移写在这里 ──
    # 约束：以当前用户身份执行，需要管理员权限时自己 sudo，失败要 exit 非零，
    # 且必须幂等。

    # 4.1.6：传输层从 lib/ 搬到 net/。新位置的三个文件已由 install_delta 下好
    # （发版时用 --new 把它们排在 delta 最前面），这里只清掉旧位置的同名文件。
    # 不删其实也能跑 —— 没有代码再 import 它们 —— 但留着会让「安装树里到底有哪份
    # tls.py」变成两说，下次改策略时容易改到没人用的那一份。
    for stale in "$MACWAVE_INSTALL_DIR/lib/tls.py" \
                 "$MACWAVE_INSTALL_DIR/lib/timeouts.py" \
                 "$MACWAVE_INSTALL_DIR/lib/domains.py"; do
        if [ -f "$stale" ]; then
            run rm -f "$stale" || exit 1
        fi
    done

    return 0
}

main "$@"
