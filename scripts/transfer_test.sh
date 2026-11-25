#!/bin/bash

# transfer_test.sh
# 重定位（Mach-O → 位置无关）的回归：检查口径、改写结果、幂等、搬移、CLI 行为。
#
# 为什么需要它：4.6 起产物分成两种形态 ——
#   - 构建时重定位好的（引用是 @loader_path 相对形式，与 base_dir 无关）；
#   - 4.6 之前装的（引用写死绝对路径）。
# 安装时要能区分这两种（对新形态不改字节、不重签），`wave transfer` 要能把旧的
# 迁移成新的，而且必须幂等。任何一条走散，症状都是"运行时 dyld 加载不到库"，
# 而这在测试里看不出来 —— 所以这里把每条断言都钉住。
#
# 全程离线：测试自己用 clang 造最小的 dylib + 可执行文件，不下载任何东西。

set -u
# 关掉 -e：本脚本故意执行会失败的命令（--check 期望 rc=1）。
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TRANSFER="$REPO_DIR/surfboard/transfer.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/transfer_test.XXXXXX")
# 规范成真实路径：$TMPDIR 常以 / 结尾，mktemp 会得到 ".../T//transfer_test.X"，
# 而 clang 会把双斜杠去掉 —— 于是断言里的路径与 otool 输出差一个斜杠。
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# ==================== 以下至「CI-ONLY END」专为 CI 而加 ====================
# 重定位是 Mach-O 的事：otool / install_name_tool / codesign 只在 Darwin 上有。
# 非 macOS 上这些断言**一条都不执行**，输出 SKIP —— 看到 SKIP 就代表这一节
# 本次没有被验证，不要把「Linux 绿」读成「跨平台都验过」。
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: 非 macOS，Mach-O 重定位不适用"
    exit 0
fi
# ==================== CI-ONLY END（下面这段是 macOS 上真正跑的断言）====================

for tool in clang otool install_name_tool codesign; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "SKIP: '$tool' 不存在，无法造 Mach-O 夹具"
        exit 0
    fi
done

# 造一份"4.6 之前"的产物：引用与 install name 都是绝对路径。
# build_legacy <工作目录>：产出 <工作目录>/stage/{bin/bar@1.0/bin/bar,deps/foo/foo@1.0/lib/libfoo.dylib}
build_legacy() {
    local root="$1" stage="$1/stage" bump="$2"
    mkdir -p "$stage/deps/foo/foo@1.0/lib" "$stage/bin/bar@1.0/bin"
    printf 'int foo(void) { return %s; }\n' "$bump" > "$root/foo.c"
    printf '#include <stdio.h>\nint foo(void);\nint main(void){printf("ok %%d\\n",foo());return 0;}\n' \
        > "$root/main.c"
    # headerpad 是必需前提：没有它 install_name_tool 装不下更长的路径（真实产物
    # 里由上游的 -headerpad_max_install_names 提供，缺了只能重新构建）。
    clang -dynamiclib \
        -install_name "$stage/deps/foo/foo@1.0/lib/libfoo.dylib" \
        -Wl,-headerpad_max_install_names \
        -o "$stage/deps/foo/foo@1.0/lib/libfoo.dylib" "$root/foo.c" 2> /dev/null
    clang -o "$stage/bin/bar@1.0/bin/bar" "$root/main.c" \
        -L"$stage/deps/foo/foo@1.0/lib" -lfoo \
        -Wl,-headerpad_max_install_names 2> /dev/null
}

transfer() {  # transfer <参数...>；输出放进 OUT，退出码放进 RC
    OUT=$(/bin/bash "$TRANSFER" "$@" 2>&1)
    RC=$?
}

ref_of() {  # ref_of <可执行文件>：第一条依赖引用（跳过首行的文件名）
    otool -L "$1" 2> /dev/null | sed -n '2p' | awk '{print $1}'
}

id_of() {  # id_of <dylib>：LC_ID_DYLIB
    otool -D "$1" 2> /dev/null | sed -n '2p'
}

sum_of() {  # sum_of <文件>：内容指纹，用来断言"一个字节都没动"
    shasum -a 256 "$1" 2> /dev/null | awk '{print $1}'
}

echo "========== 1. --check 只读：报告绝对路径，不改字节 =========="

LEGACY="$WORK/legacy"
build_legacy "$LEGACY" 7
PKG="$LEGACY/stage/bin/bar@1.0"
DEP="$LEGACY/stage/deps/foo/foo@1.0"
BASE="$LEGACY/stage"

BEFORE=$(sum_of "$PKG/bin/bar")
transfer --check "$PKG" "$BASE"
[[ "$RC" -eq 1 ]] && pass "老形态：--check 返回 1" \
    || fail "--check 应返回 1（实际 rc=${RC}）：$(printf '%.160s' "$OUT")"
[[ "$(sum_of "$PKG/bin/bar")" == "$BEFORE" ]] && pass "--check 不改动可执行文件" \
    || fail "--check 改动了可执行文件"

BEFORE_DEP=$(sum_of "$DEP/lib/libfoo.dylib")
transfer --check "$DEP" "$BASE"
[[ "$RC" -eq 1 ]] && pass "老形态的 dylib：--check 返回 1" \
    || fail "dylib 的 --check 应返回 1（实际 rc=${RC}）"
[[ "$(sum_of "$DEP/lib/libfoo.dylib")" == "$BEFORE_DEP" ]] && pass "--check 不改动 dylib" \
    || fail "--check 改动了 dylib"

# 这里曾经有个真 bug：检查分支只打了一行就往下走，new_id 未赋值，
# install_name_tool -id "" 把 ID 清空 —— 文件被改坏，而退出码还是 1。
[[ "$(id_of "$DEP/lib/libfoo.dylib")" == "$BASE/deps/foo/foo@1.0/lib/libfoo.dylib" ]] \
    && pass "--check 之后 install name 原样保留" \
    || fail "install name 被改成了 $(id_of "$DEP/lib/libfoo.dylib")"

echo "========== 2. --relative：引用与 ID 都变成位置无关 =========="

transfer --relative "$DEP" "$BASE"
[[ "$RC" -eq 0 ]] && pass "dylib 迁移成功" || fail "dylib 迁移失败：$(printf '%.160s' "$OUT")"
[[ "$(id_of "$DEP/lib/libfoo.dylib")" == "@rpath/libfoo.dylib" ]] \
    && pass "dylib 的 ID 变成 @rpath/libfoo.dylib" \
    || fail "dylib 的 ID 是 $(id_of "$DEP/lib/libfoo.dylib")"

transfer --relative "$PKG" "$BASE"
[[ "$RC" -eq 0 ]] && pass "可执行文件迁移成功" || fail "可执行文件迁移失败：$(printf '%.160s' "$OUT")"

REF=$(ref_of "$PKG/bin/bar")
case "$REF" in
    @loader_path/*) pass "引用变成 @loader_path 相对形式（${REF}）" ;;
    *) fail "引用仍是 ${REF}" ;;
esac

# 相对层数必须正确：bin/bar@1.0/bin/bar → 上升三级才到 base_dir
[[ "$REF" == "@loader_path/../../../deps/foo/foo@1.0/lib/libfoo.dylib" ]] \
    && pass "相对路径的层数正确" || fail "相对层数不对：$REF"

[[ "$(ref_of "$DEP/lib/libfoo.dylib")" != /* ]] \
    && pass "dylib 自身也不再带绝对引用" \
    || fail "dylib 里还有绝对引用：$(ref_of "$DEP/lib/libfoo.dylib")"

echo "========== 3. 迁移后可运行、可搬移、且幂等 =========="

"$PKG/bin/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "迁移后可直接运行" || fail "迁移后运行失败"

# links/ 是符号链接（../bin/x@v/x）：dyld 拿到的是真实路径，@loader_path 仍然成立
mkdir -p "$BASE/links"
ln -sfn ../bin/bar@1.0/bin/bar "$BASE/links/bar"
"$BASE/links/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "走 links/ 符号链接也能运行" || fail "走符号链接运行失败"

MOVED="$WORK/moved"
mv "$BASE" "$MOVED"
"$MOVED/bin/bar@1.0/bin/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "整棵树搬走后仍能运行" || fail "搬走后运行失败"
"$MOVED/links/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "搬走后走符号链接仍能运行" || fail "搬走后符号链接运行失败"

BEFORE=$(sum_of "$MOVED/bin/bar@1.0/bin/bar")
transfer --check "$MOVED/bin/bar@1.0" "$MOVED"
[[ "$RC" -eq 0 ]] && pass "迁移后 --check 返回 0" \
    || fail "迁移后 --check 仍返回 ${RC}：$(printf '%.160s' "$OUT")"
transfer --relative "$MOVED/bin/bar@1.0" "$MOVED"
[[ "$(sum_of "$MOVED/bin/bar@1.0/bin/bar")" == "$BEFORE" ]] \
    && pass "对已迁移的产物再跑 --relative 不改字节（幂等）" \
    || fail "重复迁移改动了字节"

echo "========== 4. 位置无关的树不建依赖索引 =========="

# 安装时对新产物要"零成本"：如果还去扫整棵依赖树，装包会慢在看不到的地方。
IDX="$WORK/idx"
mkdir -p "$IDX"
transfer --relative "$MOVED/bin/bar@1.0" "$MOVED" "$IDX"
if [[ -z "$(ls -A "$IDX" 2> /dev/null)" ]]; then
    pass "已相对 + 零改写的目标不建共享索引"
else
    fail "共享索引被建了：$(ls -A "$IDX" | tr '\n' ' ')"
fi

echo "========== 5. 不带 --relative（安装期兼容路径）仍写绝对路径 =========="

COMPAT="$WORK/compat"
build_legacy "$COMPAT" 3
transfer "$COMPAT/stage/bin/bar@1.0" "$COMPAT/stage"
[[ "$RC" -eq 0 ]] && pass "兼容改写成功" || fail "兼容改写失败：$(printf '%.160s' "$OUT")"
COMPAT_REF=$(ref_of "$COMPAT/stage/bin/bar@1.0/bin/bar")
[[ "$COMPAT_REF" == "$COMPAT/stage/deps/foo/foo@1.0/lib/libfoo.dylib" ]] \
    && pass "兼容路径指向 BASE_DIR 下的实际位置" \
    || fail "兼容路径不对：$COMPAT_REF"
"$COMPAT/stage/bin/bar@1.0/bin/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "兼容改写后能运行" || fail "兼容改写后运行失败"

echo "========== 6. wave transfer（CLI）：自动检测新旧、带动依赖、幂等 =========="

# 造一个隔离安装树：配置目录 + base_dir，组件目录用符号链接指回仓库
TESTROOT="$WORK/cli"
BASEDIR="$TESTROOT/opt/macwave"
mkdir -p "$TESTROOT/opt/macwave_config" "$BASEDIR"
printf '{"base_dir": "%s"}' "$BASEDIR" > "$TESTROOT/opt/macwave_config/config.json"
for component in cli config lib net pkg surfboard; do
    ln -sfn "$REPO_DIR/$component" "$BASEDIR/$component"
done

build_legacy "$TESTROOT/fixture" 11
cp -R "$TESTROOT/fixture/stage/." "$BASEDIR/"
echo "foo@1.0" > "$BASEDIR/bin/bar@1.0/_DEPS"

wave() {  # wave <参数...>：始终在测试根里跑，绝不碰真实安装
    OUT=$(MACWAVE_TEST="$TESTROOT" python3 "$REPO_DIR/lib/wave.py" "$@" 2>&1)
    RC=$?
}

CLI_PKG="$BASEDIR/bin/bar@1.0/bin/bar"
CLI_DEP="$BASEDIR/deps/foo/foo@1.0/lib/libfoo.dylib"

BEFORE_PKG=$(sum_of "$CLI_PKG")
BEFORE_DEP=$(sum_of "$CLI_DEP")
wave transfer bar --dry-run
[[ "$RC" -eq 0 ]] && pass "--dry-run 成功" || fail "--dry-run 失败：$(printf '%.200s' "$OUT")"
[[ "$(sum_of "$CLI_PKG")" == "$BEFORE_PKG" && "$(sum_of "$CLI_DEP")" == "$BEFORE_DEP" ]] \
    && pass "--dry-run 不改动任何文件" || fail "--dry-run 改动了文件"

wave transfer bar
[[ "$RC" -eq 0 ]] && pass "wave transfer <包> 成功" \
    || fail "wave transfer 失败：$(printf '%.200s' "$OUT")"
case "$(ref_of "$CLI_PKG")" in
    @loader_path/*) pass "CLI 迁移后引用是相对形式" ;;
    *) fail "CLI 迁移后引用是 $(ref_of "$CLI_PKG")" ;;
esac
[[ "$(id_of "$CLI_DEP")" == "@rpath/libfoo.dylib" ]] \
    && pass "CLI 迁移把 _DEPS 里列出的依赖也一起迁移了" \
    || fail "依赖没被迁移（ID 是 $(id_of "$CLI_DEP")）"

"$CLI_PKG" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "CLI 迁移后可运行" || fail "CLI 迁移后运行失败"

wave transfer bar
[[ "$RC" -eq 0 ]] && pass "重复执行成功（幂等）" \
    || fail "重复执行失败：$(printf '%.200s' "$OUT")"
if [[ "$OUT" == *"already relative 2"* ]]; then
    pass "重复执行把两个目标都判成 already relative"
else
    fail "重复执行的统计不对：$(printf '%.200s' "$OUT")"
fi

wave transfer --all
[[ "$RC" -eq 0 ]] && pass "--all 成功" || fail "--all 失败：$(printf '%.200s' "$OUT")"

# 参数校验：报错要指出下一步，不能静默成功
wave transfer nosuch
[[ "$RC" -eq 1 ]] && pass "未安装的包返回 1" || fail "未安装的包返回 $RC"
wave transfer -a bar
[[ "$RC" -eq 1 ]] && pass "-a 与包名混用被拒绝" || fail "-a 与包名混用返回 $RC"
wave transfer bar -s
[[ -z "$OUT" && "$RC" -eq 0 ]] && pass "-s 一个字节都不输出" || fail "-s 仍有输出"

echo "========== 7. 老产物写 @rpath + LC_RPATH：仍要改写（2026-11-24 回归） =========="

# 4.6 之前的一大批产物（htop / ncdu / tmux …）不是绝对路径引用，而是
#   引用 @rpath/libfoo.dylib + LC_RPATH=@loader_path/../lib —— 那个 ../lib 是
#   "包自己旁边"的老布局，而依赖实际在 deps/<依赖>/<依赖>@<版本>/lib 下。
# 2026-11-24 把 @rpath 一律当成"已重定位"跳过，于是装完 htop 立刻
#   "Library not loaded: @rpath/libncursesw.6.dylib"。判据必须是"这条 @rpath
#   在这个文件身上解析得到吗"，解析不到就得照老规矩改写。

build_rpath_legacy() {  # build_rpath_legacy <工作目录> <rpath>
    local root="$1" rpath="$2" stage="$1/stage"
    mkdir -p "$stage/deps/foo/foo@1.0/lib" "$stage/bin/bar@1.0/bin"
    printf 'int foo(void) { return 7; }\n' > "$root/foo.c"
    printf '#include <stdio.h>\nint foo(void);\nint main(void){printf("ok %%d\\n",foo());return 0;}\n' \
        > "$root/main.c"
    clang -dynamiclib -install_name @rpath/libfoo.dylib \
        -Wl,-headerpad_max_install_names \
        -o "$stage/deps/foo/foo@1.0/lib/libfoo.dylib" "$root/foo.c" 2> /dev/null
    clang -o "$stage/bin/bar@1.0/bin/bar" "$root/main.c" \
        -L"$stage/deps/foo/foo@1.0/lib" -lfoo \
        -Wl,-rpath,"$rpath" -Wl,-headerpad_max_install_names 2> /dev/null
}

# A) 老布局（rpath 指 @loader_path/../lib，解析不到）→ 必须改写，且要能跑
RPATH1="$WORK/rpath-legacy"
build_rpath_legacy "$RPATH1" "@loader_path/../lib"
[[ "$(ref_of "$RPATH1/stage/bin/bar@1.0/bin/bar")" == "@rpath/libfoo.dylib" ]] \
    && pass "夹具是「@rpath + 老 rpath」形态" || fail "夹具没造出 @rpath 引用"
transfer --relative "$RPATH1/stage/bin/bar@1.0" "$RPATH1/stage"
case "$(ref_of "$RPATH1/stage/bin/bar@1.0/bin/bar")" in
    @loader_path/*) pass "解析不到的 @rpath 被改写成 @loader_path" ;;
    *) fail "解析不到的 @rpath 没被改写：$(ref_of "$RPATH1/stage/bin/bar@1.0/bin/bar")" ;;
esac
"$RPATH1/stage/bin/bar@1.0/bin/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "改写后能运行" || fail "改写后仍加载不到库"

# B) 同一个夹具再跑一次：一个字节都不该动（ID 那行不能被当成引用空转）
BEFORE=$(sum_of "$RPATH1/stage/bin/bar@1.0/bin/bar")
transfer --relative "$RPATH1/stage/bin/bar@1.0" "$RPATH1/stage"
# transfer.sh 在"零改动"时什么都不打印（"already relative N" 是 Python CLI 层的
# 汇总），所以判据是"没有 Relocated"。
[[ "$OUT" != *"Relocated"* ]] && pass "第二次跑不再改写（零改动时不输出）" \
    || fail "第二次跑仍在改写：$(printf '%.160s' "$OUT")"
[[ "$(sum_of "$RPATH1/stage/bin/bar@1.0/bin/bar")" == "$BEFORE" ]] \
    && pass "第二次跑不改字节" || fail "第二次跑改了字节"

# C) 新形态：rpath 指向依赖树里的真实位置（解析得到）→ 不能动它
RPATH2="$WORK/rpath-new"
build_rpath_legacy "$RPATH2" "@loader_path/../../../deps/foo/foo@1.0/lib"
BEFORE=$(sum_of "$RPATH2/stage/bin/bar@1.0/bin/bar")
transfer --relative "$RPATH2/stage/bin/bar@1.0" "$RPATH2/stage"
[[ "$OUT" != *"Relocated"* ]] \
    && pass "能解析到的 @rpath 被当作已重定位（不白改）" \
    || fail "能解析到的 @rpath 仍被改写：$(printf '%.160s' "$OUT")"
[[ "$(sum_of "$RPATH2/stage/bin/bar@1.0/bin/bar")" == "$BEFORE" ]] \
    && pass "能解析到的产物字节未变（也没重签）" || fail "能解析到的产物被改了字节"
"$RPATH2/stage/bin/bar@1.0/bin/bar" > /dev/null 2>&1
[[ $? -eq 0 ]] && pass "新形态仍能运行" || fail "新形态运行失败"

echo "========== 8. 未签名的 Mach-O 要补 ad-hoc 签名（arm64 才加载得动） =========="

# conda 的依赖库普遍没有签名，而 arm64 上 dyld 拒绝加载未签名的 Mach-O：症状是
#   Symbol not found: _libiconv   Expected in: /usr/lib/libiconv.2.dylib
# —— 依赖树里明明有那份库，dyld 却退到系统里同名的那份去找符号（2026-11-24 的
# gwget）。判据不能是"改没改字节"，得看它本来有没有签名。
SIGN="$WORK/unsigned"
mkdir -p "$SIGN/deps/foo/foo@1.0/lib" "$SIGN/bin/bar@1.0/bin"
printf 'int foo(void) { return 5; }\n' > "$SIGN/foo.c"
printf '#include <stdio.h>\nint foo(void);\nint main(void){printf("ok %%d\\n",foo());return 0;}\n' \
    > "$SIGN/main.c"
clang -dynamiclib -install_name @rpath/libfoo.dylib \
    -Wl,-headerpad_max_install_names \
    -o "$SIGN/deps/foo/foo@1.0/lib/libfoo.dylib" "$SIGN/foo.c" 2> /dev/null
clang -o "$SIGN/bin/bar@1.0/bin/bar" "$SIGN/main.c" \
    -L"$SIGN/deps/foo/foo@1.0/lib" -lfoo \
    -Wl,-rpath,@loader_path/../../../deps/foo/foo@1.0/lib \
    -Wl,-headerpad_max_install_names 2> /dev/null
codesign --remove-signature "$SIGN/deps/foo/foo@1.0/lib/libfoo.dylib" > /dev/null 2>&1
if codesign --verify "$SIGN/deps/foo/foo@1.0/lib/libfoo.dylib" > /dev/null 2>&1; then
    fail "夹具没去掉签名（环境不允许 remove-signature？）"
else
    pass "夹具是一份未签名的 dylib"

    # 安装时 transfer 是**按产物逐个**跑的（软件包一次、每个依赖各一次），
    # 所以依赖目录要自己走一遍 —— 只跑 bin/ 的话，依赖库根本不在遍历范围里。
    transfer --relative "$SIGN/deps/foo/foo@1.0" "$SIGN"
    [[ "$OUT" == *"Signed 1 unsigned Mach-O"* ]] \
        && pass "未签名的那份被补签" || fail "没有补签名：$(printf '%.160s' "$OUT")"
    [[ "$OUT" != *"Relocated"* ]] \
        && pass "补签名不假装成重定位" || fail "把补签名报成了重定位"
    codesign --verify "$SIGN/deps/foo/foo@1.0/lib/libfoo.dylib" > /dev/null 2>&1 \
        && pass "补签后签名有效" || fail "补签后签名仍然无效"

    transfer --relative "$SIGN/bin/bar@1.0" "$SIGN"
    "$SIGN/bin/bar@1.0/bin/bar" > /dev/null 2>&1
    [[ $? -eq 0 ]] && pass "补签后能运行" || fail "补签后仍跑不起来"

    transfer --relative "$SIGN/deps/foo/foo@1.0" "$SIGN"
    [[ -z "$OUT" ]] && pass "第二次跑零改动、零输出（幂等）" \
        || fail "第二次跑仍有输出：$(printf '%.160s' "$OUT")"
fi

echo "========== 9. 带版本号的 dylib 名（libx.dylib.1.7.2）也要认成库 =========="

# 按扩展名判断"这是不是 dylib"会漏掉 `libfdt.dylib.1.7.2` 这种名字：ID 永远停在
# `libfdt.dylib.1`，`wave transfer` 每次都说 needs transfer，`basedir --set` 也就
# 一直拒绝搬（它要求整棵树已经是位置无关的）。判据换成 Mach-O 的 filetype。
VER="$WORK/versioned"
mkdir -p "$VER/deps/foo/foo@1.0/lib" "$VER/bin/bar@1.0/bin"
printf 'int foo(void) { return 9; }\n' > "$VER/foo.c"
printf '#include <stdio.h>\nint foo(void);\nint main(void){printf("ok %%d\\n",foo());return 0;}\n' \
    > "$VER/main.c"
clang -dynamiclib -install_name "libfoo.dylib.1" \
    -Wl,-headerpad_max_install_names \
    -o "$VER/deps/foo/foo@1.0/lib/libfoo.dylib.1.0" "$VER/foo.c" 2> /dev/null
ln -sf libfoo.dylib.1.0 "$VER/deps/foo/foo@1.0/lib/libfoo.dylib.1"
ln -sf libfoo.dylib.1 "$VER/deps/foo/foo@1.0/lib/libfoo.dylib"
clang -o "$VER/bin/bar@1.0/bin/bar" "$VER/main.c" \
    -L"$VER/deps/foo/foo@1.0/lib" -lfoo \
    -Wl,-rpath,@loader_path/../../../deps/foo/foo@1.0/lib \
    -Wl,-headerpad_max_install_names 2> /dev/null

transfer --relative "$VER/deps/foo/foo@1.0" "$VER"
[[ "$(id_of "$VER/deps/foo/foo@1.0/lib/libfoo.dylib.1.0")" == "@rpath/libfoo.dylib.1.0" ]] \
    && pass "带版本号的 dylib 的 ID 也改成了 @rpath/<文件名>" \
    || fail "ID 没改：$(id_of "$VER/deps/foo/foo@1.0/lib/libfoo.dylib.1.0")"

transfer --check "$VER/deps/foo/foo@1.0" "$VER"
[[ "$RC" -eq 0 ]] && pass "改完 --check 返回 0（它自己那条自引用也跟着改了）" \
    || fail "--check 仍然报绝对路径：$(printf '%.160s' "$OUT")"

transfer --relative "$VER/deps/foo/foo@1.0" "$VER"
[[ -z "$OUT" ]] && pass "再跑一次零改动（自引用没有悬空）" \
    || fail "再跑一次仍有输出：$(printf '%.160s' "$OUT")"
# 不在这里断言"能运行"：夹具里可执行文件引用的是**裸文件名** libfoo.dylib.1
# （clang 按 install name 记的），那不是真实老产物的形态（真实产物写绝对路径）。
# 这一段只钉两件事：ID 要按 filetype 认出来并改成 @rpath/<名>，改完 --check 要绿。

echo "========== 10. 用系统 libiconv 的产物不能被换成 conda 那份 =========="

# 判据是**符号名**：`iconv*` 走系统那份，只有 `libiconv*` 才需要 conda 的。
# 2026-11-24 我按文件名一刀切，把 git（用 _iconv/_iconv_open）改到了 conda 的
# libiconv 上 —— conda 那份不导出不带前缀的那组，git 直接
#   Symbol not found: _iconv
ICONV="$WORK/iconv"
mkdir -p "$ICONV/deps/libiconv/libiconv@1.0/lib" "$ICONV/bin/bar@1.0/bin"
# 系统那份 libiconv 在 dyld 共享缓存里，磁盘上没有实体文件，不能直接 cp。
# 造一个 install name 恰好是 /usr/lib/libiconv.2.dylib 的桩库来当"链接目标"，
# 于是可执行文件记下的引用就是 /usr/lib/libiconv.2.dylib（真实老产物的形态），
# 而它导入的符号是不带 lib 前缀的那组。
printf 'typedef void *iconv_t;\niconv_t iconv_open(const char *a, const char *b) { (void)a; (void)b; return (iconv_t)-1; }\nint iconv_close(iconv_t c) { (void)c; return 0; }\n' \
    > "$ICONV/stub.c"
clang -dynamiclib -install_name /usr/lib/libiconv.2.dylib \
    -Wl,-headerpad_max_install_names \
    -o "$ICONV/deps/libiconv/libiconv@1.0/lib/libiconv.dylib" "$ICONV/stub.c" 2> /dev/null
printf '#include <stdio.h>\ntypedef void *iconv_t;\nextern iconv_t iconv_open(const char *, const char *);\nextern int iconv_close(iconv_t);\nint main(void){ iconv_t c = iconv_open("UTF-8","UTF-8"); printf("%%d\\n", c == (iconv_t)-1); if (c != (iconv_t)-1) iconv_close(c); return 0; }\n' \
    > "$ICONV/main.c"
clang -o "$ICONV/bin/bar@1.0/bin/bar" "$ICONV/main.c" \
    -L"$ICONV/deps/libiconv/libiconv@1.0/lib" -liconv \
    -Wl,-headerpad_max_install_names 2> /dev/null

before_iconv="$(otool -L "$ICONV/bin/bar@1.0/bin/bar" | awk 'NR>1 && /iconv/ {print $1}')"
if [[ "$before_iconv" == "/usr/lib/libiconv.2.dylib" ]] && \
   nm -u "$ICONV/bin/bar@1.0/bin/bar" | grep -qx "_iconv_open"; then
    pass "夹具是「引用系统 libiconv + 用 iconv* 符号」"
    transfer --relative "$ICONV/bin/bar@1.0" "$ICONV"
    after_iconv="$(otool -L "$ICONV/bin/bar@1.0/bin/bar" | awk 'NR>1 && /iconv/ {print $1}')"
    [[ "$after_iconv" == "/usr/lib/libiconv.2.dylib" ]] \
        && pass "用 iconv* 的产物留在系统那份上（没被换成 conda 的）" \
        || fail "被换成了 $after_iconv"
    "$ICONV/bin/bar@1.0/bin/bar" > /dev/null 2>&1
    [[ $? -eq 0 ]] && pass "仍能运行" || fail "运行失败"
else
    echo "  ·  跳过：夹具没能引用到系统 libiconv（before=${before_iconv}）"
fi

echo "========== 11. 构建时已重定位的产物（_RELOCATED 标记）直接跳过 =========="
# 构建端按运行时布局算好相对路径、打完包，并在版本目录里留下 _RELOCATED 之后，
# 客户端不该再做任何事 —— 一次 otool 都不该跑。这条断言把"跳过"钉住：
# 既不能改写字节，也不能在 --check / --rescan 时偷懒（那两种就是要真扫）。
MARKED="$WORK/marked"
build_legacy "$MARKED" 7
MPKG="$MARKED/stage/bin/bar@1.0"
MBASE="$MARKED/stage"
transfer --relative "$MPKG" "$MBASE"
sum_before="$(sum_of "$MPKG/bin/bar")"
printf '@loader_path\n' > "$MPKG/_RELOCATED"

transfer "$MPKG" "$MBASE"
[[ -z "$OUT" ]] && pass "带标记：不输出任何东西（连扫描提示都没有）" \
    || fail "带标记却还有输出：$OUT"
[[ "$(sum_of "$MPKG/bin/bar")" == "$sum_before" ]] \
    && pass "带标记：一个字节都没动" || fail "带标记却改写了字节"

transfer --check "$MPKG" "$MBASE"
[[ "$RC" -eq 0 && "$OUT" == *"relative: bin/bar@1.0"* ]] \
    && pass "--check 不认标记，照常核对（确实扫了，结论是 relative）" \
    || fail "--check 在带标记的树上出错（rc=$RC）：$OUT"

# 标记不是护身符：把引用改回绝对路径，--check 必须看得见，--rescan 必须修回来
install_name_tool -change "$(ref_of "$MPKG/bin/bar")" \
    "$MBASE/deps/foo/foo@1.0/lib/libfoo.dylib" "$MPKG/bin/bar" 2>/dev/null
transfer --check "$MPKG" "$MBASE"
[[ "$RC" -ne 0 ]] && pass "--check 能看见标记之外的绝对引用" \
    || fail "--check 被标记骗过去了"
transfer --relative --rescan "$MPKG" "$MBASE"
[[ "$(ref_of "$MPKG/bin/bar")" == @loader_path/* ]] \
    && pass "--rescan 无视标记重新重定位" \
    || fail "--rescan 没有重新重定位：$(ref_of "$MPKG/bin/bar")"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All relocation tests passed${RESET}"
