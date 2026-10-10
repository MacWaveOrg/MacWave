#!/usr/bin/env python3

# depsversionparser.py
# 负责依赖引用的解析与依赖版本号的比较逻辑，版本比较复用 pkgversionparser.py。

import sys

from configpaths import require_safe_token

# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'

# -------------------- 依赖库检查 --------------------

try:
    from pkgversionparser import (
        is_special_version,
        safe_parse_pkg_version,
        sort_versions,
        get_max_version,
    )
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'pkgversionparser' module is not available.{RESET}")
    sys.exit(1)


# -------------------- 引用解析 --------------------

def parse_dep_ref(dep_ref):

    # 依赖引用强制为 {依赖名}@{版本号}，不合法直接报错退出。

    text = str(dep_ref).strip().strip('"').strip()

    if '@' not in text:
        print(f"{RED_BOLD}🌊 Error: Invalid dependency '{dep_ref}' in deps field.{RESET}")
        print(f"{RED_BOLD}🌊 Expected format: {{dep}}@{{version}}{RESET}")
        sys.exit(1)

    dep_name, dep_version = text.split('@', 1)
    dep_name = dep_name.strip()
    dep_version = dep_version.strip()

    if not dep_name or not dep_version:
        print(f"{RED_BOLD}🌊 Error: Invalid dependency '{dep_ref}' in deps field.{RESET}")
        print(f"{RED_BOLD}🌊 Expected format: {{dep}}@{{version}}{RESET}")
        sys.exit(1)

    # 依赖名与版本号来自远端数据，之后要拼进目录路径，统一过白名单
    return (require_safe_token(dep_name, "dependency name"),
            require_safe_token(dep_version, "dependency version"))


def parse_dep_refs(dep_refs):

    # 批量解析依赖引用，跳过空行，返回按原顺序排列的 (名字, 版本号) 列表。

    parsed = []
    for dep_ref in dep_refs:
        if not str(dep_ref).strip():
            continue
        parsed.append(parse_dep_ref(dep_ref))
    return parsed


def get_latest_version(versions):

    # 取最高版本号，复用 pkgversionparser.py 的排序规则。

    return get_max_version(versions)
