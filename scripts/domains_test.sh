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


def check(label, got, want):
    global ok
    if got != want:
        print(f"    {label}: {got}")
        print(f"    want{' ' * (len(label) - 4)}: {want}")
        ok = False


# 3.1 目录形状照抄 infosource（去掉前导下划线），版本写在文件名里
url, name = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    upstream_filename="jq-macos-arm64", upstream_url="", from_source=False)
check("bottle url", url, "https://bottles.example.com/pkg/pkginfo_arm64/jq/jq@1.7.1")
check("bottle name", name, "jq@1.7.1")

# 3.2 字节原样搬运：扩展名跟着上游走，文件名只换前缀
url, name = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    upstream_filename="jq-1.7.1-macos.zip", upstream_url="", from_source=False)
check("zip url", url, "https://bottles.example.com/pkg/pkginfo_arm64/jq/jq@1.7.1.zip")
check("zip name", name, "jq@1.7.1.zip")

# 3.3 多段扩展名要完整保留，不能被截成 .gz
_, name = domains.resolve_payload(
    "deps", "libidn2", "2.3.7", "arm64",
    upstream_filename="libidn2-2.3.7-darwin-arm64.tar.gz", upstream_url="", from_source=False)
check("multi-part suffix", name, "libidn2@2.3.7.tar.gz")

# 3.4 裸可执行文件没有扩展名，这是合法情况（安装器按裸二进制处理）
url, name = domains.resolve_payload(
    "bottle", "choma", "1.0", "amd64",
    upstream_filename="ChOma", upstream_url="", from_source=False)
check("bare name", name, "choma@1.0")
check("bare url", url, "https://bottles.example.com/pkg/pkginfo_amd64/choma/choma@1.0")

# 3.5 依赖走 deps/depsinfo_<架构>
url, _ = domains.resolve_payload(
    "deps", "libidn2", "2.3.7", "arm64",
    upstream_filename="libidn2.tar.gz", upstream_url="", from_source=False)
check("deps url", url, "https://deps.example.com/deps/depsinfo_arm64/libidn2/libidn2@2.3.7.tar.gz")

# 3.6 记录里有 url 也不看：地址里不能出现上游主机名
url, _ = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    upstream_filename="jq-macos-arm64",
    upstream_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64",
    from_source=False)
check("no upstream host", "github.com" in url, False)

# 3.7 --install-from-source：回到 3.x 的做法，读 url、按末段命名
url, name = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    upstream_filename="", upstream_url="https://github.com/o/r/releases/download/1.7.1/jq.zip",
    from_source=True)
check("from-source url", url, "https://github.com/o/r/releases/download/1.7.1/jq.zip")
check("from-source name", name, "jq.zip")

raise SystemExit(0 if ok else 1)
PY
then
    pass "目录形状照抄索引，扩展名跟随上游，url 默认不读"
else
    fail "地址拼法不对"
fi

echo
echo "========== 4. 缺数据或缺域名必须报错，不能悄悄回落 =========="

# 没有 file 字段 → 报错（否则不知道是什么格式，不能猜）
if PYTHONPATH="$LIB_DIR" MACWAVE_BOTTLE_DOMAIN="https://b.example.com" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        upstream_filename="", upstream_url="https://x/jq.tar.gz",
                        from_source=False)
PY
then
    fail "缺 file 字段却装了下去"
else
    pass "缺 file 字段 → 报错"
fi

# 没设 Bottle 域名 → 报错（4.0 没有别的来源，也不回上游）
if PYTHONPATH="$LIB_DIR" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        upstream_filename="jq.tar.gz", upstream_url="", from_source=False)
PY
then
    fail "没设 Bottle 域名却装了下去"
else
    pass "没设 Bottle 域名 → 报错"
fi

# 没设 Deps 域名同样报错
if PYTHONPATH="$LIB_DIR" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("deps", "libidn2", "2.3.7", "arm64",
                        upstream_filename="libidn2.tar.gz", upstream_url="", from_source=False)
PY
then
    fail "没设 Deps 域名却装了下去"
else
    pass "没设 Deps 域名 → 报错"
fi

# --install-from-source 但记录里没有 url → 报错
if PYTHONPATH="$LIB_DIR" MACWAVE_BOTTLE_DOMAIN="https://bottles.example.com" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        upstream_filename="jq.tar.gz", upstream_url="", from_source=True)
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
                        upstream_filename="", upstream_url="http://x/jq.tar.gz", from_source=True)
PY
then
    fail "from-source 接受了明文 http"
else
    pass "--install-from-source 仍拒绝明文 http"
fi

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
