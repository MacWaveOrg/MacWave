#!/bin/bash

# tls_test.sh
# 证书失败的分诊：同一句「SSL error」不许再对应同一条建议。
#
# 为什么值得一条测试：分诊的输入是错误文本 —— requests / urllib3 / curl 三家
# 的措辞各不相同，还各带一层 "Caused by"。认错一个字，用户的下一步就从
# 「找网管要根证书」变成「重试」，而这类错永远不会在开发机上出现。
#
# 全程离线：只做字符串分类，最多读一次 selfupdate.sh 里的函数定义。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

echo "========== 1. Python 侧：五类各就各位 =========="

PROBLEMS=$(python3 - "$REPO_DIR" << 'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
from components import paths as component_paths

sys.path[:0] = [str(path) for path in component_paths(repo)]
import tls

problems = []

# 真实的报错文本（requests / urllib3 的包装一字未改，包括 "Caused by" 那层）
CASES = [
    ("expired",
     "HTTPSConnectionPool(host='mirror.example', port=443): Max retries exceeded with url: /x "
     "(Caused by SSLError(SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] "
     "certificate verify failed: certificate has expired (_ssl.c:1016)')))",
     tls.EXPIRED),
    ("self-signed",
     "SSLError(SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] certificate "
     "verify failed: self-signed certificate in certificate chain (_ssl.c:1016)'))",
     tls.SELF_SIGNED),
    ("incomplete chain",
     "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local "
     "issuer certificate (_ssl.c:1016)",
     tls.INCOMPLETE),
    ("hostname mismatch",
     "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: Hostname mismatch, "
     "certificate is not valid for 'cdn.example.net'. (_ssl.c:1016)",
     tls.HOSTNAME),
    ("dns",
     "HTTPSConnectionPool(host='nope.invalid', port=443): Max retries exceeded with url: / "
     "(Caused by NameResolutionError(\": Failed to resolve 'nope.invalid' ([Errno 8] "
     "nodename nor servname provided, or not known)\"))",
     tls.NETWORK),
    ("timeout", "HTTPSConnectionPool(host='x', port=443): Read timed out. (read timeout=30)",
     tls.NETWORK),
    ("refused", "[Errno 61] Connection refused", tls.NETWORK),
    ("other certificate",
     "[SSL: CERTIFICATE_VERIFY_FAILED] unknown error (_ssl.c:1016)", tls.CERT_OTHER),
]

for label, text, want in CASES:
    got = tls.classify(text)
    if got != want:
        problems.append(f"{label}: 分类成 {got!r}，应为 {want!r}")

# 下一步要对得上分类 —— 认错类别时通常先错在这里
NEEDLES = {
    tls.EXPIRED: "has expired",
    tls.SELF_SIGNED: "root certificate",
    tls.INCOMPLETE: "intermediate",
    tls.HOSTNAME: "do not work around",
    tls.NETWORK: "not a TLS or certificate one",
    tls.CERT_OTHER: "mirror",
}
for label, text, _want in CASES:
    explained = tls.explain(text)
    if explained is None:
        problems.append(f"{label}: explain() 没给出结论")
        continue
    kind = tls.classify(text)
    blob = (explained[0] + " " + " ".join(explained[1])).lower()
    needle = (NEEDLES.get(kind) or "").lower() or None
    if needle and needle not in blob:
        problems.append(f"{label}: 建议里没有 {needle!r}（{explained[0]}）")

# 认不出来的输入不能硬塞一个分类
if tls.classify("HTTP 404") is not None:
    problems.append("HTTP 404 被当成了证书问题")
if tls.hints("HTTP 404", fallback=["fallback line"]) != ["fallback line"]:
    problems.append("认不出时没有退回 fallback")
if not tls.hints("certificate has expired")[0].startswith("the server's certificate"):
    problems.append("hints() 没有把分类结论放在第一行")

# notAfter 的格式化：证书里是 "Sep  1 00:00:00 2026 GMT"，输出要能直接读
if tls._not_after({"notAfter": "Sep  1 00:00:00 2026 GMT"}) != "2026-09-01":
    problems.append("notAfter 没有格式化成 YYYY-MM-DD")
if tls._not_after({}) is not None:
    problems.append("没有 notAfter 时应当返回 None")

print("\n".join(problems))
PY
)

if [ -z "$PROBLEMS" ]; then
    pass "过期 / 自签 / 链不完整 / 主机名 / 网络 / 其它证书 六类都分对了"
else
    while IFS= read -r line; do
        [ -n "$line" ] && fail "$line"
    done <<< "$PROBLEMS"
fi

echo "========== 2. bash 侧：selfupdate.sh 的 curl_hint =========="

# 只取函数定义，不执行整个脚本（那会真的去自更新）
CURL_HINT_FILE="$(mktemp)"
awk '/^curl_hint\(\)/,/^}/' "$REPO_DIR/lib/selfupdate.sh" > "$CURL_HINT_FILE"
RED_BOLD=''
RESET=''
# shellcheck disable=SC1090
source "$CURL_HINT_FILE"

hint_case() {   # hint_case <描述> <退出码> <stderr> <期望包含的片段>
    local label="$1" status="$2" err="$3" want="$4" out
    out="$(curl_hint "$status" "$err" 2>&1 || true)"
    if [[ "$out" == *"$want"* ]]; then
        pass "$label"
    else
        fail "${label}（实际：${out:0:120}）"
    fi
}

hint_case "curl 说证书过期"        60 "curl: (60) SSL certificate problem: certificate has expired" "has expired"
hint_case "curl 说自签"            60 "curl: (60) SSL certificate problem: self-signed certificate" "self-signed"
hint_case "curl 说拿不到签发者"    60 "curl: (60) unable to get local issuer certificate" "chain is incomplete"
hint_case "curl 说主机名不对"      60 "curl: (60) certificate is not valid for this host" "not valid for this host"
hint_case "解析不了主机名（退出码 6）" 6 "" "not a TLS or certificate one"
hint_case "连不上（退出码 7）"         7 "" "not a TLS or certificate one"
hint_case "只有证书类退出码（60）"     60 "" "certificate verification failed"

if [[ -z "$(curl_hint 42 "" 2>&1 || true)" ]]; then
    pass "认不出的失败不硬编一句话"
else
    fail "认不出的失败也说了一句"
fi
rm -f "$CURL_HINT_FILE"

echo "========== 3. 两份实现说的是同一件事 =========="

# 两种语言各写一份分类（Python 走 requests/urllib，bash 走 curl），措辞必须
# 对得上 —— 否则同一次故障在两条路径上会给出两种说法。
for phrase in "certificate has expired" "self-signed" "chain is incomplete" \
              "not valid for" "not a TLS or certificate one"; do
    if grep -qF "$phrase" "$REPO_DIR/net/tls.py" && grep -qF "$phrase" "$REPO_DIR/lib/selfupdate.sh"; then
        pass "两边都有：$phrase"
    else
        fail "措辞走散了：$phrase"
    fi
done

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED_BOLD}🌊 Certificate diagnostics are inconsistent${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 Certificate failures are classified consistently${RESET}"
