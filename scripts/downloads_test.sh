#!/bin/bash

# downloads_test.sh
# downloads/tmp 里放太久的 .partial 要在 install / uninstall 时被顺手清掉。
#
# 为什么需要它：.partial 的正常归宿只有两个 —— 下载完成后改名，或这次命令失败时
# 被删掉。中断（Ctrl-C、断网、合盖）留下的是给 `-C` 续传用的，可用户一旦不再重试，
# 它就一直占着几百 MB 到几 GB，而且既不在 `wave list` 里、也不在任何卸载路径上。
#
# 判据只认 mtime（7 天），所以这里用 `touch -t` 造新旧两种文件；边界取 8 天与 6 天，
# 不用 7 天整，免得机器慢一点就抖成两种结论。
#
# 全程离线：直接调 lib/downloads.py，不联网、不碰真实安装树。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/downloads_test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

SANDBOX="$WORK/sandbox"
BASE="$SANDBOX/opt/macwave"
TMP_DIR="$BASE/downloads/tmp"
mkdir -p "$SANDBOX/opt/macwave_config" "$BASE/bin" "$TMP_DIR"
printf '{"base_dir": "%s"}' "$BASE" > "$SANDBOX/opt/macwave_config/config.json"
for component in cli config lib net pkg surfboard; do
    ln -sfn "$REPO_DIR/$component" "$BASE/$component"
done

# 造一个「多少天前改过」的文件
aged() {  # aged <路径> <天数>
    touch "$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        touch -t "$(date -v-"$2"d +%Y%m%d%H%M)" "$1"
    else
        touch -d "$2 days ago" "$1"
    fi
}

sweep() {  # 在沙箱里跑一次 sweep，输出与退出码放在 OUT / RC
    OUT=$(MACWAVE_TEST="$SANDBOX" "$PYTHON" - "$REPO_DIR" <<'PY' 2>&1
import sys
repo = sys.argv[1]
sys.path[:0] = [repo + "/lib", repo + "/config", repo + "/cli", repo + "/net",
                repo + "/pkg", repo + "/surfboard"]
from downloads import sweep_stale_partials
removed = sweep_stale_partials()
print("REMOVED=" + ",".join(sorted(removed)))
PY
)
    RC=$?
}

echo "========== 1. 只清超过 7 天的 .partial =========="

aged "$TMP_DIR/jq-1.8.2-arm64.tar.gz.partial" 8
aged "$TMP_DIR/yq-2.47.1-arm64.tar.gz.partial" 6
sweep
[[ "$RC" -eq 0 ]] && pass "清理本身不该失败" || fail "sweep 异常退出（rc=$RC）：$(printf '%.200s' "$OUT")"
[[ ! -e "$TMP_DIR/jq-1.8.2-arm64.tar.gz.partial" ]] && pass "8 天前的 .partial 被删掉" \
    || fail "8 天前的 .partial 还在"
[[ -e "$TMP_DIR/yq-2.47.1-arm64.tar.gz.partial" ]] && pass "6 天前的 .partial 保留（还能续传）" \
    || fail "6 天前的 .partial 被误删"
[[ "$OUT" == *"REMOVED=jq-1.8.2-arm64.tar.gz.partial" ]] && pass "返回值点名删掉的那个" \
    || fail "返回值不对：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"Cleaned up 1 stale partial download(s)"* ]] && pass "打了一行汇总" \
    || fail "没有汇总行：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"untouched for 7+ days"* ]] && pass "汇总里说清了判据（多久没动）" \
    || fail "汇总没说判据：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"downloads/tmp"* ]] && pass "汇总里带上了目录（用户知道去掉了什么）" \
    || fail "汇总没说目录：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"jq-1.8.2-arm64.tar.gz.partial"* ]] && pass "汇总点名删掉的文件" \
    || fail "汇总没点名：$(printf '%.200s' "$OUT")"

echo
echo "========== 2. 不碰别的文件 =========="

aged "$TMP_DIR/ffmpeg-7.1-arm64.tar.gz" 30     # 下完但没删的归档
aged "$TMP_DIR/notes.txt" 30                   # 无关文件
aged "$TMP_DIR/.hidden.partial" 30             # 点开头的 .partial 也算
mkdir -p "$TMP_DIR/subdir.partial"
aged "$TMP_DIR/subdir.partial/keep" 30         # 目录（不该递归进去）
sweep
[[ -e "$TMP_DIR/ffmpeg-7.1-arm64.tar.gz" ]] && pass "完成的归档不归它管" \
    || fail "把下完的归档删了（那是别人的东西）"
[[ -e "$TMP_DIR/notes.txt" ]] && pass "非 .partial 文件不动" || fail "删了非 .partial 文件"
[[ ! -e "$TMP_DIR/.hidden.partial" ]] && pass "点开头的 .partial 也清" \
    || fail "点开头的 .partial 漏了"
[[ -d "$TMP_DIR/subdir.partial" && -e "$TMP_DIR/subdir.partial/keep" ]] \
    && pass "目录不递归、不删" || fail "把 .partial 目录连同里面的东西删了"

echo
echo "========== 2.5 文件很多时名字不刷屏 =========="

for index in 1 2 3 4 5 6; do
    aged "$TMP_DIR/many-$index-arm64.tar.gz.partial" 10
done
sweep
[[ "$OUT" == *"(+3)"* ]] && pass "超过三个只列前三个，剩下的计数" \
    || fail "名字全列出来了：$(printf '%.300s' "$OUT")"
[[ ! -e "$TMP_DIR/many-6-arm64.tar.gz.partial" ]] && pass "没列出来的那些也真的删了" \
    || fail "只删了列出来的那几个"

echo
echo "========== 3. 没有 downloads/tmp 时不报错 =========="

rm -rf "$TMP_DIR"
sweep
[[ "$RC" -eq 0 ]] && pass "目录不存在时安静跳过" \
    || fail "目录不存在就报错了（rc=$RC）：$(printf '%.200s' "$OUT")"
[[ "$OUT" == *"REMOVED="* ]] && pass "返回空列表" || fail "没有返回列表"
mkdir -p "$TMP_DIR"

echo
echo "========== 4. 删不掉时跳过，不让命令失败 =========="

aged "$TMP_DIR/locked.partial" 10
chmod 500 "$TMP_DIR"
sweep
chmod 755 "$TMP_DIR"
if [[ "$(id -u)" == "0" ]]; then
    echo "      （root 无视目录权限，跳过这组）"
else
    [[ "$RC" -eq 0 ]] && pass "删不掉不抛异常" \
        || fail "删不掉就失败了（rc=$RC）：$(printf '%.200s' "$OUT")"
    [[ -e "$TMP_DIR/locked.partial" ]] && pass "删不掉的那个留着（下次再说）" \
        || fail "说删不掉却删掉了？"
fi
rm -f "$TMP_DIR/locked.partial"

echo
echo "========== 5. install / uninstall 都接上了这一手 =========="

grep -q "sweep_stale_partials" "$REPO_DIR/pkg/pkginstaller.py" \
    && pass "install 路径调用了清理" || fail "install 路径没有调用清理"
grep -q "sweep_stale_partials" "$REPO_DIR/pkg/uninstaller.py" \
    && pass "uninstall 路径调用了清理" || fail "uninstall 路径没有调用清理"
# 必须在 lock 之后：downloads/tmp 里可能有另一个 wave 正在写的 .partial
python3 - "$REPO_DIR" <<'PY' && pass "清理发生在拿到锁之后（install）" \
    || fail "清理跑在拿锁之前（会删掉别人正在写的文件）"
import sys, pathlib
text = pathlib.Path(sys.argv[1], "pkg", "pkginstaller.py").read_text()
lock_at = text.find('with tree_lock("install")')
sweep_at = text.find("sweep_stale_partials()", lock_at)
sys.exit(0 if lock_at != -1 and sweep_at > lock_at else 1)
PY

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
