#!/bin/bash
# mirror-sync.sh 的定时包装：跑一次、记账、失败留 ALERT
#
# 报警只落在 ALERT 文件里 —— 服务器没装 MTA，mail 必然失败。
# 与 /root/mirror-check 的约定保持一致，两个目录用同一套看法。
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
LOG="$DIR/last-run.log"
HIST="$DIR/history.log"
ALERT="$DIR/ALERT"

bash "$DIR/mirror-sync.sh" "$@" > "$LOG" 2>&1
rc=$?

ts=$(date '+%Y-%m-%d %H:%M:%S')
if (( rc == 0 )); then
    printf '%s  rc=0  ✅ 同步完成\n' "$ts" >> "$HIST"
    rm -f "$ALERT"
else
    printf '%s  rc=%s  ❌ 同步失败\n' "$ts" "$rc" >> "$HIST"
    printf '%s rc=%s\n' "$ts" "$rc" > "$ALERT"
fi

tail -n 200 "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
exit "$rc"
