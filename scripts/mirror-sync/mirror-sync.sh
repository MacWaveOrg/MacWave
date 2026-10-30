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

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

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
        *) echo "未知参数：${arg}（可用：--dry-run / --no-payloads）"; exit 2 ;;
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

# -------------------- 小工具 --------------------

# toml_value 文件 键 —— 读平铺的 key = "value"。读不到返回非零。
#
# 用 while read 在 bash 里逐行匹配，不用 `| grep | head -1`：后者在 pipefail 下
# 会因为 head 提前退出让管道返回 141（SIGPIPE），「拿到了值却算失败」极难查。
toml_value() {
    local file=$1 key=$2 line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line; do
        line=${line%%#*}
        if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$file"
    return 1
}

# sha256_of 文件 —— Linux 用 sha256sum，macOS 用 shasum（本地演练会用到）
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}


# -------------------- 防重入 --------------------

mkdir -p "$SRC" || { say "❌ 建不了工作区 $SRC"; exit 1; }
LOCK="$SRC/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    say "另一轮同步正在进行（${LOCK}），本次跳过"
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

say "第 1/6 步 · 取同步工具与当前发布线"

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
say "第 2/6 步 · 同步三棵主干"
tree infosource infosource main "$DEST/infosource"
tree selfupdate Selfupdate main "$DEST/selfupdate"
# pythondata/<版本>/*.tar.gz 是自带解释器的产物，仓库里没有（二进制不进 git），
# 由下一步单独补。这里不排除的话，--delete 会先把它删掉，镜像就装不了解释器。
tree python     Python     main "$DEST/python" '*.tar.gz' 

hr
say "第 3/6 步 · 同步 core 分支（客户端拼的是 <CORE>/<分支>/…）"
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
say "第 4/6 步 · 补齐自带解释器的压缩包"

# python_url.toml 记的是**上游**地址，而客户端默认从镜像的
#   <PYTHON>/pythondata/<版本>/<文件名>
# 取那份字节（见 lib/domains.py 的 python_archive_url）。仓库里只有 toml、没有二进制，
# 所以这一步必须由镜像自己做，否则装不了自带解释器。
#
# 两个架构都补，与这台机器是什么架构无关 —— 镜像要同时服务两种 Mac。
python_arch() {   # python_arch 版本 架构前缀 toml 路径
    local version=$1 arch=$2 toml=$3 dest url sha name
    if [[ ! -f "$toml" ]]; then
        no "python-${arch}" "缺 ${toml}"
        return 1
    fi
    url=$(toml_value "$toml" "${arch}_url")
    sha=$(toml_value "$toml" "${arch}_sha256")
    if [[ -z "$url" || -z "$sha" ]]; then
        no "python-${arch}" "python_url.toml 里缺 ${arch}_url / ${arch}_sha256"
        return 1
    fi

    name=${url##*/}
    dest="$DEST/python/pythondata/${version}/${name}"

    if [[ -f "$dest" ]]; then
        if [[ "$(sha256_of "$dest")" == "$sha" ]]; then
            ok "python-${arch}" "${name}（已存在）"
            return 0
        fi
        note "python-${arch} 本地这份校验不符，重下"
    fi

    if (( DRY_RUN )); then
        note "python-${arch} 将要下载 ${name}"
        return 0
    fi

    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 1800 -o "${dest}.part" "$url"; then
        rm -f "${dest}.part"
        no "python-${arch}" "下载失败：${url}"
        return 1
    fi
    if [[ "$(sha256_of "${dest}.part")" != "$sha" ]]; then
        rm -f "${dest}.part"
        no "python-${arch}" "sha256 不符，已丢弃（不把验不过的文件留在镜像里）"
        return 1
    fi
    mv "${dest}.part" "$dest"
    ok "python-${arch}" "${name}（$(wc -c < "$dest" | tr -d ' ') 字节）"
    return 0
}

# 演练模式不落地任何文件，站点上还没有这份 toml 时退回到工作区里的克隆去读 ——
# 否则「演练」恰恰问不出它最该回答的问题：这两个压缩包缺不缺。
PY_DATA="$DEST/python/pythondata"
if [[ ! -f "$PY_DATA/latest.toml" && -f "$SRC/python/pythondata/latest.toml" ]]; then
    PY_DATA="$SRC/python/pythondata"
fi

PY_VERSION=""
if [[ -f "$PY_DATA/latest.toml" ]]; then
    PY_VERSION=$(toml_value "$PY_DATA/latest.toml" version)
fi

if [[ -z "$PY_VERSION" ]]; then
    no "python" "读不到 pythondata/latest.toml 里的 version"
    note "第一次演练时站点上还没有这棵树，真跑会先去同步它"
else
    note "当前解释器版本 ${PY_VERSION}"
    python_arch "$PY_VERSION" arm64 "$PY_DATA/${PY_VERSION}/python_url.toml" || FAIL=$((FAIL+1))
    python_arch "$PY_VERSION" amd64 "$PY_DATA/${PY_VERSION}/python_url.toml" || FAIL=$((FAIL+1))
fi

hr
say "第 5/6 步 · 补齐产物（bottle / deps）"
if (( DRY_RUN )); then
    note "演练模式：跳过（真跑时从 $ORG/Bottle、$ORG/Deps 的 Release 取，逐字节校验 sha256）"
elif (( NO_PAYLOADS )); then
    note "按要求跳过（--no-payloads）"
elif [[ ! -d "$DEST/bottle" ]]; then
    no "产物" "目标目录不存在：$DEST/bottle"
else
    # 只增不删：上游删掉一个旧包时，镜像里已有的文件不该跟着消失 ——
    # 客户端的索引缓存可能还指向它。
    # 索引里有几条**故意做坏**的记录（缺 sha256、校验值不符、上游 404），
    # 它们是负向测试夹具，本来就取不到。名单与 CI 共用同一份文件，免得两边走散：
    # 不跳过的话每次同步都会报同样的失败，真正的故障反而被淹没。
    #
    # 先找脚本旁边那份（运维部署时一起传上来），再找工具克隆里的那份 ——
    # 后者要等改动进了 main 才有，而镜像不该等一次合并才能正确工作。
    skip=""
    for candidate in "$SCRIPT_DIR/known-bad-records.txt" \
                     "$SRC/tools/scripts/known-bad-records.txt"; do
        if [[ -f "$candidate" ]]; then
            skip=$(tr '\n' ',' < "$candidate")
            break
        fi
    done
    if [[ -z "$skip" ]]; then
        note "没找到 known-bad-records.txt，坏记录会照常报错"
    fi

    out=$(python3 "$SRC/tools/scripts/sync_payloads.py" \
            --infosource "$DEST/infosource" \
            --out "$DEST" \
            --source payload \
            --skip "$skip" \
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
say "第 6/6 步 · 重建 versions 清单"
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
