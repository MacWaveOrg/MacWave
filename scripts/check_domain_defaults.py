#!/usr/bin/env python3

# check_domain_defaults.py
# 比对 lib/domains.py 与两份 shell 脚本里的域名默认值。
#
# install.sh 与 selfupdate.sh 各带一份域名块（它们都是被 curl 下来直接执行的，
# 没有本地文件可以 source），domains.py 是 Python 侧的那一份。三处必须同源，
# 否则 shell 下载的地址会和 Python 请求的地址不一样 —— 这种漂移只在特定路径上
# 才会暴露，最难查，所以用脚本盯着。
#
# 用法：python3 scripts/check_domain_defaults.py [仓库根目录]

import re
import sys
from pathlib import Path

DEFAULTS_RE = re.compile(r'^\s+"(api|bottle|deps|core|python|selfupdate|sourcecode)":\s+"([^"]*)",')

# shell 只有这三个（索引与二进制都在 Python 侧用）
SHELL_VARS = {
    "core": "MACWAVE_CORE_DOMAIN",
    "selfupdate": "MACWAVE_SELFUPDATE_DOMAIN",
    "python": "MACWAVE_PYTHON_DOMAIN",
}

SHELL_FILES = ("lib/install.sh", "lib/selfupdate.sh")


def python_defaults(repo):
    values = {}
    for line in (repo / "lib" / "domains.py").read_text().splitlines():
        match = DEFAULTS_RE.match(line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def shell_default(repo, script, env_name):
    text = (repo / script).read_text()
    match = re.search(r'%s:-([^}"]*)' % env_name, text)
    return match.group(1) if match else None


def main():
    repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    defaults = python_defaults(repo)

    problems = 0
    for script in SHELL_FILES:
        for kind, env_name in SHELL_VARS.items():
            expected = defaults.get(kind)
            actual = shell_default(repo, script, env_name)
            if actual != expected:
                print(f"  {script}: {env_name} = {actual!r}, lib/domains.py = {expected!r}")
                problems += 1

    if problems:
        print(f"  {problems} mismatch(es): shell and Python disagree on where files come from")
        return 1

    print(f"  {len(SHELL_FILES)} shell files x {len(SHELL_VARS)} domains match lib/domains.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
