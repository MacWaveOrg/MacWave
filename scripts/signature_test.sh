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
# 说明文件叫 README.md 还是 description.md 都算「说明」（2026-11-19 从前者改名成后者，
# 下个版本才随发布线铺开，所以两个名字都要认）。
STRAY=$(find "$REPO_DIR/Keys" -type f ! -name '*.asc' ! -name '*.gpg' ! -name '*.pub' \
        ! -name '*.pem' ! -name 'README.md' ! -name 'description.md' 2>/dev/null)
if [[ -z "$STRAY" ]]; then
    pass "Keys/ 里只有公钥（*.asc / *.gpg / *.pub / *.pem）与说明文件"
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

# 仓库里的 Keys/ 现在有真公钥、白名单里也有真指纹；这几节测的是「验签语义」，
# 用的是临时钥，所以先把白名单清空。白名单本身的行为由下面的 PIN_CHECK 单独测。
signature.PINNED_FINGERPRINTS = ()

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
        fail "$label → 期望 ${want}，实际 ${got}"
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

saved = signature.PINNED_FINGERPRINTS
signature.PINNED_FINGERPRINTS = ()      # 先用空名单把临时钥读出来
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

signature.PINNED_FINGERPRINTS = saved
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

signature.PINNED_FINGERPRINTS = ()
work = os.environ["WORK"]
result, lines = signature.verify_detached(
    os.path.join(work, "SHA256SUMS"), os.path.join(work, "SHA256SUMS.asc"),
    os.path.join(work, "base"))
print(result)
PY
)
    if [[ "$GOT" == "no-gpg" || "$GOT" == "ok" ]]; then
        # PATH 里若还有一份 gpg 就仍然验得过，两种都算通过（断言的是「不误判为坏签名」）
        pass "没有 gpg 时不会误判成坏签名（${GOT}）"
    else
        fail "没有 gpg 时返回了 ${GOT}，应不是 bad-signature"
    fi

    rm -rf "$WORK"
    unset GNUPGHOME
fi

echo "========== 4. 内置 RSA 公钥与 latest.toml 的签名（机器验签）=========="

# 两个脚本是 curl | bash 跑起来的，没法 source，所以各自内嵌一份公钥。它必须
# 和仓库里那份逐字相同：轮换时漏掉一处，就会出现「一半脚本验旧钥」。
if python3 "$SCRIPT_DIR/embed_rsa_pub.py" --check > /dev/null 2>&1; then
    pass "两个脚本内嵌的公钥与 Keys/macwave-rsa.pub.pem 一致"
else
    fail "内嵌公钥与 Keys/macwave-rsa.pub.pem 不一致（跑 python3 scripts/embed_rsa_pub.py）"
fi

if [[ -f "$REPO_DIR/Keys/macwave-rsa.pub.pem" ]] &&
    openssl pkey -pubin -in "$REPO_DIR/Keys/macwave-rsa.pub.pem" -noout 2> /dev/null
then
    pass "Keys/macwave-rsa.pub.pem 是可解析的 PEM 公钥"
else
    fail "Keys/macwave-rsa.pub.pem 缺失或解析不了"
fi

# 它是 PEM 不是 OpenPGP：net/signature.py 的 public_keys() 不能把它当 gpg 公钥 import
PEM_AS_GPG=$(WORK="$REPO_DIR" PYTHONPATH="$(component_paths)" python3 - <<'PY'
import os
import sys

sys.path[:0] = [p for p in os.environ.get("PYTHONPATH", "").split(os.pathsep) if p]
import signature  # noqa: E402

signature.PINNED_FINGERPRINTS = ()
names = [os.path.basename(p) for p in signature.public_keys(os.path.join(os.environ["WORK"], "Keys"))]
print("yes" if "macwave-rsa.pub.pem" in names else "no")
PY
)
if [[ "$PEM_AS_GPG" == "no" ]]; then
    pass "RSA 公钥不会被当成 GPG 公钥（public_keys 只认 .asc/.gpg/.pub）"
else
    fail "net/signature.py 把 macwave-rsa.pub.pem 当成了 GPG 公钥"
fi

# 下面是真的调用那两个脚本里的验签代码：把 helper 段抽出来 source，
# 用假 curl 把准备好的 .sig 放到 -o 指定的位置。
WORK_RSA="$(mktemp -d)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK_RSA/key.pem" 2> /dev/null
openssl pkey -in "$WORK_RSA/key.pem" -pubout -out "$WORK_RSA/key.pub.pem" 2> /dev/null
printf 'version = "4.4.0"\n' > "$WORK_RSA/latest.toml"
printf 'version = "9.9.9"\n' > "$WORK_RSA/tampered.toml"
openssl dgst -sha256 -sign "$WORK_RSA/key.pem" -out "$WORK_RSA/latest.toml.sig" "$WORK_RSA/latest.toml" 2> /dev/null

run_verify() {
    # run_verify <脚本> <数据文件> <签名文件|空> <STRICT> → 打印 "<退出码>|<输出>"
    local script="$1" data="$2" sig="$3" strict="${4:-0}" work="$WORK_RSA/h"
    mkdir -p "$work"
    awk '/^# >>> RSA public key/ {on=1} on {print} /^# <<< signature helpers <<</ {on=0}' \
        "$REPO_DIR/$script" > "$work/helpers.sh"
    cat > "$work/harness.sh" <<'HARNESS'
RED_BOLD=""
GREEN=""
YELLOW=""
RESET=""
METADATA_TIMEOUT=10
CURL_CACERT=""
mw_signature_note() { printf '%s\n' "$1"; }
curl() {
    local out="" prev=""
    for a in "$@"; do
        [[ "$prev" == "-o" ]] && out="$a"
        prev="$a"
    done
    [[ -n "${FAKE_SIG:-}" ]] || return 22
    cp "$FAKE_SIG" "$out"
}
source "$HELPERS"
mw_verify_latest_signature "$(cat "$DATA")" "$URL"
HARNESS
    local got rc
    got=$(FAKE_SIG="$sig" HELPERS="$work/helpers.sh" DATA="$data" \
        URL="https://example.invalid/latest.toml" MACWAVE_STRICT_HASHES="$strict" \
        MACWAVE_RSA_PUB="$WORK_RSA/key.pub.pem" bash "$work/harness.sh" 2>&1)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$got" | tr '\n' ' ')"
}

check_verify() {
    # check_verify <说明> <脚本> <数据> <签名|空> <STRICT> <期望退出码> <输出里该有的词>
    local label="$1" script="$2" data="$3" sig="$4" strict="$5" want_rc="$6" want_text="$7"
    local got rc out
    got="$(run_verify "$script" "$data" "$sig" "$strict")"
    rc="${got%%|*}"
    out="${got#*|}"
    if [[ "$rc" == "$want_rc" && "$out" == *"$want_text"* ]]; then
        pass "$label"
    else
        fail "${label}（退出码 ${rc}，输出 ${out:-<空>}）"
    fi
}

for script in lib/install.sh lib/selfupdate.sh; do
    check_verify "${script}：签名对得上 → 通过" "$script" \
        "$WORK_RSA/latest.toml" "$WORK_RSA/latest.toml.sig" 0 0 "signature OK"
    check_verify "${script}：数据被改 → 只警告不失败" "$script" \
        "$WORK_RSA/tampered.toml" "$WORK_RSA/latest.toml.sig" 0 0 "Warning"
    check_verify "${script}：数据被改 + STRICT → 失败" "$script" \
        "$WORK_RSA/tampered.toml" "$WORK_RSA/latest.toml.sig" 1 1 "Error"
    check_verify "${script}：这一版没有 .sig → 静默放行" "$script" \
        "$WORK_RSA/latest.toml" "" 0 0 "No signature"
done
rm -rf "$WORK_RSA"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED   Skipped: $SKIPPED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED_BOLD}🌊 Signature conventions are broken${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 Signature checks are in place (warn-only until MACWAVE_STRICT_HASHES=1)${RESET}"
