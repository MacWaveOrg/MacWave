#!/usr/bin/env python3

# upgrader.py
#
# `wave upgrade <package>`：把已装或未装的包带到索引里的最新版本。
#
# 因为支持多版本共存，install 一个新版本不会动旧的，所以「升级」需要额外的收尾动作 ——
# 这就是 `--remove-old-version` 及其别名存在的原因：
#   - 只有一个旧版本：直接移除；
#   - 多个旧版本：先问「全部移除？」，答 N 就像 uninstall 那样列出来让用户挑。
#
# 顺序刻意是「先装新版本，再清理旧版本」：安装失败时旧版本还在，用户仍有一个能用的。

import sys

from configpaths import require_safe_token
import quiet


RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# upgrade 只做「装到最新」，这两个旗标与它的语义冲突，直接拒绝而不是静默忽略：
# --ver 会让「升级」变成「装某个指定版本」；--unlink 会让链接留在旧版本上，
# 而随后清理旧版本正好会把那个链接指坏。两条都请用户改用对应的命令。
# 「同时移除旧版本」的四种写法完全等价。长参数之所以给了三个，是因为
# -version 与 -versions 单复数都记不牢，索性都认；--rov 是它们的缩写。
# 短参数 -X 是刻意选的：R 要留给 recurse / reverse / rollback，X 没有别的含义，
# 而且形状像「删除」的叉。
REMOVE_OLD_LONG = ("--remove-old-version", "--remove-old-versions", "--rov")
REMOVE_OLD_SHORT = "X"

# 「所有已装包」的写法。与 link / unlink / linkquery / latest 的 -a 同名同义，
# 用户不必记两套。
ALL_LONG = ("--all",)
ALL_SHORT = "a"

# 需要记下来、但不属于「删除旧版本」的写法，留着给将来扩展
REJECTED_FLAGS = {
    "--ver": "Use 'wave install <package>@<version>' to install a specific version",
    "--unlink": "Run 'wave link <package>@<version>' afterwards to choose the linked version",
}


def split_input(input_string):
    """把 upgrade 专属旗标剥掉，返回 (剩余词, 是否要求移除旧版本, 是否所有包)。

    -X 与 -a 既认单独出现的写法，也认混在短旗标簇里的写法（-Xv 等于 -X -v），
    与 pkginstaller.parse_flags 把 -abc 拆成 -a -b -c 的规则保持一致。
    """
    remove_old = False
    upgrade_all = False
    kept = []
    for word in input_string.split()[2:]:
        if word in REMOVE_OLD_LONG:
            remove_old = True
            continue
        if word in ALL_LONG:
            upgrade_all = True
            continue
        # 单个 - 开头（且不是 --）：可能是 -X，也可能是 -Xv 这种簇
        if word.startswith("-") and not word.startswith("--") and len(word) > 1:
            letters = word[1:]
            for short, mark in ((REMOVE_OLD_SHORT, "old"), (ALL_SHORT, "all")):
                if short in letters:
                    letters = letters.replace(short, "")
                    if mark == "old":
                        remove_old = True
                    else:
                        upgrade_all = True
            if letters != word[1:]:
                if not letters:
                    continue
                word = "-" + letters
        kept.append(word)
    return kept, remove_old, upgrade_all


def ask_yes_no(prompt):
    """问一次 Y/n。返回 True / False；读到 EOF（非交互）时返回 None。"""
    # 静默模式不读 stdin：提示语已被压掉，再 input() 就是卡死。
    # 返回 None 让调用方走「非交互」分支 —— 那条分支本来就保留旧版本。
    if quiet.is_silent():
        return None
    while True:
        try:
            answer = input(prompt).strip().lower()
        except (EOFError, KeyboardInterrupt):
            return None
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        print(f"{YELLOW}🌊 Please answer Y (remove all) or N (choose which ones).{RESET}")


def remove_old_versions(bin_name, keep_version, assume_yes=False):
    """移除 keep_version 之外的所有已装版本，保留 keep_version。

    assume_yes：批量升级时用。`wave upgrade --all -X` 已经把「删旧版本」这件事
    对每个包都说了，再逐个包弹一次问题既啰嗦又容易答错对象；所以批量模式下
    直接按用户写下的意图执行。
    """
    from pkgversionparser import safe_parse_pkg_version as version_key
    from uninstaller import find_installed_versions, select_versions, uninstall_versions

    old = [version for version in find_installed_versions(bin_name)
           if version_key(version) < version_key(keep_version)]
    if not old:
        quiet.say(f"🌊 No old versions of {bin_name} to remove.")
        return

    # 批量模式：-X 是对每个包说的，不必再逐个确认
    if assume_yes:
        quiet.say(f"🌊 Removing {len(old)} old version(s) of {bin_name}...")
        uninstall_versions(bin_name, old)
        return

    # 只有一个旧版本：不必再问选哪个，「移除旧版本」已经表达得很清楚
    if len(old) == 1:
        quiet.say(f"🌊 Removing the old version {bin_name}@{old[0]}...")
        uninstall_versions(bin_name, old)
        return

    # 走到这里说明旧版本不止一个，正常要问「全删还是挑几个」。
    #
    # 静默模式下不给 -X 就不会走到这个函数（调用点有 remove_old 判断），
    # 所以「静默且到了这里」等价于用户显式写了 -X。既然意图已经明确，
    # 就直接全删 —— 不该因为「问不了」而什么都不做，那是把用户的显式要求丢掉。
    if quiet.is_silent():
        quiet.say(f"🌊 Removing {len(old)} old versions of {bin_name}...")
        uninstall_versions(bin_name, old)
        return

    quiet.say(f"🌊 {len(old)} old versions of {bin_name} are installed: {', '.join(old)}")
    answer = ask_yes_no("🌊 Remove all of them? [Y/n] ")
    if answer is None:
        # 非交互（CI、管道）：没有人能替用户回答，保留旧版本比误删安全
        print(f"{YELLOW}🌊 Cannot ask without a terminal; no old version was removed.{RESET}")
        return

    if answer:
        uninstall_versions(bin_name, old)
        return

    quiet.say("🌊 Choose which old versions to remove, one or more.")
    try:
        selected = select_versions(bin_name, old)
    except SystemExit:
        # 选择过程本身被取消（Ctrl+C 或读不到输入）不该让已经完成的升级失败
        print(f"{YELLOW}🌊 No old version was removed.{RESET}")
        return
    uninstall_versions(bin_name, selected)


def upgrade_everything(words, remove_old):
    """把每个已装包都带到最新版本。

    批量不是「一把梭」：某个包在索引里没了、下载失败、校验不过，都不该让排在
    后面的包白等 —— 逐个跑、逐个收结果，最后一次性报总账。单个包的成败本来就
    由 handle_upgrade 打在终端上，这里只补汇总与退出码。
    """
    from latest import fetch_names, installed_bin_names, resolve_package_name
    from pkginstaller import confirm_skip_ssl, detect_arch
    from timeouts import from_command_line
    from uninstaller import find_installed_versions

    # 下面这一次取名字清单也走 HTTPS，所以 `--skip-ssl` 必须先有结论 ——
    # 否则用户答应了跳过校验，第一个请求照样失败。批量模式只问一次。
    confirm_skip_ssl(words)

    targets = installed_bin_names()
    if not targets:
        # 什么也没装不是错误（退出码 0），静默时连这句都不该出现
        quiet.say("🌊 No packages installed yet.")
        return

    # bin/ 里是 bin_name，索引里是包名，两者不一定相同（choma -> ChOma）。
    # 复用 latest 的对照逻辑，这样 `wave latest -a` 报的集合与这里逐个升级的集合一致。
    # 三档超时也要作用在这一步：它同样是请求。规则只有 lib/timeouts.py 一份，
    # 所以从剥掉 upgrade 专属旗标之后剩下的词里解析。
    index_names = fetch_names(detect_arch(), from_command_line(" ".join(words)))
    packages = [resolve_package_name(bin_name, index_names) for bin_name in targets]

    # 其余旗标原样带下去（--proxy / --max-time / -v…）。-X 被 split_input 剥掉了，
    # 这里补回去：批量模式下它是对每一个包都生效，而不是只对某一个。
    tail = " ".join(words)
    if remove_old:
        tail = (tail + " -X").strip()

    upgraded, unchanged, failed = [], [], []
    for bin_name, package_name in zip(targets, packages):
        before = set(find_installed_versions(bin_name))
        try:
            handle_upgrade(f"wave upgrade {package_name} {tail}".strip(), assume_yes=True)
        except SystemExit as status:
            # 单个包失败（索引里没有、下载/校验失败）只记账，继续下一个
            if status.code not in (0, None):
                failed.append(package_name)
                continue
        after = set(find_installed_versions(bin_name))
        (upgraded if after - before else unchanged).append(package_name)

    if len(targets) > 1:
        quiet.say(f"🌊 {len(upgraded)} upgraded, {len(unchanged)} already at the latest, "
                  f"{len(failed)} failed.")
    if failed:
        print(f"{RED_BOLD}🌊 Error: could not upgrade {', '.join(failed)}.{RESET}")
        print(f"{YELLOW}🌊 The other packages were handled; fix the cause and run it again.{RESET}")
        sys.exit(1)


def handle_upgrade(input_string, assume_yes=False):
    from depsinstaller import get_field
    from pkginstaller import (
        detect_arch,
        fetch_common_fields,
        fetch_max_version,
        handle_install,
        package_index,
        parse_flags,
        parse_timeout,
    )
    from pkgversionparser import safe_parse_pkg_version as version_key
    from uninstaller import find_installed_versions

    words, remove_old, upgrade_all = split_input(input_string)

    if upgrade_all:
        if package_index(words) is not None:
            print(f"{RED_BOLD}🌊 Error: --all upgrades every installed package; "
                  f"drop the package name.{RESET}")
            print(f"{YELLOW}🌊 Either 'wave upgrade <package>' or 'wave upgrade --all'.{RESET}")
            sys.exit(1)
        upgrade_everything(words, remove_old)
        return

    index = package_index(words)
    if index is None:
        print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
        print(f"{YELLOW}🌊 Use 'wave upgrade <package>', "
              f"or 'wave upgrade --all' for every installed package.{RESET}")
        sys.exit(1)

    raw_package = words[index]
    if "@" in raw_package:
        print(f"{RED_BOLD}🌊 Error: upgrade always targets the latest version.{RESET}")
        print(f"{YELLOW}🌊 Use 'wave install {raw_package}' to install that exact version.{RESET}")
        sys.exit(1)

    package_name = require_safe_token(raw_package, "package name")

    # 其余旗标交给 install 的白名单校验：upgrade 自己的旗标已经在上面剥掉了，
    # 所以这里能接受的恰好就是 install 能接受的减去被拒绝的那两个。
    # probe 只用于解析（复用 install 的白名单），不该出现在报错文案里：
    # 用户敲的是 `wave upgrade jq --bad`，回显的必须就是这一条。
    probe = "wave install placeholder " + " ".join(words[:index] + words[index + 1:])
    flags = parse_flags(probe, command="upgrade", shown=input_string)
    for flag, hint in REJECTED_FLAGS.items():
        if flag in flags:
            print(f"{RED_BOLD}🌊 Error: {flag} is not accepted by upgrade.{RESET}")
            print(f"{YELLOW}🌊 {hint}.{RESET}")
            sys.exit(1)

    budget = parse_timeout(probe, flags)
    budget.start()

    arch = detect_arch()
    quiet.say(f"🌊 Checking the latest version of {package_name}...")
    latest = fetch_max_version(package_name, arch, budget)

    # 包名与 bin_name 不一定相同（choma -> ChOma），而 bin/ 与 links/ 用的是 bin_name
    common_fields = fetch_common_fields(package_name, arch, budget)
    bin_name = get_field(common_fields, "bin_name")
    if not bin_name:
        print(f'{RED_BOLD}🌊 Missing "bin_name" field, Please contact the administrator.{RESET}')
        sys.exit(1)
    bin_name = require_safe_token(bin_name, "bin_name")

    installed = find_installed_versions(bin_name)
    newer = [version for version in installed if version_key(version) > version_key(latest)]

    did_install = False
    if newer:
        # 索引落后于本机（例如某个版本后来被撤下）：降级不是升级，宁可不动
        keep = installed[0]
        print(f"{YELLOW}🌊 Warning: {bin_name}@{installed[0]} is newer than {latest}, "
              f"the latest version in the index.{RESET}")
        print(f"{YELLOW}🌊 Leaving it in place; nothing was downloaded.{RESET}")
    elif latest in installed:
        keep = latest
        quiet.say(f"{GREEN}🌊 {bin_name} is already at the latest version ({latest}).{RESET}")
    else:
        keep = latest
        if installed:
            quiet.say(f"🌊 Upgrading {bin_name}: {installed[0]} -> {latest}")
        else:
            quiet.say(f"🌊 {bin_name} is not installed; installing {latest}.")
        # 整个安装流水线（含依赖、路径重写、建链接）都复用 install，
        # 只把包名换成「包名@最新版本」，其余旗标原样带下去
        install_words = list(words)
        install_words[index] = f"{package_name}@{latest}"
        handle_install(" ".join(["wave", "install"] + install_words))
        did_install = True

    if did_install:
        # install 自己会建链接，这里只确认真的装上了，避免后面清理旧版本时误判
        if latest not in find_installed_versions(bin_name):
            print(f"{RED_BOLD}🌊 Error: the upgrade did not complete ({bin_name}@{latest} is missing).{RESET}")
            sys.exit(1)
    else:
        # 没下载任何东西时也要把不带版本号的链接指到 keep ——
        # 否则「已经是最新」却仍让 `wave` 命令跑着旧版本。
        try:
            from linker import link_package
            linked = link_package(bin_name, keep)
            if linked:
                quiet.say(f"🌊 Linked {bin_name} -> {bin_name}@{linked}")
        except Exception as error:
            print(f"{YELLOW}🌊 Warning: could not re-point the unversioned link ({error}).{RESET}")

    if remove_old:
        remove_old_versions(bin_name, keep, assume_yes=assume_yes)


if __name__ == "__main__":
    try:
        handle_upgrade(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        quiet.say("🌊 Operation cancelled by user.")
        sys.exit(130)
