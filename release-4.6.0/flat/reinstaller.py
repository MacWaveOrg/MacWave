#!/usr/bin/env python3

# reinstaller.py

# `wave reinstall`：把**已经装着的版本**重新下载、重新校验、重新落盘。
#
# 为什么不直接用 `wave install`：install 要求你知道版本号，而且它不区分
# 「本来没装」与「装过要刷新」。reinstall 的语义只有一句：
#     同一个包、同一个版本，重来一遍。
#
# 三个真实用途：
#   1. 产物更新但版本号没变。4.6 起 Mach-O 改成位置无关（@loader_path），
#      同一个版本号的产物字节与 sha256 都变了 —— 这就是它存在的主要理由；
#   2. 安装树被改坏（缺文件、被人手改过），重装一次即可修复；
#   3. 想把某个包固定回已经装着的那个版本，而不是升级。
#
# 依赖不会被重装：依赖有自己的引用计数，重装软件包时只按当前索引检查/补齐它们。
# 版本号不会变，所以它与 upgrade 是两条路：upgrade 向前，reinstall 原地。

import sys


def _strip_all_flag(flag_words):
    """把 -a/--all 从要透传给 install 的旗标里拿掉 —— install 不认它。"""
    return " ".join(word for word in flag_words.split() if word not in ("-a", "--all"))


def _resolve_targets(specs):
    """spec 列表 -> [(包名, 版本)]。版本缺省取已装的最新那个。

    两类问题分别报错，因为下一步动作完全不同：
      根本没装        -> 该用 wave install
      装了但不是这个版本 -> 该用已装的那个版本号，或先 install 那个版本
    """
    from uninstaller import find_installed_versions

    targets = []
    never_installed = []
    wrong_version = []

    for spec in specs:
        name, _, version = spec.partition("@")
        installed = find_installed_versions(name)

        if not installed:
            never_installed.append(name)
            continue

        if version:
            if version in installed:
                targets.append((name, version))
            else:
                wrong_version.append((name, version, installed))
            continue

        # find_installed_versions 降序，第一个就是最新的
        targets.append((name, installed[0]))

    if never_installed:
        print(f"🌊 Error: not installed, so there is nothing to reinstall: "
              f"{', '.join(never_installed)}")
        print(f"🌊 Use wave install {never_installed[0]} to install it first.")

    for name, version, installed in wrong_version:
        print(f"🌊 Error: {name}@{version} is not installed "
              f"(installed: {', '.join(installed)}).")
        print(f"🌊 Reinstall one of those: wave reinstall {name}@{installed[0]}")

    if never_installed or wrong_version:
        sys.exit(1)

    return targets


def handle_reinstall(input_string):
    """`wave reinstall <package>[@<version>] [, ...]` 与 `wave reinstall --all`。"""
    from pkginstaller import _flag_words, _install_single, package_specs
    from latest import installed_bin_names

    words = input_string.split()
    flag_words = set(words[2:])

    if "--ver" in flag_words:
        print("🌊 Error: reinstall keeps the version you already have; --ver is not "
              "accepted.")
        print("🌊 Name the version on the package instead: wave reinstall jq@1.8.2")
        sys.exit(1)

    all_packages = bool({"-a", "--all"} & flag_words)

    if all_packages:
        # -a 与显式包名混用说不清谁说了算，直接拒绝，别猜（与 uninstall 一致）
        if package_specs(input_string):
            print("🌊 Error: -a/--all reinstalls every installed package; it cannot "
                  "be combined with package names.")
            print("🌊 Use wave reinstall --all, or name the packages without -a.")
            sys.exit(1)
        specs = installed_bin_names()
        if not specs:
            print("🌊 No packages installed yet.")
            return 0
    else:
        specs = package_specs(input_string)
        if not specs:
            print("🌊 Error: Missing package name.")
            print("🌊 Try: wave reinstall <package>, or wave reinstall --all")
            sys.exit(1)

    targets = _resolve_targets(specs)
    passthrough = _strip_all_flag(_flag_words(input_string))

    total = len(targets)
    done = []
    failed = []

    for index, (name, version) in enumerate(targets, 1):
        label = f"{name}@{version}"
        if total > 1:
            print(f"🌊 [{index}/{total}] {label}")
        try:
            _install_single(f"wave install {label} {passthrough}".strip())
            done.append(label)
        except SystemExit as exit_error:
            if exit_error.code in (None, 0):
                done.append(label)
            else:
                failed.append(label)

    if total > 1:
        print(f"🌊 Reinstalled {len(done)} of {total} package(s)")
        for label in done:
            print(f"🌊   ok     {label}")
        for label in failed:
            print(f"🌊   failed {label}")

    if failed:
        print(f"🌊 Error: {len(failed)} of {total} package(s) failed to reinstall: "
              f"{', '.join(failed)}")
        print("🌊 The packages listed as ok above are installed and usable.")
        sys.exit(1)


if __name__ == "__main__":
    try:
        handle_reinstall(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        sys.exit(130)
