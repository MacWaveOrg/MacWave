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


def rpaths(path):
    """文件自己的 LC_RPATH 列表。"""
    code, out = run(["otool", "-l", path])
    if code != 0:
        return []
    found = []
    want = False
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "cmd" and fields[1] == "LC_RPATH":
            want = True
            continue
        if want and fields and fields[0] == "path":
            found.append(fields[1])
            want = False
    return found


def rpath_resolves(file_path, base):
    """这个文件的 LC_RPATH 里有没有一条能解析到 base。

    与客户端 surfboard/transfer.sh 的 rpath_target_resolves 同一套口径：
    只认 @loader_path 形式（相对文件自身，本地可判定）与绝对路径；
    @executable_path 取决于谁加载它，静态判断会误判，按"解析得到"放行。
    """
    for rpath in rpaths(file_path):
        if rpath.startswith("@loader_path/"):
            expanded = os.path.join(os.path.dirname(file_path), rpath[len("@loader_path/"):])
        elif rpath.startswith("@executable_path/"):
            return True
        elif rpath.startswith("/"):
            expanded = rpath
        else:
            continue
        if os.path.exists(os.path.join(expanded, base)):
            return True
    return False


def is_position_independent(path, file_path=None):
    """这个引用在这个文件身上算不算已经就位。

    `@rpath/<名>` 不能无条件算数：conda 产物普遍是「引用写 @rpath/<名>、LC_RPATH
    指向 @loader_path/../lib」，那个 ../lib 是相对包自己的老布局；依赖实际装在
    deps/<依赖>/<依赖>@<版本>/lib 下，必须由重定位改写才对得上。
    客户端 4.6 就是因为「@rpath 一律放过」导致装完 Library not loaded
    （2026-11-24 的 htop / ncdu / tmux）。构建端必须用同一套判据，
    否则会给 conda 产物打上"已就位"的标记，客户端于是跳过改写，装完跑不起来。
    """
    if path.startswith(("@loader_path/", "@executable_path/")):
        return True
    if path.startswith("@rpath/"):
        if file_path is None:
            return True
        return rpath_resolves(file_path, path[len("@rpath/"):])
    return False


def is_signed(path):
    """文件里有没有有效的代码签名。

    arm64 上 dyld 拒绝加载**未签名**的 Mach-O，而症状极具误导性：它不会说
    "unsigned"，而是把同名符号解析到系统里另一份库上，于是报
    `Symbol not found: _libiconv`（2026-11-24 的 gwget / libidn2 就是这样）。
    conda 的产物普遍没签名，所以「位置无关」还不够 —— 必须同时签过，
    客户端才真的可以一步不做。
    """
    return subprocess.run(["codesign", "--verify", path],
                          capture_output=True).returncode == 0


def is_position_independent_id(value):
    """install name（LC_ID_DYLIB）是否已经就位。

    ID 是"别人加载我时用的名字"，不参与本次加载路径的解析，所以
    `@rpath/<文件名>` 本来就是惯例写法，不要求它能解析得到 —— 只有**引用**
    那边才查解析（见 is_position_independent）。
    """
    return value.startswith(("@loader_path/", "@executable_path/", "@rpath/"))


def needs_conda_libiconv(path):
    """产物是否用了只有 conda 那份 libiconv 才导出的符号。

    判据是符号名不是文件名：`libiconv`/`libiconv_open`/`libiconv_close` 只有
    conda 那份导出；`iconv`/`iconv_open`/`iconv_close` 两组都该留在系统那份。
    """
    code, out = run(["nm", "-u", path])
    if code != 0:
        return False
    for line in out.splitlines():
        symbol = line.strip()
        if symbol in ("_libiconv", "_libiconv_open", "_libiconv_close", "_libiconv_open_into"):
            return True
    return False


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
        conda_libiconv = None

        for ref in references(path):
            if is_system(ref):
                # 系统库不动，只有一个例外：产物用的是 conda 那份 libiconv 才导出的
                # 符号（_libiconv*），而系统那份没有 —— 那种必须改指依赖树里的
                # libiconv，否则装完就是 "Symbol not found: _libiconv"。
                if ref != "/usr/lib/libiconv.2.dylib":
                    continue
                if conda_libiconv is None:
                    conda_libiconv = needs_conda_libiconv(path)
                if not conda_libiconv:
                    continue
            elif is_position_independent(ref, path):
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

        if current_id and not is_position_independent_id(current_id):
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

    unsigned = [path for path in iter_macho(root) if not is_signed(path)]

    if check_only:
        if actions or unsigned:
            if actions:
                print(f"🌊 Not position-independent: {len(actions)} absolute reference(s)/identifier(s)")
                for file_path, kind, old, _new in actions[:20]:
                    print(f"🌊   {os.path.relpath(file_path, root)}: {kind} {old}")
            if unsigned:
                print(f"🌊 Unsigned Mach-O: {len(unsigned)} file(s) (dyld refuses those on Apple silicon)")
                for file_path in unsigned[:20]:
                    print(f"🌊   {os.path.relpath(file_path, root)}")
            return 1
        print(f"🌊 OK: all Mach-O files are position-independent and signed ({root})")
        return 0

    if not actions and not unsigned:
        print(f"🌊 Already position-independent and signed, nothing to do ({root})")
        return 0

    # 只差签名的那批：没有引用要改，但 arm64 上不签就不能加载
    if unsigned and sign:
        print(f"🌊 Signing {len(unsigned)} unsigned Mach-O file(s)")
        for path in unsigned:
            if not is_signed(path) and subprocess.run(
                    ["codesign", "--force", "--sign", "-", path],
                    capture_output=True).returncode != 0:
                print(f"🌊 Error: codesign failed: {os.path.relpath(path, root)}")
                return 1

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
