#!/bin/bash

# build_portable_python.sh
#
# 可选：把上游的 install_only 产物重新打成 MacWave 自己的归档，并给出写进
# configdata/pythondata/latest_python 用的 sha256。
#
# **主路径不是这个脚本。** install.sh / selfupdate.sh 的 portable_python_binary 已经能
# 直接在 python/install/bin/python3 找到解释器，也就是上游 install_only 解压后的布局，
# 所以 pythondata 直接指向上游 release 资产即可，由 .github/workflows/portable-python.yml
# 解析地址、下载、自己算 sha256 并开 PR。少一次几十 MB 的搬运，也少一个托管位置。
#
# 这个脚本保留给两种情形：上游归档不可达、需要一个自己的镜像；或者要打一个上游没有的
# 组合（例如把某个版本裁剪到只留标准库的一部分）。
#
# 用法：
#   bash scripts/build_portable_python.sh                 # 打包本机架构
#   bash scripts/build_portable_python.sh --arch arm64    # 指定架构
#   bash scripts/build_portable_python.sh --version 3.14.9 --output dist
#
# 产物：
#   dist/python-<version>-<arch>.tar.gz
#   dist/python-<version>-<arch>.tar.gz.sha256
#
# 然后把 <arch>_url 指向这个归档的下载地址（例如某个 release 附件），
# <arch>_sha256 填 .sha256 文件里的值。
#
# 注意：这个脚本需要联网（下载上游构建），而且要跨架构打包时必须在对应架构的机器上
# 跑（它会在最后真的执行一次解释器来确认可用）。CI 里跑，不要在受限网络下手动跑。

set -euo pipefail

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

UPSTREAM_REPO="astral-sh/python-build-standalone"
PY_VERSION="3.14.9"
ARCH=""
OUTPUT_DIR="dist"

usage() {
    sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)     ARCH="${2:-}"; shift 2 ;;
        --version)  PY_VERSION="${2:-}"; shift 2 ;;
        --output)   OUTPUT_DIR="${2:-}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "🌊 Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$ARCH" ]]; then
    case "$(uname -m)" in
        arm64|aarch64) ARCH="arm64" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *) echo -e "${RED_BOLD}🌊 Error: unsupported machine: $(uname -m)${RESET}" >&2; exit 1 ;;
    esac
fi

case "$ARCH" in
    arm64) TRIPLE="aarch64-apple-darwin" ;;
    amd64) TRIPLE="x86_64-apple-darwin" ;;
    *) echo -e "${RED_BOLD}🌊 Error: unsupported arch: $ARCH${RESET}" >&2; exit 1 ;;
esac

WORK="$(mktemp -d -t macwave-pybuild)"
trap 'rm -rf "$WORK"' EXIT

API="https://api.github.com/repos/${UPSTREAM_REPO}/releases"

echo "🌊 Looking for a ${PY_VERSION} install_only build for ${TRIPLE}..."

# 上游把产物按 tag 发布（例如 20261014）；这里取最近的几个 release 逐个找一个匹配的。
ASSET_URL=""
while IFS= read -r tag; do
    url="${API}/tags/${tag}"
    candidate="$(curl -fsSL --max-time 60 "$url" 2>/dev/null \
        | grep -o '"browser_download_url":[[:space:]]*"[^"]*"' \
        | sed 's/.*"\(https[^"]*\)"/\1/' \
        | grep -F "cpython-${PY_VERSION}" \
        | grep -F "${TRIPLE}-install_only" \
        | grep -v "stripped" \
        | head -n 1)"
    if [[ -n "$candidate" ]]; then
        ASSET_URL="$candidate"
        break
    fi
done < <(curl -fsSL --max-time 60 "${API}?per_page=10" 2>/dev/null \
    | grep -o '"tag_name":[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')

if [[ -z "$ASSET_URL" ]]; then
    echo -e "${RED_BOLD}🌊 Error: no install_only asset found for ${PY_VERSION} / ${TRIPLE}.${RESET}" >&2
    echo "🌊 Check https://github.com/${UPSTREAM_REPO}/releases for available versions." >&2
    exit 1
fi

echo "🌊 Downloading: $ASSET_URL"
mkdir -p "$WORK/src"
curl -fsSL --max-time 1800 -o "$WORK/src.tar.gz" "$ASSET_URL"

echo "🌊 Extracting..."
tar -xzf "$WORK/src.tar.gz" -C "$WORK/src"

# 上游产物形如 cpython-<version>+<tag>-<triple>-install_only/install/bin/python3
PY_BIN="$(find "$WORK/src" -maxdepth 4 -type f -name 'python3' -perm -u+x 2>/dev/null | head -n 1)"
if [[ -z "$PY_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: the extracted archive has no python3 binary.${RESET}" >&2
    exit 1
fi
ROOT="$(cd "$(dirname "$PY_BIN")/.." && pwd)"          # .../install
if [[ "$(basename "$ROOT")" == "install" ]]; then
    ROOT="$(dirname "$ROOT")"
fi

echo "🌊 Verifying the interpreter runs standalone..."
"$PY_BIN" -c 'import sys; print("   ", sys.version.split()[0], sys.executable)'

# 重新打包：只保留 install/ 这一层，去掉上游的版本目录名，便于解压后直接定位。
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$ROOT"/. "$STAGE"/

mkdir -p "$OUTPUT_DIR"
NAME="python-${PY_VERSION}-${ARCH}.tar.gz"
OUT="$OUTPUT_DIR/$NAME"

echo "🌊 Packing..."
tar -czf "$OUT" -C "$STAGE" .

SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$NAME" > "$OUT.sha256"

SIZE="$(du -h "$OUT" | awk '{print $1}')"
echo ""
echo -e "${GREEN}🌊 Built: $OUT ($SIZE)${RESET}"
echo "🌊 sha256: $SHA"
echo ""
echo "🌊 Add to configdata/pythondata/latest_python:"
echo "   version: \"${PY_VERSION}\""
echo "   ${ARCH}_url: \"<release asset URL>\""
echo "   ${ARCH}_sha256: \"${SHA}\""
