#!/usr/bin/env python3

# downloads.py
# 下载暂存目录的维护：把放太久的 `<文件名>.partial` 清掉。
#
# 为什么需要：.partial 只有两种正常归宿 —— 下载完成后改名，或者这次命令失败时
# 被删掉。但中断是常态（Ctrl-C、断网、笔记本合盖），留着的那一份本来是给
# `wave install -C` 续传用的；用户一旦不再重试，它会一直占着几百 MB 到几 GB，
# 而且 `downloads/tmp` 里的东西既不在 `wave list` 里、也不在卸载路径上，
# 谁都不会想起来删。
#
# 判据只看 mtime：**7 天**没被动过就算放弃。比「按命令记录状态」简单，也更符合
# 直觉 —— 一个礼拜没续传的下载，续上也多半因为上游换了文件而对不上 sha256。
#
# 清理是**尽力而为**：删不掉（权限、被别的进程占用）就跳过，绝不让一条本来该成功的
# 安装因为顺手打扫而失败。唯一的输出是一行汇总，静默模式（-s）下不打印。

import time

import silent
from configpaths import load_base_dir, to_tilde

# 超过这个天数的 .partial 视为放弃
STALE_DAYS = 7


def download_tmp():
    # 下载暂存目录。与 pkg/pkginstaller.py 的 DOWNLOAD_TMP 是同一个位置 ——
    # 这里不 import 那个模块，只为算一个路径不值得把整条安装流水线拉起来。
    return load_base_dir() / "downloads" / "tmp"


def sweep_stale_partials(days=STALE_DAYS):
    """删掉 downloads/tmp 里超过 `days` 天没被动过的 .partial，返回删掉的文件名。

    只看这一层、只认 `.partial` 后缀：解压用的临时目录与完成后的归档都不归它管，
    前者已经由安装流程自己清，后者在改名之后就不再是「没下完的东西」。
    """
    directory = download_tmp()
    if not directory.is_dir():
        return []

    cutoff = time.time() - days * 86400
    removed = []

    for entry in sorted(directory.glob("*.partial")):
        try:
            # 悬空的软链接也算残留（is_file() 对它是 False）
            if not entry.is_file() and not entry.is_symlink():
                continue
            if entry.stat().st_mtime >= cutoff:
                continue
            entry.unlink()
        except OSError:
            continue
        removed.append(entry.name)

    if removed:
        # 说清楚「删了什么、为什么、在哪」——这条消息的全部用处就是让用户知道
        # downloads/tmp 里少掉的东西不是丢了。名字太多时只列前几个，别刷屏。
        shown = ", ".join(removed[:3])
        if len(removed) > 3:
            shown += f", … (+{len(removed) - 3})"
        silent.say(f"🌊 Cleaned up {len(removed)} stale partial download(s) from "
                   f"{to_tilde(str(directory))} (untouched for {days}+ days): {shown}")
    return removed
