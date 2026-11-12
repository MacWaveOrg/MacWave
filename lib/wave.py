#!/usr/bin/env python3

# wave.py

import sys
from pathlib import Path

# configerror 要在读到 base_dir **之前**就跑（它判断的正是「这台机器装了没」），
# 所以这几个目录只能按脚本自身的位置推 —— install 树与仓库里，lib/ 与 cli/、
# config/ 都是同级目录，两种情形同一条规则。
HERE = Path(__file__).resolve().parent      # <base_dir>/lib
ROOT = HERE.parent                          # <base_dir>

sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "config"))
sys.path.insert(0, str(ROOT / "cli"))

from configerror import check_environment, check_dependencies
check_environment()
check_dependencies()


# -------------------- 配置与模块路径 --------------------

from configpaths import load_base_dir

BASE_DIR = load_base_dir()
CLI_DIR = BASE_DIR / "cli"
CONFIG_DIR = BASE_DIR / "config"
LIB_DIR = BASE_DIR / "lib"
NET_DIR = BASE_DIR / "net"
PKG_DIR = BASE_DIR / "pkg"
SURFBOARD_DIR = BASE_DIR / "surfboard"

# 顺序与 scripts/components.txt 一致。逆序 insert 才会得到那个顺序：每次 insert(0)
# 都插在最前面，所以最后插入的排在首位。cli/ 与 config/ 因此压在 lib/ 之上 ——
# 从 4.3.x 升级上来的树里还留着 lib/help.py 之类的旧副本，不能让它们盖住新模块。
for _component in (SURFBOARD_DIR, PKG_DIR, NET_DIR, LIB_DIR, CONFIG_DIR, CLI_DIR):
    sys.path.insert(0, str(_component))
del _component

# 放在顶层：「未知命令」那条分支也要用它们，而那条分支在分发之前。
#   silent  —— 静默旗标的解析与应用（见 cli/silent.py）
#   suggest —— 命令名打错时的纠错建议（见 cli/suggest.py）
import silent
import suggest as suggest_module


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
    "shellenv":   "shellenv",
    "manual":     "manual",
}

ARGUMENTS = {
    "-h":        "help",
    "--help":    "help",
    "-V":        "help",
    "--version": "help",
}

# -------------------- 主调度逻辑 --------------------

def main():
    words = sys.argv[1:]

    # `--zh` 只影响帮助文本，不参与分发。放在最前面算一次，下面两个帮助分支共用。
    lang = "zh" if "--zh" in words else "en"

    # 1. 无任何输入
    if not words:
        from help import print_custom_help
        print_custom_help(lang)
        sys.exit(0)

    # 先算一次静默状态：下面「命令不存在」的分支也要用它，
    # 而 words 的正式剥离发生在 COMMANDS 分支内（那里的 words 才是给 handler 的）。
    #
    # 取首词也从剥离后的副本里取：`wave -s update jq` 里的 -s 是全局旗标，
    # 不该被当成命令名报「unknown command: -s」。
    lead, is_silent, _show_error = silent.strip(words)
    FirstWord = lead[0] if lead else words[0]

    # 2. 参数优先
    if FirstWord in ARGUMENTS:
        if FirstWord in ("-h", "--help"):
            from help import print_custom_help
            print_custom_help(lang)
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

        # `--skip-ssl` 在这里只**记录**，真正生效要等确认之后（见 net/tls.py）。
        # install / upgrade 会先弹一句安全询问，用户答否时不能跳过校验；
        # 其余命令没有那道询问，直接授权。
        import tls
        tls.configure_from(words)
        if FirstWord not in ("install", "upgrade"):
            tls.grant()

        # `-s / --silent`（含 `-sS`）：剥掉旗标并落到运行期开关。细节与理由在
        # cli/silent.py 的 A 段 —— 主程序只负责「剥完继续分发」。
        words = silent.apply(words, FirstWord)

        # `wave <command> -h|--help`：打印该命令自己的用法后退出。
        # 必须在这里拦下：各 handler 的旗标白名单里没有 --help，
        # 否则它会被当作未知旗标忽略（selfupdate 甚至直接开始自更新）。
        if any(word in ("-h", "--help") for word in words[1:]):
            from help import print_command_help
            print_command_help(FirstWord, lang)
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

        elif module_name == "shellenv":
            from shellenv import handle_shellenv
            sys.exit(handle_shellenv())

        elif module_name == "manual":
            from manual import handle_manual
            sys.exit(handle_manual(full_input))

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
    #
    # 首词也要查：`wave --h` 这行里唯一的词就是写错的旗标，跳过 words[0] 就一条
    # 旗标都查不到，于是既没有回显命令行、也没有 ^^^ 指住它 —— 只剩下
    # 「For the full list: wave -h」这句，用户看不出错在哪。
    import flags as flags_module
    bad_flags = flags_module.unknown_flags(words)

    if is_silent:
        silent.unknown("command", FirstWord)
        sys.exit(1)

    # 建议里不能留着坏旗标 —— 否则「Did you mean: wave upgrade jq --unkown-flag」
    # 抄给用户一条还是错的命令，他照着改会再撞一次同样的错。
    hint = suggest_module.command(words, COMMANDS)
    if hint and bad_flags:
        fixed, wrong, right = hint
        kept = [w for w in fixed.split() if not set(flags_module.split(w)) & set(bad_flags)]
        hint = (" ".join(kept), wrong, right)

    from help import print_error_help
    print_error_help(hint, unknown_flags=bad_flags, argv=sys.argv)
    sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # 各子模块只在 __main__ 里捕获 KeyboardInterrupt，而 wave 是 import 它们再调用，
        # 那条路径捕获不到，于是 Ctrl+C 会甩出 Python 栈回溯。这里兜一层。
        print()
        print("🌊 Operation cancelled by user.")
        sys.exit(130)
