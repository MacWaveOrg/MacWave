#!/bin/bash

# arglen_test.sh
# Linux execve 对**单个参数字符串**的上限是 MAX_ARG_STRLEN = 32 页 = 131072 B，
# 判断长度时把结尾 NUL 算进去，所以一个参数正文最多 131071 B。
#
# 为什么这条归我们管：官方安装命令是
#     /bin/bash -c "$(curl -fsSL .../install.sh)"
# 整份脚本会被当成 argv 里的**一个**字符串递进去。超过 131071 B 时内核直接
# E2BIG（Argument list too long），脚本一个字节都执行不到 —— 报错停在 exec 层，
# 看着像"命令写错了"，其实是"脚本太大"。macOS 只有总的 ARG_MAX = 1 MiB，
# 没有单参数上限，所以本机能装、不代表 Linux 能装。
#
# 这个测试只量，不改脚本：谁超了、超了多少 B，一目了然。
#
# MacWave 自己只装 macOS，跑的时候不受这条限制（Darwin 只有总的 ARG_MAX = 1 MiB，
# 没有单参数上限）。守它的原因有两个：一是 LinuxWave 的安装器是从这里长出去的，
# 两边共用同一套模板，改这边会照着改那边；二是这份 install.sh 已经超线，
# 记在下面的 KNOWN_OVER 里，只许减肥不许再长。

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

LIMIT=$((32 * 4096 - 1))

# 会整份进入 argv 的文件（bash -c "$(cat …)" / bash -c "$(curl …)"）
FILES=(
    "lib/install.sh"
    "lib/uninstall.sh"
    "lib/selfupdate.sh"
)

# 已知超限的文件，值是「超出字节数」基线：只许不变或变小，不许长大，更不许新增。
# 格式 "<相对路径>:<超出字节数>"
KNOWN_OVER=(
    # 4.4.1 实测 139949 B，超 8878 B；4.4.2 加了 --skip-platform-check（旗标解析、
    # 用法文本、跳过闸门时那三行警告），141658 B，超 10587 B。它是 macOS 专属脚本，
    # 执行时不受这条限制，但既然已经超了，就不能再白白长大。
    "lib/install.sh:10587"
)

FAIL=0
CHECKED=0
OVERED=0

echo "🌊 单参数长度上限 ${LIMIT} B（MAX_ARG_STRLEN = 32 页 − 结尾 NUL）"
echo "------------------------------------------------------------"

# 按路径查已知基线，未登记则输出空
known_baseline() {
    local want="$1" entry
    for entry in ${KNOWN_OVER[@]+"${KNOWN_OVER[@]}"}; do
        if [[ "${entry%%:*}" == "$want" ]]; then
            echo "${entry##*:}"
            return 0
        fi
    done
    return 0
}

# 字节数 -> "12.3 KiB"，两段都用整数算，免得依赖 bc
kib() {
    local n="$1"
    printf '%d.%d KiB' $((n / 1024)) $(( (n % 1024) * 10 / 1024 ))
}

report() {
    local rel="$1" size over base
    if [[ ! -f "$REPO_DIR/$rel" ]]; then
        echo -e "  ${RED_BOLD}❌ $rel${RESET} 不存在"
        FAIL=1
        return
    fi
    size=$(wc -c < "$REPO_DIR/$rel" | tr -d ' ')
    over=$((size - LIMIT))
    CHECKED=$((CHECKED + 1))

    if [[ $over -le 0 ]]; then
        printf '  %b✅%b %-20s %8d B  余 %6d B (%s)\n' \
            "$GREEN" "$RESET" "$rel" "$size" $((-over)) "$(kib $((-over)))"
        return
    fi

    OVERED=$((OVERED + 1))
    base=$(known_baseline "$rel")
    if [[ -z "$base" ]]; then
        printf '  %b❌%b %-20s %8d B  %b超上限 %d B (%s)%b —— 未登记，Linux 上必然 E2BIG\n' \
            "$RED_BOLD" "$RESET" "$rel" "$size" "$RED_BOLD" "$over" "$(kib $over)" "$RESET"
        FAIL=1
    elif [[ $over -gt $base ]]; then
        printf '  %b❌%b %-20s %8d B  %b超上限 %d B，比基线 %d B 又多 %d B%b\n' \
            "$RED_BOLD" "$RESET" "$rel" "$size" "$RED_BOLD" "$over" "$base" $((over - base)) "$RESET"
        FAIL=1
    else
        printf '  %b⚠️%b  %-20s %8d B  超上限 %d B（已知基线 %d B，未恶化）\n' \
            "$YELLOW" "$RESET" "$rel" "$size" "$over" "$base"
    fi
}

echo "A. 会整份进 argv 的脚本"
for rel in "${FILES[@]}"; do
    report "$rel"
done

# 漏网之鱼：lib/ 下任何 .sh 一旦超线就必须登记，否则新脚本可以悄悄超线而没人发现
echo "------------------------------------------------------------"
echo "B. lib/*.sh 全量巡检（超线却没登记的，一样算失败）"
for path in "$REPO_DIR"/lib/*.sh; do
    [[ -f "$path" ]] || continue
    rel="lib/$(basename "$path")"
    size=$(wc -c < "$path" | tr -d ' ')
    [[ $size -le $LIMIT ]] && continue

    in_files=0
    for known in "${FILES[@]}"; do
        [[ "$known" == "$rel" ]] && in_files=1
    done
    [[ $in_files -eq 1 ]] && continue    # A 段已经量过，别重复报

    if [[ -z "$(known_baseline "$rel")" ]]; then
        OVERED=$((OVERED + 1))
        printf '  %b❌%b %-20s %8d B  超上限 %d B (%s) 但没进清单\n' \
            "$RED_BOLD" "$RESET" "$rel" "$size" $((size - LIMIT)) "$(kib $((size - LIMIT)))"
        FAIL=1
    else
        report "$rel"
    fi
done
echo "  （巡检完 $(ls "$REPO_DIR"/lib/*.sh | wc -l | tr -d ' ') 个脚本）"

echo "------------------------------------------------------------"
if [[ $FAIL -ne 0 ]]; then
    echo -e "${RED_BOLD}🌊 共量 $CHECKED 个脚本，$OVERED 个超限。超了就得减肥，别指望 macOS 的 1 MiB 替你兜底。${RESET}"
    exit 1
fi

if [[ $OVERED -gt 0 ]]; then
    echo -e "${YELLOW}🌊 共量 $CHECKED 个脚本，$OVERED 个超限但都在基线内（未恶化）。${RESET}"
else
    echo -e "${GREEN}🌊 共量 $CHECKED 个脚本，全部在上限内。${RESET}"
fi
