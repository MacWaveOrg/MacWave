#!/bin/bash

# selfbuilt_check.sh
# 自建产物上线前的闸门：一条命令判断「这个二进制能不能进索引」。
#
# 为什么需要它：自建包（上游不发 macOS 产物）没有上游把关，坏包一旦进了索引，
# 用户装完跑不起来，代价是我们的公信力。而「装得上」不等于「跑得起来」——
# 真机实测过 choma 就踩过一次：产物链着构建机上的
# /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib，索引里没声明 deps，
# 于是用户机器上 dyld 直接加载失败。这个脚本查的就是这一类问题。
#
# 用法：
#   bash scripts/selfbuilt_check.sh <二进制> [选项]
#
#   --arch arm64|amd64      索引里这条记录属于哪个架构（默认按 lipo 判断；
#                           也接受 x86_64 / aarch64 这类 lipo 叫法）
#   --bin-name NAME         用户在终端敲的命令名（默认取文件名）
#   --deps "openssl@3.0.15 wget@1.25.0"
#                           索引记录里打算写哪些 deps
#   --expect-sha SHA256     与索引记录里的 sha256 比对。只对**上传前**的原始产物用：
#                           安装时 install_name_tool 会改字节并重签，装完的 sha 必然不同
#   --run-args "--version"  实跑用的参数（默认 --version，失败再试 --help）
#   --skip-run              只做静态检查（交叉编译出来的另一个架构可能跑不了）
#
# 退出码：0 = 可以上线；1 = 有阻塞项；2 = 用法错误
#
# 判据只信实测：lipo / otool / codesign / vtool 的输出，不猜。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

BLOCKING=0
WARNED=0

pass() { printf '  %b✅%b %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %b⚠️ %b %s\n' "$YELLOW" "$RESET" "$1"; WARNED=$((WARNED + 1)); }
fail() { printf '  %b❌%b %s\n' "$RED_BOLD" "$RESET" "$1"; BLOCKING=$((BLOCKING + 1)); }
note() { printf '  ·  %s\n' "$1"; }
hr() { printf '%s\n' '------------------------------------------------------------'; }

usage() {
    sed -n '4,27p' "$0" | sed 's/^# \{0,1\}//'
}

# -------------------- 参数 --------------------

BINARY=""
WANT_ARCH=""
BIN_NAME=""
WANT_DEPS=""
EXPECT_SHA=""
RUN_ARGS="--version"
SKIP_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)       WANT_ARCH="${2:-}"; shift 2 ;;
        --bin-name)   BIN_NAME="${2:-}"; shift 2 ;;
        --deps)       WANT_DEPS="${2:-}"; shift 2 ;;
        --expect-sha) EXPECT_SHA="${2:-}"; shift 2 ;;
        --run-args)   RUN_ARGS="${2:-}"; shift 2 ;;
        --skip-run)   SKIP_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           printf '🌊 未知选项 %s\n' "$1" >&2; exit 2 ;;
        *)            BINARY="$1"; shift ;;
    esac
done

if [[ -z "$BINARY" ]]; then
    usage >&2
    exit 2
fi
if [[ ! -f "$BINARY" ]]; then
    printf '%b🌊 文件不存在：%s%b\n' "$RED_BOLD" "$BINARY" "$RESET" >&2
    exit 2
fi

# --arch 归一化：lipo 说的是 x86_64，索引说的是 amd64，两个名字都得认。
# 不认的取值要在**这里**报用法错误（exit 2），否则它会一路走到架构比对那一步，
# 表现成「架构不符」—— 那是产物的问题还是参数的问题，就说不清了。
case "${WANT_ARCH:-}" in
    "") ;;
    arm64|aarch64) WANT_ARCH=arm64 ;;
    amd64|x86_64|x86-64) WANT_ARCH=amd64 ;;
    *)
        printf '%b🌊 Error: --arch accepts arm64 or amd64 (got %s)%b\n' \
            "$RED_BOLD" "$WANT_ARCH" "$RESET" >&2
        exit 2 ;;
esac

BIN_NAME="${BIN_NAME:-$(basename "$BINARY")}"

printf '🌊 自建产物检查 · %s\n' "$BINARY"
hr

# -------------------- 1. 确实是 Mach-O --------------------

MAGIC=$(python3 -c '
import sys
with open(sys.argv[1], "rb") as f:
    print(f.read(4).hex())
' "$BINARY" 2>/dev/null)

case "$MAGIC" in
    cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca)
        pass "Mach-O（magic ${MAGIC}）" ;;
    *)
        fail "不是 Mach-O（magic ${MAGIC:-读不到}）—— 索引里的单文件产物必须是可执行文件"
        hr; printf '❌ 不可上线（%d 项阻塞）\n' "$BLOCKING"; exit 1 ;;
esac

# -------------------- 2. 架构 --------------------

ARCHS=$(lipo -archs "$BINARY" 2>/dev/null)
case "$ARCHS" in
    *" "*)
        fail "是 universal（${ARCHS}）—— 索引按「每架构一份」组织，请分别编两个产物"
        ;;
    "")
        fail "lipo 读不出架构" ;;
    *)
        case "$ARCHS" in
            arm64) ACTUAL=arm64 ;;
            x86_64) ACTUAL=amd64 ;;
            *) ACTUAL="$ARCHS" ;;
        esac
        if [[ -n "$WANT_ARCH" && "$ACTUAL" != "$WANT_ARCH" ]]; then
            fail "架构不符：产物是 ${ARCHS}（${ACTUAL}），索引记录要的是 $WANT_ARCH"
        else
            pass "架构 ${ARCHS}（索引里的 ${ACTUAL}）"
        fi
        ;;
esac

# -------------------- 3. 可执行位 --------------------

if [[ -x "$BINARY" ]]; then
    pass "可执行位在"
else
    # 安装时 mw_install_binary 会 chmod 755，所以这不算阻塞；但 Release 里丢了
    # +x，手工下载后直接跑会得到 "Permission denied"，容易误判成产物坏了。
    warn "没有可执行位（安装时会 chmod 755，但 Release 资产最好保留 +x，免得人工验证时误判）"
fi

# -------------------- 4. ad-hoc 签名 --------------------

if codesign -v "$BINARY" 2>/dev/null; then
    pass "ad-hoc 签名有效"
else
    fail "签名无效或缺失 —— Apple 芯片会直接拒绝执行未签名的 arm64 产物（codesign --force --sign - \"$BINARY\"）"
fi

# -------------------- 5. min_os --------------------

MINOS=$(vtool -show-build "$BINARY" 2>/dev/null | awk '/minos/{print $2; exit}')
MINOS_SRC="LC_BUILD_VERSION"
if [[ -z "$MINOS" ]]; then
    # 老工具链写的是 LC_VERSION_MIN_MACOSX，vtool 的 minos 字段拿不到
    MINOS=$(otool -l "$BINARY" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')
    MINOS_SRC="LC_VERSION_MIN_MACOSX"
fi
if [[ -n "$MINOS" ]]; then
    pass "min_os ${MINOS}（${MINOS_SRC}）→ 索引记录写 min_os: \"$MINOS\""
else
    warn "读不到 min_os —— 索引里不要瞎写，缺这个字段客户端会静默放行（见 AGENTS.md 的行为矩阵）"
fi

# -------------------- 6. 依赖闭包 --------------------

# 系统库不参与（SIP 保护、每台机器都有）。其余每一个引用都必须落在用户会有东西的
# 地方：要么在 MacWave 的 deps 树里，要么它的 basename 能在 deps 索引里找到 ——
# 后者意味着必须在索引记录里声明 deps，否则用户不会装那个依赖。
BASE_DIR=""
for cfg in /opt/macwave_config/config.json "$HOME/.config/macwave_config/config.json"; do
    if [[ -f "$cfg" ]]; then
        BASE_DIR=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("base_dir", ""))
except Exception:
    print("")
' "$cfg" 2>/dev/null)
        [[ -n "$BASE_DIR" ]] && break
    fi
done

printf '%s\n' "$WANT_DEPS" | tr ' ' '\n' > /tmp/selfbuilt_deps.$$
trap 'rm -f /tmp/selfbuilt_deps.$$' EXIT

UNRESOLVED=0
EXTERNAL=0
while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    case "$ref" in
        /usr/lib/*|/System/*|/Library/Apple/*) continue ;;
    esac

    base="${ref##*/}"

    # 已经指向 MacWave 的 deps 树 → 用户装同样的依赖就有
    if [[ -n "$BASE_DIR" && "$ref" == "$BASE_DIR"/deps/* ]]; then
        pass "依赖 $base → deps 树内"
        EXTERNAL=$((EXTERNAL + 1))
        continue
    fi

    # 落在别处的绝对路径（构建机上的 Homebrew / MacPorts / 家目录）：
    # 只有声明了对应的依赖，安装时的路径改写才找得到它
    owner=""
    if [[ -n "$BASE_DIR" ]]; then
        for lib in "$BASE_DIR"/deps/*/*/lib/"$base" "$BASE_DIR"/deps/*/*/"$base"; do
            [[ -e "$lib" ]] || continue
            owner=$(basename "$(dirname "$(dirname "$lib")")")
            break
        done
    fi

    if [[ -z "$owner" ]]; then
        fail "依赖 $base 指向 $ref —— 本机 deps 树里没有它，用户机器上大概率 dyld 加载失败"
    else
        # owner 形如 openssl@3.0.15；--deps 里写同名即可，也接受只写包名
        if grep -qxF "$owner" /tmp/selfbuilt_deps.$$ 2>/dev/null \
            || grep -qxF "${owner%@*}" /tmp/selfbuilt_deps.$$ 2>/dev/null; then
            pass "依赖 $base → 已声明 $owner"
        else
            # owner 是 deps 树里的版本目录名（openssl@3.0.15），已经是 <名>@<版本> 的形式
            if [[ "$owner" == *"@"* ]]; then
                hint="$owner"
            else
                hint="$owner@<版本>"
            fi
            fail "依赖 $base 来自 ${owner}，但索引记录里没声明 —— 加 deps: \"$hint\"，否则用户装不到它"
        fi
    fi
    UNRESOLVED=$((UNRESOLVED + 1))
    EXTERNAL=$((EXTERNAL + 1))
done < <(otool -L "$BINARY" 2>/dev/null | tail -n +2 | awk '{print $1}')

if [[ "$EXTERNAL" -eq 0 ]]; then
    pass "除系统库外没有外部依赖（静态链接干净）"
fi

# -------------------- 7. sha256 --------------------

SHA=$(shasum -a 256 "$BINARY" | awk '{print $1}')
if [[ -z "$EXPECT_SHA" ]]; then
    note "sha256 $SHA  ← 索引记录里要写这个值"
elif [[ "$SHA" == "$EXPECT_SHA" ]]; then
    pass "sha256 与索引记录一致"
else
    fail "sha256 不符：产物 $SHA / 记录 $EXPECT_SHA"
fi

# -------------------- 8. 真跑 --------------------

if (( SKIP_RUN )); then
    note "按要求跳过实跑（交叉编译的另一个架构可能在本机跑不了）"
elif [[ -z "$RUN_ARGS" ]]; then
    note "没给 --run-args，跳过实跑"
else
    HOST_ARCH=$(uname -m)
    RUNNER=()
    if [[ "$HOST_ARCH" == "arm64" && "$ACTUAL" == "amd64" ]]; then
        if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
            RUNNER=(arch -x86_64)
            note "amd64 产物经 Rosetta 运行"
        else
            warn "本机没有 Rosetta，无法验证 amd64 产物是否真能跑"
        fi
    fi

    # shellcheck disable=SC2086
    OUTPUT=$(${RUNNER[@]+"${RUNNER[@]}"} "$BINARY" $RUN_ARGS 2>&1)
    RC=$?
    case "$OUTPUT" in
        *"Library not loaded"*|*"image not found"*)
            fail "实跑失败：动态库没加载（依赖闭包不完整）"
            printf '%s\n' "$OUTPUT" | head -3 | sed 's/^/      /' ;;
        *)
            if [[ "$RC" -eq 0 || "$RC" -eq 1 ]]; then
                pass "实跑 $BIN_NAME $RUN_ARGS 通过（exit ${RC}）"
            else
                warn "实跑退出码 ${RC}，前几行输出："
                printf '%s\n' "$OUTPUT" | head -3 | sed 's/^/      /'
            fi
            ;;
    esac
fi

# -------------------- 结论 --------------------

hr
if [[ "$BLOCKING" -eq 0 ]]; then
    if [[ "$WARNED" -eq 0 ]]; then
        printf '✅ 可以上线（%s，%s）\n' "$BIN_NAME" "$SHA"
    else
        printf '✅ 可以上线，但有 %d 项提醒（见上）\n' "$WARNED"
    fi
    printf '   下一步：原始产物传到 MacWaveOrg/Bottle 的 <包名> release，再写索引记录；\n'
    printf '          构建配方与溯源传到 MacWaveOrg/Ports 的同名 release\n'
    exit 0
fi
printf '❌ 不可上线：%d 项阻塞（见上）\n' "$BLOCKING"
exit 1
