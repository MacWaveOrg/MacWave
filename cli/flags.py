#!/usr/bin/env python3

# flags.py
# argv 的拆解规则，以及 MacWave 认得的全部旗标。
#
# 两件事，性质不同，别混：
#
#   1. **拆解**（本文件下半部分）：`--name=value` 怎么归一化、`-abc` 怎么拆开、
#      短旗标簇里怎么拿掉某个字母、单独的 `-` 是不是终止符。这些是**纯函数**，
#      不打印、不退出、不读配置 —— 谁都可以调，规则只有一份。
#      在它之前，同一套规则至少写过四遍：pkginstaller.parse_flags 词法循环、
#      cli/silent.strip、upgrader.split_input、latest.split_arguments，
#      以及 pkginfohelper 里那句 `word.partition("=")[0]`。四份实现的差异只有
#      「谁的词法更全」，于是 `-sX` 在一处能拆、另一处要另写一遍才认。
#
#   2. **清单**（本文件上半部分）：MacWave 认得的旗标全集 ——
#      **只用于诊断，不用于校验**。校验仍然在各命令自己的白名单里
#      （pkginstaller.ALLOWED_FLAGS 等），那份才是权威。这里是给「命令名写错」
#      那种场合用的：那时一条命令的白名单都还没被选中，唯一能回答
#      「--unkown-flag 到底是不是 MacWave 的旗标」的就是全体并集。
#
#   用户：wave update jq --unkown-flag
#   期望：既说 update 不是命令，也说 --unkown-flag 不是旗标
#
# 为什么不把各模块的白名单 import 进来做并集：那会把 link/uninstall 之类的运行期
# 依赖拖进 wave.py 的启动路径（它们要 load_base_dir()），一个打错的命令不该为此
# 付出代价。代价是这份清单可能与真白名单走散，所以
# scripts/flags_test.sh 会逐项比对，少一项就红。

# 任何命令都接受（与 cli/help.py 的 Global Flags 一节对应）
GLOBAL = {
    "-v", "--verbose",
    "-C", "--continue",
    "--skip-ssl",
    "--limit-rate",
    "--proxy",
    "--max-time",
    "--connect-timeout",
    "--content-time",
    "--ver",
    "--install-python-from-source",
    # 注意没有 --help / --version：那两条在分发之前就被拦下，
    # 不算「某条命令接受的旗标」，但仍然是合法输入，所以在 ALL 里单独补。
    # 也没有 -s / -S：它们不是「任何命令都接受」，见下面的 silent 一组。
}

# 能静默的命令。**必须按命令列，不能放进 GLOBAL** —— GLOBAL 的意思是「谁都用」，
# 而 `wave list -s` 是要被拒绝的（list 存在的目的就是打印，给它 -s 等于把命令废掉）。
# 列在这里的唯一用处是让 describe("-s") 答得出「只适用于哪几条命令」，
# wave.py 在分发前就用这句话报错。名单以 cli/silent.py 的 SILENT_COMMANDS 为准，
# scripts/flags_test.sh 逐项比对，走散就红。
silent = {"-s", "--silent", "-S", "--show-error"}

# 单条命令独有的
# -F/--force：索引声明的最低系统版本高于本机时，跳过询问直接装。upgrade 复用
# install 那份白名单，所以两组都要列，describe() 才能把用错命令指到正确的地方。
install = {"-F", "--force"} | silent
uninstall = {"--unlink"} | silent
upgrade = {"-X", "--remove-old-version", "--remove-old-versions", "--rov",
           "-a", "--all", "-F", "--force"} | silent
link = {"-a", "--all"} | silent
unlink = {"-a", "--all"} | silent
linkquery = {"-a", "--all"}
# selfupdate 没有专属旗标（时长走 GLOBAL 的 --max-time），但它是能静默的六条之一，
# 缺了这一项 describe("-s") 会把 selfupdate 漏掉。
selfupdate = set(silent)
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
    "selfupdate": selfupdate,
    "latest": latest,
    "info": info,
    "mirror": mirror,
}

# 分发之前就处理掉的
# --zh 也在这里：它只改帮助文本用哪种语言（`wave -h --zh`），不参与命令分发，
# 更不该出现在任何命令的旗标白名单里。
EARLY = {"-h", "--help", "-V", "--version", "--zh"}

ALL = GLOBAL | EARLY | set().union(*COMMAND_FLAGS.values())


def flag_name(word):
    """旗标的名字：`--max-time=1min` → `--max-time`，其余原样返回。

    长旗标的值可以紧跟在 `=` 后面（也常常是空格写法，由调用方自己看下一个词），
    短旗标没有 `=` 写法。包名不以 `-` 开头，拿去问也只会原样回来。
    """
    return word.split("=", 1)[0]


def split(token):
    """把一个 argv 片段拆成旗标名列表。

        --name=value  → ["--name"]
        -abc          → ["-a", "-b", "-c"]
        其它          → []
    """
    if token.startswith("--"):
        return [flag_name(token)]
    if token.startswith("-") and len(token) > 1:
        return [f"-{ch}" for ch in token[1:]]
    return []


def tokens(words):
    """把一段 argv 拆成旗标名列表；遇到单独的 `-` 就停。

    与 split() 的分工：split() 只看一个词，这里看整段。规则与
    pkginstaller.parse_flags 逐条对应 —— 单独一个 `-` 表示「后面的都不是旗标」
    （`wave install jq - --proxy x` 里那个 `--proxy` 是包名的一部分）。
    """
    found = []
    for word in words:
        if word == "-":
            break
        found.extend(split(word))
    return found


def short_cluster(word):
    """短旗标簇的字母部分：`-sX` → `"sX"`；`--skip-ssl` 与 `jq` 都返回 None。

    「单横线开头、长度大于 1」是唯一的判据。`--skip-ssl` 里也有 s 与 S，
    但它不是簇 —— 长旗标整体匹配，绝不按字母拆。
    """
    if word.startswith("-") and not word.startswith("--") and len(word) > 1:
        return word[1:]
    return None


def remove_short(word, letters):
    """从短旗标簇里拿掉若干字母，返回剩下的写法。

    三种结果，调用方要分清：

        None   没动过（不是簇，或簇里一个都没提到）—— 原样保留
        ""     簇被拿空了（`-s` 拿掉 s）—— 整个词消失
        "-Xv"  还剩别的字母 —— 用这个替换原词

    为什么要单独一个函数：`-sX`、`-Xv`、`-CsX` 这类合并写法的处理散在
    silent.py 与 upgrader.py 两处，各自的循环都只认得自己那几个字母，
    于是「`-sX` 里 X 属于谁」两边要各判一遍。
    """
    cluster = short_cluster(word)
    if cluster is None:
        return None
    kept = cluster
    for letter in letters:
        kept = kept.replace(letter, "")
    if kept == cluster:
        return None
    return "" if not kept else "-" + kept


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
