#!/usr/bin/env python3

# backfill_file_field.py
# 给 infosource 的版本记录补上 4.0 需要的 file 字段。
#
# 4.0 只从 Bottle / Deps 取二进制，文件名因此由索引给出（见 docs/TECHNICAL-GUIDE.md
# 的 5.2.1）。3.x 的记录只有 url，没有 file，于是这里把 url 的最后一段取出来当文件名 ——
# 这也是 3.x 客户端原本就在用的那个名字，所以补出来的值与过去的实际行为一致。
#
# 用法：
#   python3 scripts/backfill_file_field.py --data-dir <infosource>           只报告，不改
#   python3 scripts/backfill_file_field.py --data-dir <infosource> --write   就地写入
#
# 只处理「有 url 但没有 file」的记录；已经有 file 的一律不动，
# 所以重复运行是安全的。@common 这类元数据记录没有 url，自然被跳过。

import argparse
import re
import sys
from pathlib import Path

# 版本记录里我们关心的三行。file 放在 sha256 之后、url 之前：
# 读的人先看到「下什么」，再看到「上游在哪」。
SHA_RE = re.compile(r'^sha256:\s*"([^"]+)"\s*$')
URL_RE = re.compile(r'^url:\s*"([^"]+)"\s*$')
FILE_RE = re.compile(r'^file:\s*"([^"]+)"\s*$')

# 有这些扩展名的会被 pkgunzip.sh 当压缩包解；没有扩展名的是一个单独的裸可执行文件，
# 安装器同样支持（format_test 里的 test_bin_no_ext 就是这一路），所以不算异常。
# 这里只用来在输出里把它们单独数一下 —— 数量突然变化通常意味着上游换了产物形态。
ARCHIVE_SUFFIXES = (".zip", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
                    ".tar", ".gz", ".bz2", ".xz", ".conda")


def version_records(data_dir):
    # 版本记录都在 pkg/pkginfo_<arch>/<包名>/ 与 deps/depsinfo_<arch>/<依赖名>/ 下，
    # 文件名形如 _<名字>@<版本号>；元数据记录叫 _<名字>@common。
    for root in (data_dir / "pkg", data_dir / "deps"):
        if not root.is_dir():
            continue
        for path in sorted(root.glob("*/*/_*@*")):
            if path.name.endswith("@common"):
                continue
            yield path


def backfill(path, write):
    lines = path.read_text().splitlines()
    if any(FILE_RE.match(line) for line in lines):
        return None   # 已经有了，不动

    url = None
    url_index = None
    sha_index = None
    for index, line in enumerate(lines):
        if url_index is None and URL_RE.match(line):
            url, url_index = URL_RE.match(line).group(1), index
        if sha_index is None and SHA_RE.match(line):
            sha_index = index

    if url is None:
        return ("no-url", path)

    name = url.rstrip("/").split("/")[-1]
    if not name:
        return ("no-name", path)
    raw_binary = not name.endswith(ARCHIVE_SUFFIXES)

    entry = f'file: "{name}"'
    # 放在 sha256 之后（保持 sha256 仍是第一行，校验器与会话记录都靠它）；
    # 没有 sha256 的记录就放在 url 之前。
    insert_at = (sha_index + 1) if sha_index is not None else url_index
    lines.insert(insert_at, entry)

    if write:
        path.write_text("\n".join(lines) + "\n")
    return ("raw-binary" if raw_binary else "ok", path)


def main():
    parser = argparse.ArgumentParser(description="Add the file field 4.0 needs to index records.")
    parser.add_argument("--data-dir", required=True, type=Path,
                        help="path to a checkout of MacWaveOrg/infosource")
    parser.add_argument("--write", action="store_true",
                        help="write the changes (default: report only)")
    args = parser.parse_args()

    if not (args.data_dir / "pkg").is_dir():
        print(f"🌊 Error: {args.data_dir} does not look like the infosource repository.")
        return 1

    counts = {"ok": 0, "raw-binary": 0, "no-url": 0, "no-name": 0}
    problems = []
    for path in version_records(args.data_dir):
        result = backfill(path, args.write)
        if result is None:
            continue
        kind, failed = result
        counts[kind] += 1
        if kind in ("no-url", "no-name"):
            problems.append((kind, failed))

    verb = "added" if args.write else "would add"
    print(f"🌊 {verb} file: to {counts['ok']} record(s)")
    if counts["raw-binary"]:
        print(f"🌊 {counts['raw-binary']} of them name a bare executable (no archive suffix)")

    for kind, path in problems:
        reason = {
            "no-url": "no url field",
            "no-name": "url has no file name",
        }[kind]
        print(f"🌊   skipped {path}: {reason}")

    if not args.write and counts["ok"]:
        print("🌊 Re-run with --write to apply.")

    # 跳过的那些需要人看一眼：它们要么缺数据，要么产物格式需要新增解压分支
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
