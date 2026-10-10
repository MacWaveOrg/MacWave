#!/usr/bin/env python3

# configpaths.py
# 解析 MacWave 的配置目录。
#
# 安装目录决定配置写在哪：
#   - 系统级（/opt/macwave、/usr/local/macwave 等需要 sudo 的目录）
#     → /opt/macwave_config
#   - 用户级（~/.local/macwave 等无需 sudo 的目录）
#     → ~/.config/macwave_config
#
# 读取时系统级优先：只要 /opt/macwave_config/config.json 存在就用它，
# 否则才回落到 ~/.config/macwave_config —— 也就是优先跑系统级的 MacWave。

import json
import re
import sys
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'


# -------------------- 配置目录候选 --------------------

CONFIG_FILE_NAME = "config.json"
VERSION_FILE_NAME = "VERSION.json"

SYSTEM_CONFIG_DIR = Path("/opt/macwave_config")
USER_CONFIG_DIR = Path.home() / ".config" / "macwave_config"


def config_dir_candidates():
    # 系统级优先，其次用户级
    return [SYSTEM_CONFIG_DIR, USER_CONFIG_DIR]


# -------------------- 配置读取 --------------------

def _read_base_dir(config_file):
    # 读得到合法 base_dir 就返回 Path，否则返回 None
    try:
        with open(config_file, 'r') as handle:
            base_dir = json.load(handle).get("base_dir")
        return Path(base_dir) if base_dir else None
    except Exception:
        return None


def find_config_dir():
    # 第一个装了 MacWave 的配置目录（config.json 合法且含 base_dir）；都没装时返回 None
    for directory in config_dir_candidates():
        if _read_base_dir(directory / CONFIG_FILE_NAME) is not None:
            return directory
    return None


def load_base_dir():
    # 按系统级 → 用户级的顺序读取 base_dir，读到就返回
    for directory in config_dir_candidates():
        base_dir = _read_base_dir(directory / CONFIG_FILE_NAME)
        if base_dir is not None:
            return base_dir

    print(f"{RED_BOLD}🌊 Error: Configuration file not found or invalid.{RESET}")
    print(f"{RED_BOLD}🌊 Please run the install script again to reinstall MacWave.{RESET}")
    sys.exit(1)


# -------------------- 名字与版本号的安全校验 --------------------
#
# 包名、版本号、可执行文件名既来自命令行，也来自远端数据（@common / deps 字段），
# 之后会被拼进 URL 和文件路径，还会以换行分隔的长字符串形式交给 shell。
# 所以这里做统一的白名单校验，外加"最终路径必须在 BASE_DIR 之内"的兜底。

# 允许的字符：字母、数字、点、下划线、加号、减号，且必须以字母或数字开头。
# 刻意不含 / \ % @ : 空白 与换行——它们要么能改变目录层级（路径穿越），
# 要么能做 URL 注入（%2f 之类），要么能往 shell 里注入额外字段。
SAFE_TOKEN_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._+-]*\Z')


def is_safe_token(value):
    value = str(value)
    if not value or len(value) > 128:
        return False
    if '..' in value or value in ('-', '.'):
        return False
    return bool(SAFE_TOKEN_RE.match(value))


def require_safe_token(value, what):
    # 不合法直接退出：这类输入没有任何"宽松解释"的余地
    if not is_safe_token(value):
        print(f"{RED_BOLD}🌊 Error: Unsafe {what}: {value!r}{RESET}")
        print(f"{RED_BOLD}🌊 Allowed: letters, digits, and . _ + - (must start with a letter or digit).{RESET}")
        sys.exit(1)
    return str(value)


def assert_inside(path, root, what):
    # 归一化后确认路径没有跑到 root 外面（防 ../ 与软链接穿越）。
    # 只做校验、不改写调用方的路径，避免改变既有行为。
    resolved_root = Path(root).resolve()
    resolved = Path(path).resolve()
    if resolved != resolved_root and resolved_root not in resolved.parents:
        print(f"{RED_BOLD}🌊 Error: Unsafe {what} escapes {resolved_root}: {resolved}{RESET}")
        sys.exit(1)
    return resolved


# -------------------- 当前生效的配置 --------------------

CONFIG_DIR = find_config_dir() or SYSTEM_CONFIG_DIR
CONFIG_FILE = CONFIG_DIR / CONFIG_FILE_NAME
VERSION_FILE = CONFIG_DIR / VERSION_FILE_NAME


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    sys.exit(1)
