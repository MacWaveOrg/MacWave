#!/bin/bash
# 镜像站同步：在服务器上把 MacWave/ 对齐到上游
#
# 五类东西来源不同，不能一把梭：
#   infosource / core/<分支> / selfupdate / python  ← git 分支
#   bottle / deps                                   ← 我们自己的 Release（不碰上游）
# 同步完还要重建 versions 清单 —— 客户端「列出版本」全靠它，漏了会表现为「没有版本可装」。
#
# 用法：
#   bash mirror-sync.sh --dry-run    只报告会做什么，不写任何文件
#   bash mirror-sync.sh --no-payloads  只同步 git 树与清单，不碰产物（快）
#   bash mirror-sync.sh              全量同步
#
# 环境变量（都有默认值，正常不用设）：
#   ROOT            站点根目录
#   SRC             工作区（浅克隆与锁都在这里）
#   KEEP_BRANCHES   除当前发布线外额外保留的 core 分支
#   JOBS            产物并发下载数
#   OWNER           站点属主，默认 www:www
#   GH / ORG        上游地址（本地演练时改成 file:// 假仓库）
#
# 退出码：0 全部成功；1 有任何一步失败（cron 包装据此写 ALERT）

set -uo pipefail

ROOT=${ROOT:-/www/wwwroot/mirror.repohub.top}
DEST=$ROOT/MacWave
SRC=${SRC:-/root/mirror-src}
GH=${GH:-https://github.com}
ORG=${ORG:-MacWaveOrg}
KEEP_BRANCHES=${KEEP_BRANCHES-4.0}
JOBS=${JOBS:-4}
OWNER=${OWNER:-www:www}

DRY_RUN=0
NO_PAYLOADS=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=1 ;;
        --no-payloads) NO_PAYLOADS=1 ;;
        *) echo "未知参数：$arg（可用：--dry-run / --no-payloads）"; exit 2 ;;
    esac
done

FAIL=0

# 产物要从「我们自己的 Release」取，地址由 domains.py 的内置默认值决定。
# 若这台机器的环境里残留了 MACWAVE_*_DOMAIN，路径会被改到别处（甚至指回自己），
# 那就成了「从镜像同步镜像」。这里显式清掉。
unset MACWAVE_API_DOMAIN MACWAVE_BOTTLE_DOMAIN MACWAVE_DEPS_DOMAIN \
      MACWAVE_CORE_DOMAIN MACWAVE_SELFUPDATE_DOMAIN MACWAVE_PYTHON_DOMAIN \
      MACWAVE_SOURCECODE_DOMAIN MACWAVE_PIP_INDEX

hr()   { printf '%s\n' "------------------------------------------------------------"; }
ok()   { printf '  ✅ %-44s %s\n' "$1" "${2:-}"; }
no()   { FAIL=$((FAIL+1)); printf '  ❌ %-44s %s\n' "$1" "${2:-}"; }
note() { printf '  ·  %s\n' "$*"; }
say()  { printf '%s\n' "$*"; }

# -------------------- 防重入 --------------------

mkdir -p "$SRC" || { say "❌ 建不了工作区 $SRC"; exit 1; }
LOCK="$SRC/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    say "另一轮同步正在进行（$LOCK），本次跳过"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# -------------------- 取一份干净的源码 --------------------

# git_update 名称 仓库 引用 —— 克隆或就地更新到该引用的最新提交
#
# 用 fetch + reset 而不是 pull：浅克隆上 pull 遇到分支切换会失败，
# 而 reset --hard FETCH_HEAD 对「换引用」与「快进」是同一种写法。
git_update() {
    local key=$1 repo=$2 ref=$3
    local dir="$SRC/$key" url="$GH/$ORG/$repo"

    if [[ ! -d "$dir/.git" ]]; then
        rm -rf "$dir"
        git clone --quiet --depth 1 --branch "$ref" "$url" "$dir" >/dev/null 2>&1
        [[ -d "$dir/.git" ]] || return 1
    else
        # 克隆里记着当初的 remote 地址；GH/ORG 变了要跟着改，否则改了两处地址还在fetch旧的
        git -C "$dir" remote set-url origin "$url" >/dev/null 2>&1
        git -C "$dir" fetch --quiet --depth 1 origin "$ref" >/dev/null 2>&1 || return 1
        git -C "$dir" reset --quiet --hard FETCH_HEAD >/dev/null 2>&1 || return 1
        git -C "$dir" clean -qxdf >/dev/null 2>&1 || return 1
    fi
    return 0
}

# publish 目录 目标 [额外排除] —— 把一棵树铺到站点上
publish() {
    local dir=$1 dest=$2 exclude=${3:-}
    local args=(-a --partial)

    # versions 由第 5 步生成，上游没有 —— 不排除就会被 --delete 删掉
    args+=(--exclude versions --exclude .git)
    [[ -n "$exclude" ]] && args+=(--exclude "$exclude")

    mkdir -p "$dest" || return 1
    rsync "${args[@]}" --delete "$dir/" "$dest/"
}

# tree 名称 仓库 引用 目标 [额外排除]
tree() {
    local key=$1 repo=$2 ref=$3 dest=$4 exclude=${5:-}

    if (( DRY_RUN )); then
        local want
        want=$(git ls-remote "$GH/$ORG/$repo" "$ref" 2>/dev/null | awk 'NR==1{print substr($1,1,8)}')
        if [[ -z "$want" ]]; then
            no "$key" "上游 $repo 的 $ref 取不到"
            return 1
        fi
        ok "$key" "上游 $ref @ ${want}"
        return 0
    fi

    if ! git_update "$key" "$repo" "$ref"; then
        no "$key" "$repo 的 $ref 更新失败"
        return 1
    fi
    if ! publish "$SRC/$key" "$dest" "$exclude"; then
        no "$key" "rsync 到 $dest 失败"
        return 1
    fi
    ok "$key" "$(find "$dest" -type f | wc -l | tr -d ' ') 个文件"
    return 0
}

# -------------------- 主流程 --------------------

say "镜像同步 · MacWave"
say "  站点根目录 $ROOT"
say "  工作区     $SRC"
(( DRY_RUN )) && say "  模式       演练（不写文件）"
hr

say "第 1/5 步 · 取同步工具与当前发布线"

if (( DRY_RUN )); then
    note "演练模式：跳过工具克隆"
else
    if git_update tools MacWave main; then
        ok "同步工具" "$SRC/tools"
    else
        no "同步工具" "取不到 MacWave 仓库，后面都做不了"
        hr; say "❌ 中止：拿不到工具就没有可信的命名规则"; exit 1
    fi
fi

CUR=""
if (( DRY_RUN )); then
    tmp=$(mktemp -d)
    git clone --quiet --depth 1 "$GH/$ORG/configdata" "$tmp/c" >/dev/null 2>&1
    CUR=$(awk -F'"' '/^branch:/{print $2; exit}' "$tmp/c/versiondata/latest_version" 2>/dev/null)
    rm -rf "$tmp"
else
    if git_update configdata configdata main; then
        CUR=$(awk -F'"' '/^branch:/{print $2; exit}' \
              "$SRC/configdata/versiondata/latest_version" 2>/dev/null)
    fi
fi

if [[ -z "$CUR" ]]; then
    no "当前发布线" "读不到 configdata 的 versiondata/latest_version 里的 branch"
    hr; say "❌ 中止：不知道要同步哪个 core 分支"; exit 1
fi
# 当前发布线若是 KEEP_BRANCHES 里的一员（刚发版时的常态），别同步两遍
BRANCHES="$CUR"
for b in $KEEP_BRANCHES; do
    [[ "$b" == "$CUR" ]] && continue
    BRANCHES="$BRANCHES $b"
done
note "当前发布线 ${CUR}，额外保留 ${KEEP_BRANCHES:-（无）}"

hr
say "第 2/5 步 · 同步三棵主干"
tree infosource infosource main "$DEST/infosource"
tree selfupdate Selfupdate main "$DEST/selfupdate"
tree python     Python     main "$DEST/python"

hr
say "第 3/5 步 · 同步 core 分支（客户端拼的是 <CORE>/<分支>/…）"
CORE_OK=1
for b in $BRANCHES; do
    tree "core-$b" MacWave "$b" "$DEST/core/$b" || CORE_OK=0
done

# 发布线会换，旧分支目录会一直留着 —— 那是「镜像仍在服务一个已下线的版本」。
# 只保留当前发布线 + KEEP_BRANCHES。
#
# 但只要有一个分支没同步成功就不清理：发布线刚切到 4.5、而 4.5 还没建分支时，
# 清理会把仍在服务的 4.1 删掉 —— 一次上游打嗝变成镜像全站不可用。
if (( ! DRY_RUN && CORE_OK )) && [[ -d "$DEST/core" ]]; then
    for d in "$DEST/core"/*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")
        keep=0
        for b in $BRANCHES; do [[ "$b" == "$name" ]] && keep=1; done
        if (( keep == 0 )); then
            rm -rf "$d"
            note "删除下线的分支目录 core/$name"
        fi
    done
elif (( ! DRY_RUN )) && (( ! CORE_OK )); then
    note "有 core 分支没同步成功，跳过清理（避免删掉仍在服务的分支）"
fi

hr
say "第 4/5 步 · 补齐产物（bottle / deps）"
if (( DRY_RUN )); then
    note "演练模式：跳过（真跑时从 $ORG/Bottle、$ORG/Deps 的 Release 取，逐字节校验 sha256）"
elif (( NO_PAYLOADS )); then
    note "按要求跳过（--no-payloads）"
elif [[ ! -d "$DEST/bottle" ]]; then
    no "产物" "目标目录不存在：$DEST/bottle"
else
    # 只增不删：上游删掉一个旧包时，镜像里已有的文件不该跟着消失 ——
    # 客户端的索引缓存可能还指向它。
    out=$(python3 "$SRC/tools/scripts/sync_payloads.py" \
            --infosource "$DEST/infosource" \
            --out "$DEST" \
            --source payload \
            --jobs "$JOBS" 2>&1)
    rc=$?
    say "$out" | tail -6
    if (( rc == 0 )); then
        ok "产物" "$(find "$DEST/bottle" "$DEST/deps" -type f 2>/dev/null | wc -l | tr -d ' ') 个文件"
    else
        no "产物" "有失败项，见上（已存在的文件不受影响）"
    fi
fi

hr
say "第 5/5 步 · 重建 versions 清单"
if (( DRY_RUN )); then
    note "演练模式：跳过"
else
    out=$(python3 "$SRC/tools/scripts/build_versions_index.py" \
            --infosource "$DEST/infosource" \
            --mirror "$DEST" 2>&1)
    rc=$?
    say "$out" | tail -4
    if (( rc == 0 )); then
        ok "清单" "$(find "$DEST/infosource" -name versions -type f | wc -l | tr -d ' ') 个"
    else
        no "清单" "重建失败 —— 客户端会表现为「没有版本可装」"
    fi
    # 索引仓库自带的 .git 不该留在站点根下
    rm -rf "$DEST/infosource/.git"
fi

hr
if (( ! DRY_RUN )); then
    if chown -R "$OWNER" "$DEST" 2>/dev/null; then
        ok "属主" "$OWNER"
    else
        no "属主" "chown 失败（nginx 可能读不到新文件）"
    fi
fi

hr
if (( FAIL > 0 )); then
    say "❌ $FAIL 项失败"
    exit 1
fi
say "✅ 同步完成"
exit 0
