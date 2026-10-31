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
#
#   --new 列出「上一版还不存在」的文件。它们会被排到 delta 的**最前面**，
#   这不是排版偏好：新模块常被改动过的老模块 import，若旧模块先落地、新模块
#   后落地，中途一次网络失败就会留下「能 import 的目录、但模块不在」的安装，
#   wave 从此起不来，连重跑 selfupdate 都做不到。先下新文件，最坏也只是
#   老逻辑继续跑，重试即可。

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
            if not name:
                continue
            entries.append(f"{directory}/{name}")
    return sorted(entries)


def sanitize(paths, source):
    """把一份原始清单收拾成能装的文件清单，返回 (保留的, [(被丢掉的, 原因)])。

    必须在这里过滤，而不是只在上游的 files_from_git 里 —— 发版时用 `--files`
    传入一份 `find` 的结果是常见做法，而 find 会把工作区里的 __pycache__ 也列
    进来（git 里其实没有这些目录）。2026-10-30 的 4.1.1 就是这么发的：清单里混进
    了 pkg/__pycache__ 与 surfboard/__pycache__，客户端更新时对两个不存在的路径
    各重试 3 次再报 404，用户看到一堆红字才更新完成。

    同一次事故里 `--files` 也绕过了 EXCLUDED（lib/install.sh 等三份被当成普通
    文件下载并覆盖了安装目录里的副本）。两个过滤器都放在这里，才不会因为换了
    入口就漏。
    """
    kept = []
    dropped = []
    for path in paths:
        path = (path or "").strip()
        if not path:
            continue
        parts = path.split("/")
        if "__pycache__" in parts:
            dropped.append((path, "字节码缓存目录，git 里没有"))
            continue
        if path.endswith(".pyc"):
            dropped.append((path, "字节码文件，git 里没有"))
            continue
        if path.rstrip("/") in EXCLUDED:
            dropped.append((path, "运行时由客户端生成或不该自装"))
            continue
        if parts[0] not in INSTALLED_DIRS:
            dropped.append((path, f"不在 {INSTALLED_DIRS} 之下"))
            continue
        kept.append(path)
    return sorted(kept), dropped


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
    parser.add_argument("--new", nargs="*", default=None,
                        help="files that did not exist in the previous release; emitted first so a "
                             "half-finished update still has every module it imports")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    branch = args.branch or ".".join(args.version.split(".")[:2])
    if not branch:
        print("🌊 Error: cannot derive a branch; pass --branch.", file=sys.stderr)
        return 1

    raw_files = args.files
    source = "--files"
    if not raw_files:
        raw_files = files_from_git(args.ref)
        source = f"git {args.ref}"
        if raw_files is None:
            return 1
    if not raw_files:
        print("🌊 Error: the file list is empty.", file=sys.stderr)
        return 1

    # 不管清单来自 --files 还是 git，都过同一道过滤（见 sanitize 的说明）
    files, dropped = sanitize(raw_files, source)
    if not files:
        print("🌊 Error: the file list is empty after filtering.", file=sys.stderr)
        return 1

    if args.delta:
        delta, dropped_delta = sanitize(args.delta, "--delta")
        dropped = dropped + dropped_delta
        # 空的 delta 不能放行：install_delta 里一条 want 都没有，脚本瞬间成功返回，
        # 客户端于是写 VERSION.json —— 版本号前进了，文件一个都没换。与「文件下不到
        # 却报成功」是同一类故障，只是更难发现（连报错都没有）。
        if not delta:
            print("🌊 Error: every entry in --delta was filtered out; "
                  "an empty delta would silently upgrade nothing.", file=sys.stderr)
            return 1
        unknown = [path for path in delta if path not in files]
        if unknown:
            print(f"🌊 Error: --delta names files missing from the full list: {unknown}",
                  file=sys.stderr)
            return 1
    else:
        delta = files

    if args.new:
        fresh, dropped_new = sanitize(args.new, "--new")
        dropped = dropped + dropped_new
        fresh = [path for path in fresh if path in delta]
        if fresh:
            # 去重后再拼接：--new 里可能有已列在 delta 的更前面的项
            delta = fresh + [path for path in delta if path not in fresh]

    if dropped:
        print(f"🌊 Dropped {len(dropped)} entries that must not be installed:", file=sys.stderr)
        for path, why in dropped:
            print(f"     - {path}  ({why})", file=sys.stderr)

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
