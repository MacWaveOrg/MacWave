#!/usr/bin/env python3

# uninstaller.py

import os
import sys
import json
import shutil
import subprocess
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 配置加载 --------------------

from configpaths import assert_inside, assert_inside_entry, load_base_dir, require_safe_token


BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"
LINKS_DIR = BASE_DIR / "links"
INSTALLED_DB = BASE_DIR / "pkg" / "installed.json"
TAGGER_SCRIPT = Path(__file__).resolve().parent.parent / "surfboard" / "tagger.sh"


# -------------------- 依赖库检查 --------------------

try:
    from pkgversionparser import get_max_version, sort_versions
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'pkgversionparser' module is not available.{RESET}")
    sys.exit(1)

try:
    from depsversionparser import parse_dep_ref
    from querier import dep_dir
except ImportError as error:
    print(f"{RED_BOLD}🌊 Error: 'surfboard' module is not available ({error}).{RESET}")
    sys.exit(1)


# -------------------- 辅助函数 --------------------

def to_tilde(path):
    # 把 $HOME 前缀显示成 ~
    home = os.path.expanduser("~")
    path = str(path)
    if path.startswith(home):
        return "~" + path[len(home):]
    return path


def load_installed():
    if INSTALLED_DB.exists():
        try:
            with open(INSTALLED_DB, 'r') as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_installed(installed):
    INSTALLED_DB.parent.mkdir(parents=True, exist_ok=True)
    with open(INSTALLED_DB, 'w') as f:
        json.dump(installed, f, indent=2)


def find_installed_versions(pkg_name):
    # 扫描 bin 目录（2.2 起为 <包名>@<版本号> 目录），
    # 返回该包所有已安装版本（降序，排除 .bak 备份）
    pkg_name = require_safe_token(pkg_name, "package name")
    if not BIN_DIR.exists():
        return []
    prefix = f"{pkg_name}@"
    versions = []
    for entry in BIN_DIR.iterdir():
        name = entry.name
        if not name.startswith(prefix):
            continue
        version = name[len(prefix):]
        if not version or version.endswith(".bak"):
            continue
        versions.append(version)
    return sort_versions(versions)


# -------------------- 删除动作 --------------------

def read_deps_file(artifact_dir):
    # 读取 _DEPS，返回依赖引用列表（每行形如 "a@1.0"）
    deps_file = artifact_dir / "_DEPS"
    if not deps_file.exists():
        return []

    refs = []
    try:
        with open(deps_file, 'r') as f:
            for line in f:
                ref = line.strip().strip('"').strip()
                if ref:
                    refs.append(ref)
    except Exception:
        return []
    return refs


def run_tagger(*args):
    return subprocess.run(
        ['bash', str(TAGGER_SCRIPT), *args],
        capture_output=True, text=True
    )


def delete_depender_tag(dep_path, depender_kind, depender_name, depender_version):
    action = "delete-pkg" if depender_kind == "pkg" else "delete-dep"
    result = run_tagger(action, str(dep_path), depender_name, depender_version)

    if result.returncode != 0:
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.stderr.strip():
            print(result.stderr.strip())
        sys.exit(result.returncode)


def has_depender_tag(dep_path):
    return run_tagger("has-marks", str(dep_path)).returncode == 0


def remove_dep_links(dep_path):
    # 依赖包保留了整棵目录，bin/ 下可能有多个可执行文件，
    # 因此按软链接指向反查，清掉所有指向该依赖目录的链接。
    if not LINKS_DIR.is_dir():
        return

    resolved_dep = dep_path.resolve()

    for link in LINKS_DIR.iterdir():
        if not link.is_symlink():
            continue
        try:
            target = (link.parent / os.readlink(link)).resolve()
        except OSError:
            continue
        if target == resolved_dep or resolved_dep in target.parents:
            link.unlink()


def remove_dependency(artifact_dir, depender_kind, depender_name, depender_version, visited=None):
    # 递归清理：删除自己的依赖者标记，没有其他依赖者时连同其依赖一起删除。
    # visited 记录本轮已处理过的依赖目录，避免循环依赖（A→B→A）导致无限递归
    if visited is None:
        visited = set()

    for ref in read_deps_file(artifact_dir):
        dep_name, dep_version = parse_dep_ref(ref)
        dep_path = dep_dir(dep_name, dep_version)

        if not dep_path.is_dir():
            continue

        delete_depender_tag(dep_path, depender_kind, depender_name, depender_version)

        if has_depender_tag(dep_path):
            continue

        resolved_dep = dep_path.resolve()
        if resolved_dep in visited:
            continue
        visited.add(resolved_dep)

        # 已无任何依赖者：先清软链接与它自己的依赖，再删除目录
        print(f"🌊 Removing orphan dependency {dep_name}@{dep_version}...")

        remove_dep_links(dep_path)

        remove_dependency(dep_path, "dep", dep_name, dep_version, visited)
        shutil.rmtree(dep_path)

        owner_dir = dep_path.parent
        if owner_dir.is_dir() and not any(owner_dir.iterdir()):
            owner_dir.rmdir()


def remove_one(pkg_name, version, installed):
    # 删除单个 <包名>@<版本号>（bin 下的目录 + links 下的软链接，含 .bak），
    # 并同步 installed.json
    pkg_name = require_safe_token(pkg_name, "package name")
    version = require_safe_token(version, "package version")

    target = BIN_DIR / f"{pkg_name}@{version}"
    backup = BIN_DIR / f"{pkg_name}@{version}.bak"
    link = LINKS_DIR / f"{pkg_name}@{version}"
    backup_link = LINKS_DIR / f"{pkg_name}@{version}.bak"

    # 要递归删除的路径必须先确认落在安装目录里
    for path, root in ((target, BIN_DIR), (backup, BIN_DIR)):
        assert_inside(path, root, "uninstall path")

    # 软链接只删链接本身，不能跟到 bin/ 里的目标去
    for path, root in ((link, LINKS_DIR), (backup_link, LINKS_DIR)):
        assert_inside_entry(path, root, "uninstall path")

    record = installed.get(pkg_name)
    if record and record.get("version") == version and record.get("binary_path"):
        display_path = record["binary_path"]
    else:
        display_path = target

    print(f"🌊 Deleting {to_tilde(display_path)}...")

    if target.is_dir():
        # 先按 _DEPS 清理依赖标记与孤立依赖，再删除整个目录
        remove_dependency(target, "pkg", pkg_name, version)
        shutil.rmtree(target)
    elif target.exists():
        target.unlink()

    if backup.is_dir():
        shutil.rmtree(backup)
    elif backup.exists():
        backup.unlink()

    # 软链接可能是悬空的，用 is_symlink 判断
    for link_path in (link, backup_link):
        if link_path.is_symlink() or link_path.exists():
            link_path.unlink()

    # 只有记录版本与删除版本一致时才移除记录，避免误删其他版本
    if record and record.get("version") == version:
        del installed[pkg_name]
        return True
    return False


# -------------------- 软件包链接联动 --------------------

def _import_linker():
    # linker.py 与 uninstaller.py 同在 pkg/ 下；缺了也不影响卸载本身
    try:
        import linker
        return linker
    except ImportError:
        return None


def refresh_link(pkg_name):
    # 卸载后同步不带版本号的软链接：还有别的版本就改指最高的，一个不剩就删掉。
    # 本来就没链接过的（用户手动 unlink 过）不重新建。
    # 链接已经是悬空的（指向被删掉的版本）时，也会在这里被治好。
    linker = _import_linker()
    if linker is None:
        return

    if linker.linked_version(pkg_name) is None:
        return

    versions = linker.installed_versions(pkg_name)
    if versions:
        version = get_max_version(versions)
        linker.create_link(pkg_name, version)
        print(f"🌊 Unversioned link now points to {pkg_name}@{version}")
    else:
        linker.remove_link(pkg_name)
        print(f"🌊 Removed the unversioned link for {pkg_name}")


def broken_link_target(pkg_name, versions):
    # --unlink 会把不带版本号的链接留在「指向已卸载版本」的坏状态上吗？
    # 是则返回那个版本号。链接只能指向存在的版本，否则宁可报错让用户自己决定。
    linker = _import_linker()
    if linker is None:
        return None

    target = linker.linked_version(pkg_name)
    if target is not None and target in versions:
        return target
    return None


def uninstall_versions(pkg_name, versions, keep_link=False):
    if keep_link:
        broken = broken_link_target(pkg_name, versions)
        if broken:
            print(f"{RED_BOLD}🌊 Error: links/{pkg_name} points to {pkg_name}@{broken}, which is being uninstalled.{RESET}")
            print(f"{RED_BOLD}🌊 --unlink would leave that link broken, so nothing was uninstalled.{RESET}")
            print(f"{RED_BOLD}🌊 Drop --unlink (the link then falls back to the next installed version), or run 'wave unlink {pkg_name}' first.{RESET}")
            sys.exit(1)

    installed = load_installed()
    changed = False
    for version in versions:
        changed = remove_one(pkg_name, version, installed) or changed
    if changed:
        save_installed(installed)
    if keep_link:
        print(f"🌊 Left the unversioned link for {pkg_name} untouched")
    else:
        refresh_link(pkg_name)
    for version in versions:
        print(f"{GREEN}🌊 Successfully uninstalled {pkg_name}@{version}.{RESET}")


# -------------------- 交互式选择 --------------------

def select_versions(pkg_name, versions):
    print(f"🌊 Multiple versions found for '{pkg_name}':")
    for index, version in enumerate(versions, start=1):
        print(f"🌊 - {index}. {version}")
    print("🌊 Enter the number(s) to uninstall (separate by @ or space):")

    try:
        choice = input().strip()
    except (EOFError, KeyboardInterrupt):
        print("🌊 Operation cancelled by user.")
        sys.exit(130)

    selected = []
    for token in choice.replace('@', ' ').split():
        if not token.isdigit() or not (1 <= int(token) <= len(versions)):
            print(f"{RED_BOLD}🌊 Error: Invalid selection '{token}'.{RESET}")
            sys.exit(1)
        selected.append(versions[int(token) - 1])

    if not selected:
        print("🌊 Nothing selected.")
        sys.exit(0)

    return selected


# -------------------- 命令入口 --------------------

def handle_uninstall(input_string):
    parts = input_string.split()

    # 先剥出 flag：--unlink 表示“不动这个包不带版本号的链接”
    flags = {word for word in parts[2:] if word.startswith("-")}
    operands = [word for word in parts[2:] if not word.startswith("-")]
    keep_link = "--unlink" in flags

    for unknown in sorted(flags - {"--unlink"}):
        print(f"{YELLOW}🌊 Warning: unknown flag '{unknown}' ignored.{RESET}")

    if not operands:
        print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
        sys.exit(1)

    raw_pkg = operands[0]

    # 1. 不带 @：只有一个版本就直接卸，多个版本才让用户选
    if '@' not in raw_pkg:
        pkg_name = raw_pkg
        versions = find_installed_versions(pkg_name)
        if not versions:
            print(f"{RED_BOLD}🌊 Error: Package '{pkg_name}' is not installed.{RESET}")
            sys.exit(1)
        if len(versions) == 1:
            uninstall_versions(pkg_name, versions, keep_link)
            return
        uninstall_versions(pkg_name, select_versions(pkg_name, versions), keep_link)
        return

    # 2. 带 @：拆分包名与版本号
    pkg_name, *raw_versions = raw_pkg.split('@')
    raw_versions = [v for v in raw_versions if v]

    if not raw_versions:
        print(f"{RED_BOLD}🌊 Error: Missing version number.{RESET}")
        sys.exit(1)

    # 2.1 通配符 *：卸载所有版本
    if raw_versions == ['*']:
        versions = find_installed_versions(pkg_name)
        if not versions:
            print(f"{RED_BOLD}🌊 Error: Package '{pkg_name}' is not installed.{RESET}")
            sys.exit(1)
        uninstall_versions(pkg_name, versions, keep_link)
        return

    # 2.2 指定一个或多个版本：批量删除
    installed_versions = find_installed_versions(pkg_name)
    targets = [v for v in raw_versions if v in installed_versions]
    missing = [v for v in raw_versions if v not in installed_versions]

    if not targets:
        print(f"{RED_BOLD}🌊 Error: Package '{pkg_name}' is not installed.{RESET}")
        sys.exit(1)

    for version in missing:
        print(f"{YELLOW}🌊 Warning: {pkg_name}@{version} is not installed, skipping.{RESET}")

    uninstall_versions(pkg_name, targets, keep_link)


if __name__ == "__main__":
    try:
        input_string = " ".join(sys.argv[1:])
        handle_uninstall(input_string)
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        sys.exit(130)
