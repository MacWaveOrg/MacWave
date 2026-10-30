#!/bin/bash

# info_format_test.sh
# `wave info` 四种输出格式的回归：
#   --json / --yaml / --toml 三者同构、可被真正的解析器读回；
#   --raw 是索引里 @common 的原文，不是格式化后的结果；
#   互斥与未知旗标要报错，默认输出不受影响。
#
# 全程离线：假索引起在 localhost，假安装目录用临时 HOME。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_SRC="$REPO_DIR/lib/wave.py"

if [[ ! -f "$WAVE_SRC" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_SRC${RESET}"
    exit 1
fi

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

ok() {
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里没有「$3」"
        printf '%s\n' "$2" | sed 's/^/      /'
    fi
}

not_ok() {
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里不该出现「$3」"
    fi
}

# -------------------- 沙箱 --------------------

WORK=$(mktemp -d)
HTTP_PID=""
cleanup() {
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

HOME_DIR="$WORK/home"
BASE="$WORK/base"
mkdir -p "$HOME_DIR/.config/macwave_config" "$BASE"
cp -R "$REPO_DIR/lib" "$REPO_DIR/pkg" "$REPO_DIR/surfboard" "$BASE/"
printf '{"version": "4.1.0"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/macwave_config/config.json"

ARCH=$(python3 -c 'import platform; m=platform.machine().lower(); print("arm64" if m in ("arm64","aarch64") else "amd64")')

mkdir -p "$BASE/bin/jq@1.7.1" "$BASE/links"
: > "$BASE/bin/jq@1.7.1/jq"
ln -s "../bin/jq@1.7.1/jq" "$BASE/links/jq"

# -------------------- 假索引 --------------------

MIRROR="$WORK/mirror"
INDEX="$MIRROR/pkg/pkginfo_$ARCH"
mkdir -p "$INDEX/jq" "$INDEX/bare"
printf 'jq\nbare\n' > "$INDEX/versions"
printf 'jq@1.8.2\njq@1.7.1\njq@common\n' > "$INDEX/jq/versions"
printf 'bare@1.0\n' > "$INDEX/bare/versions"

# 原文写成客户端读得懂的形状，同时故意留一个客户端不解析的字段，
# 用来证明 --raw 是原文而不是「把它认识的字段重新打一遍」
cat > "$INDEX/jq/_jq@common" <<'EOF'
sha256: "a89ed5a26d1098102144326ca845b025246b46445b85e6ff83495a3c97198ffb"
file: "jq-macos-arm64"
url: "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-arm64"
aut: "jqlang"
des: "Command-line JSON processor"
hom: "https://jqlang.github.io/jq/"
lic: "MIT"
note: "only-visible-in-raw"
EOF

PORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
( cd "$MIRROR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!

for _ in $(seq 1 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/pkg/pkginfo_$ARCH/versions" && break
    sleep 0.1
done

# 追加而不是覆盖：本地想额外给个装了解析器的目录（例如验证 --yaml 能被 PyYAML 读回）
USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
if [[ -d "$USER_SITE" ]]; then
    export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$USER_SITE"
fi

wave() {
    env -u MACWAVE_BOTTLE_DOMAIN -u MACWAVE_DEPS_DOMAIN \
        HOME="$HOME_DIR" \
        MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$BASE/lib/wave.py" "$@"
}

echo "========== 1. 默认输出不变 =========="

out=$(wave info jq)
ok "默认仍是人读的标签行"   "$out" "🌊 Name:               jq"
ok "默认带作者"             "$out" "Author:"
ok "默认带已装版本"         "$out" "Installed versions: 1.7.1"
not_ok "默认不带 JSON 花括号" "$out" '{'

echo
echo "========== 2. --json =========="

out=$(wave info jq --json)
ok "可被 json 解析" "$(printf '%s' "$out" | python3 -c 'import json,sys; print("ok" if json.load(sys.stdin)["name"]=="jq" else "bad")' 2>&1)" "ok"
ok "包含 latest"    "$out" '"latest": "1.8.2"'
ok "包含 installed" "$out" '"installed"'
ok "包含 license"   "$out" '"license": "MIT"'

echo
echo "========== 3. --toml =========="

out=$(wave info jq --toml)
ok "可被 tomllib 解析" "$(printf '%s' "$out" | python3 -c '
import sys, tomllib
d = tomllib.loads(sys.stdin.read())
print("ok" if d["name"] == "jq" and d["latest"] == "1.8.2" else "bad")
' 2>&1)" "ok"
ok "数组是 TOML 数组" "$out" 'available = ["1.8.2", "1.7.1"]'

echo
echo "========== 4. --yaml =========="

out=$(wave info jq --yaml)
ok "标量带引号"   "$out" 'name: "jq"'
ok "列表用 - 展开" "$out" '  - "1.8.2"'

# 装了 PyYAML 才做真实解析（CI 不装，跳过不算失败）
if python3 -c 'import yaml' 2>/dev/null; then
    ok "可被 PyYAML 解析" "$(printf '%s' "$out" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
print("ok" if d["name"] == "jq" and d["latest"] == "1.8.2" else "bad")
' 2>&1)" "ok"
else
    echo "🌊 SKIP: 本机没有 PyYAML，跳过 YAML 反向解析"
fi

echo
echo "========== 5. --raw 是原文 =========="

out=$(wave info jq --raw)
ok "带 sha256 行"              "$out" 'sha256: "a89ed5a2'
ok "带 url 行"                 "$out" 'url: "https://github.com/jqlang/jq'
ok "带客户端不解析的字段"      "$out" 'note: "only-visible-in-raw"'
not_ok "不是格式化后的标签行"  "$out" "🌊 Name:"
not_ok "不是 JSON"             "$out" '{'

echo
echo "========== 6. 参数校验 =========="

out=$(wave info jq --json --yaml 2>&1)
ok "两种格式互斥时报错"  "$out" "mutually exclusive"
wave info jq --json --yaml >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass "互斥时退出码 1"; else fail "互斥时退出码应当为 1"; fi

out=$(wave info jq --bogus 2>&1)
ok "未知旗标报错"        "$out" "unknown option --bogus"
ok "并列出可用格式"      "$out" "--json, --yaml, --toml or --raw"

out=$(wave info --json 2>&1)
ok "缺包名时报错"        "$out" "Missing package name"

echo
echo "========== 7. 没有 @common 记录时 =========="

out=$(wave info bare --raw 2>&1)
ok "--raw 明说没有记录"  "$out" "has no @common record"
wave info bare --raw >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass "缺记录时退出码 1"; else fail "缺记录时退出码应当为 1"; fi

out=$(wave info bare --json 2>&1)
ok "--json 仍给出结构"   "$out" '"name": "bare"'
ok "--json 未知字段为 null" "$out" '"author": null'
ok "--json 仍列出可装版本" "$out" '"1.0"'

echo
echo "========== 8. 帮助 =========="

out=$(wave info --help)
ok "用法里列出四种格式" "$out" "wave info <package> [--json|--yaml|--toml|--raw]"
ok "解释了 --raw 是什么" "$out" "as stored"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All info format tests passed${RESET}"
