#!/usr/bin/env python3

# sync_latest_pointer.py
# 让数据仓库的 latest.toml 与「实际存在的版本目录」保持一致。
#
# 为什么需要：latest.toml 里的 version 是一个**手写的指针**，而真正决定装哪一版的是
# 那个版本目录。发布时只加了目录、忘了改指针，客户端就会一直装着旧版本 —— 而且不会
# 报错，只是「怎么更新都没变」。这类故障很难从现象追到原因。
#
# 做法：扫对应子目录里的版本目录，取最高版本，然后
#   --check  只报告，不一致就退出 1（给 PR 与定时任务用，不改任何文件）
#   默认     就地改写 latest.toml 里的 version（以及 branch = 大版本.次版本）
#
# 只改这两行，其余内容（注释、release_date、build_number）原样保留。

import argparse
import re
import sys
from pathlib import Path

# 版本目录名必须是纯数字段：3.14.9、4.0.0、2.5
VERSION_DIR_RE = re.compile(r'^\d+(?:\.\d+)*$')


def version_key(value):
    # 只比数字段，补齐到四位：2.3 == 2.3.0，"2.10" 大于 "2.9"
    parts = [int(part) for part in re.findall(r'\d+', str(value))]
    while len(parts) < 4:
        parts.append(0)
    return parts


def version_dirs(subdir, require):
    # 返回 [(版本, 目录)]，只收「看起来是版本号、且真的完整」的目录。
    # 要求 require 文件存在：宁可报「没有可用版本」，也不要把指针指向半成品。
    found = []
    for entry in sorted(subdir.iterdir()):
        if not entry.is_dir() or not VERSION_DIR_RE.match(entry.name):
            continue
        if require and not (entry / require).is_file():
            continue
        found.append((entry.name, entry))
    return found


def read_field(text, name):
    match = re.search(rf'^{name}\s*=\s*"([^"]*)"', text, re.M)
    return match.group(1) if match else None


def replace_field(text, name, value):
    pattern = re.compile(rf'^({name}\s*=\s*)"[^"]*"', re.M)
    if pattern.search(text):
        return pattern.sub(lambda m: f'{m.group(1)}"{value}"', text, count=1)
    return text.rstrip("\n") + f'\n{name} = "{value}"\n'


def expected_branch(version):
    parts = version.split(".")
    if len(parts) < 2:
        return None
    return ".".join(parts[:2])


def main():
    parser = argparse.ArgumentParser(
        description="Keep a data repository's latest.toml in step with the version directories.")
    parser.add_argument("--data-dir", required=True, type=Path,
                        help="checkout of the data repository (contains <subdir>/latest.toml)")
    parser.add_argument("--subdir", required=True,
                        help="pythondata or macwavedata")
    parser.add_argument("--require", default="",
                        help="file that must exist inside a version directory, e.g. python_url.toml")
    parser.add_argument("--check", action="store_true",
                        help="report a mismatch and exit 1 instead of rewriting the file")
    args = parser.parse_args()

    subdir = args.data_dir / args.subdir
    latest = subdir / "latest.toml"
    if not subdir.is_dir():
        print(f"🌊 Error: {subdir} is not a directory")
        return 1
    if not latest.is_file():
        print(f"🌊 Error: {latest} is missing")
        return 1

    found = version_dirs(subdir, args.require)
    if not found:
        print(f"🌊 Error: no complete version directory under {subdir}"
              + (f" (each needs {args.require})" if args.require else ""))
        return 1

    highest = max(found, key=lambda item: version_key(item[0]))[0]
    text = latest.read_text()
    declared = read_field(text, "version")

    updated = text
    if declared != highest:
        updated = replace_field(updated, "version", highest)

    # branch 只对自更新数据有意义：代码分支跟着大版本.次版本走
    branch = expected_branch(highest)
    if read_field(updated, "branch") is not None and branch and read_field(updated, "branch") != branch:
        updated = replace_field(updated, "branch", branch)

    if updated == text:
        print(f"🌊 {args.subdir}/latest.toml is in sync (version {highest})")
        return 0

    if args.check:
        print(f"🌊 {args.subdir}/latest.toml points at {declared}, "
              f"but the newest complete directory is {highest}")
        print("🌊 Run scripts/sync_latest_pointer.py without --check to fix it.")
        return 1

    latest.write_text(updated)
    print(f"🌊 {args.subdir}/latest.toml updated: {declared} -> {highest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
