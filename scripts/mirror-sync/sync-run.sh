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
# 部署副本可能落后于仓库：mirror-sync.sh 的默认值变过一次（KEEP_BRANCHES），
# 旧副本因此把 4.5 的 core 树删了。这里每次跑之前先对齐，避免同类漂移。
SRC="${MIRROR_SRC:-$DIR/../mirror-src/tools}/scripts/mirror-sync/mirror-sync.sh"
SELF_UPDATE="$DIR/mirror-sync.sh"

refresh_self() {
    [[ -f "$SRC" ]] || return 0
    cmp -s "$SRC" "$SELF_UPDATE" && return 0
    /bin/bash -n "$SRC" || { echo "⚠️  $SRC 语法有问题，继续用现有副本"; return 0; }
    cp -a "$SELF_UPDATE" "$SELF_UPDATE.bak-$(date +%Y%m%d-%H%M)"
    cp "$SRC" "$SELF_UPDATE" && chmod +x "$SELF_UPDATE"
    echo "🔄 已用 $SRC 更新 $(basename "$SELF_UPDATE")（旧副本已备份）"
}
refresh_self > "$LOG.refresh" 2>&1

/bin/bash "$SELF_UPDATE" "$@" > "$LOG" 2>&1
rc=$?
if [[ -s "$LOG.refresh" ]]; then
    cat "$LOG" >> "$LOG.refresh" && mv "$LOG.refresh" "$LOG"
fi
rm -f "$LOG.refresh"

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
