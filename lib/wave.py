#!/usr/bin/env python3

# wave.py

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from configerror import check_environment, check_dependencies
check_environment()
check_dependencies()


# -------------------- 配置与模块路径 --------------------

from configpaths import load_base_dir

BASE_DIR = load_base_dir()
LIB_DIR = BASE_DIR / "lib"
PKG_DIR = BASE_DIR / "pkg"
SURFBOARD_DIR = BASE_DIR / "surfboard"

sys.path.insert(0, str(LIB_DIR))
sys.path.insert(0, str(PKG_DIR))
sys.path.insert(0, str(SURFBOARD_DIR))

# 放在顶层：「未知命令」那条分支也要用它，而那条分支在分发之前
import quiet


# -------------------- 字典定义 --------------------

COMMANDS = {
    "install":    "pkginstaller",
    "upgrade":    "upgrader",
    "uninstall":  "uninstaller",
    "list":       "pkginfohelper",
    "search":     "pkginfohelper",
    "info":       "pkginfohelper",
    "version":    "help",
    "selfupdate": "selfupdate",
    "link":       "linker",
    "unlink":     "linker",
    "linkquery":  "linker",
    "mirror":     "mirrorinfo",
    "latest":     "latest",
}

ARGUMENTS = {
    "-h":        "help",
    "--help":    "help",
    "-V":        "help",
    "--version": "help",
}

# 常见误输入 → 正确的命令。
#
# 只收真的会有人这么打的几条，不做通用拼写纠正：/usr/bin 里那些包管理器的叫法
# （apt update、yum update、dnf update）会让人顺手打 `wave update`，而这里只有 upgrade。
# 猜错比不猜更让人困惑，所以宁可少提示。
MISTYPED = {
    "update":  "upgrade",
    "updates": "upgrade",
    "remove":  "uninstall",
    "delete":  "uninstall",
    "rm":      "uninstall",
    "ls":      "list",
    "find":    "search",
    "show":    "info",
}


def suggest(words):
    """首词打错时给出完整改法：只换掉那个词，其余参数与旗标原样保留。

    返回 (改好的命令行, 打错的词, 正确命令)；不认识就返回 None。
    """
    if not words:
        return None
    right = MISTYPED.get(words[0])
    if right is None or right not in COMMANDS:
        return None
    return " ".join(["wave", right] + words[1:]), words[0], right


# -------------------- 全局旗标 --------------------

# `-s` 只对「有过程可安静」的命令有意义。list / latest / search / info / mirror
# 存在的目的就是打印，给它们 -s 只会得到一片空白 —— 那不是静默，是把命令废掉。
# 所以这些命令上出现 -s 直接报错，比让它默默什么都不输出好。
SILENT_COMMANDS = {"install", "upgrade", "uninstall", "link", "unlink", "selfupdate"}


def strip_silent(words):
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
        if word.startswith("-") and not word.startswith("--") and len(word) > 1:
            letters = word[1:]
            # 大写 S 与小写 s 各管一件事，顺序无关：-sS 与 -Ss 等价
            for letter in ("s", "S"):
                if letter in letters:
                    if letter == "s":
                        silent = True
                    else:
                        show_error = True
                    letters = letters.replace(letter, "")
            if letters != word[1:]:
                if letters:
                    kept.append("-" + letters)
                continue
        kept.append(word)
    return kept, silent, show_error


# -------------------- 主调度逻辑 --------------------

def main():
    words = sys.argv[1:]

    # 1. 无任何输入
    if not words:
        from help import print_custom_help
        print_custom_help()
        sys.exit(0)

    # 先算一次静默状态：下面「命令不存在」的分支也要用它，
    # 而 words 的正式剥离发生在 COMMANDS 分支内（那里的 words 才是给 handler 的）。
    #
    # 取首词也从剥离后的副本里取：`wave -s update jq` 里的 -s 是全局旗标，
    # 不该被当成命令名报「unknown command: -s」。
    lead, silent, show_error = strip_silent(words)
    FirstWord = lead[0] if lead else words[0]

    # 2. 参数优先
    if FirstWord in ARGUMENTS:
        if FirstWord in ("-h", "--help"):
            from help import print_custom_help
            print_custom_help()
        elif FirstWord in ("-V", "--version"):
            from help import print_version
            print_version()
        sys.exit(0)

    # 3. 命令分发
    if FirstWord in COMMANDS:
        # `--proxy` 必须对这条命令的**所有**请求生效，不只是下载包体那一步。
        # 做法是把值写进进程环境（HTTPS_PROXY 等），因为 requests（trust_env 默认开）、
        # urllib 与 bash 子脚本里的 curl 都读环境变量 —— 一处生效，全部覆盖。
        # 这一步放在分发之前：任何 handler 及其子进程都继承这份环境。
        from configpaths import apply_proxy_from_command_line
        apply_proxy_from_command_line(words)

        # `-s / --silent`：这条命令只留错误输出。位置放在分发之前，因为
        # handler 的旗标白名单里没有它（各命令按自己的白名单校验，加进去要改
        # 十几处），而且它天然是全局选项。所以这里**把它从 argv 里拿掉**，
        # 而不是让下游去认它 —— 留着的话 `wave install jq -s` 会报
        # 「illegal option -s」。
        #
        # 支持合并写法：`-sX`、`-Xs`、`-CsX` 里的 s 都算。upgrader 的
        # split_input 本来就用同样的办法处理 -X，这里保持一致。
        #
        # 静默优先于啰嗦：同时给了 -v，-v 会被 steplog.set_verbose 挡掉。
        words, silent, show_error = strip_silent(words)
        if silent:
            if FirstWord not in SILENT_COMMANDS:
                # 拒绝得早一点，并且用和「旗标写错」同一种形状，脚本好处理。
                # 不能说 unknown —— -s 真实存在，只是不适用于只读命令。
                applicable = ", ".join(f"wave {name}" for name in sorted(SILENT_COMMANDS))
                quiet.misplaced("-s", f"-s only applies to {applicable}")
                sys.exit(1)
            # 单给 -s 时连错误一起吞（curl 语义）；-sS 才留错误。
            quiet.set_silent(True, show_error=show_error)
            if not show_error:
                quiet.silence_everything()
            # 子脚本（pkginstaller.sh、depsmanager.sh…）也要知道：它们的输出
            # 虽然由 Python 重印，但 update_commands 那类直接写终端的脚本
            # 只能靠环境变量。
            os.environ["MACWAVE_SILENT"] = "1"

        # `wave <command> -h|--help`：打印该命令自己的用法后退出。
        # 必须在这里拦下：各 handler 的旗标白名单里没有 --help，
        # 否则它会被当作未知旗标忽略（selfupdate 甚至直接开始自更新）。
        if any(word in ("-h", "--help") for word in words[1:]):
            from help import print_command_help
            print_command_help(FirstWord)
            sys.exit(0)

        module_name = COMMANDS[FirstWord]
        full_input = "wave " + " ".join(words)

        if module_name == "pkginstaller":
            from pkginstaller import handle_install
            handle_install(full_input)

        elif module_name == "upgrader":
            from upgrader import handle_upgrade
            handle_upgrade(full_input)

        elif module_name == "uninstaller":
            from uninstaller import handle_uninstall
            handle_uninstall(full_input)

        elif module_name == "pkginfohelper":
            from pkginfohelper import handle_info_command
            handle_info_command(full_input)

        elif module_name == "help":
            from help import print_version
            print_version()

        elif module_name == "selfupdate":
            from selfupdate import handle_selfupdate
            handle_selfupdate(full_input)

        elif module_name == "mirrorinfo":
            from mirrorinfo import handle_mirror
            handle_mirror(full_input)

        elif module_name == "latest":
            from latest import handle_latest
            handle_latest(full_input)

        elif module_name == "linker":
            from linker import handle_link_command, handle_linkquery_command, handle_unlink_command
            if FirstWord == "link":
                handle_link_command(full_input)
            elif FirstWord == "linkquery":
                handle_linkquery_command(full_input)
            else:
                handle_unlink_command(full_input)

        sys.exit(0)

    # 4. 未知输入
    #
    # 静默模式下不能印整篇帮助（那是噪音，而且脚本要的是可匹配的一行）。
    # 但命令写错必须让人知道 —— 否则 `wave update jq -s` 会一声不响地失败。
    # 注意这里要先剥掉 -s 再取词，否则 `wave -s update` 会把 -s 当成命令名。
    # 命令名写错时，旗标根本轮不到校验 —— 于是 `wave update jq --unkown-flag`
    # 只会说「update 不是命令」，把那条拼错的旗标一起吞了。而「建议」还会把
    # 它原样抄进去，用户照着改仍然错。所以这里单独查一遍：
    # 不在任何命令白名单里的旗标，一并报出来。
    import flags as flags_module
    bad_flags = flags_module.unknown_flags(words[1:])

    if silent:
        quiet.unknown("command", FirstWord)
        sys.exit(1)

    # 建议里不能留着坏旗标 —— 否则「Did you mean: wave upgrade jq --unkown-flag」
    # 抄给用户一条还是错的命令，他照着改会再撞一次同样的错。
    hint = suggest(words)
    if hint and bad_flags:
        fixed, wrong, right = hint
        kept = [w for w in fixed.split() if not set(flags_module.split(w)) & set(bad_flags)]
        hint = (" ".join(kept), wrong, right)

    from help import print_error_help
    print_error_help(hint, unknown_flags=bad_flags)
    sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # 各子模块只在 __main__ 里捕获 KeyboardInterrupt，而 wave 是 import 它们再调用，
        # 那条路径捕获不到，于是 Ctrl+C 会甩出 Python 栈回溯。这里兜一层。
        print("\n🌊 Operation cancelled by user.")
        sys.exit(130)