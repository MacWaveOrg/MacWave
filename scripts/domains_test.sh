#!/bin/bash

# domains_test.sh
# 4.0 的地址层回归：环境变量 → 域名 → 下载地址，以及「平时不读 url」这条规则。
# 全程离线，不碰网络也不碰已安装的 MacWave。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$REPO_DIR/lib"

FAILED=0

pass() { echo -e "  ${GREEN}✅ $1${RESET}"; }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

echo "========== 1. 默认值仍是 3.x 的地址 =========="

# 一个都不设时，拼出来的地址必须与 3.x 写死的字面量逐字一致：
# 这是「不设环境变量就完全没变化」的唯一依据。
if PYTHONPATH="$LIB_DIR" python3 - << 'PY'
import domains

checks = [
    ("索引 @common", f"{domains.api_domain()}/pkg/pkginfo_arm64/jq/_jq@common",
     "https://raw.githubusercontent.com/MacWaveOrg/infosource/main/pkg/pkginfo_arm64/jq/_jq@common"),
    ("索引版本文件", f"{domains.api_domain()}/pkg/pkginfo_arm64/jq/_jq@1.7.1",
     "https://raw.githubusercontent.com/MacWaveOrg/infosource/main/pkg/pkginfo_arm64/jq/_jq@1.7.1"),
    ("依赖索引", f"{domains.api_domain()}/deps/depsinfo_arm64/libidn2/_libidn2@common",
     "https://raw.githubusercontent.com/MacWaveOrg/infosource/main/deps/depsinfo_arm64/libidn2/_libidn2@common"),
    ("版本数据", domains.selfupdate_version_url(),
     "https://raw.githubusercontent.com/MacWaveOrg/configdata/main/versiondata/latest_version"),
    ("文件清单", domains.selfupdate_files_url(),
     "https://raw.githubusercontent.com/MacWaveOrg/configdata/main/versiondata/files_info"),
    ("迁移脚本", domains.selfupdate_updatedata_url("3.2.1", "dir_structure_change"),
     "https://raw.githubusercontent.com/MacWaveOrg/configdata/main/updatedata/3.2.1/dir_structure_change"),
    ("解释器清单", domains.python_manifest_url(),
     "https://raw.githubusercontent.com/MacWaveOrg/configdata/main/pythondata/latest_python"),
    ("列版本", domains.index_list_url("arm64", "jq"),
     "https://api.github.com/repos/MacWaveOrg/infosource/contents/pkg/pkginfo_arm64/jq?ref=main"),
    ("列软件包", domains.index_list_url("arm64"),
     "https://api.github.com/repos/MacWaveOrg/infosource/contents/pkg/pkginfo_arm64?ref=main"),
]

bad = [(name, got, want) for name, got, want in checks if got != want]
for name, got, want in bad:
    print(f"    {name}: got {got}\n      want {want}")
print(f"  {len(checks) - len(bad)}/{len(checks)}")
raise SystemExit(1 if bad else 0)
PY
then
    pass "9 个默认地址与 3.x 逐字一致"
else
    fail "默认地址与 3.x 不一致"
fi

echo
echo "========== 2. 环境变量覆盖与规范化 =========="

if PYTHONPATH="$LIB_DIR" MACWAVE_API_DOMAIN="https://mirror.example.com/macwave/" \
     MACWAVE_SELFUPDATE_DOMAIN="https://mirror.example.com/su" python3 - << 'PY'
import domains

ok = True
if domains.api_domain() != "https://mirror.example.com/macwave":     # 末尾斜杠被去掉
    print(f"    api: {domains.api_domain()}")
    ok = False
if domains.index_list_url("arm64", "jq") != "https://mirror.example.com/macwave/pkg/pkginfo_arm64/jq/versions":
    print(f"    list: {domains.index_list_url('arm64', 'jq')}")
    ok = False
if domains.selfupdate_version_url() != "https://mirror.example.com/su/versiondata/latest_version":
    print(f"    selfupdate: {domains.selfupdate_version_url()}")
    ok = False
raise SystemExit(0 if ok else 1)
PY
then
    pass "镜像地址生效，末尾斜杠被去掉，版本清单改读镜像"
else
    fail "镜像地址处理不对"
fi

# 不合法的值必须在拼地址之前就被拒绝（它们会进 URL，也会进错误信息）
for bad in "ftp://x.example.com" "http://mirror.example.com" "no-scheme" "https://exa mple.com"; do
    if PYTHONPATH="$LIB_DIR" MACWAVE_API_DOMAIN="$bad" python3 -c "import domains; domains.api_domain()" > /dev/null 2>&1; then
        fail "非法值被接受：$bad"
    else
        pass "非法值被拒绝：$bad"
    fi
done

# 本机回环允许明文 http（离线镜像、测试用）
if PYTHONPATH="$LIB_DIR" MACWAVE_API_DOMAIN="http://127.0.0.1:8080/idx" \
     python3 -c "import domains; assert domains.api_domain() == 'http://127.0.0.1:8080/idx'"; then
    pass "回环地址允许明文 http"
else
    fail "回环地址被误拒"
fi

echo
echo "========== 3. 平时不读 url，只有 --install-from-source 才读 =========="

if PYTHONPATH="$LIB_DIR" MACWAVE_BOTTLE_DOMAIN="https://bottles.example.com" \
     MACWAVE_DEPS_DOMAIN="https://deps.example.com" python3 - << 'PY'
import domains

ok = True

# 3.1 记录里没有 url，照样能装：地址完全由 file 决定
url, name = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    filename="jq-1.7.1-macos-arm64.tar.gz", upstream_url="", from_source=False)
if url != "https://bottles.example.com/jq/1.7.1/arm64/jq-1.7.1-macos-arm64.tar.gz" or name != "jq-1.7.1-macos-arm64.tar.gz":
    print(f"    bottle: {url} / {name}")
    ok = False

# 3.2 就算给了 url 也不看：地址里不能出现上游主机名
url, name = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    filename="jq-1.7.1-macos-arm64.tar.gz",
    upstream_url="https://github.com/stedolan/jq/releases/download/jq-1.7.1/jq-other-name.zip",
    from_source=False)
if "github.com" in url or name != "jq-1.7.1-macos-arm64.tar.gz":
    print(f"    平时读了 url: {url} / {name}")
    ok = False

# 3.3 --install-from-source：回到 3.x 的做法，读 url、按末段命名
url, name = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    filename="", upstream_url="https://github.com/o/r/releases/download/1.7.1/jq.zip",
    from_source=True)
if url != "https://github.com/o/r/releases/download/1.7.1/jq.zip" or name != "jq.zip":
    print(f"    from-source: {url} / {name}")
    ok = False

# 3.4 依赖同一套规则
url, name = domains.resolve_payload(
    "deps", "libidn2", "2.3.7", "arm64",
    filename="libidn2-2.3.7.tar.gz", upstream_url="", from_source=False)
if url != "https://deps.example.com/libidn2/2.3.7/arm64/libidn2-2.3.7.tar.gz":
    print(f"    deps: {url}")
    ok = False

raise SystemExit(0 if ok else 1)
PY
then
    pass "默认只认 file，--install-from-source 才回到 url"
else
    fail "url 读取规则不对"
fi

echo
echo "========== 4. 缺数据时必须报错，不能悄悄回落 =========="

# 没有 file 字段 → 报错（而不是回头去读 url）
if PYTHONPATH="$LIB_DIR" MACWAVE_BOTTLE_DOMAIN="https://bottles.example.com" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        filename="", upstream_url="https://x/jq.tar.gz", from_source=False)
PY
then
    fail "缺 file 字段却装了下去"
else
    pass "缺 file 字段 → 报错"
fi

# 没设 Bottle 域名 → 报错（4.0 没有别的来源）
if PYTHONPATH="$LIB_DIR" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        filename="jq.tar.gz", upstream_url="", from_source=False)
PY
then
    fail "没设 Bottle 域名却装了下去"
else
    pass "没设 Bottle 域名 → 报错"
fi

# --install-from-source 但记录里没有 url → 报错
if PYTHONPATH="$LIB_DIR" MACWAVE_BOTTLE_DOMAIN="https://bottles.example.com" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        filename="jq.tar.gz", upstream_url="", from_source=True)
PY
then
    fail "缺 url 却按 from-source 装了下去"
else
    pass "--install-from-source 缺 url → 报错"
fi

# --install-from-source 照样拒绝明文 http
if PYTHONPATH="$LIB_DIR" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        filename="", upstream_url="http://x/jq.tar.gz", from_source=True)
PY
then
    fail "from-source 接受了明文 http"
else
    pass "--install-from-source 仍拒绝明文 http"
fi

echo
echo "========== 5. 旗标解析 =========="

# --install-from-source 不带值，所以不能进 FLAGS_TAKING_VALUE，
# 否则 `wave install --install-from-source jq` 会把 jq 当成它的值。
if PYTHONPATH="$LIB_DIR:$REPO_DIR/pkg:$REPO_DIR/surfboard" python3 - << 'PY'
import pkginstaller

ok = True
for line, expected in [
    ("wave install jq --install-from-source", True),
    ("wave install --install-from-source jq", True),
    ("wave install jq", False),
]:
    config = pkginstaller.handle_download_args(line)
    if config["install_from_source"] is not expected:
        print(f"    {line}: {config['install_from_source']}")
        ok = False
    if pkginstaller.first_package_token(line) != "jq":
        print(f"    {line}: 包名被解析成 {pkginstaller.first_package_token(line)}")
        ok = False
raise SystemExit(0 if ok else 1)
PY
then
    pass "旗标位置任意，包名不受影响"
else
    fail "旗标解析不对"
fi

echo
echo "========== 6. 两份 shell 脚本的域名块必须逐字一致 =========="

# install.sh 与 selfupdate.sh 各抄了一份（前者是 curl | bash，没有本地文件可 source）。
# 抄两份就会漂移，所以这里逐字比对：改一处就必须改另一处。
extract_domain_block() {
    sed -n '/^# 域名（4.0/,/^PYTHON_URL=/p' "$1"
}

if diff -q <(extract_domain_block "$REPO_DIR/lib/install.sh") \
           <(extract_domain_block "$REPO_DIR/lib/selfupdate.sh") > /dev/null; then
    pass "install.sh 与 selfupdate.sh 的域名块一致"
else
    fail "两份脚本的域名块已经漂移"
    diff <(extract_domain_block "$REPO_DIR/lib/install.sh") \
         <(extract_domain_block "$REPO_DIR/lib/selfupdate.sh") | head -20
fi

# 两边的默认值也必须与 lib/domains.py 对得上，
# 否则 shell 和 Python 会指向不同的地方。
if python3 "$REPO_DIR/scripts/check_domain_defaults.py"; then
    pass "shell 与 domains.py 的默认值一致"
else
    fail "shell 与 domains.py 的默认值不一致"
fi

echo
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 Domain tests failed: $FAILED${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 All domain tests passed${RESET}"
