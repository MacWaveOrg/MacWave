#!/usr/bin/env python3
"""
MacWave Help Module
负责展示命令行帮助信息（简版和详细版）。
"""

import json
import re

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


# -------------------- 排版 --------------------
#
# 原先靠手数空格对齐，标签长度一改就错位（实测各块描述起始列从 34 到 52 都有）。
# 改成每块先量出最宽的标签再统一补空格，加多少条都不用重新数。
#
# 颜色也统一成一条规则，避免同是旗标却一处 GREEN 一处 CYAN：
#   命令名 / 程序名   → GREEN
#   旗标             → CYAN
#   <值> 占位符       → YELLOW

_VALUE_RE = re.compile(r'^(?P<name>.*?)\s*(?P<value><[^>]+>)$')


def _label(*segments):
    """segments 是 (文本, 颜色或 None)，返回 (纯文本, 上色文本)。"""
    plain = "".join(text for text, _ in segments)
    colored = "".join(f"{color}{text}{RESET}" if color else text for text, color in segments)
    return plain, colored


def _command(name, *rest):
    return [(name, GREEN)] + list(rest)


def _flag(name, value=None):
    segments = [(name, CYAN)]
    if value:
        segments.append((f" {value}", YELLOW))
    return segments


def _flag_spec(spec):
    # "(-C, --continue)" 这类写法直接用；"--proxy <string>" 把值和旗标分开上色。
    match = _VALUE_RE.match(spec)
    if match:
        return _flag(match.group("name"), match.group("value"))
    return _flag(spec)


def _print_section(title, rows, indent=2, gap=2):
    """rows 是 [(segments, 描述)]，描述列按本块最宽标签对齐。"""
    if not rows:
        return
    labels = [_label(*segments) for segments, _ in rows]
    width = max(len(plain) for plain, _ in labels)
    print()
    print(f"{PURPLE}{title}:{RESET}")
    for (plain, colored), (_, desc) in zip(labels, rows):
        print(" " * indent + colored + " " * (width - len(plain) + gap) + desc)


def _print_note(text, indent=2):
    print(" " * indent + text)


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

    _print_section("Commands", [
        (_command("install"), "Install a package (latest version)"),
        (_command("upgrade"), "Install a package at the latest version"),
        (_command("uninstall"), "Uninstall a package"),
        (_command("list"), "List installed packages"),
        (_command("search"), "Search for a package in the index"),
        (_command("info"), "Display detailed information about a package"),
        (_command("selfupdate"), "Update MacWave itself to the latest version"),
        (_command("link"), "Link installed packages without a version number"),
        (_command("unlink"), "Remove those unversioned links"),
        (_command("linkquery"), "Show which version an unversioned link points to"),
        (_command("mirror"), "Show which addresses packages are fetched from"),
        (_command("latest"), "Show which packages have a newer version available"),
    ])

    _print_section("Flags", [
        (_flag("-h, --help"), "Show help for any command"),
        (_flag("-V, --version"), "Print version information"),
        (_flag("-v, --verbose"), "Enable verbose output (show detailed logs)"),
    ])

    _print_section("Global Flags (can be used with any command)", [
        (_flag("-s, --silent"), "Only errors are printed; good for scripts (beats -v)"),
        (_flag("-C, --continue"), "Resume interrupted downloads (like curl -C -)"),
        (_flag("--proxy", "<string>"), "Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)"),
        (_flag("--skip-ssl"), "Skip SSL certificate verification (insecure)"),
        (_flag("--limit-rate", "<string>"), "Limit download speed (e.g., 200K, 1M, 5M)"),
        (_flag("--max-time", "<string>"), "Timeout for each request (e.g., 40s, 1min, 1min20s, 2h)"),
        (_flag("--ver", "<string>"), "Install a specific version (install only; --ver=1.0 works too)"),
        (_flag("--install-from-source"), "Download from the upstream URL instead of MacWave's own store"),
        (_flag("--install-python-from-source"), "Same, for the bundled Python (install / selfupdate)"),
        (_flag("MACWAVE_PIP_INDEX"), "Env var. pip index for the Python deps; default pypi.org/simple"),
    ])

    _print_section("Special Flags", [
        (_command("wave install", (" <pkgname>@<version>", YELLOW)),
         "Download certain version(s) of a package"),
        (_flag("--unlink"), "Leave the unversioned link alone (install / uninstall)"),
        # 只列规范写法；单数的 --remove-old-version 与 --rov 仍然接受，但不再宣传
        (_flag("-X, --remove-old-versions"), "Remove older versions after upgrading"),
        (_flag("--all, -a"), "Apply to every installed package (link / unlink / linkquery)"),
    ])

    _print_section("Unversioned Links", [
        (_command("wave link", (" <name>", YELLOW)),
         "Link a package to its highest installed version"),
        (_command("wave linkquery", (" <name>", YELLOW)),
         "Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)"),
        (_command("wave unlink", (" <name>", YELLOW)), "Remove that link"),
    ])
    _print_note("Links are created on install and re-pointed on uninstall; "
                "--unlink never leaves one broken.")

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
                "stay until -X removes them.",
        "flags": [
            ("-X, --remove-old-versions", "Also remove the versions older than the one just installed"),
            ("-C, --continue", "Resume an interrupted download (like curl -C -)"),
            ("--proxy <string>", "HTTP/HTTPS proxy (e.g. http://127.0.0.1:8080)"),
            ("--skip-ssl", "Skip SSL certificate verification (insecure)"),
            ("--limit-rate <string>", "Limit download speed (e.g. 200K, 1M, 5M)"),
            ("--max-time <string>", "Timeout for each request (40s, 1min, 1min20s, 2h; bare numbers are seconds)"),
            ("-v, --verbose", "Enable verbose output"),
        ],
        "examples": ["wave upgrade jq", "wave upgrade jq -X",
                     "wave upgrade jq --remove-old-versions --max-time=2min"],
    },
    "mirror": {
        "usage": "wave mirror [flags]",
        "desc": "Show the address each kind of data is fetched from, including the "
                "built-in defaults for anything not overridden by an environment variable.",
        "flags": [
            ("--json", "Print the configuration as JSON"),
            ("--yaml", "Print the configuration as YAML"),
            ("--toml", "Print the configuration as TOML"),
            ("--raw", "Print ready-to-paste export lines"),
            ("--only-set", "With --raw: export only the sources you overrode, leaving "
                           "the rest to follow the built-in defaults"),
            ("--show-password", "Print passwords in full instead of six asterisks"),
            ("--hide-user", "Also mask the user name"),
        ],
        "examples": ["wave mirror", "wave mirror --raw",
                     "wave mirror --json", "wave mirror --show-password"],
    },
    "latest": {
        "usage": "wave latest <package> | wave latest --all",
        "desc": "Compare what you have with the newest version in the index. Reports only; "
                "nothing is downloaded.",
        "flags": [
            ("-a, --all", "Check every installed package"),
            ("--max-time <string>", "Timeout for each request (e.g. 40s, 1min)"),
            ("-v, --verbose", "Print each request as it is made"),
        ],
        "examples": ["wave latest jq", "wave latest --all", "wave latest -a --max-time=1min"],
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
        "usage": "wave info <package> [--json|--yaml|--toml|--raw]",
        "desc": "Show author, description, homepage and the installed / available versions.",
        "flags": [
            ("--json", "Print the same fields as JSON"),
            ("--yaml", "Print the same fields as YAML"),
            ("--toml", "Print the same fields as TOML"),
            ("--raw", "Print the index record as stored, without the formatting"),
        ],
        "examples": ["wave info jq", "wave info jq --json", "wave info jq --raw"],
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

    _print_section("Flags", [(_flag_spec(name), text) for name, text in entry["flags"]])

    print()
    print(f"{PURPLE}Examples:{RESET}")
    for example in entry["examples"]:
        _print_note(example)

    print()
    print(f"All commands: {GREEN}wave --help{RESET}")


# -------------------- 版本与错误提示 --------------------

def print_version():
    """输出当前 MacWave 的版本号"""
    version = get_project_version()
    print(f"🌊 MacWave {version}")


def print_error_help(suggestion=None, unknown_flags=None):
    """未知命令或参数时：先报错，能猜到本该打什么就给出改法。

    suggestion 由 wave.py 传入（打错的词表与命令清单都只在那里一份，这里不重复维护）。
    unknown_flags 是「不属于任何命令」的旗标：命令名错了时它们轮不到校验，
    不单独报出来就会被一起吞掉，而下面那句建议会把它原样抄进去。

    猜到该敲什么时**不再输出整篇帮助**：那五六十行会把唯一有用的那一句
    （「你要敲的是 upgrade」）淹掉，而用户此刻需要的正是那一句。真正不知道该
    敲什么时才展开完整清单，并留一行告诉他以后怎么自查。
    """
    print(f"{BOLD}{RED}🌊 Error: Unknown command or argument.{RESET}")

    if unknown_flags:
        listed = ", ".join(unknown_flags)
        print(f"{BOLD}{RED}🌊 Error: Unknown flag{'s' if len(unknown_flags) > 1 else ''}: "
              f"{listed}{RESET}")

    if suggestion:
        fixed, wrong, right = suggestion
        print()
        print(f"{BOLD}🌊 Did you mean:{RESET} {GREEN}{fixed}{RESET}")
        print(f"   {YELLOW}{wrong}{RESET} is not a command. "
              f"The one you want is {GREEN}{right}{RESET}.")
        print()
        print(f"   For the full list: {GREEN}wave --help{RESET}")
        return

    if unknown_flags:
        print(f"   `wave --help` lists the global flags; "
              f"`wave <command> --help` lists the rest.")

    print()
    print_custom_help()


def main():
    """直接运行 python3 help.py 时，预览帮助信息"""
    print_custom_help()


if __name__ == "__main__":
    main()
