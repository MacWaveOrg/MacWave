#!/usr/bin/env python3

# flags.py
# MacWave 认得的全部旗标 —— **只用于诊断，不用于校验**。
#
# 校验仍然在各命令自己的白名单里（pkginstaller.ALLOWED_FLAGS 等），那份才是权威。
# 这里是给「命令名写错」那种场合用的：那时一条命令的白名单都还没被选中，
# 唯一能回答「--unkown-flag 到底是不是 MacWave 的旗标」的就是全体并集。
#
#   用户：wave update jq --unkown-flag
#   期望：既说 update 不是命令，也说 --unkown-flag 不是旗标
#
# 为什么不把各模块的白名单 import 进来做并集：那会把 link/uninstall 之类的运行期
# 依赖拖进 wave.py 的启动路径（它们要 load_base_dir()），一个打错的命令不该为此
# 付出代价。代价是这份清单可能与真白名单走散，所以
# scripts/flags_test.sh 会逐项比对，少一项就红。

# 任何命令都接受（与 lib/help.py 的 Global Flags 一节对应）
GLOBAL = {
    "-v", "--verbose",
    "-C", "--continue",
    "--skip-ssl",
    "--limit-rate",
    "--proxy",
    "--max-time",
    "--ver",
    "--install-from-source",
    "--install-python-from-source",
    "-s", "--silent",
    "-S", "--show-error",
    # 注意没有 --help / --version：那两条在分发之前就被拦下，
    # 不算「某条命令接受的旗标」，但仍然是合法输入，所以在 ALL 里单独补。
}

# 单条命令独有的
install = set()
uninstall = {"--unlink"}
upgrade = {"-X", "--remove-old-version", "--remove-old-versions", "--rov",
           "-a", "--all"}
link = {"-a", "--all"}
unlink = {"-a", "--all"}
linkquery = {"-a", "--all"}
# 只有 -a/--all 是 latest 独有的；--json/--yaml/--toml/--raw 属于 info。
# 这两组混在一起时，`wave install jq --json` 会被提示成「--json 也适用于 latest」，
# 而 latest 其实会直接拒绝 --json。
latest = {"--all", "-a"}
info = {"--json", "--yaml", "--toml", "--raw"}
mirror = {"--show-password", "--hide-user", "--only-set", "--raw"}

COMMAND_FLAGS = {
    "install": install,
    "uninstall": uninstall,
    "upgrade": upgrade,
    "link": link,
    "unlink": unlink,
    "linkquery": linkquery,
    "latest": latest,
    "info": info,
    "mirror": mirror,
}

# 分发之前就处理掉的
EARLY = {"-h", "--help", "-V", "--version"}

ALL = GLOBAL | EARLY | set().union(*COMMAND_FLAGS.values())


def split(token):
    """把一个 argv 片段拆成旗标名列表，规则与 pkginstaller.parse_flags 一致。

        --name=value  → ["--name"]
        -abc          → ["-a", "-b", "-c"]
        其它          → []
    """
    if token.startswith("--"):
        return [token.split("=", 1)[0]]
    if token.startswith("-") and len(token) > 1:
        return [f"-{ch}" for ch in token[1:]]
    return []


def owner_commands(flag):
    """这个旗标属于哪些命令。空列表 = 谁都不认。"""
    return sorted(cmd for cmd, table in COMMAND_FLAGS.items() if flag in table)


def describe(flag):
    """给「用错命令」的旗标一句准确的说明。

    `-X` 不是拼错，而是升级专属。一律说成「unknown flag」会把人送去查拼写，
    真正的原因（用错了命令）反而看不到。
    """
    owners = owner_commands(flag)
    if not owners:
        return None
    if len(owners) == 1:
        return f"{flag} only applies to wave {owners[0]}"
    listed = ", ".join(f"wave {cmd}" for cmd in owners)
    return f"{flag} only applies to {listed}"


def unknown_flags(words):
    """words 里不属于任何命令的旗标，按出现顺序去重返回。"""
    seen = []
    for word in words:
        for flag in split(word):
            if flag not in ALL and flag not in seen:
                seen.append(flag)
    return seen
