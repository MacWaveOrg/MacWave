#!/bin/bash
# check.sh 的定时包装：跑一次、记账、失败时留 ALERT 并尝试发信
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
LOG="$DIR/last-run.log"
HIST="$DIR/history.log"
ALERT="$DIR/ALERT"

bash "$DIR/check.sh" > "$LOG" 2>&1
rc=$?

ts=$(date '+%Y-%m-%d %H:%M:%S')
summary=$(grep -E '全部通过|项不符合预期' "$LOG" | tail -1 | sed 's/^[[:space:]]*//')
printf '%s  rc=%s  %s\n' "$ts" "$rc" "$summary" >> "$HIST"
tail -n 120 "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"

if [[ "$rc" -ne 0 ]]; then
    { echo "检查时间：$ts"; echo "退出码：$rc"; echo; cat "$LOG"; } > "$ALERT"
    # 服务器上常有 mail 但没配 MTA，发信必然失败。所以全程静默：
    # 成败都不打扰 cron 输出，只在 ALERT 里留一行结果。
    for m in mail msmtp sendmail; do
        if command -v "$m" >/dev/null 2>&1; then
            if [[ "$m" == mail ]]; then
                "$m" -s "[mirror] check failed rc=$rc" root < "$LOG" >/dev/null 2>&1 && sent=1 || sent=0
            else
                printf 'To: root\nSubject: [mirror] check failed rc=%s\n\n' "$rc" \
                    | cat - "$LOG" | "$m" -t >/dev/null 2>&1 && sent=1 || sent=0
            fi
            if [[ "${sent:-0}" -eq 1 ]]; then
                echo "  已通过 $m 发信" >> "$ALERT"
            else
                echo "  $m 发信失败（多半没配 MTA），只看本文件与 last-run.log" >> "$ALERT"
            fi
            break
        fi
    done
else
    # 通过时必须清掉旧的 ALERT，否则一次故障会永久显示成「当前有故障」
    rm -f "$ALERT"
fi
exit "$rc"
