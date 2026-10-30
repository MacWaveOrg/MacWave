#!/usr/bin/env python3

# pkginfohelper.py
# 处理 wave 的 list / search / info 命令。

import json
import os
import sys
import platform
import re

# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

from configpaths import load_base_dir, require_safe_token
import domains


def github_api_headers(url):
    # 与 pkg/pkginstaller.py 一致：有 token 就只给 api.github.com 带上，
    # 缓解未认证 60 次/小时的限流。
    if "api.github.com" not in url:
        return {}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        return {}
    return {"Authorization": f"Bearer {token}"}

BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"

# -------------------- 依赖库检查 --------------------

try:
    import requests
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    sys.exit(1)

try:
    from pkgversionparser import sort_versions
except ModuleNotFoundError as error:
    if error.name == "pkgversionparser":
        print(f"{RED_BOLD}🌊 Error: 'pkgversionparser' module is not available.{RESET}")
    else:
        print(f"{RED_BOLD}🌊 Error: Missing Python dependency '{error.name}'.{RESET}")
        print(f"{RED_BOLD}🌊 Install the required packages and try again:{RESET}")
        print(f"{YELLOW}   python3 -m pip install --user requests packaging rich{RESET}")
        print(f"{YELLOW}   (Homebrew's Python needs --break-system-packages){RESET}")
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
    
    # 通过索引列出可安装版本，返回所有可安装版本号列表。
    # 默认走 GitHub API 读 infosource，设了索引镜像时读镜像自己的清单
    # （见 domains.index_list_url）。
    
    pkg_name = require_safe_token(pkg_name, "package name")
    api_url = domains.index_list_url(arch, pkg_name)
    try:
        resp = requests.get(api_url, timeout=30, headers=github_api_headers(api_url))
        if resp.status_code != 200:
            return []
        versions = []
        for fname in domains.listing_names(resp.text):
            if fname.endswith("@common"):
                continue
            if "@" in fname:
                versions.append(fname.split("@")[1])
        return versions
    except Exception:
        return []


def fetch_remote_info(pkg_name, arch):
    
    # 从数据仓库拉取 @common 文件，返回 (解析后的字段, 原文)。
    #
    # 原文要留着：`wave info --raw` 输出的就是它 —— 想知道「作者名为什么是这样」时，
    # 看格式化之后的几行没有意义，得看索引里到底写了什么。
    # 拉不到时返回 (None, None)，调用方据此区分「没这条记录」和「有记录但没字段」。
    
    pkg_name = require_safe_token(pkg_name, "package name")
    common_url = f"{domains.api_domain()}/pkg/pkginfo_{arch}/{pkg_name}/_{pkg_name}@common"
    try:
        resp = requests.get(common_url, timeout=30)
        if resp.status_code != 200:
            return None, None
    except Exception:
        return None, None

    result = {}
    for key in ["des", "hom", "lic", "aut"]:
        match = re.search(rf'{key}:\s*"([^"]+)"', resp.text)
        if match:
            result[key] = match.group(1)
    return result, resp.text


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
    
    # 远程搜索索引里的所有包名，匹配查询词。
    # 默认走 GitHub API 读 infosource，设了索引镜像时读镜像自己的清单。
    
    arch = get_arch()

    api_url = domains.index_list_url(arch)

    try:
        resp = requests.get(api_url, timeout=30, headers=github_api_headers(api_url))
        if resp.status_code != 200:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch package list.{RESET}")
            # 用镜像时 api_url 里带凭据，直接打印等于把密码写进终端记录
            print(f"{RED_BOLD}🌊 URL: {domains.redact_url(api_url)}{RESET}")
            sys.exit(1)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
        sys.exit(1)

    all_packages = [name for name in domains.listing_names(resp.text, dirs_only=True) if name]

    query_lower = query.lower()
    matches = [p for p in all_packages if query_lower in p.lower()]

    if not matches:
        print(f"🌊 No packages found matching '{query}'")
        return

    print(f"🌊 Found {len(matches)} package(s) matching '{query}':")
    for pkg in matches:
        print(f"🌊 - {pkg}")


# -------------------- info --------------------

# -------------------- info 的输出格式 --------------------
#
# 三条机器可读格式共用一份数据，字段名与 `wave info` 的标签一一对应；
# --raw 例外，它给的是索引里的 @common 原文，用来回答「这个作者名哪来的」。

INFO_FORMATS = ("json", "yaml", "toml", "raw")


def info_fields(pkg_name, remote, installed_versions, available_versions):
    remote = remote or {}
    return {
        "name": pkg_name,
        "author": remote.get("aut"),
        "description": remote.get("des"),
        "homepage": remote.get("hom"),
        "license": remote.get("lic"),
        "installed": list(installed_versions),
        "available": list(available_versions),
        "latest": available_versions[0] if available_versions else None,
    }


def info_as_json(fields):
    return json.dumps(fields, indent=2, ensure_ascii=False)


def info_as_yaml(fields):
    # 标量一律走 json.dumps：JSON 的字符串写法是合法的 YAML 标量，
    # 这样引号、冒号、换行都不用自己处理。
    lines = []
    for key, value in fields.items():
        if value is None:
            continue
        if isinstance(value, list):
            if not value:
                lines.append(f"{key}: []")
                continue
            lines.append(f"{key}:")
            for item in value:
                lines.append(f"  - {json.dumps(item, ensure_ascii=False)}")
        else:
            lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
    return "\n".join(lines)


def info_as_toml(fields):
    lines = []
    for key, value in fields.items():
        if value is None:
            continue
        if isinstance(value, list):
            rendered = ", ".join(json.dumps(item, ensure_ascii=False) for item in value)
            lines.append(f"{key} = [{rendered}]")
        else:
            lines.append(f"{key} = {json.dumps(value, ensure_ascii=False)}")
    return "\n".join(lines)


def render_info(output_format, pkg_name, remote, record_text,
                installed_versions, available_versions):
    if output_format == "raw":
        # 索引里没有这条记录时没什么可打印的。打印空行等于让人以为「这条记录是空的」，
        # 而实际原因是「压根没有这条记录」—— 两者要分清楚。
        if record_text is None:
            print(f"{RED_BOLD}🌊 Error: {pkg_name} has no @common record in the index.{RESET}")
            print(f"{YELLOW}🌊 Next      wave info {pkg_name} --json prints what is available{RESET}")
            sys.exit(1)
        return record_text

    fields = info_fields(pkg_name, remote, installed_versions, available_versions)
    if output_format == "json":
        return info_as_json(fields)
    if output_format == "yaml":
        return info_as_yaml(fields)
    return info_as_toml(fields)


def handle_info(pkg_name, output_format=None):
    
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
    remote, record_text = fetch_remote_info(pkg_name, arch)

    # 3. 拉取远程所有可安装版本
    available_versions = fetch_remote_versions(pkg_name, arch)
    available_versions = sort_versions(available_versions)

    # 4. 输出
    if output_format:
        text = render_info(output_format, pkg_name, remote, record_text,
                           installed_versions, available_versions)
        if text is not None:
            print(text)
        return

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

def parse_info_arguments(words):
    """返回 (其余参数, 输出格式或 None)。

    四种格式互斥：同时给两个就报错，而不是悄悄挑一个 —— 「哪个生效」不该靠猜。
    """
    chosen = []
    operands = []
    for word in words:
        if not word.startswith("-"):
            operands.append(word)
            continue
        name = word.partition("=")[0]
        if name[2:] in INFO_FORMATS and name.startswith("--"):
            chosen.append(name[2:])
        else:
            print(f"{RED_BOLD}🌊 Error: unknown option {word}{RESET}")
            print(f"{YELLOW}🌊 Next      wave info accepts "
                  f"--json, --yaml, --toml or --raw{RESET}")
            sys.exit(1)

    if len(chosen) > 1:
        given = ", ".join(f"--{name}" for name in chosen)
        print(f"{RED_BOLD}🌊 Error: choose one output format, got: {given}{RESET}")
        print(f"{YELLOW}🌊 Next      --json, --yaml, --toml and --raw are "
              f"mutually exclusive{RESET}")
        sys.exit(1)

    return operands, (chosen[0] if chosen else None)


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
        # 容忍 <包名>@<版本号> 这种写法；--json 之类的输出格式会被挑出来
        operands, output_format = parse_info_arguments(words[2:])
        pkg_name = operands[0].partition("@")[0] if operands else ""
        if not pkg_name:
            print(f"{RED_BOLD}🌊 Error: Missing package name.{RESET}")
            print(f"{YELLOW}🌊 Next      wave info <name> [--json|--yaml|--toml|--raw]{RESET}")
            sys.exit(1)
        handle_info(pkg_name, output_format)
    else:
        print(f"{RED_BOLD}🌊 Error: Unknown subcommand '{subcommand}'.{RESET}")
        sys.exit(1)


if __name__ == "__main__":
    input_string = " ".join(sys.argv[1:])
    handle_info_command(input_string)
