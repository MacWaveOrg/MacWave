#!/usr/bin/env python3

# linker.py

# 软件包的“不带版本号软链接”管理：
#   binary -> ../bin/{名称}@{版本号}/{名称}
#   tree   -> ../bin/{名称}@{版本号}/bin/{名称}   （安装目录里有 .is_a_tree）
#   tree 的其余命令（dtc 的 fdtget、testdisk 的 photorec…）各链一条：
#            ../bin/{名称}@{版本号}/bin/{另一个命令}
# 只处理软件包（bin/ 下的目录），不碰依赖（deps/ 下的整棵树）。
# 装完软件包后会自动改指到最高版本；早期装的包可以用 `wave link` 补上，
# 用 `wave unlink` 撤掉。

import os
import sys

import silent


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 配置加载 --------------------

from configpaths import assert_inside_entry, load_base_dir, require_safe_token


BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"
LINKS_DIR = BASE_DIR / "links"
TREE_MARKER = ".is_a_tree"


# -------------------- 版本库 --------------------

try:
    from versioncompare import get_max_version
except ModuleNotFoundError as error:
    # 区分「自己的模块找不到」和「它依赖的第三方库找不到」：后者是环境问题，
    # 报成「模块不可用」会把人往错误方向带（实际是 packaging 没装）。
    if error.name == "versioncompare":
        print(f"{RED_BOLD}🌊 Error: 'versioncompare' module is not available.{RESET}")
    else:
        print(f"{RED_BOLD}🌊 Error: Missing Python dependency '{error.name}'.{RESET}")
        print(f"{RED_BOLD}🌊 Install the required packages and try again:{RESET}")
        print(f"{YELLOW}   python3 -m pip install --user requests packaging rich{RESET}")
        print(f"{YELLOW}   (Homebrew's Python needs --break-system-packages){RESET}")
    sys.exit(1)


# -------------------- 安装状态查询 --------------------

def installed_versions(name):
    # bin/{名称}@{版本号}/ 里的版本号列表（名称即 `wave list` 显示的那个）
    name = require_safe_token(name, "package name")
    versions = []
    if not BIN_DIR.is_dir():
        return versions

    prefix = f"{name}@"
    for entry in BIN_DIR.iterdir():
        if entry.is_dir() and entry.name.startswith(prefix):
            version = entry.name[len(prefix):]
            if version:
                versions.append(version)
    return versions


def installed_packages():
    # bin/ 下所有软件包的名称，去重并按字母序
    names = set()
    if not BIN_DIR.is_dir():
        return []

    for entry in BIN_DIR.iterdir():
        if not entry.is_dir() or "@" not in entry.name:
            continue
        name, _, version = entry.name.partition("@")
        if name and version:
            names.add(name)
    return sorted(names)


def is_tree_package(name, version):
    # 整树软件包的标记：安装时由 depsmanager.sh 写在 bin/{名称}@{版本}/.is_a_tree
    return (BIN_DIR / f"{name}@{version}" / TREE_MARKER).is_file()


def link_target(name, version, bin_name=None):
    # 链接应当指向哪个相对路径（相对 links/）。形态由安装目录里的标记决定，
    # 索引里的 install 字段只在安装那一刻用，这里不重新读索引。
    # bin_name 只在整树包链接「其余命令」时才与包名不同。
    bin_name = bin_name or name
    if is_tree_package(name, version):
        return f"../bin/{name}@{version}/bin/{bin_name}"
    return f"../bin/{name}@{version}/{bin_name}"


def extra_bin_names(name, version):
    # 整树包 bin/ 下除主命令之外的可执行文件名。与 surfboard/depsmanager.sh
    # 装完那一刻做的事保持一致：那边是当场逐条 ln，这边给 `wave link` 补链用。
    if not is_tree_package(name, version):
        return []

    bin_dir = BIN_DIR / f"{name}@{version}" / "bin"
    if not bin_dir.is_dir():
        return []

    names = []
    for entry in sorted(bin_dir.iterdir()):
        if not entry.is_file() or not os.access(entry, os.X_OK):
            continue
        if entry.name == name:
            continue
        names.append(entry.name)
    return names


def _link_owner(link_name):
    # links/{链接名} 属于哪个包、指向哪个版本（不校验名字，调用方自己处理输入）。
    #
    # 整树包的附属命令（git-upload-pack、fdtget 这种）链接名**不是**包名，
    # 只看名字会把它当成「一个没链接的包」；目标路径里那段 {包名}@{版本} 才是权威。
    link = LINKS_DIR / link_name
    if not link.is_symlink():
        return None

    target = os.readlink(link)
    if os.path.basename(target) != link_name:
        return None

    # 从后往前找形如 {名称}@{版本} 的那一段：binary 是 links/x -> ../bin/x@1/x，
    # 整树是 links/x -> ../bin/x@1/bin/x，中间多一层 bin/。
    for part in reversed(os.path.dirname(target).split(os.sep)):
        if "@" not in part:
            continue
        name, _, version = part.partition("@")
        if name and version:
            return name, version
        return None
    return None


def linked_version(name):
    # links/{名称} 当前指向哪个版本；没链接、或指向别的名字时返回 None
    name = require_safe_token(name, "package name")
    owner = _link_owner(name)
    return owner[1] if owner and owner[0] == name else None


def is_dangling(name):
    # links/{名称} 是不是指向一个已经不存在的版本（已卸载，或目录被手动删掉）
    version = linked_version(name)
    return version is not None and version not in installed_versions(name)


def unversioned_links():
    # links/ 下所有不带版本号的软链接（带版本号的链接名里一定有 @）
    if not LINKS_DIR.is_dir():
        return []

    names = []
    for entry in LINKS_DIR.iterdir():
        if entry.is_symlink() and "@" not in entry.name:
            names.append(entry.name)
    return sorted(names)


# -------------------- 链接操作 --------------------

def create_link(name, version):
    # 建立或重指 links/{名称}；已存在（含悬空链接）先删掉再建
    name = require_safe_token(name, "package name")
    version = require_safe_token(version, "package version")
    LINKS_DIR.mkdir(parents=True, exist_ok=True)

    link = LINKS_DIR / name
    assert_inside_entry(link, LINKS_DIR, "link path")
    if link.is_symlink() or link.exists():
        link.unlink()

    # 这个链接由我们自己按固定形状生成（相对路径，永远指向 bin/ 下），不来自产物，
    # 所以它不可能越界 —— 与「包自带的符号链接必须检查目标」那条规则（见
    # SECURITY.md）是两回事。产物里的链接由解压产生，需要在解压后单独遍历检查。
    link.symlink_to(link_target(name, version))

    # 整树包里的其余命令也各链一条，否则 dtc/testdisk 这类装完只剩主命令可用
    for extra in extra_bin_names(name, version):
        extra_link = LINKS_DIR / extra
        assert_inside_entry(extra_link, LINKS_DIR, "link path")
        if extra_link.is_symlink() or extra_link.exists():
            extra_link.unlink()
        extra_link.symlink_to(link_target(name, version, extra))

    return link


def linked_bin_names(name):
    # links/ 下所有指回 {名称}@{版本} 这个包的命令（含主命令与其余命令）
    if not LINKS_DIR.is_dir():
        return []

    names = []
    for entry in LINKS_DIR.iterdir():
        if not entry.is_symlink() or "@" in entry.name:
            continue
        target = os.readlink(entry)
        if os.path.basename(target) != entry.name:
            continue
        for part in reversed(os.path.dirname(target).split(os.sep)):
            if "@" not in part:
                continue
            if part.partition("@")[0] == name:
                names.append(entry.name)
            break
    return sorted(names)


def remove_link(name):
    name = require_safe_token(name, "package name")
    link = LINKS_DIR / name
    assert_inside_entry(link, LINKS_DIR, "link path")
    if link.is_symlink() or link.exists():
        link.unlink()
        return True
    return False


def link_package(name, requested_version=None):
    # 把某个已安装的软件包链接到指定版本（默认最高版本），返回版本号；没装返回 None
    versions = installed_versions(name)
    if not versions:
        return None

    version = requested_version
    if not version or version == "latest":
        version = get_max_version(versions)
    elif version not in versions:
        return None

    create_link(name, version)
    return version


# -------------------- 命令解析 --------------------

def parse_targets(input_string):
    # 形如 "wave link ffmpeg@latest -a"；返回 (是否 --all, [目标...])
    words = input_string.split()[2:]

    everything = False
    targets = []
    for word in words:
        if word in ("-a", "--all"):
            everything = True
        elif not word.startswith("-"):
            targets.append(word)
    return everything, targets


# -------------------- wave link --------------------

def handle_link_command(input_string=""):
    everything, targets = parse_targets(input_string)

    if everything:
        targets = installed_packages()
        if not targets:
            print(f"{YELLOW}🌊 No packages installed, nothing to link.{RESET}")
            sys.exit(0)

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Nothing to link. Use 'wave link <name>@latest' or 'wave link --all'.{RESET}")
        sys.exit(1)

    linked = 0
    for target in targets:
        name, _, version = target.partition("@")

        versions = installed_versions(name)
        if not versions:
            print(f"{YELLOW}🌊 Warning: {name} is not installed, skipping.{RESET}")
            continue

        chosen = version
        if not chosen or chosen == "latest":
            chosen = get_max_version(versions)
        elif chosen not in versions:
            print(f"{YELLOW}🌊 Warning: {name}@{chosen} is not installed, skipping.{RESET}")
            continue

        previous = linked_version(name)
        create_link(name, chosen)

        if previous == chosen:
            silent.say(f"🌊 {name} is already linked to {chosen}")
        elif previous:
            silent.say(f"🌊 {name}: re-linked from {previous} to {chosen}")
        else:
            silent.say(f"🌊 {name}: linked to {chosen}")
        linked += 1

    if linked:
        silent.say(f"{GREEN}🌊 Linked {linked} package(s).{RESET}")
    else:
        print(f"{YELLOW}🌊 Nothing was linked.{RESET}")
    sys.exit(0)


# -------------------- wave unlink --------------------

def handle_unlink_command(input_string=""):
    everything, targets = parse_targets(input_string)

    if everything:
        targets = unversioned_links()
        if not targets:
            print(f"{YELLOW}🌊 No unversioned links found, nothing to unlink.{RESET}")
            sys.exit(0)

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Nothing to unlink. Use 'wave unlink <name>' or 'wave unlink --all'.{RESET}")
        sys.exit(1)

    unlinked = 0
    for target in targets:
        name = target.partition("@")[0]
        # 整树包的其余命令也一起摘掉，不然 links/ 里会留下没人认领的软链
        names = [name] + [n for n in linked_bin_names(name) if n != name]
        removed = [n for n in names if remove_link(n)]
        if removed:
            silent.say(f"🌊 {', '.join(removed)}: unlinked")
            unlinked += 1
        else:
            print(f"{YELLOW}🌊 Warning: {name} has no unversioned link, skipping.{RESET}")

    if unlinked:
        silent.say(f"{GREEN}🌊 Unlinked {unlinked} package(s).{RESET}")
    else:
        print(f"{YELLOW}🌊 Nothing was unlinked.{RESET}")
    sys.exit(0)


# -------------------- wave linkquery --------------------

def report_all_links():
    """`linkquery -a`：按**包名**逐个报，而不是按 links/ 里的条目名。

    整树包会给树里的每个可执行文件各建一条链接（git 的 git-upload-pack、
    dtc 的 fdtget…）。拿这些名字去 bin/ 里找 {名字}@{版本} 目录永远找不到，
    于是每台装了 git / dtc / testdisk 的机器上 `linkquery -a` 都会吐一片
    「is not linked」并以 1 退出 —— 而链接其实好得很。名单取自 bin/，才是包。
    """
    if not unversioned_links():
        print(f"{YELLOW}🌊 No unversioned links found.{RESET}")
        sys.exit(0)

    # 退出码只表达「有坏链接」：一个装好但没链接的包只是状态，不是错误 ——
    # 用户可以自己决定要不要 link 它，脚本也不该因此判定这台机器有问题。
    missing = 0
    for name in installed_packages():
        version = linked_version(name)
        if version is None:
            print(f"{YELLOW}🌊 {name} is not linked.{RESET}")
        elif version not in installed_versions(name):
            print(f"{RED_BOLD}🌊 Error: {name} points to {name}@{version}, which is not installed.{RESET}")
            missing += 1
        else:
            print(f"🌊 {name}@{version}")

    # 反过来也要查：链接还在、包目录没了（手删 bin，或卸载漏删链接）。只按包名
    # 走一遍永远发现不了这种 —— 而它正是「昨天还好好的命令今天 command not found」。
    packages = set(installed_packages())
    for link_name in unversioned_links():
        if link_name in packages:
            continue  # 主命令已经在上面按包报过了
        owner = _link_owner(link_name)
        if owner is None:
            print(f"{YELLOW}🌊 Warning: links/{link_name} is not a link MacWave made.{RESET}")
            missing += 1
        elif owner[0] not in packages or owner[1] not in installed_versions(owner[0]):
            print(f"{RED_BOLD}🌊 Error: {link_name} points to {owner[0]}@{owner[1]}, "
                  f"which is not installed.{RESET}")
            missing += 1

    sys.exit(1 if missing else 0)


def handle_linkquery_command(input_string=""):
    # 查询不带版本号的链接当前指向哪个版本：wave linkquery ffmpeg -> 🌊 ffmpeg@9.0
    everything, targets = parse_targets(input_string)

    if everything:
        report_all_links()

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Missing package name. Use 'wave linkquery <name>' or 'wave linkquery --all'.{RESET}")
        sys.exit(1)

    missing = 0
    for target in targets:
        name = target.partition("@")[0]
        version = linked_version(name)
        if version is None:
            # 整树包的附属命令：名字不是包，但链接确实是 MacWave 建的。
            # 说它「is not linked」是假话，还会让人以为坏了。
            owner = _link_owner(name)
            if owner is None:
                print(f"{YELLOW}🌊 {name} is not linked.{RESET}")
                missing += 1
            elif owner[1] not in installed_versions(owner[0]):
                print(f"{RED_BOLD}🌊 Error: {name} points to {owner[0]}@{owner[1]}, "
                      f"which is not installed.{RESET}")
                missing += 1
            else:
                print(f"🌊 {name} -> {owner[0]}@{owner[1]}")
        elif version not in installed_versions(name):
            print(f"{RED_BOLD}🌊 Error: {name} points to {name}@{version}, which is not installed.{RESET}")
            missing += 1
        else:
            print(f"🌊 {name}@{version}")

    sys.exit(1 if missing else 0)


# -------------------- 直接运行 --------------------

def main():
    words = sys.argv[1:]
    if words and words[0] == "link":
        handle_link_command("wave link " + " ".join(words[1:]))
    elif words and words[0] == "unlink":
        handle_unlink_command("wave unlink " + " ".join(words[1:]))
    elif words and words[0] == "linkquery":
        handle_linkquery_command("wave linkquery " + " ".join(words[1:]))

    print(f"{RED_BOLD}🌊 Error: Unknown argument.{RESET}")
    print("🌊 Usage: linker.py link <name>@latest | link --all | unlink <name> | unlink --all | linkquery <name>")
    sys.exit(1)


if __name__ == "__main__":
    main()
