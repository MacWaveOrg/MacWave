#!/usr/bin/env python3

# querier.py
# 查询依赖是否已安装，以及解析 `依赖名@版本号` 形式的依赖引用。
# 依赖目录结构：BASE_DIR/deps/{依赖引用名}/{依赖引用名}@{版本号}/

import sys

# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

from configpaths import assert_inside, load_base_dir, require_safe_token


BASE_DIR = load_base_dir()
DEPS_DIR = BASE_DIR / "deps"


# -------------------- 查询 --------------------

def dep_owner_dir(dep_name):

    # 依赖名目录，同一依赖的所有版本都放在这里。

    dep_name = require_safe_token(dep_name, "dependency name")
    return DEPS_DIR / dep_name


def dep_dir(dep_name, dep_version):

    # 依赖具体版本的安装目录。

    dep_name = require_safe_token(dep_name, "dependency name")
    dep_version = require_safe_token(dep_version, "dependency version")
    path = DEPS_DIR / dep_name / f"{dep_name}@{dep_version}"
    assert_inside(path, DEPS_DIR, "dependency path")
    return path


def is_installed(dep_name, dep_version):

    # 安装目录存在、且已写入 _DEPS 才算安装完成。
    # _DEPS 是安装流程的最后一步，用它判断可避免中途失败留下的空目录被误判为已安装。

    target_dir = dep_dir(dep_name, dep_version)
    if not target_dir.is_dir():
        return False
    return (target_dir / "_DEPS").is_file()


def installed_versions(dep_name):

    # 列出某个依赖在本地的所有已安装版本目录名，如 ["openssl@3.0.15"]。

    owner_dir = dep_owner_dir(dep_name)
    if not owner_dir.is_dir():
        return []
    return sorted([entry.name for entry in owner_dir.iterdir() if entry.is_dir()])


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
