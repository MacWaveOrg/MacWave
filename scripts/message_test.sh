#!/bin/bash

# message_test.sh
# 两条「说清楚该怎么办」的回归：
#   1. 命令打错（wave update …）→ 提示正确的命令，并把其余参数原样带出来
#   2. 包名打错（wave upgrade treee）→ 从索引的名字清单里猜出最接近的包名
#
# 全程离线：假镜像用 python3 -m http.server 起在 localhost，
# 假安装目录用临时 HOME，不碰真实安装、不发外网请求。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"
WAVE_SRC="$REPO_DIR/lib/wave.py"

if [[ ! -f "$WAVE_SRC" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_SRC${RESET}"
    exit 1
fi

FAILED=0
PASSED=0

pass()  { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail()  { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# ok <描述> <命令输出> <应包含的片段>
ok() {
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里没有「$3」"
        printf '%s\n' "$2" | sed 's/^/      /'
    fi
}

# not_ok <描述> <命令输出> <不该出现的片段>
not_ok() {
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1 — 输出里不该出现「$3」"
    fi
}

# strip_ansi <文本> —— 去掉颜色码。
# 断言应当比对**用户看到的字**，而不是终端转义序列：文案里高亮的是哪个词属于
# 呈现细节，随时可能调整，不该让断言跟着碎。
strip_ansi() { printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

# -------------------- 沙箱 --------------------
#
# wave.py 会从配置里读 base_dir，再从那里加载 lib/ pkg/ surfboard/。
# 这里造一份临时安装，HOME 也指到临时目录，确保不会用到本机已有的配置。

WORK=$(mktemp -d)
HTTP_PID=""
cleanup() {
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

HOME_DIR="$WORK/home"
BASE="$WORK/base"
mkdir -p "$HOME_DIR/.config/macwave_config" "$BASE"
copy_components "$BASE/"
printf '{"version": "4.1.0"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/macwave_config/config.json"

# -------------------- 假镜像 --------------------
#
# 只放三个包的名字清单，用来测「猜包名」。列表格式与 build_versions_index.py 的
# 输出一致：一行一个包名 / 一行一条 <包名>@<版本>。

MIRROR="$WORK/mirror"

# 索引目录按架构分家。写死 arm64 的话，测试只在 Apple Silicon 上成立 ——
# Linux runner 是 x86_64，代码会去请求 pkginfo_amd64，目录不存在，全部 404。
# 这段映射必须与 pkg/pkginstaller.detect_arch() 保持一致。
ARCH=$(python3 -c 'import platform; m = platform.machine().lower(); print("arm64" if m in ("arm64", "aarch64") else "amd64")')

mkdir -p "$MIRROR/pkg/pkginfo_$ARCH/tree" "$MIRROR/pkg/pkginfo_$ARCH/jq" \
         "$MIRROR/pkg/pkginfo_$ARCH/nolist"
# nolist：名字在清单里、但没有它的 <包名>/versions —— 用来区分「拼错」与「镜像缺数据」
printf 'bat\njq\nnolist\ntree\nwget\n' > "$MIRROR/pkg/pkginfo_$ARCH/versions"
printf 'tree@2.2.1\ntree@2.1.0\n' > "$MIRROR/pkg/pkginfo_$ARCH/tree/versions"
printf 'jq@1.8.2\n' > "$MIRROR/pkg/pkginfo_$ARCH/jq/versions"

PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
( cd "$MIRROR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
HTTP_PID=$!

for _ in $(seq 1 40); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/pkg/pkginfo_$ARCH/versions"; then break; fi
    sleep 0.1
done

# wave <args> —— 全部在沙箱里跑，索引指向假镜像
wave() {
    env -u MACWAVE_BOTTLE_DOMAIN -u MACWAVE_DEPS_DOMAIN \
        HOME="$HOME_DIR" \
        MACWAVE_API_DOMAIN="http://127.0.0.1:$PORT" \
        python3 "$BASE/lib/wave.py" "$@"
}

# 依赖装在本机解释器里；HOME 换了之后 --user 目录也跟着换，补回真实路径。
# 用 site.getusersitepackages()，它算的就是 HOME 改掉之后会丢的那个目录。
USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())')
if [[ -d "$USER_SITE" ]]; then
    export PYTHONPATH="$USER_SITE"
fi

echo "========== 1. 命令打错：update → upgrade =========="

out=$(wave update jq -Xv --max-time=120s 2>&1)
ok     "给出完整的改法（参数与旗标原样保留）" "$(strip_ansi "$out")" "wave upgrade jq -Xv --max-time=120s"
ok     "说明哪个词打错了"                   "$out" "is not a command"
# 猜到该敲什么时不再展开整篇帮助：那五六十行会淹掉唯一有用的那一句。
# 但也得留一个自查入口，否则用户想知道还有哪些命令就没地方去了。
not_ok "猜对时不再打印整篇帮助"               "$out" "Commands:"
ok     "改而指向 wave -h"                    "$(strip_ansi "$out")" "wave -h"

wave update jq >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass "退出码是 1"; else fail "退出码应当为 1"; fi

out=$(wave remove jq --all 2>&1)
ok "remove → uninstall" "$(strip_ansi "$out")" "wave uninstall jq --all"

out=$(wave ls 2>&1)
ok "ls → list" "$(strip_ansi "$out")" "wave list"

echo
echo "========== 1.5 手滑少字母：按拼写猜，猜不到就别打整篇帮助 =========="

# 以前只查一张语义误用表（update→upgrade 之类），手滑完全不管：`wave instal jq`
# 会打一整篇帮助，把唯一有用的那句淹掉，而且连「Did you mean」都没有。
out=$(wave instal jq 2>&1)
plain=$(strip_ansi "$out")
ok     "instal → install"        "$plain" "wave install jq"
not_ok "猜得到时不打整篇帮助"      "$plain" "Commands:"
ok     "指出是哪个词写错了"        "$plain" "instal is not a command"
if [[ "$plain" == *"^^^^"* ]]; then
    pass "caret 指向那个错词"
else
    fail "caret 没有出现在输出里"
fi

out=$(wave upgrad jq 2>&1)
ok "upgrad → upgrade" "$(strip_ansi "$out")" "wave upgrade jq"

out=$(wave lst 2>&1)
ok "lst → list" "$(strip_ansi "$out")" "wave list"

# 语义误用要优先于拼写：`update` 与 `selfupdate` 的相似度是 0.75，
# 先跑拼写会把它猜成 selfupdate，而用户想的是 upgrade。
out=$(wave update jq 2>&1)
plain=$(strip_ansi "$out")
ok     "update 仍指向 upgrade（不被拼写抢走）" "$plain" "wave upgrade jq"
not_ok "update 不指向 selfupdate"              "$plain" "wave selfupdate jq"

# 半截词不该被当成笔误：`inst` 与 `list` 的相似度有 0.75，
# 会把它猜成 list —— 而它显然是 install 的缩写。首字母约束挡掉这一类。
for word in inst li xyzzy; do
    out=$(wave "$word" 2>&1)
    not_ok "「${word}」不乱猜" "$(strip_ansi "$out")" "Did you mean"
done

# 猜不到时也**不能**倒一整篇帮助：那五六十行会把仅有的两行有效信息推出屏幕。
# 只留一条指向 `wave -h` 的提示。这四条覆盖四种结局（猜得到 / 猜不到 / 只有坏旗标 / 空）。
for word in xyzzy instal "instal jq"; do
    out=$(wave $word 2>&1)
    plain=$(strip_ansi "$out")
    not_ok "「${word}」不打整篇帮助" "$plain" "Commands:"
    ok     "「${word}」指向 wave -h" "$plain" "wave -h"
done

out=$(wave instal jq 2>&1)
lines=$(printf '%s\n' "$(strip_ansi "$out")" | wc -l | tr -d ' ')
if [[ "$lines" -le 10 ]]; then
    pass "猜得到时输出不超过 10 行（实际 ${lines} 行）"
else
    fail "猜得到时输出 ${lines} 行，太长了"
fi

echo
echo "========== 2. 不相干的乱词：不乱猜 =========="

out=$(wave frobnicate xyz 2>&1)
plain=$(strip_ansi "$out")
not_ok "不给出 Did you mean" "$plain" "Did you mean"
ok     "仍然报未知命令"      "$plain" "Unknown command or argument"

# 猜不到该敲什么时，**仍然要指出是哪个词有问题** —— 否则整段输出里没有任何
# 定位信息，用户只能自己盯着命令行找。caret 长度必须与那个词等长。
ok     "无建议时也回显命令行" "$plain" "wave frobnicate xyz"
if [[ "$plain" == *"^^^^^^^^^^"* ]]; then
    pass "无建议时也用 ^ 指住出错的词"
else
    fail "无建议时没有用 ^ 指住出错的词"
fi
# caret 必须落在 frobnicate 底下，而不是行首
if printf '%s\n' "$plain" | grep -qE '^ +\^{10}$'; then
    pass "caret 单独成行且带缩进"
else
    fail "caret 行的形状不对（应只有缩进与 ^）"
fi

echo
echo "========== 2.5 只有旗标写错：也要用 ^^^ 指出来 =========="

# `wave --h` 这行里唯一的词就是写错的旗标。以前只在 words[1:] 里查坏旗标，
# 于是首词怎么写错都查不到任何东西 —— 既没有回显命令行，也没有 ^^^，
# 用户只看到一句「For the full list: wave -h」，看不出错在哪个词。
out=$(wave --h 2>&1)
plain=$(strip_ansi "$out")
ok     "点名写错的旗标"   "$plain" "Unknown flag: --h"
ok     "回显整条命令行"   "$plain" "wave --h"
if printf '%s\n' "$plain" | grep -qE '^ +\^{3}$'; then
    pass "用 ^^^ 指住那个旗标"
else
    fail "没有用 ^^^ 指住那个旗标"
fi

echo
echo "========== 3. 包名打错：treee → tree =========="

out=$(wave upgrade treee 2>&1)
ok "猜出近似的包名" "$out" 'did you mean `tree`?'
ok "给出可以直接跑的命令" "$out" "try: wave info tree"
ok "不带架构后缀地列出真实版本" "$(wave info tree 2>&1)" "Available versions: 2.2.1"

out=$(wave upgrade zzzznonsense 2>&1)
not_ok "猜不出来时保持沉默" "$out" 'did you mean'

echo
echo "========== 3.5 装包时包名不存在：别让人去查镜像 =========="

# 输出里有「HTTP 404」时，人的第一反应是「GitHub / 镜像挂了」。
# 但名字清单读得到、只是没有这个名字时，那是拼写问题 —— 报错必须先说清这一点，
# 否则用户会去查网络、换镜像、找管理员，全都白费。
out=$(wave install abc 2>&1)
plain=$(strip_ansi "$out")
ok     "点名「索引里没有这个包」"       "$plain" "no package named 'abc' in the index"
ok     "明确排除网络/镜像问题"          "$plain" "not a network or mirror problem"
ok     "给几个真实存在的名字作参考"      "$plain" "some names in the index"
not_ok "不再提 MACWAVE_API_DOMAIN"      "$plain" "MACWAVE_API_DOMAIN"
not_ok "不再提 versions lists"          "$plain" "no versions lists yet"

out=$(wave install treee 2>&1)
plain=$(strip_ansi "$out")
# 断言里的反引号用单引号包：双引号里它会变成命令替换，把 `tree` 真跑一遍，
# 输出变成目录树，测试于是莫名其妙地红 —— 实测踩过。
ok     "拼错时给近似名"                 "$plain" 'did you mean `tree`?'
ok     "并给出能直接跑的命令"            "$plain" "try: wave info tree"
ok     "同样排除网络/镜像问题"           "$plain" "not a network or mirror problem"

# 名字确实在清单里、只是镜像没提供它的版本清单：这时候才该指向镜像。
out=$(wave install nolist 2>&1)
plain=$(strip_ansi "$out")
ok     "名字对但缺清单时说的是数据问题"   "$plain" "the index has no version list for nolist"
ok     "并指明名字本身没错"              "$plain" "the package name is right"
ok     "给出管理员的修复动作"            "$plain" "build_versions_index.py"

echo
echo "========== 4. 正常用法不受影响 =========="

out=$(wave -V 2>&1)
not_ok "-V 不触发纠错" "$out" "Did you mean"
ok     "-V 打印版本"   "$out" "MacWave"

out=$(wave upgrade --help 2>&1)
ok "upgrade --help 仍是用法说明" "$out" "wave upgrade <package>"

out=$(wave search tre 2>&1)
ok "search 按片段匹配" "$out" "tree"

echo
echo "========== 3. 旗标拼错：给候选，但只在真有候选时 =========="

# --connect-time 是 --connect-timeout 少了三个字母。只说 "illegal option"
# 等于让用户回去翻 --help。
out=$(wave install jq --connect-time=1min 2>&1)
# 出错的那个旗标被标红，所以「you ran:」那一行里夹着转义序列。
plain=$(strip_ansi "$out")
ok     "给出最接近的旗标"   "$plain" "Did you mean --connect-timeout?"
ok     "仍然点名哪个旗标"   "$plain" "illegal option --connect-time"
ok     "仍然回显整条命令"   "$plain" "you ran: wave install jq --connect-time=1min"
ok     "保留 --help 自查"   "$plain" "wave install --help"
# 高亮只落在出错的旗标上：整行唯一的红色片段应当就是它
# 颜色按「未知命令」那块的配色来：旗标与 ^ 用普通红（31），不用加粗红。
if [[ "$out" == *$'\033[31m--connect-time'* ]]; then
    pass "出错的旗标被单独标红"
else
    fail "出错的旗标没有被标红"
fi

# Next 那几行不该再是黄字 —— 与「Did you mean:」保持一致：黑色正文，该敲的就是绿的。
if [[ "$out" != *$'\033[33m'* ]]; then
    pass "用法错误不再用黄色提示"
else
    fail "用法错误仍然是黄字"
fi

# --skip-ssl 是全工具唯一一处「用户主动要求降低安全性」的提示，必须与普通询问
# 区分开：用 RED_BOLD（1;31），与下面那个 retry 询问同一种红。
# 故意用一个**不存在的包名**：提示在取版本列表之前就打出来，所以这一段全程只碰
# 本地假镜像，不会真的去下载。
out=$(wave install no_such_pkg_for_skip_ssl --skip-ssl </dev/null 2>&1)
plain=$(strip_ansi "$out")
ok     "提示点名了旗标"     "$plain" "--skip-ssl"
ok     "提示说明了后果"     "$plain" "skip SSL certificate verification"
ok     "提示问了一句"       "$plain" "Are you sure?"
if [[ "$out" == *$'\033[1;31m🌊 You selected --skip-ssl'* ]]; then
    pass "--skip-ssl 的安全提示是红字"
else
    fail "--skip-ssl 的安全提示不是红字（应为 RED_BOLD）"
fi
# 拒绝（stdin 读到 EOF）之后不该继续安装
if [[ "$out" != *"Successfully installed"* ]]; then
    pass "读了 EOF 之后没有继续安装"
else
    fail "读了 EOF 之后仍然装了 —— 缺省应当往安全的方向倒"
fi

out=$(wave install jq --limt-rate=10M 2>&1)
ok     "限速旗标拼错也给建议" "$(strip_ansi "$out")" "Did you mean --limit-rate?"

# 没有任何接近的候选时不要瞎猜 —— 编一个坏建议比不给建议更伤人。
out=$(wave install jq --unkown-flag 2>&1)
not_ok "无候选时不编造建议"   "$out" "Did you mean"
ok     "仍然给出 --help"      "$out" "wave install --help"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All message tests passed${RESET}"
