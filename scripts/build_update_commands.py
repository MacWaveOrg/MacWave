#!/usr/bin/env python3

# build_update_commands.py
# 生成 macwavedata/<版本>/update_commands.sh。
#
# 为什么要有生成器：脚本对客户端承诺了一整套环境变量契约，还要处理「首次安装」
# 与「从上一版升级」两种情形。手写容易漏掉某一路径，而漏掉的后果是某个文件没被
# 下载 —— 装完之后某条命令才 ModuleNotFoundError。
#
# 两种清单的区别：
#   full  首次安装（或修复受损安装）要的**全部**文件
#   delta 从上一版升级时**变动过**的文件
# 客户端把「安装目录里有没有 lib/wave.py」作为两者的判据。之所以要两个，
# 是因为只列变化不足以支持全新安装 —— 没变的文件在首次安装时一个都不存在。
#
# 用法：
#   python3 scripts/build_update_commands.py \
#       --version 4.0.0 \
#       --out ../Selfupdate/macwavedata/4.0.0/update_commands.sh
#
#   --delta 省略时等于 full（新版本首次发布时的正常情形）。
#   --files 省略时按 --ref 指向的仓库树生成。

import argparse
import subprocess
import sys
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent

# 这些目录下的文件装进安装树；其余（docs、scripts、.github、notes）不参与安装。
INSTALLED_DIRS = ("lib", "pkg", "surfboard")

# 运行时由客户端生成、不从仓库复制的文件：
#   lib/wave        启动器，write_launcher 按私有 venv 与解释器路径生成
#   lib/install.sh  安装器装自己没意义（每次都是从远端执行的）
#   lib/uninstall.sh 同理
EXCLUDED = {
    "lib/wave",
    "lib/install.sh",
    "lib/uninstall.sh",
}


def files_from_git(ref):
    entries = []
    for directory in INSTALLED_DIRS:
        result = subprocess.run(
            ["git", "-C", str(REPO_DIR), "ls-tree", "--name-only", f"{ref}:{directory}"],
            capture_output=True, text=True)
        if result.returncode != 0:
            print(f"🌊 Error: cannot list {directory} at {ref}", file=sys.stderr)
            return None
        for name in result.stdout.splitlines():
            name = name.strip()
            if not name or name == "__pycache__":
                continue
            repo_path = f"{directory}/{name}"
            if repo_path in EXCLUDED:
                continue
            entries.append(repo_path)
    return sorted(entries)


def want_lines(paths):
    lines = []
    for path in paths:
        executable = "1" if path.endswith(".sh") else "0"
        lines.append(f"    want {path} {executable}")
    return "\n".join(lines)


TEMPLATE = open(Path(__file__).resolve().parent / "update_commands.template.sh").read()


def main():
    parser = argparse.ArgumentParser(description="Generate update_commands.sh for one release.")
    parser.add_argument("--version", required=True, help="target version, e.g. 4.0.0")
    parser.add_argument("--branch", default="", help="code branch; defaults to major.minor of --version")
    parser.add_argument("--ref", default="HEAD", help="git ref to read the file list from")
    parser.add_argument("--files", nargs="*", default=None, help="full file list (default: from --ref)")
    parser.add_argument("--delta", nargs="*", default=None,
                        help="changed files since the previous release (default: same as --files)")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    branch = args.branch or ".".join(args.version.split(".")[:2])
    if not branch:
        print("🌊 Error: cannot derive a branch; pass --branch.", file=sys.stderr)
        return 1

    files = args.files
    if not files:
        files = files_from_git(args.ref)
        if files is None:
            return 1
    if not files:
        print("🌊 Error: the file list is empty.", file=sys.stderr)
        return 1

    delta = args.delta if args.delta else files
    unknown = [path for path in delta if path not in files]
    if unknown:
        print(f"🌊 Error: --delta names files missing from the full list: {unknown}", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(TEMPLATE
                        .replace("@@VERSION@@", args.version)
                        .replace("@@BRANCH@@", branch)
                        .replace("@@FULL@@", want_lines(files))
                        .replace("@@DELTA@@", want_lines(delta)))
    args.out.chmod(0o755)

    print(f"🌊 {args.out}")
    print(f"   version {args.version}  branch {branch}")
    print(f"   full {len(files)} file(s), delta {len(delta)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
