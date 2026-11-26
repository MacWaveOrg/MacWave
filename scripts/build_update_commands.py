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
import hashlib
import re
import subprocess
import sys
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent

# 这些目录下的文件装进安装树；其余（docs、scripts、.github、notes）不参与安装。
#
# 清单的唯一来源是 scripts/components.txt —— 与 lib/wave.py 的 sys.path、测试沙箱的
# 拷贝、CI 的工作目录共用同一份。加一个顶层组件只改那份文件。
# 清单由 scripts/components.py 读（与 components.sh 同源）。
sys.path.insert(0, str(Path(__file__).resolve().parent))
from components import names as component_names  # noqa: E402
import assets as asset_dirs  # noqa: E402

# 装进安装树的两类目录：
#   components  运行时可执行代码，会进 sys.path
#   assets      文档等资源，**不进 sys.path**
# 清单与 sys.path 因此不能共用一份 —— 把它们混在一起，`import` 就会去
# man/ 里找模块（找不到，但错误信息会指向一个莫名其妙的地方）。
COMPONENT_DIRS = tuple(component_names())
ASSET_DIRS = tuple(asset_dirs.names())
INSTALLED_DIRS = COMPONENT_DIRS + ASSET_DIRS
if not COMPONENT_DIRS:
    raise SystemExit("🌊 Error: scripts/components.txt lists no component directory.")

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
        # 必须递归：`git ls-tree` 不加 -r 时，子目录只会出现它的名字（如 `lib/net`），
        # 于是清单里多出一条「文件」，客户端去 curl 它必然 404 —— 安装直接失败。
        # 用 -r 之后列出的全是 blob（文件），tree 不会混进来。
        result = subprocess.run(
            ["git", "-C", str(REPO_DIR), "ls-tree", "-r", "--name-only", f"{ref}:{directory}"],
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
        # 资源目录里的 README.md / description.md 是写给**仓库读者**的说明，装进
        # 安装树没人读，但它一缺就会让整个安装失败 —— 2026-11-19 装 4.4.0 时，
        # Keys/README.md 的 404 直接把「镜像还没同步 core/4.4」变成了一个看起来像
        # 单文件问题的事故。
        #
        # 两个名字都列出来，是因为 `Keys/README.md` 已经改名成了
        # `Keys/description.md`（2026-11-19）：只排除其中一个，另一个就会悄悄回到
        # 清单里，把上面那个坑重新挖开。
        if parts[-1] in ("README.md", "description.md"):
            dropped.append((path, "给人看的说明文件，不进安装树"))
            continue
        if parts[0] not in INSTALLED_DIRS:
            dropped.append((path, f"不在 {INSTALLED_DIRS} 之下"))
            continue
        kept.append(path)
    return sorted(kept), dropped


def want_lines(paths, digests=None):
    """生成 `want <路径> <0|1> <sha256>` 三列。

    第三列是 4.4 起的实验性签名：哈希写进清单，客户端据此判断「下到的字节是不是
    发布时那一份」。列缺失或为空时客户端退回旧行为（只靠 TLS），所以老版本客户端
    看到三列也只是忽略第三列 —— 这一列是**纯加法**。
    """
    lines = []
    for path in paths:
        executable = "1" if path.endswith(".sh") else "0"
        digest = (digests or {}).get(path, "")
        lines.append(f"    want {path} {executable} {digest}".rstrip())
    return "\n".join(lines)


def file_digests(paths, repo, ref=None):
    """每个文件的 sha256；读不到就留空（那一行退回「不校验」）。

    ref 给定时读 git 对象里的字节（发布产物必须来自 tag / 分支，而不是工作区），
    否则读工作区 —— `--files` 模式就是这么用的，它本来就允许带未提交的内容。
    """
    digests = {}
    for path in paths:
        data = None
        if ref:
            result = subprocess.run(["git", "-C", str(repo), "cat-file", "blob", f"{ref}:{path}"],
                                    capture_output=True)
            if result.returncode == 0:
                data = result.stdout
        else:
            try:
                data = (repo / path).read_bytes()
            except OSError:
                data = None
        if data is not None:
            digests[path] = hashlib.sha256(data).hexdigest()
    return digests


def manifest_lines(paths, digests=None):
    """生成 files.txt 的一行：`<仓库内路径> <0|1> <sha256>`（空白分隔，无 shell 语法）。

    这是 4.7 起的**数据形态**清单：逻辑全在 lib/install.sh 里，这里只描述
    「这一版的安装树应该长什么样」。与 4.6 及更早的 update_commands.sh 相比：

      * 不再是可执行脚本 —— 没有人会去 bash 它，也就不存在「执行了什么」的疑问；
      * 不再区分 full / delta —— 客户端拿本地的 sha256 与清单逐条比对，
        只下载不一致的那些，比维护两份清单更准（手工删掉一个文件也能自愈）；
      * 路径里的空格由 `` 转义（目前没有这种路径，但格式先定死，
        以后加进来不必改客户端）。
    """
    lines = []
    for path in paths:
        executable = "1" if path.endswith(".sh") else "0"
        digest = (digests or {}).get(path, "-")
        lines.append(f"{path.replace(' ', chr(92) + ' ')} {executable} {digest}")
    return "\n".join(lines)


def list_lines(paths):
    """全量清单的裸路径，一行一个，给脚本里的 tree_complete() 用。

    与 want_lines 分开写：判断「安装树完整吗」只需要路径，不需要 +x 标记。
    两者必须来自同一个 files 列表 —— 各写一份就会漂移，而漂移的后果是
    「自检说完整、实际缺文件」（比不检查更糟）。
    """
    return "\n".join(paths)


def agreement_id(ref):
    """这一版的用户协议标识，从 `<ref>:lib/selfupdate.py` 读 —— 唯一来源仍是那里。

    生成器不自己抄一份日期：两份日期迟早会不一致，后果是「问的是新协议、记下的
    却是旧标识」，于是下次再问一遍（AGENTS.md 里那条规矩说的是同一件事）。

    读不到（老 ref 里没有这个常量）就返回空 —— 生成的脚本会自动放行闸门，
    与「这一版没带协议信息」等价，不会把老版本卡死。
    """
    text = ""
    if ref:
        result = subprocess.run(["git", "-C", str(REPO_DIR), "show", f"{ref}:lib/selfupdate.py"],
                                capture_output=True, text=True)
        if result.returncode == 0:
            text = result.stdout
    if not text:
        try:
            text = (REPO_DIR / "lib/selfupdate.py").read_text()
        except OSError:
            text = ""
    match = re.search(r'^AGREEMENT_ID = "([^"]*)"$', text, re.MULTILINE)
    return match.group(1) if match else ""


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
    parser.add_argument("--agreement-id", default=None,
                        help="override the agreement id baked into the script "
                             "(default: read AGREEMENT_ID from --ref's lib/selfupdate.py)")
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
        # 去重后拼接：--new 里可能有重复项，也可能已列在 delta 的更前面
        fresh = list(dict.fromkeys(path for path in fresh if path in delta))
        if fresh:
            delta = fresh + [path for path in delta if path not in fresh]

    if dropped:
        print(f"🌊 Dropped {len(dropped)} entries that must not be installed:", file=sys.stderr)
        for path, why in dropped:
            print(f"     - {path}  ({why})", file=sys.stderr)

    digests = file_digests(files, REPO_DIR, None if source == "--files" else args.ref)
    missing = [path for path in files if path not in digests]
    if missing:
        # 没有哈希 = 这一行不校验。发布时静默漏掉几个，等于签名只覆盖一半。
        print(f"🌊 Warning: no sha256 for {len(missing)} file(s): {missing}", file=sys.stderr)

    baked_agreement = args.agreement_id
    if baked_agreement is None:
        baked_agreement = agreement_id(None if source == "--files" else args.ref)
    if not baked_agreement:
        # 空着等于闸门放行。发布时静默漏掉，就等于这一版不会被任何人问到协议。
        print("🌊 Warning: no AGREEMENT_ID for this ref; the agreement gate in the "
              "generated script will let every update through.", file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(TEMPLATE
                        .replace("@@AGREEMENT_ID@@", baked_agreement)
                        .replace("@@VERSION@@", args.version)
                        .replace("@@BRANCH@@", branch)
                        .replace("@@FULL@@", want_lines(files, digests))
                        .replace("@@FULL_FILES@@", list_lines(files))
                        .replace("@@DELTA@@", want_lines(delta, digests)))
    args.out.chmod(0o755)

    # files.txt：与上面那份同源、同时生成。install.sh 只读它，不再 bash 任何东西。
    manifest_path = args.out.parent / "files.txt"
    manifest_path.write_text(manifest_lines(files, digests) + "\n")

    print(f"🌊 {args.out}")
    print(f"   version {args.version}  branch {branch}")
    print(f"   full {len(files)} file(s), delta {len(delta)} file(s)")
    # 这一行是给 latest.toml 用的：客户端先验 latest.toml 的签名，再用这里记下的
    # 哈希确认「即将被 bash 执行的那个脚本」没被换过。
    print(f"   update_commands_sha256 = {hashlib.sha256(args.out.read_bytes()).hexdigest()}")
    print(f"   files.txt {manifest_path}")
    print(f"   files_sha256 = {hashlib.sha256(manifest_path.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
