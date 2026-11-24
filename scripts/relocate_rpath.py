#!/usr/bin/env python3

# relocate_rpath.py

# 把 staging 树里的 Mach-O 改成"位置无关"，供构建流水线在**打包之前**跑一次。
#
# 目标形态（推导见 docs/RELOCATION.md）：
#   - dylib 的 LC_ID_DYLIB  -> @rpath/<basename>
#   - 每条非系统引用        -> @loader_path/<相对路径>
#
# 改完之后产物里没有任何绝对路径，于是：
#   - 装到任意 BASE_DIR 都成立，安装时不必再改写，也不必重签；
#   - 整棵树可以整体搬走（相对关系跟着走）；
#   - 发布时的 sha256 与用户机器上的字节一致。
#
# 用法：
#   python3 scripts/relocate_rpath.py <stage-dir>            改写（默认 ad-hoc 重签）
#   python3 scripts/relocate_rpath.py <stage-dir> --check    只检查；有绝对路径则 exit 1
#   python3 scripts/relocate_rpath.py <stage-dir> --no-sign  只改不签（实验用）
#
# <stage-dir> 必须是**运行时布局**：里面有 bin/<包名>@<版本>/ 与
# deps/<依赖名>/<依赖名>@<版本>/。相对路径按这个布局算，所以 staging 时就要摆成
# 这个样子（和 MacPorts 的 destroot 一个意思）。
#
# 只处理 Mach-O；系统库（/usr/lib、/System、/Library/Apple）不动，因为它们在
# dyld shared cache 里，既改不了也不需要改。

import os
import subprocess
import sys

MAGICS = {
    "cffaedfe", "cefaedfe", "feedfacf", "feedface", "cafebabe", "bebafeca",
}

SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Apple/")
POSITION_INDEPENDENT_PREFIXES = ("@loader_path/", "@executable_path/", "@rpath/")


def is_system(path):
    return path.startswith(SYSTEM_PREFIXES)


def is_position_independent(path):
    return path.startswith(POSITION_INDEPENDENT_PREFIXES)


def iter_macho(root):
    """树里所有 Mach-O（跳过符号链接本身：它指向的真实文件会被单独处理）。"""
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as handle:
                    if handle.read(4).hex() in MAGICS:
                        yield path
            except OSError:
                continue


def run(argv):
    result = subprocess.run(argv, capture_output=True, text=True)
    return result.returncode, result.stdout


def dylib_id(path):
    """LC_ID_DYLIB；可执行文件与 MH_BUNDLE 没有，返回空串。"""
    code, out = run(["otool", "-D", path])
    if code != 0:
        return ""
    lines = out.splitlines()
    return lines[1].strip() if len(lines) > 1 else ""


def references(path):
    """otool -L 里的依赖路径（不含首行的文件名）。"""
    code, out = run(["otool", "-L", path])
    if code != 0:
        return []
    refs = []
    for line in out.splitlines()[1:]:
        if not line.startswith((" ", "\t")):
            continue
        fields = line.split()
        if fields:
            refs.append(fields[0])
    return refs


def package_root(path, root):
    """bin/<包名>@<版本> 或 deps/<依赖名>/<依赖名>@<版本> 这两段。"""
    rel = os.path.relpath(path, root)
    parts = rel.split(os.sep)
    if len(parts) >= 3 and parts[0] == "deps":
        return os.path.join(*parts[:3])
    if len(parts) >= 2:
        return os.path.join(*parts[:2])
    return parts[0]


def build_index(root):
    """basename -> [绝对路径]；同名多份时留给调用方去按"同包优先"裁决。"""
    index = {}
    for path in iter_macho(root):
        index.setdefault(os.path.basename(path), []).append(path)
    return index


def pick_candidate(candidates, file_path, root):
    """同名多份时的裁决：优先和引用者同一个包；仍有歧义就报错。"""
    if len(candidates) == 1:
        return candidates[0], None

    mine = package_root(file_path, root)
    same = [c for c in candidates if package_root(c, root) == mine]
    if len(same) == 1:
        return same[0], None

    listed = "\n".join("    " + os.path.relpath(c, root) for c in candidates)
    return None, f"{os.path.relpath(file_path, root)}: ambiguous dependency name, candidates:\n{listed}"


def plan(root, index):
    """算出要做的改动。返回 (actions, problems)。

    actions: [(file, kind, old, new)]，kind 是 "change" 或 "id"。
    problems: [(file, description)]，指无法安全处理的情况。
    """
    actions = []
    problems = []

    for path in iter_macho(root):
        current_id = dylib_id(path)
        dir_name = os.path.dirname(path)

        for ref in references(path):
            if is_system(ref) or is_position_independent(ref):
                continue
            if ref == current_id:
                continue

            candidates = index.get(os.path.basename(ref), [])
            if not candidates:
                problems.append((path, f"not provided by staging tree: {ref}"))
                continue

            target, error = pick_candidate(candidates, path, root)
            if error:
                problems.append((path, error))
                continue

            rel = os.path.relpath(target, dir_name)
            actions.append((path, "change", ref, "@loader_path/" + rel))

        if current_id and not is_position_independent(current_id):
            actions.append((path, "id", current_id, "@rpath/" + os.path.basename(path)))

    return actions, problems


def apply_actions(actions, sign):
    """执行改动；返回失败列表。同一个文件的多条改动合成一次 install_name_tool。"""
    by_file = {}
    for file_path, kind, old, new in actions:
        by_file.setdefault(file_path, []).append((kind, old, new))

    failures = []
    for file_path in sorted(by_file):
        argv = ["install_name_tool"]
        for kind, old, new in by_file[file_path]:
            if kind == "change":
                argv += ["-change", old, new]
            else:
                argv += ["-id", new]
        argv.append(file_path)

        result = subprocess.run(argv, capture_output=True, text=True)
        if result.returncode != 0:
            reason = result.stderr.strip().splitlines()
            failures.append((file_path, reason[0] if reason else "install_name_tool failed"))
            continue

        if sign:
            result = subprocess.run(
                ["codesign", "--force", "--sign", "-", file_path],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                failures.append((file_path, "codesign failed"))

    return failures


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print("usage: relocate_rpath.py <stage-dir> [--check] [--no-sign]")
        return 2 if len(argv) < 2 else 0

    root = os.path.abspath(argv[1])
    check_only = "--check" in argv[2:]
    sign = "--no-sign" not in argv[2:]

    if not os.path.isdir(root):
        print(f"🌊 Error: stage directory not found: {root}")
        return 1

    index = build_index(root)
    actions, problems = plan(root, index)

    for path, description in problems:
        print(f"🌊 Error: {os.path.relpath(path, root)}: {description}")
    if problems:
        print("🌊 Refusing to continue: every reference must resolve inside the staging tree.")
        return 1

    if check_only:
        if actions:
            print(f"🌊 Not position-independent: {len(actions)} absolute reference(s)/identifier(s)")
            for file_path, kind, old, _new in actions[:20]:
                print(f"🌊   {os.path.relpath(file_path, root)}: {kind} {old}")
            return 1
        print(f"🌊 OK: all Mach-O files are position-independent ({root})")
        return 0

    if not actions:
        print(f"🌊 Already position-independent, nothing to do ({root})")
        return 0

    failures = apply_actions(actions, sign)
    for path, reason in failures:
        print(f"🌊 Error: {os.path.relpath(path, root)}: {reason}")

    if failures:
        print("🌊 Failed: the artifact would not load at runtime. It was most likely built")
        print("🌊 without header space (no -headerpad_max_install_names) for the longer path.")
        return 1

    touched = len({file_path for file_path, _kind, _old, _new in actions})
    print(f"🌊 Relocated {touched} Mach-O file(s) to @loader_path (signed: {'yes' if sign else 'no'})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
