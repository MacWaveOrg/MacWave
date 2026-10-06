#!/usr/bin/env python3

# wave.py

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from configerror import check_environment
check_environment()


# -------------------- 配置与模块路径 --------------------

from configpaths import load_base_dir

BASE_DIR = load_base_dir()
LIB_DIR = BASE_DIR / "lib"
PKG_DIR = BASE_DIR / "pkg"
SURFBOARD_DIR = BASE_DIR / "surfboard"

sys.path.insert(0, str(LIB_DIR))
sys.path.insert(0, str(PKG_DIR))
sys.path.insert(0, str(SURFBOARD_DIR))


# -------------------- 字典定义 --------------------

COMMANDS = {
    "install":    "pkginstaller",
    "uninstall":  "uninstaller",
    "list":       "pkginfohelper",
    "search":     "pkginfohelper",
    "info":       "pkginfohelper",
    "version":    "help",
    "selfupdate": "selfupdate",
    "link":       "linker",
    "unlink":     "linker",
    "linkquery":  "linker",
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

    # 1. 无任何输入
    if not words:
        from help import print_custom_help
        print_custom_help()
        sys.exit(0)

    FirstWord = words[0]

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

        elif module_name == "linker":
            from linker import handle_link_command, handle_linkquery_command, handle_unlink_command
            if FirstWord == "link":
                handle_link_command(full_input)
            elif FirstWord == "linkquery":
                handle_linkquery_command(full_input)
            else:
                handle_unlink_command(full_input)

        # 预留：query

        sys.exit(0)

    # 4. 未知输入
    from help import print_error_help
    print_error_help()
    sys.exit(1)


if __name__ == "__main__":
    main()