#!/bin/bash

# configpath_test.sh
# 配置目录解析回归（离线，不碰网络、不碰真实的 /opt 与 ${HOME}）：
#   系统级 /opt/macwave_config 优先 → 只有用户级时才回落 ~/.config/macwave_config
#   系统级配置损坏或缺 base_dir 时也要能回落到用户级
# 做法是把 configpaths 的两个目录常量替换成临时目录，直接测实现本身。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIGPATHS_PY="$REPO_DIR/lib/configpaths.py"

if [[ ! -f "$CONFIGPATHS_PY" ]]; then
    echo -e "${RED_BOLD}🌊 Error: configpaths.py not found at $CONFIGPATHS_PY${RESET}"
    exit 1
fi

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

echo "========== config dir resolution =========="

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if python3 - "$CONFIGPATHS_PY" "$TMP_ROOT" << 'PYEOF'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('configpaths_module', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

root = Path(sys.argv[2])
module.SYSTEM_CONFIG_DIR = root / "system"
module.USER_CONFIG_DIR = root / "user"
assert module.config_dir_candidates() == [root / "system", root / "user"]

system_config = root / "system" / "config.json"
user_config = root / "user" / "config.json"
(root / "system").mkdir(parents=True)
(root / "user").mkdir(parents=True)

# 1) 两边都没装
assert module.find_config_dir() is None

# 2) 只有用户级
user_config.write_text('{"base_dir": "/tmp/user-install"}')
assert module.find_config_dir() == root / "user"
assert module.load_base_dir() == Path("/tmp/user-install")

# 3) 系统级出现后优先
system_config.write_text('{"base_dir": "/tmp/system-install"}')
assert module.find_config_dir() == root / "system"
assert module.load_base_dir() == Path("/tmp/system-install")

# 4) 系统级配置损坏时回落用户级
system_config.write_text('not json')
assert module.find_config_dir() == root / "user"
assert module.load_base_dir() == Path("/tmp/user-install")

# 5) 系统级缺少 base_dir 时回落用户级
system_config.write_text('{"foo": 1}')
assert module.find_config_dir() == root / "user"
assert module.load_base_dir() == Path("/tmp/user-install")

# 6) 两边都没有有效配置时报错退出
system_config.unlink()
user_config.unlink()
try:
    module.load_base_dir()
    raise AssertionError("load_base_dir should have exited")
except SystemExit as error:
    assert error.code == 1, error.code

print('🌊 Config dir resolution OK')
PYEOF
then
    pass "system-level config wins, user-level fallback works"
else
    fail "config dir resolution"
fi

echo ""
echo "🌊 configpath test: $PASSED passed, $FAILED failed"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
