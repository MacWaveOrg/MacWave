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
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${MACWAVE_INSTALL_DIR:?MACWAVE_INSTALL_DIR is required}"
: "${MACWAVE_CORE_URL:?MACWAVE_CORE_URL is required}"

# 语言：install.sh 通过 MACWAVE_LANG 传进来。老版本客户端不会传，所以默认英文。
# 与 lib/install.sh 用同一套约定（mw_say "<English>" "<中文>"），不引 gettext。
MW_LANG="${MACWAVE_LANG:-en}"
mw_say() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$2"; else printf '%b\n' "$1"; fi
}
mw_say_err() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$2" >&2; else printf '%b\n' "$1" >&2; fi
}
: "${MACWAVE_BRANCH:?MACWAVE_BRANCH is required}"

VERSION="@@VERSION@@"
BRANCH="@@BRANCH@@"
FILE_TIMEOUT="${MACWAVE_FILE_TIMEOUT:-60}"
ATTEMPTS=3

# 额外根证书（MACWAVE_CACERT）：企业网络里 TLS 会被重签，自建镜像也可能用私有 CA。
# 这个脚本是客户端调起来的，环境变量直接继承；没设时行为不变。
# 设了却读不到就报错退出 —— 静默忽略会让人以为已经信任了那家 CA。
CURL_CACERT=""
if [[ -n "${MACWAVE_CACERT:-}" ]]; then
    _cacert="${MACWAVE_CACERT/#\~/$HOME}"
    if [[ ! -f "$_cacert" || ! -r "$_cacert" ]]; then
        mw_say_err "🌊 Error: MACWAVE_CACERT is not a readable file: $_cacert" "🌊 错误：MACWAVE_CACERT 不是一个可读的文件：$_cacert"
        mw_say_err "🌊 Next      export MACWAVE_CACERT=/path/to/root.pem (or unset it)" "🌊 下一步     export MACWAVE_CACERT=/path/to/root.pem（或取消这个变量）"
        exit 1
    fi
    CURL_CACERT="$_cacert"
fi

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
        run curl -fsSL --max-time "$FILE_TIMEOUT" ${CURL_CACERT:+--cacert "$CURL_CACERT"} -o "$partial" "$url" || status=$?
        if [ "$status" -eq 0 ]; then
            # mv 失败也要报：权限不足（sudo 没拿到）时文件还在 .macwave-part 里，
            # 目标位置是旧的甚至不存在。以前这里不看返回值，于是「下载成功但没就位」
            # 会被当成这一步成功 —— 和 want 里那个 return/exit 是同一类问题。
            if ! run mv -f "$partial" "$destination"; then
                mw_say_err "🌊 Error: cannot move $partial into place" "🌊 错误：无法把 $partial 移动到目标位置"
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

    if [ "${MACWAVE_SILENT:-}" != "1" ]; then
        mw_say "🌊 Downloading $repo_path..." "🌊 正在下载 ${repo_path}……"
    fi
    if ! fetch "$url" "$destination"; then
        mw_say_err "🌊 Error: cannot download $repo_path" "🌊 错误：无法下载 $repo_path"
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
            mw_say_err "🌊 Error: cannot make $repo_path executable" "🌊 错误：无法把 $repo_path 设为可执行"
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

# 本版安装树应有的全部文件（与 install_fresh 同一份清单，见生成器里的 list_lines）。
FULL_FILES="
@@FULL_FILES@@
"

tree_complete() {
    # 判断这棵安装树是不是「本版应有的文件一个不缺」。
    #
    # 为什么不能只看 lib/wave.py 在不在：那种判据会把三种坏树当成好树 ——
    #   1. 上一版留下的一半升级（下到第 20 个文件时断网 / Ctrl-C）
    #   2. 跨版本跳级升级：4.1.0 直接升 4.3.3，delta 只含 4.3.2→4.3.3 的差异
    #   3. 文件被手工删过（2026-11-15 就出现过：4.4 的迁移删掉 lib/configerror.py，
    #      但 lib/wave.py 还是 4.3.x 的，于是 wave 连启动都做不到）
    # 缺一个就走全量，代价是多重下几个文件，换的是「永远能自愈」。
    local path
    for path in $FULL_FILES; do
        [ -e "$MACWAVE_INSTALL_DIR/$path" ] || return 1
    done
    return 0
}

main() {
    # 「已经是这个版本」也要先确认树是完整的。VERSION.json 只证明「上次跑完过」，
    # 不证明文件还在 —— 只信版本号的话，一棵坏树会永远停在 "Already at"，
    # 无论跑多少次都不会修好（这正是 2026-11-15 那次的形态）。
    if [ "${MACWAVE_FULL_INSTALL:-}" != "1" ] \
       && [ "${MACWAVE_CURRENT_VERSION:-}" = "$VERSION" ] \
       && tree_complete; then
        mw_say "🌊 Already at $VERSION; nothing to download." "🌊 已经是 ${VERSION}，无需下载。"
        return 0
    fi

    if [ "${MACWAVE_FULL_INSTALL:-}" = "1" ] || [ ! -f "$MACWAVE_INSTALL_DIR/lib/wave.py" ]; then
        mw_say "🌊 Installing MacWave $VERSION" "🌊 正在安装 MacWave $VERSION"
        install_fresh || return 1
    elif ! tree_complete; then
        # 树在那儿但不完整：增量的前提（「没变动的文件都是对的」）不成立，
        # 直接全量补齐。这里不先跑 delta —— 缺的文件正好可能就是它要留着的那些。
        mw_say "🌊 The installed tree is incomplete; reinstalling all of MacWave $VERSION"
        mw_say "🌊 安装树不完整，正在重新安装 MacWave ${VERSION} 的全部文件"
        install_fresh || return 1
    else
        mw_say "🌊 Updating MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION" "🌊 正在更新 MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION"
        install_delta || return 1
        # 增量之后再确认一次：delta 只含「上一版 → 本版」的差异，跨版本跳级时
        # 会漏掉中间那些版本改过的文件。补全比报错好 —— 用户什么也没做错。
        if ! tree_complete; then
            mw_say "🌊 Some files are still missing after the update; fetching all of MacWave $VERSION"
            mw_say "🌊 更新后仍有文件缺失，正在补齐 MacWave ${VERSION} 的全部文件"
            install_fresh || return 1
        fi
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

    # 4.4.0：配置解析与命令行层从 lib/ 搬到了 config/ 与 cli/。新位置的文件已经由
    # 上面的 install_fresh / install_delta 下好（`want` 会先 mkdir -p，所以这两个
    # 目录在旧安装树里也会被建出来），这里清掉 lib/ 下的平铺副本。
    #
    # 这一条比 4.1.6 那条**更**不能省：4.1.6 的旧文件已经没有代码 import，留着只是
    # 说不清；而这里 lib/ 仍在 sys.path 上，留着 lib/help.py 就等于「同一个模块有
    # 两份，哪份生效看路径顺序」—— wave.py 把 cli/ 排在 lib/ 之前，于是跑的是新的，
    # 但下一次有人调整顺序就会悄悄退回旧代码。删掉才没有第二种可能。
    #
    # lib/quiet.py 是漏过一次的：4.1.4 起它一直在清单里，4.4 把它并进了
    # cli/silent.py，但它没被列进这份删除名单 —— 于是从 4.1.4~4.3.3 升上来的树里
    # 会永久留一份没人 import 的 quiet.py。查出来时是 2026-11-15。
    for stale in "$MACWAVE_INSTALL_DIR/lib/configpaths.py" \
                 "$MACWAVE_INSTALL_DIR/lib/configerror.py" \
                 "$MACWAVE_INSTALL_DIR/lib/help.py" \
                 "$MACWAVE_INSTALL_DIR/lib/flags.py" \
                 "$MACWAVE_INSTALL_DIR/lib/suggest.py" \
                 "$MACWAVE_INSTALL_DIR/lib/silent.py" \
                 "$MACWAVE_INSTALL_DIR/lib/quiet.py"; do
        if [ -f "$stale" ]; then
            run rm -f "$stale" || exit 1
        fi
    done

    # 4.4.0：版本逻辑三份合成一份（lib/versioncompare.py）。pkg/pkgversionparser.py 与
    # surfboard/depsversionparser.py 已并进去，旧树里留着的那两份没有任何代码 import，
    # 所以删不删都跑得动 —— 但留着就是两套「差不多」的比较器躺在安装树里，下次改
    # 版本规则时很容易改到没人用的那一份。quiet.py 漏过一次，这里不重复。
    #
    # lib/versioncmp.py 是同一个模块的旧名字（4.4.0-beta1 起叫这个）。改成
    # versioncompare 之后旧文件没人 import 了，但留在 lib/ 里就是「同一个模块有两个
    # 名字」—— 与 help.py 那条同理，路径顺序一变就会悄悄跑旧代码。
    for stale in "$MACWAVE_INSTALL_DIR/pkg/pkgversionparser.py" \
                 "$MACWAVE_INSTALL_DIR/surfboard/depsversionparser.py" \
                 "$MACWAVE_INSTALL_DIR/lib/versioncmp.py"; do
        if [ -f "$stale" ]; then
            run rm -f "$stale" || exit 1
        fi
    done

    return 0
}

main "$@"
