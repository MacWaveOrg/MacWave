#!/bin/bash
# 在服务器上安装镜像站巡检：每天 04:17 跑一次 check.sh
set -uo pipefail
DIR=${DIR:-/root/mirror-check}
# 权限在 rsync 之后可能被覆盖成 644（本地没加 +x 时），这里每次都兜底
chmod +x "$DIR/check.sh" "$DIR/run.sh" "$DIR/install.sh" 2>/dev/null || true

if ! bash -n "$DIR/check.sh"; then
    echo "❌ check.sh 语法有问题，不安装"; exit 1
fi

# cron：先删旧的同目录条目，再加一条（幂等）
# 用 bash 显式解释，这样即使 rsync 覆盖把执行位弄丢也不会 126
CRON_LINE="17 4 * * * bash $DIR/run.sh >/dev/null 2>&1"
CUR=$(crontab -l 2>/dev/null | grep -v "$DIR/run.sh" || true)
{ [[ -n "$CUR" ]] && printf '%s\n' "$CUR"; printf '%s\n' "$CRON_LINE"; } | crontab -
echo "✅ cron 已安装：" ; crontab -l | grep "$DIR/run.sh" | sed 's/^/   /'

echo
echo "首次执行一次（约 10 秒）…"
"$DIR/run.sh"
rc=$?
echo
if [[ "$rc" -eq 0 ]]; then
    echo "✅ 首次巡检通过"
else
    echo "❌ 首次巡检失败（退出码 $rc），详见 $DIR/last-run.log"
fi

echo
echo "查看方式："
echo "  tail -5  $DIR/history.log      最近几次的结论"
echo "  cat      $DIR/last-run.log     本次完整输出"
echo "  ls       $DIR/ALERT            存在=当前有故障"
exit "$rc"
