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
#   MACWAVE_SILENT           1 = 少打印
#   MACWAVE_DRY_RUN          1 = 只报告将要做什么，不落盘
#
# 约定：
#   - 任何一步失败都要 exit 非零；客户端据此判定「什么都没更新」，不写 VERSION.json
#   - 必须幂等：重跑一次不能把已经就位的东西弄坏

set -u

: "${MACWAVE_INSTALL_DIR:?MACWAVE_INSTALL_DIR is required}"
: "${MACWAVE_CORE_URL:?MACWAVE_CORE_URL is required}"
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

fetch() {
    # fetch <url> <目标>：先写 .macwave-part 再 mv，重试期间目标位置不会出现半个文件
    local url="$1" destination="$2" attempt status partial
    partial="$destination.macwave-part"

    run mkdir -p "$(dirname "$destination")"
    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        status=0
        run curl -fsSL --max-time "$FILE_TIMEOUT" -o "$partial" "$url" || status=$?
        if [ "$status" -eq 0 ]; then
            run mv -f "$partial" "$destination"
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
        echo "would fetch $repo_path"
        return 0
    fi

    if [ "${MACWAVE_SILENT:-}" != "1" ]; then
        echo "🌊 Downloading $repo_path..."
    fi
    if ! fetch "$url" "$destination"; then
        echo "🌊 Error: cannot download $repo_path" >&2
        echo "🌊   $url" >&2
        return 1
    fi
    if [ "$exec_flag" = "1" ]; then
        run chmod +x "$destination"
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
        echo "🌊 Already at $VERSION; nothing to download."
        return 0
    fi

    if [ -f "$MACWAVE_INSTALL_DIR/lib/wave.py" ]; then
        echo "🌊 Updating MacWave ${MACWAVE_CURRENT_VERSION:-unknown} -> $VERSION"
        install_delta || return 1
    else
        echo "🌊 Installing MacWave $VERSION"
        install_fresh || return 1
    fi

    # ── 目录结构变更的迁移写在这里 ──
    # 本版本没有变更，所以这段是空的。需要时按下面的形状追加：
    #   按 ${MACWAVE_CURRENT_VERSION} 判断是否早于分界版本，再搬迁、改路径。
    # 约束与以前一样：以当前用户身份执行，需要管理员权限时自己 sudo，
    # 失败要 exit 非零，且必须幂等。

    return 0
}

main "$@"
