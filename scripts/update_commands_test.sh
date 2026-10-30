#!/bin/bash

# update_commands_test.sh
# 升级脚本生成的回归（离线，除第 7 段起一个本地 http 服务外不联网）
#
# 钉死两件在 2026-10-30 真实出过事故的事：
#
#   1. 清单过滤只在 files_from_git 里做过。发版时用 `--files` 传一份 find 的结果
#      是常见做法，而 find 会把工作区里的 __pycache__ 也列进来（git 里其实没有）。
#      4.1.1 就这么发出去的：客户端对 pkg/__pycache__ 与 surfboard/__pycache__
#      各重试 3 次再报 404。同一条路径还绕过了 EXCLUDED，于是 lib/install.sh 与
#      lib/uninstall.sh 被当成普通文件下载，覆盖了安装器自己写的那份。
#
#   2. want 失败只 return 1，而 install_fresh / install_delta 是一串裸的 want
#      调用，脚本没有 set -e，调用方也不看返回值 —— 于是「有文件没下到」被当成
#      更新成功，客户端照旧写 VERSION.json，留下版本号前进但安装树残缺的状态。
#
# 还有一条安全断言：报错里的地址必须打码。用镜像时 MACWAVE_CORE_URL 里带凭据。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}
BUILDER="$SCRIPT_DIR/build_update_commands.py"
TEMPLATE="$SCRIPT_DIR/update_commands.template.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

expect() {  # expect 描述 实际 期望子串
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（期望含「$3」，实际：$(printf '%.160s' "$2")）"; fi
}

expect_absent() {  # expect_absent 描述 实际 不该出现的子串
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1（不该出现「$3」）"; fi
}

gen() {  # gen 输出文件 [额外参数...]
    local out=$1; shift
    # stderr 落到 GEN_ERR 指定的文件（默认 err.txt）。调用方要看报告时先改它。
    "$PYTHON" "$BUILDER" --version 9.9.9 --branch main --out "$out" "$@" 2>"${GEN_ERR:-$WORK/err.txt}"
}

wants() {  # 打印清单里所有 want 的路径
    grep '^    want ' "$1" 2>/dev/null | awk '{print $2}' | sort -u
}

# ==========================================================
echo "========== 1. --files 传进来的脏清单必须被过滤 =========="
# ==========================================================

gen "$WORK/dirty.sh" --files \
    lib/wave.py lib/help.py lib/install.sh lib/uninstall.sh \
    pkg/__pycache__ pkg/linker.py \
    surfboard/__pycache__ surfboard/querier.py \
    docs/README.md 2>/dev/null
rc=$?

if [ "$rc" -eq 0 ]; then pass "--files 的脏清单仍能生成"; else fail "--files 的脏清单生成失败（退出码 ${rc}）"; fi

list=$(wants "$WORK/dirty.sh")
expect_absent "__pycache__ 被过滤"        "$list" "__pycache__"
expect_absent "lib/install.sh 被过滤"     "$list" "lib/install.sh"
expect_absent "lib/uninstall.sh 被过滤"   "$list" "lib/uninstall.sh"
expect_absent "docs/ 不在安装目录被过滤"   "$list" "docs/"
expect        "正常的 .py 保留"           "$list" "lib/help.py"
expect        "pkg 下的正常文件保留"       "$list" "pkg/linker.py"

# .pyc 单独一条：有些工具会直接列出文件而不是目录
gen "$WORK/pyc.sh" --files lib/wave.py lib/__pycache__/wave.cpython-314.pyc 2>/dev/null
expect_absent ".pyc 被过滤" "$(wants "$WORK/pyc.sh")" ".pyc"

# 被丢掉的东西要报出来，不能悄悄消失 —— 否则清单少了一行没人知道
GEN_ERR="$WORK/r.txt" gen "$WORK/report.sh" --files lib/wave.py pkg/__pycache__ >/dev/null
expect "被丢掉的条目有报告" "$(cat "$WORK/r.txt")" "Dropped"
expect "报告里点名了那条路径" "$(cat "$WORK/r.txt")" "pkg/__pycache__"

# ==========================================================
echo "========== 2. 从 git 取清单时同样过滤 =========="
# ==========================================================

# worktree 的 .git 是文件不是目录，不能靠 -d 判断
ref=$(git -C "$REPO_DIR" rev-parse --verify -q HEAD 2>/dev/null || true)
if [ -n "$ref" ]; then
    gen "$WORK/fromgit.sh" --ref "$ref" 2>/dev/null
    list=$(wants "$WORK/fromgit.sh")
    expect_absent "git 来源也没有 __pycache__"      "$list" "__pycache__"
    expect_absent "git 来源也没有 lib/install.sh"   "$list" "lib/install.sh"
    expect        "git 来源取到了真实文件"          "$list" "lib/wave.py"
else
    echo "  ·  跳过：$REPO_DIR 不是可用的 git 检出"
fi

# ==========================================================
echo "========== 3. --delta 指向被过滤的文件要报错 =========="
# ==========================================================

gen "$WORK/baddelta.sh" --files lib/wave.py lib/help.py --delta pkg/__pycache__ >/dev/null 2>&1
if [ $? -ne 0 ]; then
    pass "--delta 里只有被过滤的条目时拒绝生成"
else
    fail "--delta 里只有被过滤的条目时竟然生成了"
fi

gen "$WORK/okdelta.sh" --files lib/wave.py lib/help.py --delta lib/help.py >/dev/null 2>&1
if [ $? -eq 0 ]; then pass "--delta 是合法子集时正常生成"; else fail "--delta 合法却失败"; fi

# ==========================================================
echo "========== 4. 清单为空要硬失败 =========="
# ==========================================================

gen "$WORK/empty.sh" --files pkg/__pycache__ surfboard/__pycache__ >/dev/null 2>&1
if [ $? -ne 0 ]; then
    pass "全是脏条目时拒绝生成（而不是产出一份空清单）"
else
    fail "全是脏条目时竟然生成了空清单"
fi

# ==========================================================
echo "========== 5. 可执行位按扩展名决定 =========="
# ==========================================================

gen "$WORK/exec.sh" --files lib/wave.py lib/selfupdate.sh pkg/pkgunzip.sh >/dev/null 2>&1
line_py=$(grep '^    want lib/wave.py' "$WORK/exec.sh")
line_sh=$(grep '^    want lib/selfupdate.sh' "$WORK/exec.sh")
expect ".py 不带 +x" "$line_py" "lib/wave.py 0"
expect ".sh 带 +x"   "$line_sh" "lib/selfupdate.sh 1"

# ==========================================================
echo "========== 6. 报错里的地址要打码 =========="
# ==========================================================

# 把模板里的 redact_url 单独抽出来测，不必跑完整脚本
sed -n '/^redact_url() {/,/^}/p' "$TEMPLATE" > "$WORK/ru.sh"
if grep -q '^redact_url() {' "$WORK/ru.sh"; then
    pass "模板里有 redact_url"

    secret_user="alice"
    secret_pass="s3cr3tWith@At"
    masked=$(bash -c "source '$WORK/ru.sh'; redact_url 'https://$secret_user:$secret_pass@mirror.repohub.top/MacWave/core/4.1/lib/wave.py'")
    expect_absent "密码被隐去"       "$masked" "$secret_pass"
    expect        "用户名打码成形"   "$masked" ":***@"
    expect        "主机与路径保留"   "$masked" "mirror.repohub.top/MacWave/core/4.1/lib/wave.py"

    plain="https://mirror.repohub.top/MacWave/core/4.1/lib/wave.py"
    same=$(bash -c "source '$WORK/ru.sh'; redact_url '$plain'")
    if [ "$same" = "$plain" ]; then pass "无凭据的地址原样返回"; else fail "无凭据的地址被改坏了：$same"; fi

    # 路径里的 @ 是合法文件名字符（jq@1.8.2.arm64），不能被当成密码位置
    withat="https://mirror.repohub.top/MacWave/bottle/jq/jq@1.8.2.arm64"
    same=$(bash -c "source '$WORK/ru.sh'; redact_url '$withat'")
    if [ "$same" = "$withat" ]; then pass "路径里的 @ 不被误判"; else fail "路径里的 @ 把地址改坏了：$same"; fi
else
    fail "模板里找不到 redact_url"
fi

# ==========================================================
echo "========== 7. 文件下不到必须让整次更新失败 =========="
# ==========================================================

if command -v python3 >/dev/null 2>&1; then
    mkdir -p "$WORK/www/main/lib" "$WORK/www/main/pkg"
    printf 'new configerror\n' > "$WORK/www/main/lib/configerror.py"
    printf 'new linker\n'      > "$WORK/www/main/pkg/linker.py"
    # 第三个文件故意不放在服务端
    gen "$WORK/fail.sh" --files lib/configerror.py pkg/linker.py pkg/missing.py >/dev/null 2>&1

    PORT=$(( 18900 + (RANDOM % 500) ))
    ( cd "$WORK/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
    server_pid=$!
    # 等端口起来
    for _ in $(seq 1 40); do
        if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)"; then
            break
        fi
        sleep 0.1
    done

    mkdir -p "$WORK/install/lib"
    printf 'old wave\n' > "$WORK/install/lib/wave.py"   # 让它走 install_delta

    out=$(MACWAVE_INSTALL_DIR="$WORK/install" \
          MACWAVE_CORE_URL="http://127.0.0.1:$PORT" \
          MACWAVE_BRANCH=main \
          MACWAVE_CURRENT_VERSION=9.9.8 \
          bash "$WORK/fail.sh" 2>&1)
    rc=$?

    if [ "$rc" -ne 0 ]; then
        pass "有文件 404 时整次更新失败（退出码 ${rc}）"
    else
        fail "有文件 404 却报告成功 —— 客户端会写 VERSION.json 留下残缺安装树"
    fi
    expect "报错点名了缺的那个文件" "$out" "pkg/missing.py"
    expect_absent "报错里没有明文密码" "$out" "no-such-secret"

    # 全部存在时必须成功
    gen "$WORK/ok.sh" --files lib/configerror.py pkg/linker.py >/dev/null 2>&1
    out=$(MACWAVE_INSTALL_DIR="$WORK/install" \
          MACWAVE_CORE_URL="http://127.0.0.1:$PORT" \
          MACWAVE_BRANCH=main \
          MACWAVE_CURRENT_VERSION=9.9.8 \
          bash "$WORK/ok.sh" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then pass "文件齐全时正常成功"; else fail "文件齐全却失败（退出码 ${rc}）"; fi

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
else
    echo "  ·  跳过：没有 python3 起本地服务"
fi

# ==========================================================
echo "========== 8. 就位与 +x 失败也必须失败 =========="
# ==========================================================

# chmod 失败（例如安装树是 root 装的、当前用户只是 sudo 拿到了写权限）
# 以前是静默忽略 —— 用户随后看到「命令找不到」，比下载失败难懂得多。
if command -v chflags >/dev/null 2>&1; then
    # 必须放在客户端真正会去取的路径上（branch=main → /main/lib/wave.py），
    # 否则先 404，测到的就不是 mv 失败而是下载失败了
    mkdir -p "$WORK/www/main/lib"
    printf 'new wave\n' > "$WORK/www/main/lib/wave.py"
    gen "$WORK/ex.sh" --files lib/wave.py >/dev/null 2>&1
    mkdir -p "$WORK/install2/lib"
    printf 'old\n' > "$WORK/install2/lib/wave.py"
    # 目标文件不可变 → mv 覆盖会失败
    chflags uchg "$WORK/install2/lib/wave.py" 2>/dev/null

    PORT2=$(( PORT + 1 ))
    ( cd "$WORK/www" && exec python3 -m http.server "$PORT2" --bind 127.0.0.1 ) >/dev/null 2>&1 &
    server2=$!
    for _ in $(seq 1 40); do
        python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT2))==0 else 1)" && break
        sleep 0.1
    done

    out=$(MACWAVE_INSTALL_DIR="$WORK/install2" \
          MACWAVE_CORE_URL="http://127.0.0.1:$PORT2" MACWAVE_BRANCH=main \
          MACWAVE_CURRENT_VERSION=9.9.8 bash "$WORK/ex.sh" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "mv 覆盖失败时整次更新失败"
    else
        fail "mv 失败却报告成功"
    fi
    expect "报错说明了是 mv 出问题" "$out" "move"

    chflags nouchg "$WORK/install2/lib/wave.py" 2>/dev/null || true
    kill "$server2" 2>/dev/null || true
    wait "$server2" 2>/dev/null || true
else
    echo "  ·  跳过：没有 chflags，无法可靠制造 mv 失败"
fi

# ==========================================================
echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All update_commands tests passed${RESET}"
