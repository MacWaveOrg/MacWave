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
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

CONFIG_FILE = Path("/opt/macwave_config/config.json")
VERSION_FILE = Path("/opt/macwave_config/VERSION.json")

def get_version():
    if VERSION_FILE.exists():
        try:
            with open(VERSION_FILE, 'r') as f:
                data = json.load(f)
                return data.get("version", "unknown")
        except Exception:
            pass
    return "unknown"

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
    print(f"{RED_BOLD}🌊 Please run the install script again to reinstall MacWave.{RESET}")
    sys.exit(1)

BASE_DIR = load_config()
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
    "--limit-rate", "--proxy"
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
    attempt = 0
    while not download_success:
        attempt += 1
        try:
            response = requests.get(url, **request_kwargs)

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
            if attempt < 2:
                print(f"{RED_BOLD}🌊 Download failed: {e}{RESET}")
                print(f"{RED_BOLD}🌊 Do you want to retry? [y/N]: {RESET}")
                retry = input().strip().lower()
                if retry == 'y':
                    continue
                else:
                    print(f"{RED_BOLD}🌊 Error: Failed to download package{RESET}")
                    sys.exit(1)
            else:
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
    api_url = f"https://api.github.com/repos/MacWaveOrg/MacWave/contents/pkg/pkginfo_{arch}/{package_name}"
    try:
        response = requests.get(api_url, timeout=30)
        if response.status_code != 200:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch package list.{RESET}")
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
    parts = input_string.split()
    if len(parts) >= 3:
        raw_pkg = parts[2]
    else:
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

    # 3. 解析版本号
    ParsePkgVersion = None
    if "@" in input_string:
        if "--ver" in input_string:
            print(f"{RED_BOLD}🌊 Error: Repeated Version Number{RESET}")
            sys.exit(1)
        else:
            ParsePkgVersion = input_string.split("@")[1].split(" ")[0].strip()
    elif "--ver" in input_string:
        ParsePkgVersion = input_string.split("--ver")[1].strip().split(" ")[0]
    else:
        print("🌊 Fetching version info...")
        ParsePkgVersion = fetch_max_version(ParsePkgName, ARCH)
        print("🌊 Version info fetched successfully.")

    # 4. 获取 bin_name（从 @common 文件）
    common_url = f"https://raw.githubusercontent.com/MacWaveOrg/MacWave/infosource/pkg/pkginfo_{ARCH}/{ParsePkgName}/_{ParsePkgName}@common"
    try:
        common_resp = requests.get(common_url)
        if common_resp.status_code != 200:
            print(f"{RED_BOLD}🌊 Error: Cannot fetch @common file.{RESET}")
            sys.exit(1)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: {e}{RESET}")
        sys.exit(1)

    bin_name_match = re.search(r'bin_name:\s*"([^"]+)"', common_resp.text)
    if not bin_name_match:
        print(f"{RED_BOLD}🌊 Missing \"bin_name\" field, Please contact the administrator.{RESET}")
        sys.exit(1)
    bin_name = bin_name_match.group(1)

    # 5. 获取 URL 和 SHA256
    pkg_version_url = f"https://raw.githubusercontent.com/MacWaveOrg/MacWave/infosource/pkg/pkginfo_{ARCH}/{ParsePkgName}/_{ParsePkgName}@{ParsePkgVersion}"
    try:
        resp = requests.get(pkg_version_url)
        if resp.status_code != 200:
            if config["verbose"]:
                print(resp.text)
            elif resp.status_code == 404:
                print(f"{RED_BOLD}🌊 Error: Can't find parse package version.\n🌊 If you certain this version is existent, Please contact the administrator.{RESET}")
                sys.exit(1)
            else:
                print(f"{RED_BOLD}🌊 Error: Service unavailable, Please contact the administrator.{RESET}")
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

    # 9. 拼接长字符串并传给 pkginstaller.sh
    parse_dir_value = f"{BASE_DIR}/bin/{bin_name}@{ParsePkgVersion}"
    pkg_info_string = (
        f"{ParsePkgName}\n{ParsePkgVersion}\n{ParsePkgSHA256}\n{parse_dir_value}"
    )

    try:
        script_path = os.path.join(os.path.dirname(__file__), 'pkginstaller.sh')
        result = subprocess.run(
            ['bash', script_path, pkg_info_string],
            capture_output=True, text=True
        )
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.stderr.strip():
            print(result.stderr.strip())
        if result.returncode != 0:
            sys.exit(result.returncode)
    except Exception as e:
        print(f"{RED_BOLD}🌊 Error: Failed to invoke shell script: {e}{RESET}")
        sys.exit(1)


if __name__ == "__main__":
    try:
        input_string = " ".join(sys.argv[1:])
        handle_install(input_string)
    except KeyboardInterrupt:
        print("🌊 Operation cancelled by user.")
        print("🌊 You can use -C to resume the download next time.")
        sys.exit(130)
