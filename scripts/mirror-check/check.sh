#!/bin/bash
# 镜像站全量体检：两个产品的公开页、认证、隔离、真实产物
#
# 只读，不创建也不修改任何东西 —— 随时可跑。
#
# 用法（在 Mac 终端执行，脚本本身在服务器上跑）：
#   ssh root@<服务器> 'bash -s' < check.sh
#
# 退出码 = 不符合预期的项数（0 表示全绿）。

set -uo pipefail

BASE=${BASE:-/www/wwwroot/mirror.repohub.top}
DOMAIN=${DOMAIN:-https://mirror.repohub.top}
LW_PASS_DIR=${LW_PASS_DIR:-/root/LinuxWaveMirror/password}
MACPASS_FILE=${MACPASS_FILE:-/root/macwave-passwords.txt}

FAIL=0
PASS=0

hr()   { printf '%s\n' "------------------------------------------------------------"; }
section() { hr; printf '%s\n' "$*"; hr; }
ok()   { PASS=$((PASS+1)); printf '  ✅ %-46s %s\n' "$1" "${2:-}"; }
no()   { FAIL=$((FAIL+1)); printf '  ❌ %-46s 实际 %s / 期望 %s\n' "$1" "$2" "$3"; }
note() { printf '  ·  %s\n' "$*"; }

expect() {   # expect 说明 实际 期望
    if [[ "$2" == "$3" ]]; then ok "$1" "$2"; else no "$1" "$2" "$3"; fi
}

need() {   # need 说明 URL 用户 口令 期望 —— URL 为空视为失败，绝不静默跳过
    local label=$1 url=$2 u=${3:-} p=${4:-} want=$5
    if [[ -z "$url" ]]; then no "$label" "没有测试目标" "$want"; return; fi
    if [[ -n "$u" ]]; then
        expect "$label" "$(code "$url" "$u" "$p")" "$want"
    else
        expect "$label" "$(code "$url")" "$want"
    fi
}

# ── 口令（只在服务器本机读取，不落到命令行历史）────────────────
LW_USER=REPOHUBUSER10001
LW_PASS=$(cat "$LW_PASS_DIR/10001" 2>/dev/null | tr -d '\r\n')

MAC_USER=REPOHUBUSER1
MAC_PASS=$(awk -v u="$MAC_USER" '$1==u {print $2; exit}' "$MACPASS_FILE" 2>/dev/null)
[[ -n "${MAC_PASS:-}" ]] || MAC_PASS=$(sed -nE "s/^${MAC_USER}:(.*)$/\1/p" "$MACPASS_FILE" 2>/dev/null | head -1)

# ── 从镜像里挑真实产物作为测试目标 ───────────────────────────
pick_rel() {   # 挑一个「能当靶子」的文件，输出相对路径（不含前导斜杠）
    # 必须排除点开头的路径段：nginx 里通常有一条 location ~ /\. 在认证之前就返回 404，
    # 拿那种文件当靶子会得到「404 而不是 401」的假失败 —— 客户端本来也不取这些文件。
    # 同时限制字符集，避免空格、#、? 之类让 curl 拼出无效 URL。
    #
    # 所有需要「从镜像里挑个文件」的地方都必须走这里 —— 两处各写一份自己的 find，
    # 就是这次「第 6 段修好了、第 7 段还在用旧逻辑」的由来。
    # 注意：这里**不能**写成 `... | sort | head -1`。`head` 读完一行就退出，
    # `sort` 继续写会吃到 SIGPIPE，而 `set -o pipefail` 会把那个 141 当成整条管道的结果。
    # 后果很隐蔽：输出明明有值，函数却返回非零 —— 大目录（MacWave 886 个文件、
    # 路径约 62 KB，正好塞满管道）必失败，小目录（LinuxWave 69 个）正常。
    # 所以先收全量，再在 bash 里取第一行，不让任何一段提前退出。
    local all
    all=$(find "$BASE/$1" -type f 2>/dev/null \
          | grep -vE '/\.[^/]' \
          | grep -E '^[A-Za-z0-9._@+/-]+$' \
          | sort)
    [[ -n "$all" ]] || return 1
    all=${all%%$'\n'*}
    printf '%s' "${all#"$BASE/"}"
}

pick() {   # pick 子目录 → 输出 URL 路径（@ 编码成 %40）
    local rel
    rel=$(pick_rel "$1") || return 1
    [[ -n "$rel" ]] || return 1
    printf '/%s' "${rel//@/%40}"
}
MAC_URL=$(pick MacWave)          || MAC_URL=""
LW_BOTTLE_URL=$(pick LinuxWave/bottle) || LW_BOTTLE_URL=""
LW_DEPS_URL=$(pick LinuxWave/deps)     || LW_DEPS_URL=""

code() {   # code URL [用户 口令]
    if [[ -n "${2:-}" ]]; then
        curl -so /dev/null -w '%{http_code}' --max-time 20 -u "${2}:${3}" "$DOMAIN$1"
    else
        curl -so /dev/null -w '%{http_code}' --max-time 20 "$DOMAIN$1"
    fi
}

size_of() {   # size_of URL 用户 口令 → 服务端声明的字节数（HEAD，省流量）
    # 必须声明 identity：nginx 开了 gzip 时 content-length 是压缩后的大小，
    # 拿它和磁盘字节比会「看起来不一致」，而实际没问题。
    curl -sI -H 'Accept-Encoding: identity' --max-time 20 -u "${2}:${3}" "$DOMAIN$1" \
        | awk 'BEGIN{IGNORECASE=1} /^content-length:/{gsub(/\r/,"");print $2}' | tail -1
}

# ─────────────────────────────────────────────────────────────
section "环境"
note "站点      $DOMAIN"
note "根目录    $BASE"
[[ -n "$LW_PASS"  ]] && ok "LinuxWave 口令可读" "$LW_PASS_DIR/10001" || no "LinuxWave 口令可读" "读不到" "存在"
[[ -n "$MAC_PASS" ]] && ok "MacWave 口令可读"   "$MACPASS_FILE"      || no "MacWave 口令可读"   "读不到" "存在"
note "MacWave  测试文件 ${MAC_URL:-（没有，MacWave/ 是空的？）}"
note "LW bottle 测试文件 ${LW_BOTTLE_URL:-（空）}"
note "LW deps   测试文件 ${LW_DEPS_URL:-（空）}"

# ─────────────────────────────────────────────────────────────
section "0. 数据规模（空目录必须报错，不能静默通过）"
cnt() { find "$BASE/$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
for sub in MacWave LinuxWave/bottle LinuxWave/deps; do
    n=$(cnt "$sub")
    if [[ "$n" -gt 0 ]]; then
        ok "$sub 有产物" "$n 个"
    else
        no "$sub 有产物" "$n 个" "> 0"
    fi
done

# ─────────────────────────────────────────────────────────────
section "1. 公开页：不需要口令"
# 图片在 images/ 下 —— 与 index.html 里的引用一致。写成根目录的 /macwave.png
# 会让体检长期报假失败，而首页其实是好的。
for p in / /index.html /macwave.html /linuxwave.html \
         /images/mascot.png /images/macwave.png /images/linuxwave.png \
         /images/oclp.png; do
    expect "GET $p" "$(code "$p")" 200
done

# ─────────────────────────────────────────────────────────────
section "2. 无口令：数据目录必须 401"
need "GET /MacWave/…"          "$MAC_URL"       ""       ""         401
need "GET /LinuxWave/bottle/…" "$LW_BOTTLE_URL" ""       ""         401
need "GET /LinuxWave/deps/…"   "$LW_DEPS_URL"   ""       ""         401

# ─────────────────────────────────────────────────────────────
section "3. LinuxWave 账号 $LW_USER"
if [[ -z "$LW_PASS" ]]; then
    note "读不到口令，无法验证隔离"; FAIL=$((FAIL+1))
else
    need "GET /LinuxWave/bottle/…（放行）" "$LW_BOTTLE_URL" "$LW_USER" "$LW_PASS" 200
    need "GET /LinuxWave/deps/…（放行）"   "$LW_DEPS_URL"   "$LW_USER" "$LW_PASS" 200
    need "GET /MacWave/…（隔离）"          "$MAC_URL"       "$LW_USER" "$LW_PASS" 401
fi

# ─────────────────────────────────────────────────────────────
section "4. MacWave 账号 $MAC_USER"
if [[ -z "$MAC_PASS" ]]; then
    note "读不到口令，无法验证隔离"; FAIL=$((FAIL+1))
else
    need "GET /MacWave/…（放行）"                "$MAC_URL"       "$MAC_USER" "$MAC_PASS" 200
    need "GET /LinuxWave/bottle/…（隔离）"       "$LW_BOTTLE_URL" "$MAC_USER" "$MAC_PASS" 401
    need "GET /LinuxWave/deps/…（隔离）"         "$LW_DEPS_URL"   "$MAC_USER" "$MAC_PASS" 401
fi

# ─────────────────────────────────────────────────────────────
section "5. 认证域（realm）应各不同"
realm() { curl -sI --max-time 20 "$DOMAIN$1" | awk 'BEGIN{IGNORECASE=1} /^www-authenticate:/{gsub(/\r/,"");print}' | head -1; }
MA=$(realm "${MAC_URL:-/MacWave/}")
LA=$(realm "${LW_BOTTLE_URL:-/LinuxWave/}")
note "MacWave   $MA"
note "LinuxWave $LA"
if [[ -n "$MA" && -n "$LA" && "$MA" != "$LA" ]]; then ok "两边 realm 不同" "已区分"; else no "两边 realm 不同" "相同或为空" "不同"; fi

# ─────────────────────────────────────────────────────────────
section "6. 路径归一化：这些都不该绕过认证"
# 注：点开头的路径（/.gitignore 等）会返回 404 而不是 401 —— 那是 nginx 的
# `location ~ /\.` 规则在认证之前就拒掉，属于预期行为，客户端也不取这类文件。
# 所以下面用普通产物做靶子。
# 用真实存在的 LinuxWave 文件做靶子，这样 401 是认证拦下的，而不是 404 造成的假象
T="${LW_BOTTLE_URL:-/LinuxWave/probe.txt}"
B="${T#/LinuxWave}"
for v in \
    "/LinuxWave" \
    "/linuxwave$B" \
    "//LinuxWave$B" \
    "/./LinuxWave$B" \
    "/MacWave/../LinuxWave$B" \
    "/LinuxWave/../MacWave/" \
    "/Linux%57ave$B" \
    "/LinuxWave%2F${B#/}" \
    ; do
    # --path-as-is 让 curl 原样发送，不自己把 // 与 .. 规整掉 —— 否则测的就不是 nginx 了
    c=$(curl --path-as-is -so /dev/null -w '%{http_code}' --max-time 15 "$DOMAIN$v")
    expect "$v" "$c" 401
done

# ─────────────────────────────────────────────────────────────
section "7. 真实产物内容长度（确认不是空壳 200）"
check_len() {   # check_len 说明 相对路径 用户 口令
    local label=$1 rel=$2 u=$3 p=$4
    local local_bytes remote_bytes
    local_bytes=$(wc -c < "$BASE/$rel" 2>/dev/null | tr -d ' ')
    remote_bytes=$(size_of "/${rel//@/%40}" "$u" "$p")
    if [[ -n "${local_bytes:-}" && "$local_bytes" == "${remote_bytes:-}" ]]; then
        ok "$label" "$remote_bytes 字节"
    else
        no "$label" "远端 ${remote_bytes:-?}" "本地 ${local_bytes:-?}"
    fi
}
for pair in "MacWave:$MAC_USER:$MAC_PASS" "LinuxWave/bottle:$LW_USER:$LW_PASS" "LinuxWave/deps:$LW_USER:$LW_PASS"; do
    sub=${pair%%:*}; rest=${pair#*:}; u=${rest%%:*}; p=${rest#*:}
    rel=$(pick_rel "$sub")
    [[ -z "${rel:-}" ]] && { note "$sub 下没有可用作靶子的文件"; FAIL=$((FAIL+1)); continue; }
    [[ -z "${u:-}" || -z "${p:-}" ]] && { note "$sub 没有可用口令"; FAIL=$((FAIL+1)); continue; }
    check_len "$sub 首个产物大小一致" "$rel" "$u" "$p"
done

# ─────────────────────────────────────────────────────────────
hr
if [[ "$FAIL" -eq 0 ]]; then
    printf '✅ 全部通过（%d 项）\n' "$PASS"
else
    printf '❌ %d 项不符合预期，%d 项通过\n' "$FAIL" "$PASS"
fi
hr
exit "$FAIL"
