#!/usr/bin/env python3

# silent.py
# `-s / --silent` 与 `-S / --show-error` 的**参数层**。
#
# 与 quiet.py 的分工（两个模块，一件事各管一半）：
#
#   silent.py   拿到用户敲的那串词之后要做的判断：哪些命令能静默、怎么把旗标
#               从 argv 里剥掉、剥完怎么落到运行期开关。**它只被 wave.py 调用。**
#   quiet.py    运行期的一切输出闸门：say / ask / silence_everything /
#               machine_readable。pkg/、surfboard/ 里的模块都用它。
#
# 为什么解析要单独一个模块而不是留在 wave.py：主程序只该做「读命令、分发」，
# 而静默涉及一张白名单、合并短旗标（`-sX`、`-CsX`）、fd 层重定向与环境变量下传
# 四件事 —— 塞在 main() 里会把分发逻辑淹掉。

import os
import sys

import flags
import quiet


# `-s` 只对「有过程可安静」的命令有意义。list / latest / search / info / mirror
# 存在的目的就是打印，给它们 -s 只会得到一片空白 —— 那不是静默，是把命令废掉。
# 所以这些命令上出现 -s 直接报错，比让它默默什么都不输出好。
#
# **这份名单是权威**，flags.COMMAND_FLAGS 里那份是给它做提示文案用的副本；
# scripts/flags_test.sh 比对两边。加一条能静默的命令时，两处都要改。
SILENT_COMMANDS = {"install", "upgrade", "uninstall", "link", "unlink", "selfupdate"}


def strip(words):
    """把 `-s` / `--silent` / `-S` / `--show-error` 从 argv 里拿掉。

    返回 (剩下的 words, 是否静默, 是否保留错误)。写法与 upgrader 处理 -X 一致：

        wave install jq -s          单个
        wave install jq --silent    长写法
        wave upgrade jq -sX         合并（s 与 X 都在这一簇里）
        wave upgrade jq -CsX        合并里夹着别的短旗标
        wave install jq -sS         静默但保留错误（curl 的 -sS）

    只处理单横线短旗标簇，`--skip-ssl` 这类长旗标不受影响（`s`/`S` 不在
    `--` 开头的那一类里找）。包名不以 `-` 开头，所以不会被误伤。
    """
    silent = False
    show_error = False
    kept = []
    for word in words:
        if word == "--silent":
            silent = True
            continue
        if word == "--show-error":
            show_error = True
            continue
        cluster = flags.short_cluster(word)
        if cluster is not None:
            # 大写 S 与小写 s 各管一件事，顺序无关：-sS 与 -Ss 等价
            silent = silent or "s" in cluster
            show_error = show_error or "S" in cluster
            remaining = flags.remove_short(word, "sS")
            if remaining is not None:
                if remaining:
                    kept.append(remaining)
                continue
        kept.append(word)
    return kept, silent, show_error


def apply(words, command):
    """剥掉静默旗标、把结论落到 quiet，返回剩下该交给 handler 的 words。

    位置必须在分发之前，而且必须**从 argv 里拿掉**这两个旗标：各 handler 的旗标
    白名单里没有它们（按命令各自校验，加进去要改十几处），留着的话
    `wave install jq -s` 会报「illegal option -s」。

    静默优先于啰嗦：同时给了 -v，-v 会被各模块的 verbose 判定挡掉。
    """
    words, is_silent, show_error = strip(words)
    if not is_silent:
        return words

    if command not in SILENT_COMMANDS:
        # 拒绝得早一点，并且用和「旗标写错」同一种形状，脚本好处理。
        # 不能说 unknown —— -s 真实存在，只是不适用于只读命令。
        # 这句话由 flags.describe 生成，别在这里另拼一份：命令清单存在
        # flags.COMMAND_FLAGS 里，与下面的 SILENT_COMMANDS 由 flags_test.sh
        # 钉着不许走散。
        quiet.misplaced("-s", flags.describe("-s") or "-s is not available here")
        sys.exit(1)

    # 单给 -s 时连错误一起吞（curl 语义）；-sS 才留错误。
    quiet.set_silent(True, show_error=show_error)
    if show_error:
        # -sS：输出给脚本读，一律不带 🌊（见 quiet.machine_readable）
        quiet.machine_readable()
    else:
        quiet.silence_everything()

    # 子脚本（pkginstaller.sh、depsmanager.sh…）也要知道：它们的输出虽然由
    # Python 重印，但 update_commands 那类直接写终端的脚本只能靠环境变量。
    os.environ["MACWAVE_SILENT"] = "1"
    return words


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    sys.exit(1)
