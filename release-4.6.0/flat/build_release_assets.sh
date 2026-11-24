#!/bin/bash

# build_release_assets.sh
# 铺一次发版要上传的资产集，并生成 SHA256SUMS。
#
# 用法：
#   bash scripts/build_release_assets.sh 4.6.0            # 只铺 + 清单
#   bash scripts/build_release_assets.sh 4.6.0 --sign     # 顺便用 gpg 签清单
#
# 产出 release-<版本>/ ：
#   flat/                          该 tag 下每个 .py / .sh（扁平）+ PROJECT_CONTEXT.md
#   macwave-<版本>-archive.tar   整棵源码树，顶层目录 macwave-<版本>/
#   macwave-<版本>-archive.tar.gz
#   SHA256SUMS                     上面每个文件的 SHA-256
#   SHA256SUMS.asc                 （--sign 时）
#
# 三个坑是写这个脚本的理由：
#   1. **`gh release` 的资产名只有 basename，没有路径。** 两个不同目录里的同名文件
#      （`lib/selfupdate.sh` 与 `scripts/selfupdate.sh`、`archive/` 里那份副本）
#      会让上传在中途 422 `ReleaseAsset.name already exists`，而 Release 不会建出来。
#      所以这里拍平、给重名加目录前缀，并在上传前再自检一次。
#   2. **清单必须在提交之后生成**：清单取自 git 树，未提交的新文件会被漏掉
#      （4.6.0 第一次生成时 License/NOTICE 就不在里面）。这里用 git archive 同一个
#      提交，天然一致。
#   3. **签完名不能改清单**：所以 --sign 排在生成清单之后，且提示任何改动都要重签。

set -eu

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

VERSION="${1:-}"
SIGN=0
[[ "${2:-}" == "--sign" ]] && SIGN=1

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED_BOLD}🌊 Error: usage: bash scripts/build_release_assets.sh <x.y.z> [--sign]${RESET}" >&2
    exit 1
fi

OUT="release-${VERSION}"
COMPONENTS=(cli config lib net pkg surfboard scripts)

echo -e "${GREEN}🌊 Building assets for ${VERSION} in ${OUT}/${RESET}"

# 未提交的改动会让「清单」与「实际上传的字节」说的不是一回事
if [[ -n "$(git status --porcelain)" ]]; then
    echo -e "${YELLOW}🌊 Warning: working tree is dirty; the archive is built from HEAD,"
    echo -e "🌊          so uncommitted files will NOT be in it.${RESET}"
fi

rm -rf "$OUT"
mkdir -p "$OUT/flat"

# -------------------- flat/ --------------------

copied=0
for dir in "${COMPONENTS[@]}"; do
    for file in "$dir"/*.py "$dir"/*.sh; do
        [[ -e "$file" ]] || continue
        base="$(basename "$file")"
        # 重名加目录前缀 —— gh 的资产名只有 basename，撞名会在上传中途 422
        if [[ -e "$OUT/flat/$base" ]]; then
            base="${dir}_${base}"
        fi
        if [[ -e "$OUT/flat/$base" ]]; then
            echo -e "${RED_BOLD}🌊 Error: two files both map to ${base}${RESET}" >&2
            exit 1
        fi
        cp "$file" "$OUT/flat/$base"
        copied=$((copied + 1))
    done
done

# 给人读的那份也进 flat/（不要另建 archive/：里面那份 selfupdate.sh 会和 flat 撞名）
# MacWave 把它放在 docs/ 下；LinuxWave 在仓库根 —— 这一行是两边唯一的路径差异。
cp docs/PROJECT_CONTEXT.md "$OUT/flat/PROJECT_CONTEXT.md"

# -------------------- 源码树归档 --------------------

git archive --prefix="macwave-${VERSION}/" -o "$OUT/macwave-${VERSION}-archive.tar" HEAD
gzip -kf "$OUT/macwave-${VERSION}-archive.tar"

# -------------------- 清单 --------------------

( cd "$OUT" && shasum -a 256 flat/* ./*.tar ./*.tar.gz > SHA256SUMS )

# 上传前自检：资产名（basename）不许有重复
DUPLICATES="$(find "$OUT" -type f -exec basename {} \; | sort | uniq -d)"
if [[ -n "$DUPLICATES" ]]; then
    echo -e "${RED_BOLD}🌊 Error: duplicate asset names would break gh release create:${RESET}" >&2
    printf '%s\n' "$DUPLICATES" >&2
    exit 1
fi

echo -e "${GREEN}🌊 flat: ${copied} file(s) + PROJECT_CONTEXT.md${RESET}"
echo -e "${GREEN}🌊 SHA256SUMS: $(wc -l < "$OUT/SHA256SUMS" | tr -d ' ') entr(ies)${RESET}"

# -------------------- 签名（可选） --------------------

if [[ "$SIGN" -eq 1 ]]; then
    gpg --armor --detach-sign -o "$OUT/SHA256SUMS.asc" "$OUT/SHA256SUMS"
    gpg --verify "$OUT/SHA256SUMS.asc" "$OUT/SHA256SUMS"
    echo -e "${GREEN}🌊 Signed: ${OUT}/SHA256SUMS.asc${RESET}"
fi

echo
echo -e "${YELLOW}🌊 Next:${RESET}"
if [[ "$SIGN" -eq 0 ]]; then
    echo "    gpg --armor --detach-sign -o ${OUT}/SHA256SUMS.asc ${OUT}/SHA256SUMS"
    echo -e "${YELLOW}🌊   (any change to the files below means re-signing)${RESET}"
fi
cat <<EOF
    files=\$(find ${OUT} -type f | sort)
    gh release create v${VERSION} --repo MacWaveOrg/MacWave \\
      --verify-tag --title "MacWave ${VERSION}" \\
      --notes-file docs/RELEASE-${VERSION}.md \$files
EOF
