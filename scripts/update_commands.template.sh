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
#   MACWAVE_CORE_URL         MacWave 代码的地址前缀（不含分支）
#   MACWAVE_BRANCH           代码分支
#   MACWAVE_CURRENT_VERSION  当前已装版本；首次安装时为空
#   MACWAVE_FILE_TIMEOUT     单个文件的超时秒数
#   MACWAVE_NEED_SUDO        1 = 安装目录需要 sudo 才能写
#   MACWAVE_LANG             zh = 中文输出；未设置或其它值 = 英文
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

# ==========================================
# 迁移：旧版外部配置目录（4.7）
# ==========================================
#
# 这一份是 4.6 → 4.7 唯一能跑到的新代码：旧客户端的 lib/selfupdate.sh 不认得
# 树内 var/，所以「写状态 + 清旧目录」必须在这里做一遍。4.7 之后升级由
# lib/selfupdate.sh 自己做，全新安装由 lib/install.sh 做 —— 三处用同一个判据。
#
# 本脚本由客户端以环境变量驱动，安装根是 MACWAVE_INSTALL_DIR。
#
# 判据正文来自 scripts/shared/legacy_config_action.sh（三处副本逐字节一致，
# 由 scripts/check_shared_blocks.py 在 CI 里盯着）。

# >>> SHARED: legacy-config-action
mw_legacy_config_action() {
    local base_dir="$1" state_file="$2" legacy_dir="$3"

    [[ -n "$state_file" && -f "$state_file" ]] || { printf 'none\n'; return 0; }
    [[ -n "$legacy_dir" && -f "$legacy_dir/config.json" ]] || { printf 'none\n'; return 0; }

    local recorded
    recorded="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("base_dir", "") or "")
except Exception:
    print("")' "$legacy_dir/config.json" 2>/dev/null)"

    if [[ -z "$recorded" ]]; then
        printf 'none\n'
        return 0
    fi
    if [[ "$recorded" == "$base_dir" ]]; then
        printf 'clear\n'
    else
        printf 'other:%s\n' "$recorded"
    fi
}
# <<< SHARED

mq_migrate_legacy_config() {
    # 只在 4.7 及以上调用（调用点会先判断目标版本）。
    local base_dir="${MACWAVE_INSTALL_DIR:-}" state_file legacy_dir action
    [[ -n "$base_dir" ]] || return 0
    state_file="$base_dir/var/config.sh"
    [[ -f "$state_file" ]] || return 0

    for legacy_dir in "$base_dir/../macwave_config" \
                      "${HOME:-/nonexistent}/.config/macwave_config"; do
        [[ -d "$legacy_dir" ]] || continue
        action="$(mw_legacy_config_action "$base_dir" "$state_file" "$legacy_dir")"
        case "$action" in
            none) : ;;
            other:*)
                mw_say "🌊 Keeping $legacy_dir: it points at another installation (${action#other:})." \
                       "🌊 保留 ${legacy_dir}：它指向另一份安装（${action#other:}）。"
                ;;
            clear)
                rm -f "$legacy_dir/config.json" "$legacy_dir/VERSION.json" "$legacy_dir/AGREEMENT.json" 2>/dev/null || true
                rmdir "$legacy_dir" 2>/dev/null || true
                mw_say "🌊 Removed the legacy config directory $legacy_dir (state now lives in $base_dir/var)." \
                       "🌊 已删除旧版配置目录 ${legacy_dir}（状态现在在 ${base_dir}/var）。"
                ;;
        esac
    done
}

: "${MACWAVE_INSTALL_DIR:?MACWAVE_INSTALL_DIR is required}"
: "${MACWAVE_CORE_URL:?MACWAVE_CORE_URL is required}"

# 语言：install.sh 通过 MACWAVE_LANG 传进来。老版本客户端不会传，所以默认英文。
# 与 lib/install.sh 用同一套约定（mw_say "<English>" "<中文>"），不引 gettext。
MW_LANG="${MACWAVE_LANG:-en}"
mw_strip_item() {
    # --raw（install.sh 传下来的 MACWAVE_RAW=1）：去掉行首的 🌊 与紧跟的一个空格。
    # 与 `wave install --raw` 同一条规则；本脚本的几条提示都带 🌊，落进日志会脏。
    # 🌊 用 printf 的字节写：$'\U0001F30A' 在 bash 3.2 上不支持。
    local line="$1" item
    [[ "${MACWAVE_RAW:-}" == "1" ]] || { printf '%s' "$line"; return 0; }
    item="$(printf '\xf0\x9f\x8c\x8a')"
    case "$line" in
        "$item "*) line="${line#"$item "}" ;;
        "$item"*) line="${line#"$item"}" ;;
    esac
    printf '%s' "$line"
}
mw_say() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$(mw_strip_item "$2")"; else printf '%b\n' "$(mw_strip_item "$1")"; fi
}
mw_say_err() {
    if [[ "$MW_LANG" == "zh" ]]; then printf '%b\n' "$(mw_strip_item "$2")" >&2; else printf '%b\n' "$(mw_strip_item "$1")" >&2; fi
}
: "${MACWAVE_BRANCH:?MACWAVE_BRANCH is required}"

# ==========================================
# 用户协议闸门
# ==========================================
#
# 为什么闸门在这里，而不是在客户端：判据必须是**目标版本**的协议，而运行中的
# 客户端的 lib/selfupdate.py 属于它自己那一版，常量永远是旧的。2026-11-24 的
# 实测形态：4.5.2 升 4.6.0，跑的是 4.5.2 的 selfupdate.py，读到的是
# ID=2026-11-17 / INTRODUCED_IN=4.4.0，于是「记录里就是这一版」直接放行 ——
# 4.6.0 换成 Apache-2.0 之后重新落款的新协议一次都没被问到。
#
# 本脚本由客户端从**目标分支**拉下来执行，还被 latest.toml 里的
# update_commands_sha256 钉住，常量与本版一致 —— 所以任何年龄的客户端都会在
# 这里被拦一次，而不必等用户升级到「带新常量」的那一版客户端。
#
# 全新安装不问：install.sh 自己在装完前有一道提问（`Have you read and agreed`），
# 两边都问会连问两次。判据是 MACWAVE_CURRENT_VERSION 是否为空 —— install.sh
# 一律传空，selfupdate.sh 传的是本机已装版本。

agreement_config_dir() {
    # 与 config/configpaths.py 同一套规则（系统级优先、其次用户级），外加两条：
    #
    #   1. MACWAVE_TEST 指向测试根时，只认测试根里的那两份 —— 否则测试会去读**真实**
    #      安装的协议记录（2026-11-24：沙箱里明明已经"同意过"，闸门却读到了
    #      /opt/macwave_config 里那份旧记录，于是把无人值守的端到端测试拦了下来）。
    #   2. 优先 `base_dir` 与这次安装目录一致的那份配置。同一台机器上既有系统级又有
    #      用户级安装时，"系统级优先"会读到另一台安装的记录。
    local system user candidate base
    if [ -n "${MACWAVE_TEST:-}" ]; then
        system="$MACWAVE_TEST/opt/macwave_config"
        user="$MACWAVE_TEST${HOME}/.config/macwave_config"
    else
        system="/opt/macwave_config"
        user="$HOME/.config/macwave_config"
    fi

    for candidate in "$system" "$user"; do
        [ -f "$candidate/config.json" ] || continue
        base="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("base_dir", ""))
except Exception:
    pass' "$candidate/config.json" 2>/dev/null || true)"
        if [ -n "$base" ] && [ -n "${MACWAVE_INSTALL_DIR:-}" ] && [ "$base" = "$MACWAVE_INSTALL_DIR" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    if [ -f "$system/config.json" ]; then printf '%s' "$system"; return 0; fi
    if [ -f "$user/config.json" ]; then printf '%s' "$user"; return 0; fi
    if [ "${MACWAVE_NEED_SUDO:-}" = "1" ]; then printf '%s' "$system"; else printf '%s' "$user"; fi
}

agreement_recorded_id() {
    # 与 lib/selfupdate.py 的 recorded_agreement() 读同一个文件、同一种格式。
    [ -f "$1" ] || return 0
    sed -n 's/.*"agreement"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n 1
}

agreement_say_tty() {
    # 静默模式下 fd 1、2 都指向 /dev/null，提示只能直接写终端设备。
    # 没有终端（CI、管道）时什么都不写 —— 退出码是唯一的信号。
    if [[ "$MW_LANG" == "zh" ]]; then
        { printf '%b\n' "$(mw_strip_item "$2")" > /dev/tty; } 2>/dev/null
    else
        { printf '%b\n' "$(mw_strip_item "$1")" > /dev/tty; } 2>/dev/null
    fi
}

agreement_gate() {
    [ -n "$AGREEMENT_ID" ] || return 0
    [ -n "${MACWAVE_CURRENT_VERSION:-}" ] || return 0

    local dir file recorded answer
    dir="$(agreement_config_dir)"
    file="$dir/AGREEMENT.json"
    recorded="$(agreement_recorded_id "$file")"
    [ "$recorded" = "$AGREEMENT_ID" ] && return 0

    mw_say "🌊 MacWave's user agreement has been updated ($AGREEMENT_ID)." \
        "🌊 MacWave 的用户协议已更新（${AGREEMENT_ID}）。"
    mw_say "🌊 Read it here: https://macwave.org/#agreement" \
        "🌊 协议正文：https://macwave.org/#agreement"

    if [ "${MACWAVE_SILENT:-}" = "1" ]; then
        # 静默模式不能替用户同意，也不该挂在读取上等人 —— 按「没有同意」退出。
        agreement_say_tty "🌊 Error: the user agreement ($AGREEMENT_ID) must be accepted, and silent mode cannot accept it." \
            "🌊 错误：需要接受用户协议（${AGREEMENT_ID}），静默模式不能代答。"
        agreement_say_tty "🌊 Next      run wave selfupdate without -s, read it, then accept." \
            "🌊 下一步    不带 -s 再跑一次 wave selfupdate，阅读后接受。"
        return 1
    fi

    mw_say "🌊 Do you accept it? [y/N]" "🌊 你是否接受？[y/N]"
    answer=""
    read -r answer || answer=""
    answer=$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$answer" in
        y|yes) ;;
        *)
            mw_say_err "🌊 Error: the updated user agreement was not accepted; nothing was changed." \
                "🌊 错误：未接受更新后的用户协议，未做任何改动。"
            return 1
            ;;
    esac

    # 记法与 install.sh / lib/selfupdate.py 完全一致，三处读的是同一个文件。
    run mkdir -p "$dir" > /dev/null 2>&1 || true
    if ! printf '{\n  "agreement": "%s"\n}\n' "$AGREEMENT_ID" | run tee "$file" > /dev/null 2>&1; then
        # 记不下来不该让更新失败 —— 代价只是下次再问一遍，比「更新到一半退出」轻。
        mw_say "🌊 Warning: could not record the agreement in $file" \
            "🌊 警告：未能把同意写进 ${file}"
    fi
    run chmod 644 "$file" > /dev/null 2>&1 || true
    mw_say "🌊 Agreement accepted ($AGREEMENT_ID)." "🌊 已接受用户协议（${AGREEMENT_ID}）。"
    return 0
}


VERSION="@@VERSION@@"
BRANCH="@@BRANCH@@"
# 这一版的用户协议标识。由生成器从 lib/selfupdate.py 抄来（那里是唯一来源）。
# 空 = 这一版没带协议信息，闸门自动放行 —— 老 ref 生成的脚本就是这种状态。
AGREEMENT_ID="@@AGREEMENT_ID@@"
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

file_sha256() {
    # 用 openssl 而不是 shasum：install.sh / selfupdate.sh 里验签名已经要用它，
    # 少一个依赖就少一种「某台机器上没有那个命令」的失败。
    openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
}

verify_hash() {
    # verify_hash <仓库内路径> <已下载的文件> <期望哈希>
    #
    # 4.4 是**实验期**：默认只警告，装还是照装。理由是老客户端拿不到这份判断
    # （它们跑的是自己那份老脚本），真正的强制要等客户端版本铺开。开关：
    #   MACWAVE_WANT_HASHES=1   客户端要求校验（由 install.sh / selfupdate.sh 置）
    #   MACWAVE_STRICT_HASHES=1 不符即失败（未来的默认，现在不设）
    local repo_path="$1" file="$2" expect="$3" got
    got="$(file_sha256 "$file")"
    [ -n "$expect" ] || return 0
    [ "$got" = "$expect" ] && return 0

    if [ "${MACWAVE_STRICT_HASHES:-}" = "1" ]; then
        mw_say_err "🌊 Error: $repo_path does not match the signed manifest" \
                   "🌊 错误：$repo_path 与已签名清单不符"
        mw_say_err "🌊   expected $expect" "🌊   期望 $expect"
        mw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
        exit 1
    fi

    mw_say_err "🌊 Warning: $repo_path does not match the signed manifest (continuing)" \
               "🌊 警告：$repo_path 与已签名清单不符（继续安装）"
    mw_say_err "🌊   expected $expect" "🌊   期望 $expect"
    mw_say_err "🌊   got      ${got:-<unreadable>}" "🌊   实际 ${got:-读不到}"
    return 0
}

want() {
    # want <仓库内路径> <是否 +x> [期望的 sha256]
    local repo_path="$1" exec_flag="${2:-0}" expect_sha="${3:-}"
    local destination="$MACWAVE_INSTALL_DIR/$repo_path"
    local url="$MACWAVE_CORE_URL/$MACWAVE_BRANCH/$repo_path"

    if [ "${MACWAVE_SILENT:-}" != "1" ]; then
        mw_say "🌊 Downloading $repo_path..." "🌊 正在下载 ${repo_path}……"
    fi
    if ! fetch "$url" "$destination"; then
        mw_say_err "🌊 Error: cannot download $repo_path" "🌊 错误：无法下载 $repo_path"
        echo "🌊   $(redact_url "$url")" >&2
        # 404 有两种完全不同的原因：单个文件被删了，或者整棵 core/<分支>/ 压根没同步。
        # 后者是新分支上线当天的常态（镜像一天只跑一次），而且症状看起来一模一样 ——
        # 2026-11-19 装 4.4.0 时就被这条绕了：日志里只说某一个文件下不到。
        mw_say_err "🌊 If every file fails like this, the mirror has not synced branch $MACWAVE_BRANCH yet." \
                   "🌊 如果每个文件都这样，说明镜像还没同步 ${MACWAVE_BRANCH} 这个分支。"
        mw_say_err "🌊 Run scripts/mirror-sync/mirror-sync.sh on the mirror (see docs/MIRROR-SETUP.md)." \
                   "🌊 在镜像机上跑 scripts/mirror-sync/mirror-sync.sh（见 docs/MIRROR-SETUP.md）。"
        # 必须 exit 而不是 return：install_fresh / install_delta 是一串裸的
        # `want ...`，没有 `|| exit`，脚本也没有 set -e。用 return 1 的话
        # 调用方不看返回值，于是「有文件没下到」会被当成更新成功，客户端照旧
        # 写 VERSION.json —— 安装树缺文件但版本号已经前进了，这种状态最难查。
        # 2026-10-30 的 4.1.1 就是这样：两个 __pycache__ 路径 404 之后，
        # 那一步仍然打印了 "MacWave has been updated to 4.1.1!"。
        exit 1
    fi
    # 校验放在 chmod 之前：先确认字节对不对，再决定要不要给它执行位
    if [ "${MACWAVE_WANT_HASHES:-}" = "1" ] && [ -n "$expect_sha" ]; then
        verify_hash "$repo_path" "$destination" "$expect_sha"
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
    # 协议闸门在最前面：同意是「做这次更新」的前提，先于任何下载与写入。
    if ! agreement_gate; then
        return 1
    fi

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
        # 两句要合成**一次**调用：mw_say 的第二个参数才是中文。分成两次的话，
        # 英文模式会看到中文那行、中文模式会看到英文那行 —— 2026-11-19 用户报的就是这个。
        mw_say "🌊 The installed tree is incomplete; reinstalling all of MacWave $VERSION" \
            "🌊 安装树不完整，正在重新安装 MacWave ${VERSION} 的全部文件"
        install_fresh || return 1
    else
        mw_say "🌊 Updating MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION" "🌊 正在更新 MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION"
        install_delta || return 1
        # 增量之后再确认一次：delta 只含「上一版 → 本版」的差异，跨版本跳级时
        # 会漏掉中间那些版本改过的文件。补全比报错好 —— 用户什么也没做错。
        if ! tree_complete; then
            mw_say "🌊 Some files are still missing after the update; fetching all of MacWave $VERSION" \
                "🌊 更新后仍有文件缺失，正在补齐 MacWave ${VERSION} 的全部文件"
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

    # 4.7：状态搬进树内 <base>/var/，旧的外部配置目录（4.6 及更早）在这里清掉。
    #
    # **必须放在所有文件都到位之后**：mq_migrate_legacy_config 只在
    # var/config.sh 已经存在时才动手，否则删掉旧配置就等于把这棵树的位置信息
    # 一起删了 —— 客户端下次 wave selfupdate 会报「没装」。
    #
    # 这一路是 4.6 → 4.7 唯一能跑到的新代码：旧客户端的 lib/selfupdate.sh 不认得
    # var/，所以安装器里那两处（install.sh / selfupdate.sh）覆盖不到这次升级。
    #
    # 顺序也要留意：改这一行之前先确认它仍在 `want` 清单下载完成之后。
    mq_migrate_legacy_config || true

    return 0
}

main "$@"
