#!/usr/bin/env python3

# components.py

# 运行时组件清单的唯一读取入口（Python 侧）—— 清单本身在 scripts/components.txt，
# shell 侧见 scripts/components.sh。
#
# 为什么要有它：脚本要 import 出货模块（domains / tls / timeouts…）时，得先把组件
# 目录塞进 sys.path。以前这类脚本各写一句 `sys.path.insert(0, REPO/"lib")`，加一个
# 顶层组件（例如 net/）时它们全都静默失效 —— 报错是「找不到 domains」，指不到原因。

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
LIST_FILE = SCRIPT_DIR / "components.txt"


def names():
    """组件目录名，顺序即清单里的顺序。"""
    lines = LIST_FILE.read_text(encoding="utf-8").splitlines()
    found = [line.split("#", 1)[0].strip() for line in lines]
    return [name for name in found if name]


def paths(repo_dir=None):
    """组件目录的绝对路径。"""
    root = Path(repo_dir) if repo_dir else REPO_DIR
    return [root / name for name in names()]


def add_to_sys_path(repo_dir=None):
    """把全部组件目录加进 sys.path，返回加了哪几条。"""
    entries = [str(path) for path in paths(repo_dir)]
    sys.path[:0] = entries
    return entries
