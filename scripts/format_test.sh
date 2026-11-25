#!/bin/bash

# format_test.sh
# 对 10 种格式的测试包逐个跑：install → 执行 → uninstall

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"
WAVE_BIN="$REPO_DIR/lib/wave.py"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

# 沙箱：这个测试会真装真卸，必须在自己的树里跑。以前它读的是**真实**安装的
# base_dir，跑一次就把现有安装改一遍（2026-11-24 的教训）。
SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/format_test.XXXXXX")"

trap 'rm -rf "$SANDBOX_ROOT"' EXIT
sandbox_install_tree "$SANDBOX_ROOT"
CONFIG_FILE="$SANDBOX_CONFIG_FILE"
BASE_DIR="$SANDBOX_BASE"
BIN_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"

PKGS=(
    "test_bin_no_ext|no-extension"
    "test_bin_zip|.zip"
    "test_bin_targz|.tar.gz"
    "test_bin_tarbz2|.tar.bz2"
    "test_bin_tarxz|.tar.xz"
    "test_bin_tar|.tar"
    "test_bin_gz|.gz"
    "test_bin_bz2|.bz2"
    "test_bin_xz|.xz"
    "test_bin_conda|.conda"
)

FAILED=0
PASSED=0

for entry in "${PKGS[@]}"; do
    IFS='|' read -r pkg fmt <<< "$entry"
    echo ""
    echo "========== $pkg ($fmt) =========="

    if ! python3 "$WAVE_BIN" install "${pkg}@1.0"; then
        echo -e "${RED_BOLD}🌊 FAIL: install ${pkg}@1.0${RESET}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if [[ ! -x "$BIN_DIR/${pkg}@1.0/${pkg}" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: ${pkg}@1.0/${pkg} not executable${RESET}"
        FAILED=$((FAILED + 1))
        python3 "$WAVE_BIN" uninstall "${pkg}@1.0" || true
        continue
    fi

    if [[ ! -L "$LINKS_DIR/${pkg}@1.0" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: ${pkg}@1.0 link not found${RESET}"
        FAILED=$((FAILED + 1))
        python3 "$WAVE_BIN" uninstall "${pkg}@1.0" || true
        continue
    fi

    if [[ ! -x "$LINKS_DIR/${pkg}@1.0" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: ${pkg}@1.0 link not executable${RESET}"
        FAILED=$((FAILED + 1))
        python3 "$WAVE_BIN" uninstall "${pkg}@1.0" || true
        continue
    fi

    if [[ ! -L "$LINKS_DIR/${pkg}" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: install did not create the unversioned link ${pkg}${RESET}"
        FAILED=$((FAILED + 1))
        python3 "$WAVE_BIN" uninstall "${pkg}@1.0" || true
        continue
    fi

    OUTPUT=$("$BIN_DIR/${pkg}@1.0/${pkg}")
    if [[ "$OUTPUT" != *"Test Successful! ($fmt)"* ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: unexpected output: $OUTPUT${RESET}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}🌊 PASS: $pkg${RESET}"
        PASSED=$((PASSED + 1))
    fi

    python3 "$WAVE_BIN" uninstall "${pkg}@1.0" || true
done

echo ""
echo "========== install --no-link =========="
if python3 "$WAVE_BIN" install "test_bin_zip@1.0" --no-link </dev/null >/dev/null 2>&1; then
    if [[ -L "$LINKS_DIR/test_bin_zip" ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: install --no-link created links/test_bin_zip${RESET}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}🌊 PASS: install --no-link skipped the unversioned link${RESET}"
        PASSED=$((PASSED + 1))
    fi
    python3 "$WAVE_BIN" uninstall "test_bin_zip@1.0" >/dev/null 2>&1 || true
else
    echo -e "${RED_BOLD}🌊 FAIL: install test_bin_zip@1.0 --no-link${RESET}"
    FAILED=$((FAILED + 1))
fi

echo ""
echo "=========================================="
TOTAL=$(( ${#PKGS[@]} + 1 ))
echo "🌊 Passed: $PASSED / $TOTAL"
echo "🌊 Failed: $FAILED / $TOTAL"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi

exit 0
