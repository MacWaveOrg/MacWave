#!/usr/bin/env python3

# assets.py
# 资源目录清单的读取入口（Python 侧），清单本身在 scripts/assets.txt。
#
# 与 components.py 分开是**故意的**：那两份清单的用处不同 ——
# components 进 sys.path，assets 不进。合并成一份，早晚会有人把 man/ 加进
# 模块搜索路径，然后对着「No module named ...」猜半天。

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
LIST_FILE = SCRIPT_DIR / "assets.txt"


def names():
    """资源目录名，顺序即清单里的顺序。"""
    lines = LIST_FILE.read_text(encoding="utf-8").splitlines()
    found = [line.split("#", 1)[0].strip() for line in lines]
    return [name for name in found if name]


def paths(repo_dir=None):
    root = Path(repo_dir) if repo_dir else REPO_DIR
    return [root / name for name in names()]


if __name__ == "__main__":
    sys.exit(0 if names() else 1)
