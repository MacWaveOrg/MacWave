#!/usr/bin/env python3

# commands.py

# 子命令的元数据 —— **唯一来源**。
#
# 一张表同时喂四个地方：
#
#   1. lib/wave.py          命令分发（名字 → 模块 / 处理函数 / 要不要传命令行）
#   2. `wave -h`            Commands 一节的每一行（名字 + 一句话）
#   3. `wave <cmd> --help`  用法 / 说明 / 旗标 / 示例
#   4. man/ 与 info/        由 scripts/build_docs.py 从 2、3 生成
#
# 为什么合成一处：这几份以前各写一遍，删掉一条命令要记得改两个字典 + 一条
# if/elif 分支，漏一处的症状又各不相同 —— 帮助里挂着一条敲下去是 unknown
# command 的僵尸命令（`wave -h` 从 1.x 一直残留到 2.3.1 才被发现），或者命令
# 能分发但没有任何帮助。现在删除即删除：一张表里没有，四个地方都没有。
#
# 加一条命令要动的只有这里 + 处理函数本身。scripts/commands_test.sh 盯三件事：
# 表里的模块与函数真的存在、帮助里列出的旗标是处理函数真接受的、README 里有它。
#
# 字段：
#   name          命令名（argv 里的第一词，也是 `wave <name> --help` 的键）
#   module        处理函数所在的模块（组件目录之一里的模块名）
#   handler       处理函数名；标准签名是 handler(input_string)
#   takes_input   False 表示无参调用 handler()（shellenv / version）
#   listed        False 表示它不出现在 `wave -h` 的 Commands 一节（version 走 -V）
#   summary       一句话，`wave -h` 里那一行
#   usage/desc/flags/examples    `wave <cmd> --help` 与手册的正文
#
# 这个文件**不 import 任何东西**：`wave -h` 会在没有安装树、依赖也没装全的
# 环境里被调用，能早退就早退。校验放在测试里，不放在启动路径上。


class Command:
    """一条子命令。字段含义见文件头。"""

    __slots__ = ("name", "module", "handler", "takes_input", "listed",
                 "summary", "usage", "desc", "flags", "examples")

    def __init__(self, name, module, handler, takes_input, listed,
                 summary, usage, desc, flags, examples):
        self.name = name
        self.module = module
        self.handler = handler
        self.takes_input = takes_input
        self.listed = listed
        self.summary = summary
        self.usage = usage
        self.desc = desc
        self.flags = flags
        self.examples = examples

    def __repr__(self):
        return f"Command({self.name!r} -> {self.module}.{self.handler})"


# 顺序即 `wave -h` 里的顺序。
COMMANDS = (
    Command(
        name="install",
        module="pkginstaller",
        handler="handle_install",
        takes_input=True,
        listed=True,
        summary="Install a package (latest version)",
        usage="wave install <package>[@<version>] [flags]",
        desc="Install a package, or one specific version of it.",
        flags=[
            ("-C, --continue", "Resume an interrupted download"),
            ("--proxy <string>", "HTTP/HTTPS proxy (e.g. http://127.0.0.1:8080)"),
            ("--skip-ssl", "Skip SSL certificate verification (insecure)"),
            ("--limit-rate <string>", "Limit download speed (e.g. 200K, 1M, 5M; a bare number means bytes)"),
            ("--max-time <string>", "Maximum total time for one request (40s, 1min, 1min20s, 2h; a bare number means seconds)"),
            ("--connect-timeout <string>", "Maximum time for the handshake"),
            ("--content-time <string>", "Maximum time to receive data"),
            ("--no-link", "Do not touch the unversioned link (the old name --unlink "
                          "still works)"),
            ("-F, --force", "Install anyway when the running macOS is older than the package declares"),
            ("-v, --verbose", "Verbose mode"),
        ],
        examples=[
            "wave install jq",
            "wave install ffmpeg@6.1",
            "wave install jq --limit-rate 1M",
            "wave install jq --max-time=1min",
        ],
    ),
    Command(
        name="upgrade",
        module="upgrader",
        handler="handle_upgrade",
        takes_input=True,
        listed=True,
        summary="Install a package at the latest version",
        usage="wave upgrade <package> | wave upgrade --all",
        desc="Upgrade a package to its latest version; with --all, every installed package. Old versions are kept — -X, --remove-old-versions removes them in the same run.",
        flags=[
            ("-a, --all", "Upgrade every installed package that has a newer version"),
            ("-X, --remove-old-versions", "Remove the older versions as part of the upgrade"),
            ("-C, --continue", "Resume an interrupted download"),
            ("--proxy <string>", "HTTP/HTTPS proxy (e.g. http://127.0.0.1:8080)"),
            ("--skip-ssl", "Skip SSL certificate verification (insecure)"),
            ("--limit-rate <string>", "Limit download speed (e.g. 200K, 1M, 5M; a bare number means bytes)"),
            ("--max-time <string>", "Maximum total time for one request (40s, 1min, 1min20s, 2h; a bare number means seconds)"),
            ("--connect-timeout <string>", "Maximum time for the handshake"),
            ("--content-time <string>", "Maximum time to receive data"),
            ("-F, --force", "Install anyway when the running macOS is older than the package declares"),
            ("-v, --verbose", "Verbose mode"),
        ],
        examples=[
            "wave upgrade jq",
            "wave upgrade jq -X",
            "wave upgrade --all",
            "wave upgrade jq --remove-old-versions --max-time=2min",
        ],
    ),
    Command(
        name="uninstall",
        module="uninstaller",
        handler="handle_uninstall",
        takes_input=True,
        listed=True,
        summary="Uninstall a package",
        usage="wave uninstall <package>[@<version>] [flags]",
        desc="Uninstall a package version. The unversioned link falls back to the highest remaining version, and goes away with the last one.",
        flags=[
            ("--no-link", "Do not touch the unversioned link (the old name --unlink "
                          "still works)"),
        ],
        examples=[
            "wave uninstall jq",
            "wave uninstall ffmpeg@6.1",
        ],
    ),
    Command(
        name="list",
        module="pkginfohelper",
        handler="handle_info_command",
        takes_input=True,
        listed=True,
        summary="List installed packages",
        usage="wave list",
        desc="List the packages you have installed, with their versions.",
        flags=[
        ],
        examples=[
            "wave list",
        ],
    ),
    Command(
        name="search",
        module="pkginfohelper",
        handler="handle_info_command",
        takes_input=True,
        listed=True,
        summary="Search for a package in the index",
        usage="wave search <keyword>",
        desc="Search the online package index.",
        flags=[
        ],
        examples=[
            "wave search json",
        ],
    ),
    Command(
        name="info",
        module="pkginfohelper",
        handler="handle_info_command",
        takes_input=True,
        listed=True,
        summary="Display detailed information about a package",
        usage="wave info <package> [--json|--yaml|--toml|--raw]",
        desc="Show author, description, homepage and the installed / available versions.",
        flags=[
            ("--json", "Print as JSON"),
            ("--yaml", "Print as YAML"),
            ("--toml", "Print as TOML"),
            ("--raw", "Print as stored"),
        ],
        examples=[
            "wave info jq",
            "wave info jq --json",
            "wave info jq --raw",
        ],
    ),
    Command(
        name="selfupdate",
        module="selfupdate",
        handler="handle_selfupdate",
        takes_input=True,
        listed=True,
        summary="Update MacWave itself to the latest version",
        usage="wave selfupdate [flags]",
        desc="Update MacWave itself to the version published in the self-update repository.",
        flags=[
            ("--max-time <string>", "Maximum total time for one request (40s, 1min, 1min20s, 2h; a bare number means seconds)"),
            ("--connect-timeout <string>", "Maximum time for the handshake"),
            ("--content-time <string>", "Maximum time to receive data"),
            ("--install-python-from-source", "Fetch the bundled Python from its upstream URL instead of MacWave's own repository"),
            ("--dry-run", "Print what would be updated and change nothing (no download, no agreement prompt)"),
        ],
        examples=[
            "wave selfupdate",
            "wave selfupdate --max-time=2min",
            "wave selfupdate --dry-run",
        ],
    ),
    Command(
        name="link",
        module="linker",
        handler="handle_link_command",
        takes_input=True,
        listed=True,
        summary="Link installed packages without a version number",
        usage="wave link <package>[@<version>] | wave link --all",
        desc="Create a versionless shortcut, or re-point it at another installed version. Installs and uninstalls keep it up to date afterwards.",
        flags=[
            ("--all, -a", "Apply to every installed package"),
        ],
        examples=[
            "wave link jq",
            "wave link ffmpeg@6.1",
            "wave link --all",
        ],
    ),
    Command(
        name="unlink",
        module="linker",
        handler="handle_unlink_command",
        takes_input=True,
        listed=True,
        summary="Remove those unversioned links",
        usage="wave unlink <package> | wave unlink --all",
        desc="Remove the versionless shortcut. A later uninstall will not re-create it.",
        flags=[
            ("--all, -a", "Apply to every installed package"),
        ],
        examples=[
            "wave unlink jq",
            "wave unlink --all",
        ],
    ),
    Command(
        name="linkquery",
        module="linker",
        handler="handle_linkquery_command",
        takes_input=True,
        listed=True,
        summary="Show which version an unversioned link points to",
        usage="wave linkquery <package> | wave linkquery --all",
        desc="Show which version the versionless shortcut points at.",
        flags=[
            ("--all, -a", "Apply to every installed package"),
        ],
        examples=[
            "wave linkquery jq",
        ],
    ),
    Command(
        name="mirror",
        module="mirrorinfo",
        handler="handle_mirror",
        takes_input=True,
        listed=True,
        summary="Show which addresses packages are fetched from",
        usage="wave mirror [flags]",
        desc="Show the address each kind of data is fetched from, including the built-in defaults for anything not overridden by an environment variable.",
        flags=[
            ("--json", "Print the configuration as JSON"),
            ("--yaml", "Print the configuration as YAML"),
            ("--toml", "Print the configuration as TOML"),
            ("--raw", "Print export lines"),
            ("--only-set", "With --raw: export only the sources you overrode (the MACWAVE_*_DOMAIN variables), leaving the rest to the built-in defaults"),
            ("--show-password", "Print the real password"),
            ("--hide-user", "Hide the user name"),
        ],
        examples=[
            "wave mirror",
            "wave mirror --raw",
            "wave mirror --json",
            "wave mirror --show-password",
        ],
    ),
    Command(
        name="latest",
        module="latest",
        handler="handle_latest",
        takes_input=True,
        listed=True,
        summary="Show which packages have a newer version available",
        usage="wave latest <package> | wave latest --all",
        desc="Compare what you have with the newest version in the index; nothing is downloaded.",
        flags=[
            ("-a, --all", "Check every installed package"),
            ("--max-time <string>", "Maximum total time for one request (40s, 1min)"),
            ("--connect-timeout <string>", "Maximum time for the handshake"),
            ("--content-time <string>", "Maximum time to receive data"),
            ("-v, --verbose", "Print each request as it is made"),
        ],
        examples=[
            "wave latest jq",
            "wave latest --all",
            "wave latest -a --max-time=1min",
        ],
    ),
    Command(
        name="shellenv",
        module="shellenv",
        handler="handle_shellenv",
        takes_input=False,
        listed=True,
        summary="Print the shell code that puts MacWave on your PATH",
        usage="wave shellenv",
        desc="Print the shell code that prepends MacWave's directories to PATH. You eval it once from your shell profile; it does nothing on its own.",
        flags=[
        ],
        examples=[
            "eval \"$(~/.local/macwave/lib/wave shellenv)\"",
            "echo 'eval \"$(~/.local/macwave/lib/wave shellenv)\"' >> ~/.zprofile",
        ],
    ),
    Command(
        name="manual",
        module="manual",
        handler="handle_manual",
        takes_input=True,
        listed=True,
        summary="Show the full manual (same text as man and info)",
        usage="wave manual [<command>] [--zh] [--color]",
        desc="Show the full manual — the same text that ships as man pages and info files — or just one command's section.",
        flags=[
            ("--zh", "Print the Chinese edition"),
            ("--color", "Colour headings and flags (plain text by default)"),
        ],
        examples=[
            "wave manual",
            "wave manual install",
            "wave manual --zh",
            "wave manual install --color",
        ],
    ),
    Command(
        name="version",
        module="help",
        handler="print_version",
        takes_input=False,
        listed=False,
        summary="Print the installed MacWave version",
        usage="wave version",
        desc="Print the installed MacWave version.",
        flags=[
        ],
        examples=[
            "wave version",
        ],
    ),
)


_BY_NAME = {command.name: command for command in COMMANDS}


def get(name):
    """按名字取一条；没有返回 None（未知命令要给出建议，不能当异常）。"""
    return _BY_NAME.get(name)


def all():
    """全部命令，按 `wave -h` 的顺序。"""
    return COMMANDS


def listed():
    """出现在 `wave -h` Commands 一节里的命令（version 不在其中）。"""
    return tuple(command for command in COMMANDS if command.listed)


def dispatch_table():
    """名字 → 模块名。`suggest.command()` 用它判断「这个错名字像哪条命令」。"""
    return {command.name: command.module for command in COMMANDS}


def module_names():
    """全部处理函数所在模块（去重，按首次出现的顺序）。"""
    seen = []
    for command in COMMANDS:
        if command.module not in seen:
            seen.append(command.module)
    return seen
