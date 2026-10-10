#!/usr/bin/env python3

# pkginstaller.py

import os
import sys
import json
import hashlib
import shutil
import time
import platform
import subprocess
import re
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

from configpaths import VERSION_FILE, load_base_dir


def github_api_headers(url):
    # api.github.com 未认证只有 60 次/小时，CI Runner / 办公网常常整栋楼共用一个出口 IP，
    # 很容易被限流（表现是 "Cannot fetch package list."）。有 token 就带上；
    # 只发给 api.github.com，raw.githubusercontent.com 与各下载站都不带。
    if "api.github.com" not in url:
        return {}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        return {}
    return {"Authorization": f"Bearer {token}"}


def get_version():
    if VERSION_FILE.exists():
        try:
            with open(VERSION_FILE, 'r') as f:
                data = json.load(f)
                return data.get("version", "unknown")
        except Exception:
            pass
    return "unknown"


BASE_DIR = load_base_dir()
DOWNLOAD_TMP = BASE_DIR / "downloads" / "tmp"

# -------------------- 依赖库检查 --------------------

try:
    import requests
    from requests.exceptions import HTTPError, ConnectionError, Timeout
    from urllib3.exceptions import InsecureRequestWarning
    import urllib3
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    print(f"{RED_BOLD}🌊 Please install it using: pip3 install requests{RESET}")
    sys.exit(1)

try:
    from packaging.version import parse as parse_version, InvalidVersion
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'packaging' library is not installed.{RESET}")
    print(f"{RED_BOLD}🌊 Please install it using: pip3 install packaging{RESET}")
    sys.exit(1)

try:
    from rich.progress import (
        Progress, BarColumn, DownloadColumn, TextColumn,
        TimeRemainingColumn,
    )
    from rich.console import Console
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False

try:
    from depsinstaller import (
        install_dependencies, parse_common_fields, get_field, get_deps,
        transfer_installed_artifacts,
    )
except ImportError as error:
    print(f"{RED_BOLD}🌊 Error: 'surfboard' module is not available ({error}).{RESET}")
    sys.exit(1)


# -------------------- 辅助函数 --------------------

def _parse_rate_limit(rate_str):
    rate_str = rate_str.upper().strip()
    multipliers = {'K': 1024, 'M': 1024**2, 'G': 1024**3}
    try:
        if rate_str[-1] in multipliers:
            return float(rate_str[:-1]) * multipliers[rate_str[-1]]
        return float(rate_str)
    except ValueError:
        return None


def _check_disk_space(path: Path, required_bytes: int = 10 * 1024 * 1024) -> bool:
    total, used, free = shutil.disk_usage(path)
    if free < required_bytes:
        print(f"{RED_BOLD}🌊 Error: Insufficient disk space in {path}.{RESET}")
        sys.exit(1)
    return True


# -------------------- 参数解析 --------------------

ALLOWED_FLAGS = {
    "-v", "-C",
    "--verbose", "--skip-ssl", "--continue",
    "--limit-rate", "--proxy", "--unlink"
}

def parse_flags(input_string):

    # 截取所有 "-开头"（且 - 前是空格）至下一个空格的内容。
    # 规则：
    # 1. 单独的 "-" 表示参数结束，后续不统计。
    # 2. "--" 开头保持不变。
    # 3. "-" 开头（但不是 "--"）将其每个字母拆开，如 -abc = -a -b -c。
    # 4. 参数必须在白名单内，否则报错。

    flags = []
    stop_parsing = False

    for token in input_string.split(" "):
        if stop_parsing:
            break

        if token == "-":
            stop_parsing = True
            continue

        if token.startswith("--"):
            flags.append(token)
        elif token.startswith("-") and len(token) > 1:
            for ch in token[1:]:
                flags.append(f"-{ch}")

    # 白名单校验
    for flag in flags:
        if flag not in ALLOWED_FLAGS:
            print(f"{RED_BOLD}🌊 Error: Input contains illegal fields.{RESET}")
            sys.exit(1)

    return flags


def first_package_token(input_string):
    # 取第一个真正的包名（跳过 flag 和 --limit-rate / --proxy 后面的值），
    # 这样 `wave install --unlink wget@1.25.0` 与 `wave install wget@1.25.0 --unlink` 等价
    skip_next = False
    for word in input_string.split()[2:]:
        if skip_next:
            skip_next = False
            continue
        if word in ("--limit-rate", "--proxy"):
            skip_next = True
            continue
        if word.startswith("-"):
            continue
        return word
    return None


def handle_download_args(input_string):
    """
    处理下载相关的参数逻辑。
    返回配置字典。
    """
    flags = parse_flags(input_string)

    config = {
        "skip_ssl_verify": False,
        "verbose": False,
        "resume": False,
        "limit_rate": None,
        "proxy": None,
    }

    # 1. --skip-ssl 安全询问
    if "--skip-ssl" in flags:
        print('🌊 You selected --skip-ssl, this will skip SSL certificate verification, which may cause security risks. Are you sure?')
        confirm = input().strip()
        if confirm in ("Y", "y"):
            config["skip_ssl_verify"] = True

    # 2. verbose 判定
    if "-v" in flags or "--verbose" in flags:
        config["verbose"] = True

    # 3. 断点续传开关
    if "-C" in flags or "--continue" in flags:
        config["resume"] = True

    # 4. 限速
    if "--limit-rate" in flags:
        parts = input_string.split("--limit-rate")
        if len(parts) > 1:
            rate_str = parts[1].strip().split(" ")[0]
            config["limit_rate"] = _parse_rate_limit(rate_str)

    # 5. 代理
    if "--proxy" in flags:
        parts = input_string.split("--proxy")
        if len(parts) > 1:
            proxy_value = parts[1].strip().split(" ")[0]
            if not (proxy_value.startswith("http://") or
                    proxy_value.startswith("https://") or
                    proxy_value.startswith("socks5://")):
                print('🌊 Proxy error, please check your network proxy settings, whether the input is correct, or contact your ISP.')
                sys.exit(1)
            config["proxy"] = proxy_value

    return config


# -------------------- 下载核心（含真正断点续传） -------------------

def download_file(url, temp_path, config, input_string, display_name):
    request_kwargs = {"stream": True}

    # SSL 验证（内部变量 SkipSSLVerify 逻辑）
    if config["skip_ssl_verify"]:
        request_kwargs["verify"] = False
        urllib3.disable_warnings(InsecureRequestWarning)
    else:
        request_kwargs["verify"] = True

    # 简单代理检查，避免低级错误
    if config["proxy"]:
        request_kwargs["proxies"] = {
            "http": config["proxy"],
            "https": config["proxy"],
        }

    # 断点续传准备
    existing_size = 0
    mode = "wb"
    if config["resume"] and temp_path.exists():
        existing_size = temp_path.stat().st_size
        if existing_size > 0:
            request_kwargs["headers"] = {"Range": f"bytes={existing_size}-"}
            mode = "ab"

    download_success = False
    while not download_success:
        try:
            # 30 秒无响应即超时，交给下面的重试询问处理，避免永久挂起
            response = requests.get(url, timeout=30, **request_kwargs)

            if response.status_code == 416:
                download_success = True
                break
            elif response.status_code == 404:
                print(f"{RED_BOLD}🌊 Error: ErrorCode 404 - The URL or file does not exist.{RESET}")
                print(f"{RED_BOLD}🌊 URL: {url}{RESET}")
                sys.exit(404)
            elif response.status_code not in (200, 206):
                print(f"{RED_BOLD}🌊 Error: ErrorCode {response.status_code}{RESET}")
                print(f"{RED_BOLD}🌊 URL: {url}{RESET}")
                sys.exit(response.status_code)

            # 如果服务器不支持续传
            if response.status_code == 200 and existing_size > 0:
                print(f"{RED_BOLD}🌊 Server does not support resume, restarting download.{RESET}")
                existing_size = 0
                mode = "wb"

            total_size = int(response.headers.get('content-length', 0))
            if existing_size > 0:
                total_size += existing_size

            limit_bps = config["limit_rate"]

            if RICH_AVAILABLE:
                console = Console()
                progress_columns = [
                    TextColumn("[progress.description]{task.description}"),
                    BarColumn(bar_width=None),
                    TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
                    DownloadColumn(),
                    TextColumn("•"),
                    TimeRemainingColumn(),
                ]
                with Progress(*progress_columns, console=console) as progress:
                    task_id = progress.add_task(
                        description=f"🌊 {display_name}",
                        total=total_size or None
                    )
                    if existing_size > 0:
                        progress.update(task_id, advance=existing_size)

                    token_bucket = 0.0
                    last_time = time.monotonic()

                    with open(temp_path, mode) as f:
                        for chunk in response.iter_content(chunk_size=8192):
                            if chunk:
                                if limit_bps:
                                    now = time.monotonic()
                                    delta = now - last_time
                                    token_bucket += delta * limit_bps
                                    last_time = now
                                    if token_bucket > 8192:
                                        token_bucket = 8192
                                    if token_bucket < len(chunk):
                                        time.sleep((len(chunk) - token_bucket) / limit_bps)
                                        now = time.monotonic()
                                        delta = now - last_time
                                        token_bucket += delta * limit_bps
                                        last_time = now
                                    token_bucket -= len(chunk)

                                f.write(chunk)
                                progress.update(task_id, advance=len(chunk))
            else:
                with open(temp_path, mode) as f:
                    for chunk in response.iter_content(chunk_size=8192):
                        if chunk:
                            f.write(chunk)
                            if config["verbose"]:
                                print(".", end="", flush=True)
                if config["verbose"]:
                    print(" ")

            download_success = True
            break

        except (ConnectionError, Timeout) as e:
            # 超时或连接失败：每次都询问是否重试，不再直接放弃
            print(f"{RED_BOLD}🌊 Download failed: {e}{RESET}")
            print(f"{RED_BOLD}🌊 Do you want to retry? [y/N]: {RESET}")

            try:
                retry = input().strip().lower()
            except (EOFError, KeyboardInterrupt):
                retry = ""

            if retry == 'y':
                continue

            print(f"{RED_BOLD}🌊 Error: Failed to download package{RESET}")
            sys.exit(1)

        except HTTPError as e:
            status_code = e.response.status_code if e.response is not None else 1
            print(f"{RED_BOLD}🌊 Error: ErrorCode {status_code}{RESET}")
            sys.exit(status_code)

        except Exception as e:
            print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
            sys.exit(1)

    return temp_path


# -------------------- 获取最高版本（GitHub API） --------------------

def fetch_max_version(package_name, arch):
    # 数据在 MacWaveOrg/infosource 仓库的 main 分支
    api_url = f"https://api.github.com/repos/MacWaveOrg/infosource/contents/pkg/pkginfo_{arch}/{package_name}?ref=main"
    try:
        response = requests.get(api_url, timeout=30, headers=github_api_headers(api_url))
        if response.status_code != 200:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch package list.{RESET}")
            print(f"{RED_BOLD}🌊 URL: {api_url}{RESET}")
            sys.exit(1)

        file_list = response.json()
        versions = []
        for item in file_list:
            fname = item["name"]
            if fname.endswith("@common"):
                continue
            if "@" in fname:
                versions.append(fname.split("@")[1])

        from pkgversionparser import get_max_version
        return get_max_version(versions)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: Failed to fetch version list: {e}{RESET}")
        sys.exit(1)


# -------------------- 核心安装流程 --------------------

def handle_install(input_string):
    # 参数解析
    config = handle_download_args(input_string)

    # 1. 解析包名
    raw_pkg = first_package_token(input_string)
    if not raw_pkg:
        print(f"{RED_BOLD}🌊 Error: Invalid package name{RESET}")
        sys.exit(1)

    if "@" in raw_pkg:
        ParsePkgName = raw_pkg.split("@")[0]
    else:
        ParsePkgName = raw_pkg

    # 2. 获取架构
    machine = platform.machine().lower()
    if machine in ["arm64", "aarch64"]:
        ARCH = "arm64"
    elif machine in ["x86_64", "amd64"]:
        ARCH = "amd64"
    else:
        print(f"{RED_BOLD}🌊 Error: Unknown Arch!{RESET}")
        sys.exit(1)

    # 3. 解析版本号（只看包名 token，避免 --proxy 里的 user:pass@host 被误认）
    ParsePkgVersion = None
    if "@" in raw_pkg:
        if "--ver" in input_string:
            print(f"{RED_BOLD}🌊 Error: Repeated Version Number{RESET}")
            sys.exit(1)
        else:
            ParsePkgVersion = raw_pkg.split("@", 1)[1].strip()
    elif "--ver" in input_string:
        ParsePkgVersion = input_string.split("--ver")[1].strip().split(" ")[0]
    else:
        print("🌊 Fetching version info...")
        ParsePkgVersion = fetch_max_version(ParsePkgName, ARCH)
        print("🌊 Version info fetched successfully.")

    # 4. 获取 bin_name（从 @common 文件）
    common_url = f"https://raw.githubusercontent.com/MacWaveOrg/infosource/main/pkg/pkginfo_{ARCH}/{ParsePkgName}/_{ParsePkgName}@common"
    try:
        common_resp = requests.get(common_url, timeout=30)
        if common_resp.status_code != 200:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch @common file.{RESET}")
            sys.exit(1)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
        sys.exit(1)

    common_fields = parse_common_fields(common_resp.text)
    bin_name = get_field(common_fields, "bin_name")
    if not bin_name:
        print(f"{RED_BOLD}🌊 Missing \"bin_name\" field, Please contact the administrator.{RESET}")
        sys.exit(1)

    # 5. 获取 URL 和 SHA256（deps 也写在该版本文件里）
    pkg_version_url = f"https://raw.githubusercontent.com/MacWaveOrg/infosource/main/pkg/pkginfo_{ARCH}/{ParsePkgName}/_{ParsePkgName}@{ParsePkgVersion}"
    try:
        resp = requests.get(pkg_version_url, timeout=30)
        if resp.status_code != 200:
            if config["verbose"]:
                print(resp.text)
            elif resp.status_code == 404:
                print(f"{RED_BOLD}🌊 Error: Can't find parse package version.\n🌊 If you certain this version is existent, Please contact the administrator.{RESET}")
                sys.exit(1)
            else:
                print(f"{RED_BOLD}🌊 Error: GitHub returned HTTP {resp.status_code} for the package data.{RESET}")
                print(f"{RED_BOLD}🌊   {pkg_version_url}{RESET}")
                print(f"{RED_BOLD}🌊 This is usually a network hiccup. Check your network or proxy, then run the command again.{RESET}")
                sys.exit(1)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
        sys.exit(1)

    url_match = re.search(r'url:\s*"([^"]+)"', resp.text)
    sha_match = re.search(r'sha256:\s*"([^"]+)"', resp.text)

    if url_match:
        ParsePkgURL = url_match.group(1)
    else:
        print(f"{RED_BOLD}🌊 Error: URL field not found.{RESET}")
        sys.exit(1)

    ParsePkgSHA256 = sha_match.group(1) if sha_match else None

    # 5.1 解析 deps 字段（写在版本文件里，可能多行），缺失视为无依赖
    dep_refs = get_deps(parse_common_fields(resp.text))

    # 6. 简单 URL 检查，避免低级错误
    if not ParsePkgURL.startswith("https://"):
        if ParsePkgURL.startswith("http://"):
            print(f"{RED_BOLD}🌊 ParsePkgURL using HTTP! That's insecure, Please contact the administrator.{RESET}")
            sys.exit(1)
        else:
            print(f"{RED_BOLD}🌊 ParsePkgURL Invalid, Please contact the administrator.{RESET}")
            sys.exit(1)

    # 7. 下载
    original_filename = ParsePkgURL.split("/")[-1]
    DOWNLOAD_TMP.mkdir(parents=True, exist_ok=True)
    temp_path = DOWNLOAD_TMP / f"{original_filename}.partial"

    download_file(ParsePkgURL, temp_path, config, input_string, bin_name)

    # 8. 删掉 .partial 后缀
    final_download_path = DOWNLOAD_TMP / original_filename
    temp_path.rename(final_download_path)

    # 9. 拼接长字符串并传给 pkginstaller.sh（同时带上依赖列表）
    target_dir = BASE_DIR / "bin" / f"{bin_name}@{ParsePkgVersion}"
    pkg_info_string = "\n".join([
        ParsePkgName,
        ParsePkgVersion,
        ParsePkgSHA256 or "",
        str(target_dir),
        str(BASE_DIR),
        bin_name,
        "",
        original_filename,
    ])
    deps_string = "\n".join(dep_refs)

    try:
        script_path = os.path.join(os.path.dirname(__file__), 'pkginstaller.sh')
        result = subprocess.run(
            ['bash', script_path, pkg_info_string, deps_string],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.returncode != 0:
            sys.exit(result.returncode)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: Failed to invoke shell script: {e}{RESET}")
        sys.exit(1)

    # 10. 安装依赖（递归处理依赖的依赖，进度条与软件包一致）
    if dep_refs:
        install_dependencies(dep_refs, ARCH, config, input_string,
                             ("pkg", bin_name, ParsePkgVersion))

    # 11. 路径替换：依赖与软件包都就位后统一做一遍
    #     （必须放最后：先装的依赖可能引用后装的依赖，提前替换会解析不到）
    transfer_installed_artifacts(target_dir)

    # 12. 把不带版本号的软链接指到刚装好的版本（--unlink 可跳过）
    if "--unlink" not in input_string:
        try:
            from linker import link_package
            if link_package(bin_name, ParsePkgVersion):
                print(f"🌊 Linked {bin_name} -> {bin_name}@{ParsePkgVersion}")
        except Exception as error:
            print(f"{YELLOW}🌊 Warning: could not create the unversioned link ({error}).{RESET}")


if __name__ == "__main__":
    try:
        input_string = " ".join(sys.argv[1:])
        handle_install(input_string)
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        print("🌊 You can use -C to resume the download next time.")
        sys.exit(130)
