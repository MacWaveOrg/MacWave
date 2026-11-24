#!/bin/bash

# basedir_set_test.sh
# `wave basedir --set` 的回归：校验、预检、三段式确认、--dry-run 的零副作用。
#
# 为什么需要它：这条命令会**复制整棵安装树并改写 config.json**。它坏掉的方式都很安静：
#   - 校验漏一条 → 把树复制到 /usr/local 里，或者复制到自己的子目录里（无限套娃）；
#   - 预检漏一条 → 搬完之后每个包都在 dyld 报 "Library not loaded"；
#   - 确认漏一段 → 手滑回车就把安装根换了；
#   - --dry-run 真的动手 → "预览"变成破坏性操作。
# 所以每一段都钉死，包括"输错要中止"。
#
# 三段确认要 tty，用 pty 驱动（纯离线）。Mach-O 相关的断言只在 macOS 上跑。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/basedir_set_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# -------------------- 沙箱 --------------------
#
# 配置目录 + base_dir 都在测试根里；组件目录用符号链接指回仓库，这样 `wave`
# 能正常 import，又完全不碰真实安装（MACWAVE_TEST 还会把 HOME 一起搬进来）。

setup_sandbox() {  # setup_sandbox <名字>：设好 SANDBOX / BASE / CONFIG
    SANDBOX="$WORK/$1"
    BASE="$SANDBOX/opt/macwave"
    CONFIG="$SANDBOX/opt/macwave_config/config.json"
    mkdir -p "$SANDBOX/opt/macwave_config" "$BASE/bin" "$BASE/deps"
    printf '{"base_dir": "%s"}' "$BASE" > "$CONFIG"
    local component
    for component in cli config lib net pkg surfboard; do
        ln -sfn "$REPO_DIR/$component" "$BASE/$component"
    done
}

wave() {  # wave <参数...>；OUT / RC 是结果
    OUT=$(MACWAVE_TEST="$SANDBOX" "$PYTHON" "$REPO_DIR/lib/wave.py" "$@" < /dev/null 2>&1)
    RC=$?
}

config_base_dir() {
    "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_dir"])' "$CONFIG"
}

# 造一份"4.6 之前"的产物（引用是绝对路径）。只在 macOS 上有意义。
build_legacy_tree() {
    local work="$WORK/build-$RANDOM"
    mkdir -p "$work"
    printf 'int foo(void) { return 4; }\n' > "$work/foo.c"
    printf '#include <stdio.h>\nint foo(void);\nint main(void){printf("sg %%d\\n",foo());return 0;}\n' \
        > "$work/main.c"
    mkdir -p "$BASE/deps/foo/foo@1.0/lib" "$BASE/bin/bar@1.0/bin"
    clang -dynamiclib -install_name "$BASE/deps/foo/foo@1.0/lib/libfoo.dylib" \
        -Wl,-headerpad_max_install_names \
        -o "$BASE/deps/foo/foo@1.0/lib/libfoo.dylib" "$work/foo.c" 2> /dev/null
    clang -o "$BASE/bin/bar@1.0/bin/bar" "$work/main.c" \
        -L"$BASE/deps/foo/foo@1.0/lib" -lfoo -Wl,-headerpad_max_install_names 2> /dev/null
    printf 'foo@1.0\n' > "$BASE/bin/bar@1.0/_DEPS"
}

echo "========== 1. 参数与路径校验：提问之前就要失败 =========="

setup_sandbox validate

wave basedir --set relative/path
[[ "$RC" -eq 1 && "$OUT" == *"not an absolute path"* ]] \
    && pass "相对路径被拒绝" || fail "相对路径：rc=$RC $(printf '%.160s' "$OUT")"

wave basedir --set /usr/local
[[ "$RC" -eq 1 && "$OUT" == *"system directory"* ]] \
    && pass "系统目录被拒绝" || fail "系统目录：rc=$RC $(printf '%.160s' "$OUT")"

wave basedir --set "$BASE"
[[ "$RC" -eq 1 && "$OUT" == *"already the install directory"* ]] \
    && pass "与当前安装路径相同被拒绝" || fail "同一路径：rc=$RC $(printf '%.160s' "$OUT")"

wave basedir --set "$BASE/nested"
[[ "$RC" -eq 1 && "$OUT" == *"inside the current install directory"* ]] \
    && pass "目标在当前树内部被拒绝（防止无限套娃）" \
    || fail "嵌套：rc=$RC $(printf '%.160s' "$OUT")"

wave basedir --set "$SANDBOX"
[[ "$RC" -eq 1 && "$OUT" == *"current install directory is inside"* ]] \
    && pass "当前树在目标内部被拒绝" || fail "反向嵌套：rc=$RC $(printf '%.160s' "$OUT")"

mkdir -p "$SANDBOX/occupied" && touch "$SANDBOX/occupied/keep"
wave basedir --set "$SANDBOX/occupied"
[[ "$RC" -eq 1 && "$OUT" == *"already exists and is not empty"* ]] \
    && pass "非空目标被拒绝" || fail "非空目标：rc=$RC $(printf '%.160s' "$OUT")"

[[ ! -e "$BASE/nested" && ! -e "$SANDBOX/opt/macwave/nested" ]] \
    && pass "以上失败都没有留下任何目录" || fail "校验失败却建了目录"

echo "========== 2. --dry-run：报告但不动手，且不需要 tty =========="

BEFORE_CONFIG=$(config_base_dir)
wave basedir --set "$SANDBOX/newhome" --dry-run
[[ "$RC" -eq 0 ]] && pass "--dry-run 成功（无 tty 也能跑）" \
    || fail "--dry-run：rc=$RC $(printf '%.200s' "$OUT")"
[[ "$OUT" == *"Dry run"* && "$OUT" == *"config.json"* ]] \
    && pass "--dry-run 打出将要做的事" || fail "--dry-run 输出不完整：$(printf '%.200s' "$OUT")"
[[ ! -e "$SANDBOX/newhome" ]] && pass "--dry-run 没有创建目标" || fail "--dry-run 创建了目标"
[[ "$(config_base_dir)" == "$BEFORE_CONFIG" ]] \
    && pass "--dry-run 没有改 config.json" || fail "--dry-run 改了 config.json"

echo "========== 3. 没有 tty：拒绝，而不是"假装确认" =========="

wave basedir --set "$SANDBOX/newhome"
[[ "$RC" -eq 1 && "$OUT" == *"interactive terminal"* ]] \
    && pass "非 tty 被拒绝" || fail "非 tty：rc=$RC $(printf '%.200s' "$OUT")"
[[ ! -e "$SANDBOX/newhome" ]] && pass "非 tty 时没有复制" || fail "非 tty 却复制了"

# ==================== 以下至「CI-ONLY END」专为 CI 而加 ====================
# 预检与整条 pty 流程都依赖 Mach-O（otool / install_name_tool / codesign）。
# 非 macOS 上这些断言一条都不执行，看到 SKIP 就代表本节本次没有被验证。
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: 非 macOS，Mach-O 预检与整条确认流程不适用"

    echo
    echo "=========================================="
    echo -e "🌊 Passed: $PASSED"
    echo -e "🌊 Failed: $FAILED"
    echo "=========================================="
    [[ "$FAILED" -eq 0 ]] || exit 1
    echo -e "${GREEN}🌊 All basedir --set tests passed${RESET}"
    exit 0
fi
# ==================== CI-ONLY END（下面这段是 macOS 上真正跑的断言）====================

for tool in clang otool install_name_tool codesign; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "SKIP: '$tool' 不存在，无法造 Mach-O 夹具"
        exit 0
    fi
done

echo "========== 4. 预检：还有绝对路径的产物就拒绝搬 =========="

setup_sandbox preflight
build_legacy_tree

wave basedir --set "$SANDBOX/newhome"
[[ "$RC" -eq 1 ]] && pass "预检失败时返回 1" \
    || fail "预检应返回 1（实际 rc=${RC}）"
[[ "$OUT" == *"wave transfer --all"* ]] \
    && pass "预检提示先跑 wave transfer --all" || fail "缺少迁移提示：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"bin/bar@1.0"* ]] && pass "点名了具体是哪个产物" \
    || fail "没有点名产物：$(printf '%.200s' "$OUT")"
[[ ! -e "$SANDBOX/newhome" ]] && pass "预检失败没有复制" || fail "预检失败却复制了"

wave transfer --all
[[ "$RC" -eq 0 ]] && pass "迁移成位置无关后可继续" || fail "wave transfer --all：rc=$RC"

echo "========== 5. 三段确认（pty）：输错就中止，全对才搬 =========="

# drive_set <模式>：用 pty 跑一次 basedir --set，按模式喂答案。
# 模式：ok / wrong-yes / wrong-path / short-sentence / typo-inside
drive_set() {
    "$PYTHON" - "$SANDBOX" "$BASE" "$SANDBOX/newhome" "$1" <<'PY'
import os, pty, select, subprocess, sys, time

sandbox, old, new, mode = sys.argv[1:5]
repo = os.environ["REPO_DIR"]
python = os.environ.get("PYTHON", sys.executable)

line_yes = b"Yes\n"
line_path = (old + "\n").encode()
sentence = "Yes, I confirm switching basedir to " + new + "."
# typo-inside：在中间插一个错字符。实现上输错的位不前进，所以正确字符随后
# 仍然对得上 —— 这一条同时证明"打错不会让句子错位"。
if mode == "typo-inside":
    mid = len(sentence) // 2
    line_sentence = (sentence[:mid] + "X" + sentence[mid:] + "\n").encode()
elif mode == "short-sentence":
    line_sentence = (sentence[:-5] + "\n").encode()
else:
    line_sentence = (sentence + "\n").encode()

if mode == "wrong-yes":
    line_yes = b"yes\n"
if mode == "wrong-path":
    line_path = b"/tmp/definitely-not-it\n"

master, slave = pty.openpty()
env = dict(os.environ, MACWAVE_TEST=sandbox)
proc = subprocess.Popen([python, repo + "/lib/wave.py", "basedir", "--set", new],
                        stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
os.close(slave)

buf = b""
sent = set()
deadline = time.time() + 60

def drain(timeout):
    global buf
    while select.select([master], [], [], timeout)[0]:
        try:
            data = os.read(master, 4096)
        except OSError:
            return
        if not data:
            return
        buf += data
        timeout = 0

while time.time() < deadline:
    drain(0.1)
    if b"Type Yes" in buf and "yes" not in sent:
        os.write(master, line_yes); sent.add("yes")
    elif b"Path:" in buf and "path" not in sent:
        os.write(master, line_path); sent.add("path")
    elif b"full stop." in buf and "sentence" not in sent:
        os.write(master, line_sentence); sent.add("sentence")
    if proc.poll() is not None:
        break

drain(0.3)
os.close(master)
try:
    proc.wait(timeout=20)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
sys.stdout.write(buf.decode("utf-8", "replace"))
sys.exit(proc.returncode)
PY
}

export REPO_DIR
export PYTHON

# --- 5a 输错第一段：中止，且什么都不复制 ---
setup_sandbox wrong_yes
build_legacy_tree
wave transfer --all > /dev/null 2>&1
OUT=$(drive_set wrong-yes 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "第一段打错 Yes 就中止" || fail "第一段打错仍继续（rc=${RC}）"
[[ "$OUT" == *"nothing was changed"* ]] \
    && pass "中止时说明什么都没改" || fail "中止提示不对：$(printf '%.160s' "$OUT")"
[[ ! -e "$SANDBOX/newhome" ]] && pass "第一段打错没有复制" || fail "第一段打错却复制了"

# --- 5b 输错第二段：旧路径不对 ---
setup_sandbox wrong_path
build_legacy_tree
wave transfer --all > /dev/null 2>&1
OUT=$(drive_set wrong-path 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "第二段路径不对就中止" || fail "第二段路径不对仍继续（rc=${RC}）"
[[ ! -e "$SANDBOX/newhome" ]] && pass "第二段打错没有复制" || fail "第二段打错却复制了"

# --- 5c 第三段没打完就回车：中止 ---
setup_sandbox short_sentence
build_legacy_tree
wave transfer --all > /dev/null 2>&1
OUT=$(drive_set short-sentence 2>&1); RC=$?
[[ "$RC" -ne 0 ]] && pass "第三段没打完就回车即中止" \
    || fail "第三段不完整仍继续（rc=${RC}）"
[[ "$OUT" == *"not complete"* ]] && pass "报出"没打完"" || fail "提示不对：$(printf '%.160s' "$OUT")"
[[ ! -e "$SANDBOX/newhome" ]] && pass "第三段不完整没有复制" || fail "第三段不完整却复制了"

# --- 5d 第三段中间打错一个字符：不前进，最终仍然成功 ---
setup_sandbox typo_inside
build_legacy_tree
wave transfer --all > /dev/null 2>&1
OUT=$(drive_set typo-inside 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "中间打错一个字符不会让句子错位（不前进）" \
    || fail "中间打错导致失败（rc=${RC}）：$(printf '%.300s' "$OUT")"

# --- 5e 全对：复制 + 改配置 + 旧树保留 + 新树可运行 ---
setup_sandbox happy
build_legacy_tree
wave transfer --all > /dev/null 2>&1
OLD_CONFIG=$(config_base_dir)
OUT=$(drive_set ok 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && pass "三段全对之后成功" || fail "正常流程失败（rc=${RC}）：$(printf '%.300s' "$OUT")"
[[ -d "$SANDBOX/newhome" ]] && pass "新树已创建" || fail "新树没建出来"
[[ "$(config_base_dir)" == "$SANDBOX/newhome" ]] \
    && pass "config.json 的 base_dir 已更新" || fail "config.json 没更新"
if [[ "$OUT" == *"APFS clone"* || "$OUT" == *"copied"* ]]; then
    pass "复制方式有明确交代（APFS clone 或普通复制）"
else
    fail "没说清用了哪种复制方式：$(printf '%.200s' "$OUT")"
fi
[[ "$(config_base_dir)" != "$OLD_CONFIG" ]] && pass "确实换了值（不是空操作）" \
    || fail "base_dir 没变"
[[ -d "$BASE" ]] && pass "旧树保留（留作退路）" || fail "旧树被删了"
"$SANDBOX/newhome/bin/bar@1.0/bin/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "新树里的包能运行（相对引用生效）" || fail "新树里的包跑不起来"
[[ "$OUT" == *"rm -rf"* ]] && pass "结尾给出了删旧树的命令" \
    || fail "没提示怎么删旧树：$(printf '%.200s' "$OUT")"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All basedir --set tests passed${RESET}"
