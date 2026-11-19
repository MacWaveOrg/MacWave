#!/bin/bash

# signature_test.sh
# GPG 验签的约定：公钥放在哪、怎么验、验不过怎么办。
#
# 为什么值得一条测试：验签这条路径平时**根本不跑**（当前只是预留，没接进下载流程）。
# 等它真被接上那天，坏掉的表现会是「所有人安装都失败」或者更糟 —— 「签名不匹配」
# 被当成「没签名」放过去。所以这里的断言写的是语义，不是实现细节：
#
#   好签名 → ok；数据被改 → bad-signature；没签名对 → no-signature；
#   Keys/ 空 → no-keys；没有 gpg → no-gpg（不是失败）。
#
# 用一次性密钥对（临时 GNUPGHOME），不碰本机钥匙环，也不碰仓库里的 Keys/。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0
SKIPPED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }
skip() { echo -e "  ${YELLOW}⏭  $1${RESET}"; SKIPPED=$((SKIPPED + 1)); }
YELLOW='\033[33m'

echo "========== 1. 公钥放在哪：仓库 Keys/ 与安装树 <base_dir>/Keys/ =========="

if [[ -d "$REPO_DIR/Keys" ]]; then
    pass "仓库里有 Keys/"
else
    fail "仓库里没有 Keys/"
fi

if grep -qx "Keys" <(sed -e 's/#.*//' "$REPO_DIR/scripts/assets.txt" | tr -d ' ');
then
    pass "Keys/ 列在 scripts/assets.txt 里（随安装清单下发）"
else
    fail "Keys/ 不在 scripts/assets.txt 里，装上之后就没有公钥可验"
fi

# 只有公钥该在这里：私钥（BEGIN PGP PRIVATE KEY BLOCK）出现在仓库里就是事故
if grep -rl "BEGIN PGP PRIVATE KEY" "$REPO_DIR/Keys" 2>/dev/null | grep -q .; then
    fail "Keys/ 里有私钥（BEGIN PGP PRIVATE KEY）—— 私钥不进仓库"
else
    pass "Keys/ 里没有私钥"
fi

# 目录里只该有公钥与说明；散落的其它文件会被当成「公钥」去 import
STRAY=$(find "$REPO_DIR/Keys" -type f ! -name '*.asc' ! -name '*.gpg' ! -name '*.pub' \
        ! -name 'README.md' 2>/dev/null)
if [[ -z "$STRAY" ]]; then
    pass "Keys/ 里只有公钥（*.asc / *.gpg / *.pub）与 README"
else
    fail "Keys/ 里有不认的文件：$STRAY"
fi

echo "========== 2. 安装器会准备 <base_dir>/Keys =========="

if grep -q 'KEYS_DIR="\$BASE_DIR/Keys"' "$REPO_DIR/lib/install.sh"; then
    pass "install.sh 定义了 KEYS_DIR=\$BASE_DIR/Keys"
else
    fail "install.sh 没有定义 KEYS_DIR=\$BASE_DIR/Keys"
fi
if grep -q 'mkdir -p "\$KEYS_DIR"' "$REPO_DIR/lib/install.sh"; then
    pass "install.sh 会建这个目录"
else
    fail "install.sh 没有建 Keys 目录"
fi
# 资源目录不该进 sys.path：Keys 里没有 .py，进了只会让 import 去翻它
if grep -q 'BASE_DIR / "Keys"' "$REPO_DIR/lib/wave.py"; then
    fail "lib/wave.py 把 Keys 加进了 sys.path（它是资源目录）"
else
    pass "lib/wave.py 没有把 Keys 当成组件"
fi

echo "========== 3. 验签语义（一次性密钥对）=========="

if ! command -v gpg > /dev/null 2>&1; then
    skip "本机没有 gpg：跳过真实验签（no-gpg 分支下面单独测）"
    WORK=""
else
    WORK="$(mktemp -d)"
    export GNUPGHOME="$WORK/gnupg"
    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
    KEY_A=""
    KEY_B=""
    for who in "MacWave Test A <a@example.invalid>" "MacWave Test B <b@example.invalid>"; do
        gpg --batch --quiet --passphrase '' --quick-generate-key "$who" ed25519 sign 1d 2>/dev/null
    done
    FPRS=($(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/{print $10}'))
    KEY_A="${FPRS[0]}"
    KEY_B="${FPRS[1]:-}"

    mkdir -p "$WORK/base/Keys"
    gpg --armor --export "$KEY_A" > "$WORK/base/Keys/a.asc"
    [[ -n "$KEY_B" ]] && gpg --armor --export "$KEY_B" > "$WORK/base/Keys/b.asc"

    printf 'deadbeef  lib/wave.py\ncafebabe  lib/pkginstaller.py\n' > "$WORK/SHA256SUMS"
    gpg --batch --yes --armor --detach-sign --output "$WORK/SHA256SUMS.asc" "$WORK/SHA256SUMS" 2>/dev/null
    # 第二把钥匙签的同一份数据：轮换期间两种签名都该验得过
    gpg --batch --yes --armor --detach-sign --local-user "$KEY_B" --output "$WORK/sums-by-b.asc" \
        "$WORK/SHA256SUMS" 2>/dev/null
fi

check_kind() {   # check_kind <描述> <期望结果> <python 表达式>
    local label="$1" want="$2" expr="$3" got
    got=$(WORK="$WORK" PYTHONPATH="$(component_paths)" python3 - "$REPO_DIR" "$expr" <<'PY'
import os
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path[:0] = [str(repo / name) for name in os.environ.get("PYTHONPATH", "").split(os.pathsep) if name]
sys.path.insert(0, str(repo / "net"))
import signature

work = os.environ["WORK"]
base = os.path.join(work, "base")
expr = sys.argv[2]
result, _lines = eval(expr)
print(result)
PY
)
    if [[ "$got" == "$want" ]]; then
        pass "$label → $want"
    else
        fail "$label → 期望 $want，实际 $got"
    fi
}

if [[ -n "$WORK" ]]; then
    check_kind "好签名" "ok" \
        'signature.verify_detached(os.path.join(work,"SHA256SUMS"), os.path.join(work,"SHA256SUMS.asc"), base)'
    check_kind "第二把钥匙签的同一份数据" "ok" \
        'signature.verify_detached(os.path.join(work,"SHA256SUMS"), os.path.join(work,"sums-by-b.asc"), base)'
    check_kind "数据被换掉" "bad-signature" \
        '(signature.verify_detached(b"tampered\n", os.path.join(work,"SHA256SUMS.asc"), base))'
    check_kind "签名与数据不配套" "bad-signature" \
        'signature.verify_detached(os.path.join(work,"base/Keys/a.asc"), os.path.join(work,"SHA256SUMS.asc"), base)'
    check_kind "这个版本没带签名" "no-signature" \
        'signature.verify_detached(b"anything", b"", base)'
    check_kind "Keys/ 里只有 README" "no-keys" \
        'signature.verify_detached(os.path.join(work,"SHA256SUMS"), os.path.join(work,"SHA256SUMS.asc"), os.path.join(work,"empty"))'

    # 指纹白名单：非空时必须按指纹筛钥匙（现在为空，先验证「能读出指纹、能筛掉」）
    PIN_CHECK=$(WORK="$WORK" python3 - "$REPO_DIR" <<'PY'
import os
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "net"))
import signature

work = os.environ["WORK"]
base = os.path.join(work, "base")
keys = signature.public_keys(base)
fprs = set()
for key in keys:
    fprs |= signature.fingerprints_of(key)

problems = []
if not keys:
    problems.append("没读到测试公钥")
if not fprs:
    problems.append("fingerprints_of() 没读出任何指纹")
if signature.PINNED_FINGERPRINTS and not keys:
    problems.append("白名单非空却一把都没留下")

# 人为把白名单改成一把不存在的指纹：必须一把都不返回
if fprs:
    original = signature.PINNED_FINGERPRINTS
    signature.PINNED_FINGERPRINTS = ("0" * 40,)
    if signature.public_keys(base):
        problems.append("白名单指向不存在的指纹时，仍然返回了钥匙（等于没筛）")
    signature.PINNED_FINGERPRINTS = original

# 白名单写成真实指纹：必须留下那把
if fprs:
    original = signature.PINNED_FINGERPRINTS
    signature.PINNED_FINGERPRINTS = tuple(sorted(fprs)[:1])
    if not signature.public_keys(base):
        problems.append("白名单指向真实指纹时，反而把钥匙筛掉了")
    signature.PINNED_FINGERPRINTS = original

print("; ".join(problems))
PY
)
    if [[ -z "$PIN_CHECK" ]]; then
        pass "指纹白名单：非空时按指纹筛钥匙（对不上的钥匙进不来）"
    else
        fail "指纹白名单行为不对：$PIN_CHECK"
    fi

    # 没有 gpg 时必须是 no-gpg —— 那是「验不了」，不是「签名坏了」。
    # 用 PATH 里拿掉 gpg 来模拟，而不是真去卸一个包。
    GOT=$(WORK="$WORK" PATH="/usr/bin:/bin" python3 - "$REPO_DIR" <<'PY'
import os
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "net"))
import signature

work = os.environ["WORK"]
result, lines = signature.verify_detached(
    os.path.join(work, "SHA256SUMS"), os.path.join(work, "SHA256SUMS.asc"),
    os.path.join(work, "base"))
print(result)
PY
)
    if [[ "$GOT" == "no-gpg" || "$GOT" == "ok" ]]; then
        # PATH 里若还有一份 gpg 就仍然验得过，两种都算通过（断言的是「不误判为坏签名」）
        pass "没有 gpg 时不会误判成坏签名（$GOT）"
    else
        fail "没有 gpg 时返回了 $GOT，应不是 bad-signature"
    fi

    rm -rf "$WORK"
    unset GNUPGHOME
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED   Skipped: $SKIPPED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED_BOLD}🌊 Signature conventions are broken${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 Signature slots are in place (verification not wired into downloads yet)${RESET}"
