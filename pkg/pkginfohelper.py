#!/usr/bin/env python3

# pkginfohelper.py
# 处理 wave 的 list / search / info 命令。

import os
import sys
import json
import platform
import re
from pathlib import Path

# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

CONFIG_FILE = Path("/opt/macwave_config/config.json")

def load_config():
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)
                base_dir = config.get("base_dir")
                if base_dir:
                    return Path(base_dir)
        except Exception:
            pass
    print(f"{RED_BOLD}🌊 Error: Configuration file not found or invalid.{RESET}")
    sys.exit(1)

BASE_DIR = load_config()
BIN_DIR = BASE_DIR / "bin"

# -------------------- 依赖库检查 --------------------

try:
    import requests
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    sys.exit(1)

try:
    from pkgversionparser import sort_versions
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'pkgversionparser' module is not available.{RESET}")
    sys.exit(1)


# -------------------- 辅助函数 --------------------

def get_arch():
    machine = platform.machine().lower()
    if machine in ["arm64", "aarch64"]:
        return "arm64"
    elif machine in ["x86_64", "amd64"]:
        return "amd64"
    else:
        print(f"{RED_BOLD}🌊 Error: Unknown Arch!{RESET}")
        sys.exit(1)


def parse_pkg_from_bin(dirname):
    
    # 从 bin 目录下的目录名解析出包名和版本。
    # 形如 ldid@2.1.5-procursus7 -> ("ldid", "2.1.5-procursus7")
    
    if "@" in dirname:
        name, version = dirname.split("@", 1)
        return name, version
    return dirname, None


def fetch_remote_versions(pkg_name, arch):
    
    # 通过 GitHub API 遍历 infosource 中的版本文件，返回所有可安装版本号列表。
    # API 必须显式带 ref=infosource，否则查到默认分支（main）会 404。
    
    api_url = f"https://api.github.com/repos/MacWaveOrg/MacWave/contents/pkg/pkginfo_{arch}/{pkg_name}?ref=infosource"
    try:
        resp = requests.get(api_url, timeout=30)
        if resp.status_code != 200:
            return []
        file_list = resp.json()
        versions = []
        for item in file_list:
            fname = item["name"]
            if fname.endswith("@common"):
                continue
            if "@" in fname:
                versions.append(fname.split("@")[1])
        return versions
    except Exception:
        return []


def fetch_remote_info(pkg_name, arch):
    
    # 从 infosource 拉取 @common 文件，返回描述信息。
    
    common_url = f"https://raw.githubusercontent.com/MacWaveOrg/MacWave/infosource/pkg/pkginfo_{arch}/{pkg_name}/_{pkg_name}@common"
    try:
        resp = requests.get(common_url, timeout=30)
        if resp.status_code != 200:
            return None
    except Exception:
        return None

    result = {}
    for key in ["des", "hom", "lic", "aut"]:
        match = re.search(rf'{key}:\s*"([^"]+)"', resp.text)
        if match:
            result[key] = match.group(1)
    return result


# -------------------- list --------------------

def handle_list():
    
    # 直接扫描 BASE_DIR/bin 目录下的子目录，列出所有已安装的包
    # （2.2 起每个包是一个 <包名>@<版本号> 目录）。
    
    if not BIN_DIR.exists():
        print("🌊 No packages installed yet.")
        return

    entries = sorted([f.name for f in BIN_DIR.iterdir() if f.is_dir()])
    if not entries:
        print("🌊 No packages installed yet.")
        return

    for name in entries:
        print(f"🌊 - {name}")


# -------------------- search --------------------

def handle_search(query):
    
    # 远程搜索 infosource 分支下所有包名，匹配查询词。
    
    arch = get_arch()

    # API 必须显式带 ref=infosource，否则查到默认分支（main）会 404
    api_url = f"https://api.github.com/repos/MacWaveOrg/MacWave/contents/pkg/pkginfo_{arch}?ref=infosource"

    try:
        resp = requests.get(api_url, timeout=30)
        if resp.status_code != 200:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch package list.{RESET}")
            print(f"{RED_BOLD}🌊 URL: {api_url}{RESET}")
            sys.exit(1)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
        sys.exit(1)

    all_packages = []
    for item in resp.json():
        if item["type"] == "dir":
            all_packages.append(item["name"])

    query_lower = query.lower()
    matches = [p for p in all_packages if query_lower in p.lower()]

    if not matches:
        print(f"🌊 No packages found matching '{query}'")
        return

    print(f"🌊 Found {len(matches)} package(s) matching '{query}':")
    for pkg in matches:
        print(f"🌊 - {pkg}")


# -------------------- info --------------------

def handle_info(pkg_name):
    
    # 先扫描本地 bin 目录，已安装则输出本地信息；
    # 未安装则拉远程 @common 文件。
    
    arch = get_arch()

    # 1. 扫描本地 bin 目录，找出所有该包的已安装版本
    # （2.2 起每个版本对应一个 <包名>@<版本号> 目录）
    installed_versions = []
    if BIN_DIR.exists():
        for f in BIN_DIR.iterdir():
            if f.is_dir():
                name, version = parse_pkg_from_bin(f.name)
                if name.lower() == pkg_name.lower() and version:
                    installed_versions.append(version)

    installed_versions = sort_versions(installed_versions)

    # 2. 拉取远程 @common
    remote = fetch_remote_info(pkg_name, arch)

    # 3. 拉取远程所有可安装版本
    available_versions = fetch_remote_versions(pkg_name, arch)
    available_versions = sort_versions(available_versions)

    # 4. 输出
    print(f"🌊 Name:               {pkg_name}")

    if remote:
        print(f"🌊 Author:             {remote.get('aut', 'Unknown')}")
        print(f"🌊 Description:        {remote.get('des', 'No description')}")
        if remote.get("hom"):
            print(f"🌊 Homepage:           {remote.get('hom')}")

    if installed_versions:
        print(f"🌊 Installed versions: {installed_versions[0]}")
        for ver in installed_versions[1:]:
            print(f"                       {ver}")
    else:
        print(f"🌊 Installed versions: None")

    if available_versions:
        print(f"🌊 Available versions: {available_versions[0]}")
        for ver in available_versions[1:]:
            print(f"                       {ver}")


# -------------------- 入口 --------------------

def handle_info_command(input_string):
  
    # 解析完整输入字符串（如 "wave info ldid"），分派到 list / search / info
  
    words = input_string.split()
    if len(words) < 2:
        print(f"{RED_BOLD}🌊 Error: Missing subcommand.{RESET}")
        sys.exit(1)

    subcommand = words[1].lower()

    if subcommand == "list":
        handle_list()
    elif subcommand == "search":
        if len(words) < 3:
            print(f"{RED_BOLD}🌊 Error: Missing search query.{RESET}")
            sys.exit(1)
        handle_search(words[2])
    elif subcommand == "info":
        if len(words) < 3:
            print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
            sys.exit(1)
        handle_info(words[2])
    else:
        print(f"{RED_BOLD}🌊 Error: Unknown subcommand '{subcommand}'.{RESET}")
        sys.exit(1)


if __name__ == "__main__":
    input_string = " ".join(sys.argv[1:])
    handle_info_command(input_string)
