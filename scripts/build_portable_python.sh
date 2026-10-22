#!/bin/bash

# build_portable_python.sh
#
# 打出一个可以随 MacWave 分发的便携 CPython，并给出写进
# configdata/pythondata/latest_python 用的 sha256。
#
# 为什么需要它：MacWave 的入口是一个 sh 启动器，默认使用**自带的**解释器，
# 这样用户机器上的 python3 由谁接管（Homebrew / pyenv / 系统自带）都不影响运行。
# 自带解释器本身必须来自一个可重复、可校验的来源，而不是"随便从网上下一个"。
#
# 用法：
#   bash scripts/build_portable_python.sh                 # 打包本机架构
#   bash scripts/build_portable_python.sh --arch arm64    # 指定架构
#   bash scripts/build_portable_python.sh --version 3.14.13 --output dist
#
# 产物：
#   dist/python-<version>-<arch>.tar.gz
#   dist/python-<version>-<arch>.tar.gz.sha256
#
# 然后把 version / <arch>_url / <arch>_sha256 写进 configdata 的
# pythondata/latest_python，并把压缩包作为某个 release 的附件上传。
#
# 注意：这个脚本需要联网（下载上游构建）。CI 里跑，不要在受限网络下手动跑。

set -euo pipefail

RED_BOLD='\033[1;31m'
GREEN='\032[32m'
YELLOW='\033[33m'
RESET='\033[0m'

UPSTREAM_REPO="astral-sh/python-build-standalone"
PY_VERSION="3.14.13"
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
