#!/usr/bin/env python3
"""
MacWave Help Module
负责展示命令行帮助信息（简版和详细版）。
"""

import json

from configpaths import VERSION_FILE

# 颜色定义
RED = '\033[31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
CYAN = '\033[36m'
RESET = '\033[0m'
BOLD = '\033[1m'
PURPLE = '\033[35m'
ORANGE = '\033[38;5;197m'


def get_project_version():
    """从 VERSION.json 获取主程序版本号"""
    if VERSION_FILE.exists():
        try:
            with open(VERSION_FILE, 'r') as f:
                data = json.load(f)
                return data.get("version", "unknown")
        except Exception:
            pass
    return "unknown"


def print_custom_help():
    """简版帮助：与 README 的 Command Reference 保持一致"""
    version = get_project_version()
    print(f"{PURPLE}usage: {ORANGE}wave <command> [package] [flags]{RESET}")
    print()
    print(f"MacWave {version} 🌊")
    print("A package manager for macOS software developers.")
    print()
    print(f"{PURPLE}Commands:{RESET}")
    print(f"  {GREEN}install{RESET}               Install a package (latest version)")
    print(f"  {GREEN}upgrade{RESET}               Install a package at the latest version")
    print(f"  {GREEN}uninstall{RESET}             Uninstall a package")
    print(f"  {GREEN}list{RESET}                  List installed packages")
    print(f"  {GREEN}search{RESET}                Search for a package in the index")
    print(f"  {GREEN}info{RESET}                  Display detailed information about a package")
    print(f"  {GREEN}selfupdate{RESET}            Update MacWave itself to the latest version")
    print(f"  {GREEN}link{RESET}                  Link installed packages without a version number")
    print(f"  {GREEN}unlink{RESET}                Remove those unversioned links")
    print(f"  {GREEN}linkquery{RESET}             Show which version an unversioned link points to")
    print()
    print(f"{PURPLE}Flags:{RESET}")
    print(f"  {GREEN}-h, --help{RESET}            Show help for any command")
    print(f"  {GREEN}-V, --version{RESET}         Print version information")
    print(f"  {GREEN}-v, --verbose{RESET}         Enable verbose output (show detailed logs)")
    print()
    print(f"{PURPLE}Global Flags (can be used with any command):{RESET}")
    print(f"  {GREEN}-C, --continue{RESET}        Resume interrupted downloads (like curl -C -)")
    print(f"  {CYAN}--proxy{RESET} {YELLOW}string{RESET}        Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)")
    print(f"  {CYAN}--skip-ssl{RESET}            Skip SSL certificate verification (insecure)")
    print(f"  {CYAN}--limit-rate{RESET} {YELLOW}string{RESET}   Limit download speed (e.g., 200K, 1M, 5M)")
    print(f"  {CYAN}--max-time{RESET} {YELLOW}string{RESET}     Timeout for each request (e.g., 40s, 1min, 1min20s, 2h)")
    print(f"  {CYAN}--ver{RESET} {YELLOW}string{RESET}          Install a specific version (install only; --ver=1.0 works too)")
    print(f"  {CYAN}--install-from-source{RESET}     Download from the upstream URL instead of MacWave's own store")
    print(f"  {CYAN}--install-python-from-source{RESET} Same, for the bundled Python (install / selfupdate)")
    print(f"  {CYAN}MACWAVE_PIP_INDEX{RESET}  (env) pip index for the Python deps; default pypi.org/simple")
    print()
    print(f"{PURPLE}Special Flags:{RESET}")
    print(f"  {GREEN}wave install <pkgname>@<version>{RESET}   Download certain version(s) of a package")
    print(f"  {CYAN}--unlink{RESET}                         Leave the unversioned link alone (install / uninstall)")
    # 四种写法逐行列全，并在同一列对齐，避免续行看起来像另一个旗标
    print(f"  {CYAN}--remove-old-version{RESET}             Remove older versions after upgrading")
    print(f"  {CYAN}--remove-old-versions{RESET}, {CYAN}--rov{RESET}, {CYAN}-X{RESET} Same as --remove-old-version")
    print(f"  {CYAN}--all, -a{RESET}                        Apply to every installed package (link / unlink / linkquery)")
    print()
    print(f"{PURPLE}Unversioned Links:{RESET}")
    print(f"  {GREEN}wave link <name>{RESET}                 Link a package to its highest installed version")
    print(f"  {GREEN}wave linkquery <name>{RESET}            Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)")
    print(f"  {GREEN}wave unlink <name>{RESET}               Remove that link")
    print("  Links are created on install and re-pointed on uninstall; --unlink never leaves one broken.")
    print()
    print("For more details, visit: https://macwave.org")


# -------------------- 子命令帮助 --------------------
#
# `wave <command> -h|--help` 用这张表。只列该命令真正接受的旗标
# （依据各 handler 的旗标白名单），避免承诺做不到的事。

COMMAND_HELP = {
    "install": {
        "usage": "wave install <package>[@<version>] [flags]",
        "desc": "Install a package, or one specific version of it.",
        "flags": [
            ("-C, --continue", "Resume an interrupted download (like curl -C -)"),
            ("--proxy <string>", "HTTP/HTTPS proxy (e.g. http://127.0.0.1:8080)"),
            ("--skip-ssl", "Skip SSL certificate verification (insecure)"),
            ("--limit-rate <string>", "Limit download speed (e.g. 200K, 1M, 5M)"),
            ("--max-time <string>", "Timeout for each request (40s, 1min, 1min20s, 2h; bare numbers are seconds)"),
            ("--unlink", "Do not create or re-point the unversioned link"),
            ("--install-from-source", "Download from the upstream URL in the index instead of "
                                      "MacWave's own bottle store (dependencies follow the same rule)"),
            ("-v, --verbose", "Enable verbose output"),
        ],
        "examples": ["wave install jq", "wave install ffmpeg@6.1", "wave install jq --limit-rate 1M",
                     "wave install jq --max-time=1min", "wave install jq --install-from-source"],
    },
    "upgrade": {
        "usage": "wave upgrade <package> [flags]",
        "desc": "Install the latest version of a package. Versions coexist, so the old ones "
                "stay until one of the remove-old flags removes them.",
        "flags": [
            ("--remove-old-version", "Also remove the versions older than the one just installed"),
            ("--remove-old-versions", "Same as --remove-old-version"),
            ("--rov", "Same as --remove-old-version"),
            ("-X", "Same as --remove-old-version"),
            ("-C, --continue", "Resume an interrupted download (like curl -C -)"),
            ("--proxy <string>", "HTTP/HTTPS proxy (e.g. http://127.0.0.1:8080)"),
            ("--skip-ssl", "Skip SSL certificate verification (insecure)"),
            ("--limit-rate <string>", "Limit download speed (e.g. 200K, 1M, 5M)"),
            ("--max-time <string>", "Timeout for each request (40s, 1min, 1min20s, 2h; bare numbers are seconds)"),
            ("-v, --verbose", "Enable verbose output"),
        ],
        "examples": ["wave upgrade jq", "wave upgrade jq --remove-old-version",
                     "wave upgrade jq -X", "wave upgrade jq --rov --max-time=2min"],
    },
    "uninstall": {
        "usage": "wave uninstall <package>[@<version>] [flags]",
        "desc": "Uninstall a package version. The unversioned link falls back to the "
                "highest remaining version, and goes away with the last one.",
        "flags": [
            ("--unlink", "Leave the unversioned link alone"),
        ],
        "examples": ["wave uninstall jq", "wave uninstall ffmpeg@6.1"],
    },
    "list": {
        "usage": "wave list",
        "desc": "List the packages you have installed, with their versions.",
        "flags": [],
        "examples": ["wave list"],
    },
    "search": {
        "usage": "wave search <keyword>",
        "desc": "Search the package index.",
        "flags": [],
        "examples": ["wave search json"],
    },
    "info": {
        "usage": "wave info <package>",
        "desc": "Show author, description, homepage and the installed / available versions.",
        "flags": [],
        "examples": ["wave info jq"],
    },
    "selfupdate": {
        "usage": "wave selfupdate [flags]",
        "desc": "Update MacWave itself to the version published in the self-update repository.",
        "flags": [
            ("--max-time <string>", "Timeout for each request (40s, 1min, 1min20s, 2h; bare numbers are seconds)"),
            ("--install-python-from-source", "Fetch the bundled Python from its upstream URL "
                                             "instead of MacWave's own repository"),
        ],
        "examples": ["wave selfupdate", "wave selfupdate --max-time=2min"],
    },
    "link": {
        "usage": "wave link <package>[@<version>] | wave link --all",
        "desc": "Create a versionless shortcut, or re-point it at another installed "
                "version. Installs and uninstalls keep it up to date afterwards.",
        "flags": [
            ("--all, -a", "Apply to every installed package"),
        ],
        "examples": ["wave link jq", "wave link ffmpeg@6.1", "wave link --all"],
    },
    "unlink": {
        "usage": "wave unlink <package> | wave unlink --all",
        "desc": "Remove the versionless shortcut. A later uninstall will not re-create it.",
        "flags": [
            ("--all, -a", "Apply to every installed package"),
        ],
        "examples": ["wave unlink jq", "wave unlink --all"],
    },
    "linkquery": {
        "usage": "wave linkquery <package> | wave linkquery --all",
        "desc": "Show which version the versionless shortcut points at.",
        "flags": [
            ("--all, -a", "Apply to every installed package"),
        ],
        "examples": ["wave linkquery jq"],
    },
    "version": {
        "usage": "wave version",
        "desc": "Print the installed MacWave version.",
        "flags": [],
        "examples": ["wave version"],
    },
}


def print_command_help(command):
    """`wave <command> --help`：打印该命令自己的用法"""
    entry = COMMAND_HELP.get(command)
    if entry is None:
        print_custom_help()
        return

    print(f"{PURPLE}usage: {ORANGE}{entry['usage']}{RESET}")
    print()
    print(entry["desc"])

    if entry["flags"]:
        print()
        print(f"{PURPLE}Flags:{RESET}")
        for name, text in entry["flags"]:
            print(f"  {GREEN}{name}{RESET}" + " " * max(1, 22 - len(name)) + text)

    print()
    print(f"{PURPLE}Examples:{RESET}")
    for example in entry["examples"]:
        print(f"  {example}")

    print()
    print(f"All commands: {GREEN}wave --help{RESET}")


# -------------------- 版本与错误提示 --------------------

def print_version():
    """输出当前 MacWave 的版本号"""
    version = get_project_version()
    print(f"🌊 MacWave {version}")


def print_error_help():
    """未知命令或参数时：先报错，再输出完整帮助"""
    print(f"{BOLD}{RED}🌊 Error: Unknown command or argument.{RESET}")
    print()
    print_custom_help()


def main():
    """直接运行 python3 help.py 时，预览帮助信息"""
    print_custom_help()


if __name__ == "__main__":
    main()
