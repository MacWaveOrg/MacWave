#!/bin/bash
# 在服务器上安装镜像同步：每天 03:23 跑一次 mirror-sync.sh
#
# 时间排在巡检（04:17）之前：同步完再体检，体检看到的就是同步后的状态。
set -uo pipefail
DIR=${DIR:-/root/mirror-sync}
# 权限在 rsync 之后可能被覆盖成 644，这里每次都兜底
chmod +x "$DIR"/*.sh 2>/dev/null || true

if ! bash -n "$DIR/mirror-sync.sh"; then
    echo "❌ mirror-sync.sh 语法有问题，不安装"; exit 1
fi

CRON_LINE="23 3 * * * bash $DIR/sync-run.sh >/dev/null 2>&1"
CUR=$(crontab -l 2>/dev/null | grep -v "$DIR/sync-run.sh" || true)
{ [[ -n "$CUR" ]] && printf '%s\n' "$CUR"; printf '%s\n' "$CRON_LINE"; } | crontab -
echo "✅ cron 已安装："
crontab -l | grep "$DIR/sync-run.sh" | sed 's/^/   /'

echo
echo "首次执行一次（只同步 git 树与清单，不碰产物）…"
bash "$DIR/sync-run.sh" --no-payloads
rc=$?
echo
if (( rc == 0 )); then
    echo "✅ 首次同步通过"
else
    echo "❌ 首次同步失败（退出码 $rc），详见 $DIR/last-run.log"
fi

echo
echo "查看方式："
echo "  tail -5  $DIR/history.log      最近几次的结论"
echo "  cat      $DIR/last-run.log     本次完整输出"
echo "  ls       $DIR/ALERT            存在=当前有故障"
echo
echo "产物（bottle/deps）暂不纳入 cron：先手工跑一次全量，确认无误后把 --no-payloads 去掉。"
exit "$rc"
