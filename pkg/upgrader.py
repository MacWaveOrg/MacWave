#!/usr/bin/env python3

# upgrader.py
#
# `wave upgrade <package>`：把已装或未装的包带到索引里的最新版本。
#
# 因为支持多版本共存，install 一个新版本不会动旧的，所以「升级」需要额外的收尾动作 ——
# 这就是 `--remove-old-version`（别名 `--rov`）存在的原因：
#   - 只有一个旧版本：直接移除；
#   - 多个旧版本：先问「全部移除？」，答 N 就像 uninstall 那样列出来让用户挑。
#
# 顺序刻意是「先装新版本，再清理旧版本」：安装失败时旧版本还在，用户仍有一个能用的。

import sys

from configpaths import require_safe_token


RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# upgrade 只做「装到最新」，这两个旗标与它的语义冲突，直接拒绝而不是静默忽略：
# --ver 会让「升级」变成「装某个指定版本」；--unlink 会让链接留在旧版本上，
# 而随后清理旧版本正好会把那个链接指坏。两条都请用户改用对应的命令。
REJECTED_FLAGS = {
    "--ver": "Use 'wave install <package>@<version>' to install a specific version",
    "--unlink": "Run 'wave link <package>@<version>' afterwards to choose the linked version",
}

REMOVE_OLD_FLAGS = ("--remove-old-version", "--rov")

def split_input(input_string):
    """把 upgrade 专属旗标剥掉，返回 (剩余词, 是否要求移除旧版本)。"""
    remove_old = False
    kept = []
    for word in input_string.split()[2:]:
        if word in REMOVE_OLD_FLAGS:
            remove_old = True
            continue
        kept.append(word)
    return kept, remove_old


def ask_yes_no(prompt):
    """问一次 Y/n。返回 True / False；读到 EOF（非交互）时返回 None。"""
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


def remove_old_versions(bin_name, keep_version):
    """移除 keep_version 之外的所有已装版本，保留 keep_version。"""
    from pkgversionparser import safe_parse_pkg_version as version_key
    from uninstaller import find_installed_versions, select_versions, uninstall_versions

    old = [version for version in find_installed_versions(bin_name)
           if version_key(version) < version_key(keep_version)]
    if not old:
        print(f"🌊 No old versions of {bin_name} to remove.")
        return

    # 只有一个旧版本：不必再问选哪个，「移除旧版本」已经表达得很清楚
    if len(old) == 1:
        print(f"🌊 Removing the old version {bin_name}@{old[0]}...")
        uninstall_versions(bin_name, old)
        return

    print(f"🌊 {len(old)} old versions of {bin_name} are installed: {', '.join(old)}")
    answer = ask_yes_no("🌊 Remove all of them? [Y/n] ")
    if answer is None:
        # 非交互（CI、管道）：没有人能替用户回答，保留旧版本比误删安全
        print(f"{YELLOW}🌊 Cannot ask without a terminal; no old version was removed.{RESET}")
        return

    if answer:
        uninstall_versions(bin_name, old)
        return

    print("🌊 Choose which old versions to remove, one or more.")
    try:
        selected = select_versions(bin_name, old)
    except SystemExit:
        # 选择过程本身被取消（Ctrl+C 或读不到输入）不该让已经完成的升级失败
        print(f"{YELLOW}🌊 No old version was removed.{RESET}")
        return
    uninstall_versions(bin_name, selected)


def handle_upgrade(input_string):
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

    words, remove_old = split_input(input_string)

    index = package_index(words)
    if index is None:
        print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
        sys.exit(1)

    raw_package = words[index]
    if "@" in raw_package:
        print(f"{RED_BOLD}🌊 Error: upgrade always targets the latest version.{RESET}")
        print(f"{YELLOW}🌊 Use 'wave install {raw_package}' to install that exact version.{RESET}")
        sys.exit(1)

    package_name = require_safe_token(raw_package, "package name")

    # 其余旗标交给 install 的白名单校验：upgrade 自己的旗标已经在上面剥掉了，
    # 所以这里能接受的恰好就是 install 能接受的减去被拒绝的那两个。
    probe = "wave install placeholder " + " ".join(words[:index] + words[index + 1:])
    flags = parse_flags(probe)
    for flag, hint in REJECTED_FLAGS.items():
        if flag in flags:
            print(f"{RED_BOLD}🌊 Error: {flag} is not accepted by upgrade.{RESET}")
            print(f"{YELLOW}🌊 {hint}.{RESET}")
            sys.exit(1)

    timeout = parse_timeout(probe, flags)

    arch = detect_arch()
    print(f"🌊 Checking the latest version of {package_name}...")
    latest = fetch_max_version(package_name, arch, timeout)

    # 包名与 bin_name 不一定相同（choma -> ChOma），而 bin/ 与 links/ 用的是 bin_name
    common_fields = fetch_common_fields(package_name, arch, timeout)
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
        print(f"{GREEN}🌊 {bin_name} is already at the latest version ({latest}).{RESET}")
    else:
        keep = latest
        if installed:
            print(f"🌊 Upgrading {bin_name}: {installed[0]} -> {latest}")
        else:
            print(f"🌊 {bin_name} is not installed; installing {latest}.")
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
                print(f"🌊 Linked {bin_name} -> {bin_name}@{linked}")
        except Exception as error:
            print(f"{YELLOW}🌊 Warning: could not re-point the unversioned link ({error}).{RESET}")

    if remove_old:
        remove_old_versions(bin_name, keep)


if __name__ == "__main__":
    try:
        handle_upgrade(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        sys.exit(130)
