#!/usr/bin/env python3

# check_domain_defaults.py
# 比对 config/envvar.py（唯一来源）与两份 shell 脚本里的域名默认值。
#
# install.sh 与 selfupdate.sh 各带一份域名块 —— 它们都是被 curl 下来直接执行的，
# 没有本地文件可以 source，所以那几行只能内联。三处必须同源，否则 shell 下载的
# 地址会和 Python 请求的地址不一样，而这种漂移只在特定路径上才暴露，最难查。
#
# 扫的是 envvar.DOMAINS 这张表，不是某个文件的源码行：名字与默认值改了，这里
# 自动跟着查；shell 里多出一个表上没有的 MACWAVE_*_DOMAIN，也会被点出来。
#
# 用法：python3 scripts/check_domain_defaults.py [仓库根目录]

import re
import sys
from pathlib import Path

# shell 只需要这三个（索引与二进制都在 Python 侧取）。
SHELL_KINDS = ("core", "selfupdate", "python")

SHELL_FILES = ("lib/install.sh", "lib/selfupdate.sh")

# shell 里「变量名 + 默认值」的写法：${MACWAVE_CORE_DOMAIN:-https://…}
DEFAULT_RE = r'\$\{%s:-([^}"]*)\}'
# 任何 MACWAVE_*_DOMAIN 的出现（用来发现表上没有的名字）
ANY_DOMAIN_RE = re.compile(r"MACWAVE_[A-Z0-9_]*_DOMAIN")


def main():
    repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(repo / "config"))
    import envvar

    problems = 0

    for script in SHELL_FILES:
        path = repo / script
        if not path.exists():
            print(f"  {script}: missing")
            problems += 1
            continue
        text = path.read_text()

        for kind in SHELL_KINDS:
            name = envvar.name(kind)
            expected = envvar.default(kind)
            match = re.search(DEFAULT_RE % re.escape(name), text)
            actual = match.group(1) if match else None
            if actual != expected:
                print(f"  {script}: {name} = {actual!r}, "
                      f"config/envvar.py = {expected!r}")
                problems += 1

        # pip 索引也是 shell 内联的默认值
        match = re.search(DEFAULT_RE % re.escape(envvar.PIP_INDEX), text)
        actual = match.group(1) if match else None
        if actual != envvar.PIP_DEFAULT:
            print(f"  {script}: {envvar.PIP_INDEX} = {actual!r}, "
                  f"config/envvar.py = {envvar.PIP_DEFAULT!r}")
            problems += 1

        # 反过来查：shell 里出现了一个 envvar 不认识的名字
        known = {envvar.name(kind) for kind in envvar.DOMAINS}
        known.add(envvar.PIP_INDEX)
        for found in sorted(set(ANY_DOMAIN_RE.findall(text)) - known):
            print(f"  {script}: {found} 不在 config/envvar.py 里（拼错或没有登记）")
            problems += 1

    # 名字本身也要对得上：shell 只认 MACWAVE_*_DOMAIN 这种形状
    for kind in envvar.kinds():
        name = envvar.name(kind)
        if not (name.startswith("MACWAVE_") and name.endswith("_DOMAIN")):
            print(f"  envvar: {kind} 的变量名 {name} 不像一个域名变量")
            problems += 1

    if problems:
        print(f"  {problems} mismatch(es): shell and config/envvar.py disagree "
              f"on where files come from")
        return 1

    print(f"  {len(SHELL_FILES)} shell files x {len(SHELL_KINDS)} domains match "
          f"config/envvar.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
