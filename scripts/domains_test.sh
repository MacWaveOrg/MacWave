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

echo "========== 1. 默认地址形状 =========="

# 一个都不设时拼出来的地址，是「不设环境变量就没有意外」的唯一依据。
# 4.0 起索引 / core 仍是 3.x 的 raw 地址，但自更新数据与解释器换了布局
# （macwavedata/latest.toml、pythondata/latest.toml），所以下面逐条写死预期值。
if PYTHONPATH="$LIB_DIR" python3 - << 'PY'
import domains

checks = [
    ("索引 @common", f"{domains.api_domain()}/pkg/pkginfo_arm64/jq/_jq@common",
     "https://raw.githubusercontent.com/MacWaveOrg/infosource/main/pkg/pkginfo_arm64/jq/_jq@common"),
    ("索引版本文件", f"{domains.api_domain()}/pkg/pkginfo_arm64/jq/_jq@1.7.1",
     "https://raw.githubusercontent.com/MacWaveOrg/infosource/main/pkg/pkginfo_arm64/jq/_jq@1.7.1"),
    ("依赖索引", f"{domains.api_domain()}/deps/depsinfo_arm64/libidn2/_libidn2@common",
     "https://raw.githubusercontent.com/MacWaveOrg/infosource/main/deps/depsinfo_arm64/libidn2/_libidn2@common"),
    ("版本指针", domains.selfupdate_latest_url(),
     "https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/main/macwavedata/latest.toml"),
    ("更新脚本", domains.selfupdate_commands_url("4.0.0"),
     "https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/main/macwavedata/4.0.0/update_commands.sh"),
    ("解释器指针", domains.python_latest_url(),
     "https://raw.githubusercontent.com/MacWaveOrg/Python/main/pythondata/latest.toml"),
    ("解释器各架构", domains.python_url_toml_url("3.14.9"),
     "https://raw.githubusercontent.com/MacWaveOrg/Python/main/pythondata/3.14.9/python_url.toml"),
    ("解释器归档", domains.python_archive_url("3.14.9", "cpython-aarch64.tar.gz"),
     "https://raw.githubusercontent.com/MacWaveOrg/Python/main/pythondata/3.14.9/cpython-aarch64.tar.gz"),
    ("列版本", domains.index_list_url("arm64", "jq"),
     "https://api.github.com/repos/MacWaveOrg/infosource/contents/pkg/pkginfo_arm64/jq?ref=main"),
    ("列软件包", domains.index_list_url("arm64"),
     "https://api.github.com/repos/MacWaveOrg/infosource/contents/pkg/pkginfo_arm64?ref=main"),
]

print(f"  {len(checks)} 项")
bad = [(name, got, want) for name, got, want in checks if got != want]
for name, got, want in bad:
    print(f"    {name}: got {got}\n      want {want}")
raise SystemExit(1 if bad else 0)
PY
then
    pass "${CHECKS} 个默认地址与预期逐字一致"
else
    fail "默认地址与预期不一致"
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
if domains.selfupdate_latest_url() != "https://mirror.example.com/su/macwavedata/latest.toml":
    print(f"    selfupdate: {domains.selfupdate_latest_url()}")
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
echo "========== 3. 默认从自己的存储取，只有 --install-from-source 才读 url =========="

if PYTHONPATH="$LIB_DIR" python3 - << 'PY'
import domains

ok = True


def check(label, got, want):
    global ok
    if got != want:
        print(f"    {label}: {got}")
        print(f"    want{' ' * (len(label) - 4)}: {want}")
        ok = False


# 3.1 默认从我们自己的存储取，url 一个字都不读
payload = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64",
    upstream_filename="jq-macos-arm64",
    upstream_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64",
    from_source=False)
check("transport", payload["transport"], "https")
check("文件名带架构", payload["filename"], "jq@1.7.1.arm64")
check("地址形状", payload["url"],
      "https://github.com/MacWaveOrg/Bottle/releases/download/jq/jq%401.7.1.arm64")
check("不出现上游主机", "github.com/jqlang" in payload["url"], False)

# 3.2 两个架构不撞名（arm64 / amd64 是同名同版本的两条索引记录）
amd = domains.resolve_payload("bottle", "jq", "1.7.1", "amd64",
                              upstream_filename="jq-macos-arm64", upstream_url="",
                              from_source=False)
check("amd64 文件名", amd["filename"], "jq@1.7.1.amd64")
check("两架构不同名", amd["filename"] != payload["filename"], True)

# 3.3 扩展名跟随上游（字节原样搬运，落盘要带对后缀供解压器识别）
payload = domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                                  upstream_filename="jq-1.7.1.zip", upstream_url="",
                                  from_source=False)
check("zip 后缀", payload["filename"], "jq@1.7.1.arm64.zip")

# 3.4 多段扩展名完整保留，不能被截成 .gz
payload = domains.resolve_payload("deps", "libidn2", "2.3.7", "arm64",
                                  upstream_filename="libidn2-darwin.tar.gz", upstream_url="",
                                  from_source=False)
check("多段后缀", payload["filename"], "libidn2@2.3.7.arm64.tar.gz")
check("依赖专用仓库", payload["url"].split("/releases")[0],
      "https://github.com/MacWaveOrg/Deps")

# 3.5 裸可执行文件没有扩展名，合法
payload = domains.resolve_payload("bottle", "choma", "1.0", "amd64",
                                  upstream_filename="ChOma", upstream_url="",
                                  from_source=False)
check("裸二进制", payload["filename"], "choma@1.0.amd64")

# 3.6 --install-from-source 回到 3.x 的做法：读 url、按末段命名
payload = domains.resolve_payload(
    "bottle", "jq", "1.7.1", "arm64", upstream_filename="",
    upstream_url="https://github.com/o/r/releases/download/1.7.1/jq.zip",
    from_source=True)
check("from-source url", payload["url"],
      "https://github.com/o/r/releases/download/1.7.1/jq.zip")
check("from-source 文件名", payload["filename"], "jq.zip")

# 3.7 重建后缀原样保留（多版本共存靠它区分同一版本的不同产物）
payload = domains.resolve_payload("bottle", "jq", "1.7.1-1", "arm64",
                                  upstream_filename="jq.tar.gz", upstream_url="",
                                  from_source=False)
check("重建后缀", payload["filename"], "jq@1.7.1-1.arm64.tar.gz")

raise SystemExit(0 if ok else 1)
PY
then
    pass "地址形状、架构不撞名、扩展名、from-source 全部符合预期"
else
    fail "payload 规则不对"
fi

echo
echo "========== 4. 缺数据必须报错，不能悄悄回落 =========="

# 没有 file 字段 → 报错（否则不知道压缩格式）
if PYTHONPATH="$LIB_DIR" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64", upstream_filename="",
                        upstream_url="https://x/jq.tar.gz", from_source=False)
PY
then
    fail "缺 file 字段却继续了"
else
    pass "缺 file 字段 → 报错"
fi

# --install-from-source 但记录里没有 url → 报错
if PYTHONPATH="$LIB_DIR" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64", upstream_filename="jq.tar.gz",
                        upstream_url="", from_source=True)
PY
then
    fail "缺 url 却按 from-source 继续了"
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

# 默认值被清空时必须报错（防守性路径：正常使用不会走到，但代码里必须挡得住）
if PYTHONPATH="$LIB_DIR" python3 - << 'PY' > /dev/null 2>&1
import domains
domains.DEFAULTS["bottle"] = ""
domains.resolve_payload("bottle", "jq", "1.7.1", "arm64",
                        upstream_filename="jq.tar.gz", upstream_url="", from_source=False)
PY
then
    fail "没有可用域名却继续了"
else
    pass "域名缺失 → 报错（不回落到上游）"
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
    sed -n '/^# 域名（4.0/,/^PYTHON_DOMAIN_URL=/p' "$1"
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
