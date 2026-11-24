#!/usr/bin/env python3

# transferrer.py

# `wave transfer`：把**已经装着**的产物改写成位置无关的形式（@loader_path）。
#
# 为什么需要它 —— 4.6 之前装的包，Mach-O 里的引用是写死的绝对路径：
#     <base_dir>/deps/openssl/openssl@3.0.15/lib/libcrypto.3.dylib
# 那份树只能待在当前 base_dir 里，搬到别处（换机器、换前缀）就加载不到。
# 迁移之后引用变成相对形式，整棵树可以整体搬走：
#     @loader_path/../../../deps/openssl/openssl@3.0.15/lib/libcrypto.3.dylib
#
# 一句话分工：
#   - 构建侧 scripts/relocate_rpath.py  给 staging 树做同样的事（打包前）；
#   - 安装时 surfboard/transfer.sh      对新产物只核对，不改写；
#   - 这个模块                          给**已经装着**的老产物做一次性迁移。
#
# 自动检测新旧：每个目标目录先跑 `transfer.sh --check`（只读、不建索引），
# 已经全是相对引用的直接跳过，只对还写着绝对路径的那些动手。所以重复执行安全，
# 混着新旧产物的树也只会迁移该迁移的那部分。
#
# 迁移会重写二进制字节并重新 ad-hoc 签名，因此：
#   - 先在 --dry-run 下看一眼要动哪些包；
#   - 想彻底恢复原样，`wave reinstall <包>` 重新下一份即可。

import os
import subprocess
import sys
import tempfile

import silent
from configpaths import load_base_dir

TRANSFER_SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "surfboard", "transfer.sh",
)

BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"


def _run_transfer(args):
    """跑一次 transfer.sh，返回 (退出码, 输出)。输出已去掉尾部空白。"""
    result = subprocess.run(
        ["/bin/bash", TRANSFER_SCRIPT] + list(args),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    return result.returncode, (result.stdout or "").strip()


def _read_deps(artifact_dir):
    """读取某个产物目录的 `_DEPS`，返回 [(依赖名, 版本)]。"""
    path = os.path.join(artifact_dir, "_DEPS")
    if not os.path.isfile(path):
        return []
    refs = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            ref = line.strip().strip('"').strip()
            if not ref or "@" not in ref:
                continue
            name, _, version = ref.partition("@")
            if name and version:
                refs.append((name, version))
    return refs


def _dep_dir(name, version):
    return os.path.join(str(BASE_DIR), "deps", name, f"{name}@{version}")


def _collect_deps(package_dirs):
    """把若干软件包目录用到的依赖（含依赖的依赖）收成目录集合。

    必须连依赖一起迁移：只改软件包自己的引用，它指向的 dep 里那些绝对路径
    仍然写死，整棵树照样搬不动。
    """
    seen = {}
    pending = list(package_dirs)

    while pending:
        current = pending.pop()
        for name, version in _read_deps(current):
            target = _dep_dir(name, version)
            if target in seen or not os.path.isdir(target):
                continue
            seen[target] = True
            pending.append(target)

    return sorted(seen)


def _package_dirs(specs):
    """spec 列表 -> [(标签, 目录)]。不带 @版本 时取该包的所有已装版本。"""
    from uninstaller import find_installed_versions

    targets = []
    problems = []

    for spec in specs:
        name, _, version = spec.partition("@")
        installed = find_installed_versions(name)

        if not installed:
            problems.append(f"not installed: {name}")
            continue

        if version:
            if version not in installed:
                problems.append(
                    f"not installed: {name}@{version} (installed: {', '.join(installed)})")
                continue
            wanted = [version]
        else:
            wanted = list(reversed(installed))  # find_installed_versions 降序

        for each in wanted:
            targets.append((f"{name}@{each}", os.path.join(str(BIN_DIR), f"{name}@{each}")))

    return targets, problems


def all_installed_dirs():
    """所有已装软件包 + 所有已装依赖：[(标签, 目录)]。--all 与 basedir 预检共用。"""
    targets = []

    if os.path.isdir(str(BIN_DIR)):
        for entry in sorted(os.listdir(str(BIN_DIR))):
            path = os.path.join(str(BIN_DIR), entry)
            if os.path.isdir(path) and "@" in entry:
                targets.append((f"bin/{entry}", path))

    deps_root = os.path.join(str(BASE_DIR), "deps")
    if os.path.isdir(deps_root):
        for owner in sorted(os.listdir(deps_root)):
            owner_dir = os.path.join(deps_root, owner)
            if not os.path.isdir(owner_dir):
                continue
            for version_dir in sorted(os.listdir(owner_dir)):
                path = os.path.join(owner_dir, version_dir)
                if os.path.isdir(path):
                    targets.append((f"deps/{owner}/{version_dir}", path))

    return targets


def _relative_label(path):
    try:
        return os.path.relpath(path, str(BASE_DIR))
    except ValueError:
        return path


def position_independence(artifact_dir):
    """True / False / None（None = 判断不了，例如没有 otool）。

    用 `transfer.sh --check` 判断 —— 那是唯一的口径（同一个脚本负责改写），
    在这里另写一份 Mach-O 解析只会和它走散。只读、不建索引。
    退出码：0 = 已是相对形式，1 = 还有绝对路径，2 = 无法检查。
    """
    code, _output = _run_transfer(["--check", str(artifact_dir), str(BASE_DIR)])
    if code == 0:
        return True
    if code == 1:
        return False
    return None


def is_position_independent(artifact_dir):
    return position_independence(artifact_dir) is True


def absolute_artifacts():
    """还写着绝对路径的产物：[(标签, 目录)]。空列表 = 整棵树可以搬走。

    「判断不了」不算在内：把未知当成"坏"，会让 `basedir --set` 在缺 otool 的环境里
    永远拒绝搬家。
    """
    return [(label, path) for label, path in all_installed_dirs()
            if position_independence(path) is False]


def handle_transfer(input_string):
    """`wave transfer <package>[@<version>] [, ...]` 与 `wave transfer --all`。"""
    from lock import tree_lock
    with tree_lock("transfer"):
        return _handle_transfer_locked(input_string)


def _handle_transfer_locked(input_string):
    words = input_string.split()
    operands = [word for word in words[2:] if not word.startswith("-")]
    flag_words = {word for word in words[2:] if word.startswith("-")}

    all_packages = bool({"-a", "--all"} & flag_words)
    dry_run = bool({"-n", "--dry-run"} & flag_words)

    tolerated = {"-a", "--all", "-n", "--dry-run"}
    from flags import GLOBAL
    for unknown in sorted(flag_words - tolerated - set(GLOBAL)):
        print(f"🌊 Warning: unknown flag '{unknown}' ignored.")

    if all_packages:
        if operands:
            print("🌊 Error: -a/--all transfers every installed package; it cannot be "
                  "combined with package names.")
            print("🌊 Use wave transfer --all, or name the packages without -a.")
            sys.exit(1)
        targets = all_installed_dirs()
        if not targets:
            print("🌊 No packages installed yet.")
            return 0
    else:
        # 逗号与空格都当分隔，与 install / uninstall 一致
        specs = []
        for token in operands:
            specs.extend(part.strip() for part in token.split(",") if part.strip())
        if not specs:
            print("🌊 Error: Missing package name.")
            print("🌊 Try: wave transfer <package>, wave transfer <package>@<version>, "
                  "or wave transfer --all")
            sys.exit(1)

        targets, problems = _package_dirs(specs)
        for problem in problems:
            print(f"🌊 Error: {problem}")
        if problems:
            print("🌊 Nothing was transferred.")
            sys.exit(1)

        # 连这些包用到的依赖一起迁移，否则整棵树仍然搬不动
        extras = _collect_deps([path for _label, path in targets])
        targets.extend((_relative_label(path), path) for path in extras)

    # 去重（包与依赖可能被重复列出），保持顺序
    unique = {}
    for label, path in targets:
        unique.setdefault(path, label)
    targets = [(label, path) for path, label in unique.items()]

    if dry_run:
        silent.say(f"🌊 Would transfer {len(targets)} installed artifact(s):")

    shared_index = tempfile.mkdtemp(prefix="macwave-transfer-index-")
    migrated = []
    already = []
    failed = []

    try:
        for label, path in targets:
            code, output = _run_transfer(["--check", path, str(BASE_DIR)])
            if code == 0:
                already.append(label)
                continue
            if code != 1:
                failed.append((label, output or "check failed"))
                continue

            if dry_run:
                migrated.append(label)
                silent.say(f"🌊   needs transfer: {label}")
                continue

            code, output = _run_transfer(
                ["--relative", path, str(BASE_DIR), shared_index])
            if code == 0:
                migrated.append(label)
                detail = output.splitlines()[-1] if output else ""
                detail = detail.lstrip("🌊").strip()
                silent.say(f"🌊 {label}: {detail or 'ok'}")
            else:
                failed.append((label, output))
    finally:
        for name in os.listdir(shared_index):
            try:
                os.unlink(os.path.join(shared_index, name))
            except OSError:
                pass
        try:
            os.rmdir(shared_index)
        except OSError:
            pass

    verb = "would transfer" if dry_run else "transferred"
    silent.say(f"🌊 {verb} {len(migrated)}, already relative {len(already)}, "
               f"failed {len(failed)} (of {len(targets)})")

    for label, output in failed:
        print(f"🌊 Error: {label} could not be transferred.")
        for line in (output or "").splitlines():
            print(f"🌊   {line}")

    if failed:
        print("🌊 These artifacts still name absolute paths; reinstalling them with "
              "'wave reinstall <package>' gives a build-time relocated copy instead.")
        sys.exit(1)


if __name__ == "__main__":
    try:
        handle_transfer(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        sys.exit(130)
