#!/bin/bash

# mirror_test.sh
# `wave mirror` 的回归：脱敏、占位、格式互斥、四种输出格式的可解析性。
# 全程离线：这个命令只读环境变量与内置默认值，不发任何请求。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_BIN="$REPO_DIR/lib/wave.py"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# 每次都在干净的环境里跑，避免开发者自己的 MACWAVE_* 干扰结果。
# 需要带凭据时用 run_mirror_api：先把所有变量清掉，再单独设一个，
# 否则「先 unset 再赋值」的顺序会让设置被抹掉（本脚本第一版就踩了这个坑）。
CLEAN_ENV=(env
    -u MACWAVE_API_DOMAIN -u MACWAVE_BOTTLE_DOMAIN -u MACWAVE_DEPS_DOMAIN
    -u MACWAVE_CORE_DOMAIN -u MACWAVE_PYTHON_DOMAIN -u MACWAVE_SELFUPDATE_DOMAIN
    -u MACWAVE_PKG_SOURCECODE_DOMAIN -u MACWAVE_PIP_INDEX)

run_mirror() {
    "${CLEAN_ENV[@]}" python3 "$WAVE_BIN" mirror "$@"
}

run_mirror_api() {
    local url="$1"; shift
    "${CLEAN_ENV[@]}" MACWAVE_API_DOMAIN="$url" python3 "$WAVE_BIN" mirror "$@"
}

MIRROR="https://alice:s3cr3t-pw@mirror.example.test/MacWave"

echo "========== defaults are printed, nothing is blank =========="
OUT="$(run_mirror 2>&1)"
if [[ "$OUT" == *"https://github.com/MacWaveOrg/Bottle/releases/download"* ]]; then
    pass "built-in default for bottle is shown"
else
    fail "default for bottle missing"
fi
if [[ "$OUT" == *"(not configured)"* ]]; then
    pass "an unset entry shows a placeholder instead of a blank"
else
    fail "unset entry did not show a placeholder"
fi
if echo "$OUT" | grep -qE '^\s+\S+\s+\S+\s*$'; then
    fail "a row printed an empty value"
else
    pass "no row prints an empty value"
fi

echo "========== password is masked with exactly six asterisks =========="
OUT="$(run_mirror_api "$MIRROR/infosource" 2>&1)"
if [[ "$OUT" == *"alice:******@mirror.example.test"* ]]; then
    pass "password replaced by six asterisks"
else
    fail "password not masked as ******"
fi
if [[ "$OUT" == *"s3cr3t-pw"* ]]; then
    fail "real password leaked into the output"
else
    pass "real password never printed"
fi
if [[ "$OUT" == *"(auth)"* ]]; then
    pass "auth requirement is marked"
else
    fail "auth marker missing"
fi

echo "========== --hide-user masks the user name =========="
OUT="$(run_mirror_api "$MIRROR/infosource" --hide-user 2>&1)"
if [[ "$OUT" == *"https://******:******@mirror.example.test"* ]]; then
    pass "user name masked as well"
else
    fail "user name not masked"
fi

echo "========== --show-password prints the real password =========="
OUT="$(run_mirror_api "$MIRROR/infosource" --show-password 2>&1)"
if [[ "$OUT" == *"alice:s3cr3t-pw@mirror.example.test"* ]]; then
    pass "--show-password reveals it"
else
    fail "--show-password did not reveal it"
fi

echo "========== masking only applies to entries that need auth =========="
OUT="$(run_mirror_api "$MIRROR/infosource" 2>&1)"
if [[ "$OUT" == *"https://github.com/MacWaveOrg/Deps/releases/download"* ]]; then
    pass "an address without credentials is left alone"
else
    fail "plain address was altered"
fi

echo "========== output formats are mutually exclusive =========="
run_mirror --json --toml >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "--json --toml exits 1" || fail "--json --toml should exit 1"
run_mirror --raw --yaml >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "--raw --yaml exits 1" || fail "--raw --yaml should exit 1"
run_mirror --nope >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "unknown flag exits 1" || fail "unknown flag should exit 1"

echo "========== structured formats parse with a real parser =========="
if run_mirror_api "$MIRROR/infosource" --json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert len(data["mirrors"]) == 8, len(data["mirrors"])
assert any(row["requires_auth"] for row in data["mirrors"])
assert not any("s3cr3t-pw" in row["value"] for row in data["mirrors"]), "password leaked"
' 2>/dev/null; then pass "--json parses and stays masked"; else fail "--json invalid"; fi

if run_mirror_api "$MIRROR/infosource" --toml 2>/dev/null | python3 -c '
import sys
text = sys.stdin.read()
assert "[[mirror]]" in text
assert text.count("[[mirror]]") == 8, text.count("[[mirror]]")
assert "s3cr3t-pw" not in text
try:
    import tomllib
except ImportError:
    raise SystemExit(0)          # 3.10 之前没有 tomllib，只做形状检查
tomllib.loads(text)
' 2>/dev/null; then pass "--toml parses"; else fail "--toml invalid"; fi

if run_mirror_api "$MIRROR/infosource" --yaml 2>/dev/null | python3 -c '
import sys
text = sys.stdin.read()
assert text.startswith("mirrors:")
assert text.count("  - name:") == 8, text.count("  - name:")
assert "s3cr3t-pw" not in text
' 2>/dev/null; then pass "--yaml parses"; else fail "--yaml invalid"; fi

echo "========== --raw is ready to paste and keeps the same masking =========="
OUT="$(run_mirror_api "$MIRROR/infosource" --raw 2>/dev/null)"
if [[ "$OUT" == *'export MACWAVE_API_DOMAIN="https://alice:******@mirror.example.test/MacWave/infosource"'* ]]; then
    pass "--raw emits a full export line with a masked password"
else
    fail "--raw line missing or wrong"
fi
if [[ "$OUT" == *'$B'* ]]; then
    fail "--raw still uses a prefix variable"
else
    pass "--raw writes every address out in full"
fi
if [[ "$OUT" == *'# MACWAVE_PKG_SOURCECODE_DOMAIN  (not configured)'* ]]; then
    pass "--raw comments out the unset entry instead of exporting an empty value"
else
    fail "--raw did not comment the unset entry"
fi

echo "========== --raw --only-set exports only the overridden sources =========="
OUT="$(run_mirror_api "$MIRROR/infosource" --raw --only-set 2>/dev/null)"
if [[ "$OUT" == *'export MACWAVE_API_DOMAIN='* ]]; then
    pass "--only-set keeps the source that was overridden"
else
    fail "--only-set dropped the overridden source"
fi
if [[ "$OUT" == *'export MACWAVE_DEPS_DOMAIN='* ]]; then
    fail "--only-set still exported a built-in default"
else
    pass "--only-set omits sources that fall back to the built-in default"
fi
if [[ "$OUT" == *'s3cr3t-pw'* ]]; then
    fail "--only-set leaked the password"
else
    pass "--only-set stays masked"
fi
run_mirror_api "$MIRROR/infosource" --only-set --json >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "--only-set without --raw exits 1" || fail "--only-set should require --raw"

echo
echo "=========================================="
echo "🌊 Passed: $PASSED / $((PASSED + FAILED))"
if [[ "$FAILED" -gt 0 ]]; then
    echo "🌊 mirror tests failed: $FAILED"
    exit 1
fi
echo "🌊 All mirror tests passed"
