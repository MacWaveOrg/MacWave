#!/usr/bin/env python3

# check_shared_blocks.py
# 「必须逐字节一致」的共享代码块，在这里逐个比对。
#
# 为什么需要它：MacWave 有三个脚本是「被 curl 下来直接执行」的独立文件 ——
#   lib/install.sh                  全新安装
#   lib/selfupdate.sh               4.7 → 4.8 及以后的升级
#   scripts/update_commands.template.sh   4.6 → 4.7 的升级（旧客户端执行新代码）
# 它们没法 source 同一份文件，只能各带一份副本；而副本会漂移，漂移的后果不是崩溃，
# 是「某一条路径上少了半句判断」——最难查的那一类。
#
# 做法：共享块在 scripts/shared/<名字>.sh 里维护唯一正文，用标记包起来：
#
#   # >>> SHARED: <名字>
#   ...
#   # <<< SHARED
#
# 本脚本从每个声明了该块的文件里把标记之间的内容取出来，与正本逐字节比较。
# 与 scripts/check_domain_defaults.py 是同一套思路：让「必须一样」这件事可执行。
#
# 用法：python3 scripts/check_shared_blocks.py [仓库根目录]

import sys
from pathlib import Path

START = "# >>> SHARED: "
END = "# <<< SHARED"

# 块名 → 必须带上这个块的脚本（相对仓库根）。新增块时在这里登记：
# 少登记一个，就等于允许那一路悄悄不用同步。
SYNC = {
    "legacy-config-action": (
        "lib/install.sh",
        "lib/selfupdate.sh",
        "scripts/update_commands.template.sh",
    ),
}


def extract(text, name):
    """取出标记之间的正文（不含标记行本身）；没有这个块返回 None。"""
    lines = text.splitlines()
    begin = None
    for index, line in enumerate(lines):
        if line.strip() == START + name:
            begin = index + 1
            continue
        if begin is not None and line.strip() == END:
            return "\n".join(lines[begin:index])
    if begin is not None:
        return None  # 有开头没结尾
    return None


def canonical(repo, name):
    path = repo / "scripts" / "shared" / f"{name.replace('-', '_')}.sh"
    if not path.is_file():
        return None, path
    block = extract(path.read_text(encoding="utf-8"), name)
    return block, path


def main():
    repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    problems = 0
    checked = 0

    for name, files in SYNC.items():
        block, source = canonical(repo, name)
        if block is None:
            print(f"  {source}: 找不到块 {name!r}（正本本身就不合格）")
            problems += 1
            continue

        for relative in files:
            path = repo / relative
            if not path.is_file():
                print(f"  {relative}: 文件不存在")
                problems += 1
                continue
            found = extract(path.read_text(encoding="utf-8"), name)
            checked += 1
            if found is None:
                print(f"  {relative}: 缺少 {name!r} 块（标记没写或没配对）")
                problems += 1
            elif found != block:
                print(f"  {relative}: {name!r} 块与 {source.name} 不一致")
                problems += 1

    if problems:
        print(f"  {problems} 处不一致：共享块的正本是 scripts/shared/，"
              f"改它、然后把同一段原样拷进上面每一个文件")
        return 1

    print(f"  {len(SYNC)} 个共享块 × {checked} 处副本全部一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
