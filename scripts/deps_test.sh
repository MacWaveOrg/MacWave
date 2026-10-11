#!/bin/bash

# deps_test.sh
# 端到端依赖回归：装一个带依赖链的包 → 运行二进制 → 确认没有未解析的库引用
# → 检查引用计数标记 → 卸载 → 确认依赖目录与软链接都被级联清理
#
# 用法：
#   bash scripts/deps_test.sh                         # 全量：infosource 里所有声明了 deps 的包
#   bash scripts/deps_test.sh wget@1.25.0 tmux@3.6     # 只测指定的包
#   bash scripts/deps_test.sh --infosource <目录>      # 指定 infosource 检出目录
#
# 全量模式下每个包各取最高版本，一个包失败不会中断其余的，最后统一汇总。

set -o pipefail

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_BIN="$REPO_DIR/lib/wave.py"

INFOSOURCE_DIR=""
PKGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --infosource)   INFOSOURCE_DIR="$2"; shift 2 ;;
        --infosource=*) INFOSOURCE_DIR="${1#*=}"; shift ;;
        *)              PKGS+=("$1"); shift ;;
    esac
done

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

# 配置目录：系统级优先，其次用户级
if [[ -f /opt/macwave_config/config.json ]]; then
    CONFIG_FILE="/opt/macwave_config/config.json"
elif [[ -f "$HOME/.config/macwave_config/config.json" ]]; then
    CONFIG_FILE="$HOME/.config/macwave_config/config.json"
else
    echo -e "${RED_BOLD}🌊 Error: MacWave not installed (config not found).${RESET}"
    exit 1
fi

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")
BIN_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"
DEPS_DIR="$BASE_DIR/deps"

FAILED=0
CASE_FAILED=0
PASSED=0

# ==========================================
# 目标包清单
# ==========================================

discover_pkgs() {
    # 扫 infosource 的 pkginfo_<arch>，输出「包名@最高版本 bin_name」，
    # 只有声明了 deps: 的包才算「带依赖链」。test_* 是测试夹具，不进池子。
    python3 - "$1" <<'PY'
import pathlib
import platform
import re
import sys

root = pathlib.Path(sys.argv[1])
machine = platform.machine().lower()
arch = "arm64" if machine in ("arm64", "aarch64") else "amd64"
pkg_root = root / "pkg" / f"pkginfo_{arch}"
if not pkg_root.is_dir():
    sys.exit(0)


def version_key(version):
    parts = [int(part) for part in re.findall(r"\d+", version)]
    return parts + [0] * (4 - len(parts))


for pkg_dir in sorted(pkg_root.iterdir()):
    if not pkg_dir.is_dir() or pkg_dir.name.startswith("test"):
        continue

    bin_name = pkg_dir.name
    versions = []
    for entry in pkg_dir.iterdir():
        if entry.name.endswith("@common"):
            match = re.search(r'bin_name:\s*"([^"]+)"', entry.read_text(errors="ignore"))
            if match:
                bin_name = match.group(1)
            continue
        if "@" not in entry.name:
            continue
        if re.search(r"^deps:", entry.read_text(errors="ignore"), re.M):
            versions.append(entry.name.split("@", 1)[1])

    if versions:
        print(f"{pkg_dir.name}@{max(versions, key=version_key)} {bin_name}")
PY
}

TARGETS=()
if [[ ${#PKGS[@]} -gt 0 ]]; then
    for pkg in "${PKGS[@]}"; do
        TARGETS+=("$pkg ${pkg%@*}")
    done
elif [[ -n "$INFOSOURCE_DIR" && -d "$INFOSOURCE_DIR" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && TARGETS+=("$line")
    done < <(discover_pkgs "$INFOSOURCE_DIR")
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}🌊 No dependency-bearing package found, falling back to wget@1.25.0${RESET}"
    TARGETS=("wget@1.25.0 wget")
fi

echo "🌊 Dependency chain test: ${#TARGETS[@]} package(s)"
for target in "${TARGETS[@]}"; do
    echo "   ${target%% *}"
done

# ==========================================
# 单个包的完整回归
# ==========================================

run_case() {
    local PKG="$1"
    local BIN_NAME="$2"
    local VERSION="${PKG##*@}"
    local ARTIFACT_DIR="$BIN_DIR/$BIN_NAME@$VERSION"
    local ARTIFACT_LINK="$LINKS_DIR/$BIN_NAME@$VERSION"
    local LOG_FILE
    local INSTALL_RC=0
    local MARKERS
    local REMAINING
    local before="$FAILED"

    LOG_FILE="$(mktemp)"

    # 1. 安装（会把整条依赖链拉下来）
    echo ""
    echo "========== install $PKG =========="
    python3 "$WAVE_BIN" install "$PKG" > "$LOG_FILE" 2>&1 || INSTALL_RC=$?
    cat "$LOG_FILE"

    if [[ "$INSTALL_RC" -ne 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: install $PKG${RESET}"
        rm -f "$LOG_FILE"
        FAILED=$((FAILED + 1))
        CASE_FAILED=$((CASE_FAILED + 1))
        return
    fi

    # 2. 二进制要能真正跑起来（relink 漏改会在这里以 dyld 报错暴露）
    echo "========== run $PKG =========="
    if "$ARTIFACT_LINK" --version > /dev/null 2>&1; then
        echo -e "${GREEN}🌊 OK: $PKG --version${RESET}"
    else
        echo -e "${RED_BOLD}🌊 FAIL: $PKG --version${RESET}"
        FAILED=$((FAILED + 1))
    fi

    # 3. 依赖里的动态库引用不能有未解析项
    if grep -qE 'could not be linked|not provided by any installed dependency' "$LOG_FILE"; then
        echo -e "${RED_BOLD}🌊 FAIL: unresolved library references${RESET}"
        grep -E 'could not be linked|not provided by any installed dependency' "$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi

    # 4. 引用计数标记必须写出来
    MARKERS=$(find "$DEPS_DIR" -name '.depped_*' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$MARKERS" -eq 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: no .depped_* marker was written${RESET}"
        FAILED=$((FAILED + 1))
    else
        echo "🌊 Found $MARKERS marker(s)"
    fi

    # 5. 卸载，整条依赖链应被级联清理
    echo "========== uninstall $PKG =========="
    python3 "$WAVE_BIN" uninstall "$PKG" > /dev/null 2>&1 || true

    if [[ -e "$ARTIFACT_DIR" || -e "$ARTIFACT_LINK" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: $PKG was left behind${RESET}"
        FAILED=$((FAILED + 1))
    fi

    REMAINING=$(find "$DEPS_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$REMAINING" -ne 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: $REMAINING dependency dir(s) left behind${RESET}"
        find "$DEPS_DIR" -mindepth 2 -maxdepth 2 -type d
        FAILED=$((FAILED + 1))
    fi

    rm -f "$LOG_FILE"

    if [[ "$FAILED" -gt "$before" ]]; then
        echo -e "${RED_BOLD}🌊 $PKG: FAILED${RESET}"
        CASE_FAILED=$((CASE_FAILED + 1))
    else
        echo -e "${GREEN}🌊 $PKG: OK${RESET}"
        PASSED=$((PASSED + 1))
    fi
}

for target in "${TARGETS[@]}"; do
    run_case "${target%% *}" "${target##* }"
done

# ==========================================
# 结果
# ==========================================

echo ""
echo "🌊 Dependency chain test: ${#TARGETS[@]} package(s), $PASSED ok, $CASE_FAILED failed"
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 Dependency test failed ($FAILED check(s))${RESET}"
    exit 1
fi

echo -e "${GREEN}🌊 Dependency test passed${RESET}"
