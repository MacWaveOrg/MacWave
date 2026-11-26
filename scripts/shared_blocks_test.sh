#!/bin/bash

# shared_blocks_test.sh
# 共享块的同步检查**本身**要被验证：不光要证明「现在一致」，还要证明「不一致时会红」。
#
# 为什么值得单独一个测试：check_shared_blocks.py 是防止漂移的唯一闸门。闸门自己
# 失效是最坏的情况 —— 它会一直报绿，而三份副本早就各写各的了（2026-11-24 那次
# 「同一个判据两种写法」就是这么漏过去的）。
#
# 全程离线、只读仓库副本：把文件拷到临时目录再改动，不碰工作区。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CHECK="$SCRIPT_DIR/check_shared_blocks.py"

FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shared_blocks_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 1. 工作区本身必须是一致的
if python3 "$CHECK" "$REPO_DIR"; then
    pass "仓库里所有共享块一致"
else
    fail "仓库里的共享块不一致（改 scripts/shared/ 之后忘了同步副本）"
fi

# 2. 少一份副本 → 必须红。造一个只含「正本 + 一个缺块的脚本」的假仓库。
mkdir -p "$WORK/repo/scripts/shared" "$WORK/repo/lib"
cp "$REPO_DIR/scripts/shared/legacy_config_action.sh" "$WORK/repo/scripts/shared/"
cp "$REPO_DIR/lib/install.sh" "$WORK/repo/lib/install.sh"
printf '#!/bin/bash\necho nothing\n' > "$WORK/repo/lib/selfupdate.sh"
cp "$REPO_DIR/scripts/update_commands.template.sh" "$WORK/repo/scripts/"
if python3 "$CHECK" "$WORK/repo" > /dev/null 2>&1; then
    fail "缺块的文件没有被发现"
else
    pass "缺块的文件被发现"
fi

# 3. 块被改了一个字符 → 必须红。这是最接近真实漂移的形态。
cp "$REPO_DIR/lib/selfupdate.sh" "$WORK/repo/lib/selfupdate.sh"
python3 - "$WORK/repo/lib/selfupdate.sh" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
# 把判据里的 == 改成 =(笔误级改动)，内容与正本就不一致了
patched = text.replace('if [[ "$recorded" == "$base_dir" ]]; then',
                       'if [[ "$recorded" = "$base_dir" ]]; then', 1)
assert patched != text, "夹具没找到要改的那一行"
path.write_text(patched)
PY
if python3 "$CHECK" "$WORK/repo" > /dev/null 2>&1; then
    fail "被改动过的副本没有被发现"
else
    pass "被改动过的副本被发现"
fi

# 4. 正本自己缺标记 → 必须红（否则比对会静默跳过整个块）
cp "$REPO_DIR/lib/selfupdate.sh" "$WORK/repo/lib/selfupdate.sh"
python3 - "$WORK/repo/scripts/shared/legacy_config_action.sh" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
patched = text.replace("# >>> SHARED: legacy-config-action", "# >>> 忘了写标记", 1)
assert patched != text
path.write_text(patched)
PY
if python3 "$CHECK" "$WORK/repo" > /dev/null 2>&1; then
    fail "正本缺标记没有被发现"
else
    pass "正本缺标记被发现"
fi

echo
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 Shared block tests failed: $FAILED${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 All shared block tests passed${RESET}"
