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
import difflib
import re
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

# -------------------- 配置加载 --------------------

from configpaths import (
    VERSION_FILE,
    assert_inside,
    load_base_dir,
    require_safe_filename,
    require_safe_token,
)
import domains
import quiet
import steplog


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


DEFAULT_TIMEOUT = 30

def _parse_duration(text):
    # 把 curl 风格的时长解析成秒数：40 / 40s / 1min / 1min20s / 2h / 1m30s / 250ms。
    # 无单位时按秒处理（与 curl 一致）。返回 None 表示格式不合法。
    if text is None:
        return None
    raw = text.strip().lower()
    if not raw:
        return None

    # 单位必须**长优先**：`1min` 若先匹配到单字母 `m`，剩下的 `in` 就无解了。
    pattern = re.compile(r"(\d+(?:\.\d+)?)(hrs|hr|h|mins|min|ms|secs|sec|s|m)?")
    units = {
        None: 1, "s": 1, "sec": 1, "secs": 1,
        "m": 60, "min": 60, "mins": 60,
        "h": 3600, "hr": 3600, "hrs": 3600,
        "ms": 0.001,
    }

    total = 0.0
    position = 0
    matched = False
    while position < len(raw):
        match = pattern.match(raw, position)
        if not match or match.end() == position:
            return None
        value, unit = match.group(1), match.group(2)
        total += float(value) * units.get(unit, 1)
        position = match.end()
        matched = True

    if not matched or total <= 0:
        return None
    return total


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
    "--limit-rate", "--proxy", "--unlink", "--ver", "--max-time",
    "--install-from-source",
}

# 只对 upgrade 有意义的参数。单列出来是为了在 install 里用错时能说清原因，
# 而不是丢一句「illegal fields」让人自己猜。
UPGRADE_ONLY_FLAGS = {
    "-X", "--remove-old-version", "--remove-old-versions", "--rov",
}

# 其余命令独有的参数：用错时指到正确的那条命令（值要能直接照着敲）
OTHER_COMMAND_FLAGS = {
    "-a": "`wave link --all`",
    "--all": "`wave link --all`",
}

def parse_flags(input_string, command="install", shown=None):
    """校验旗标白名单。

    command: 报错时说的命令名。upgrade 复用这个函数，报错必须说 `wave upgrade`，
             不能让用户以为自己在用 install。
    shown:   报错里「you ran:」要回显的命令行。upgrade 传的是用户真实输入 ——
             它内部会构造一条 `wave install placeholder …` 的探针去复用白名单，
             那条探针只该用于解析，不该出现在给用户看的文案里。
    """
    # 截取所有 "-开头"（且 - 前是空格）至下一个空格的内容。
    # 规则：
    # 1. 单独的 "-" 表示参数结束，后续不统计。
    # 2. "--" 开头保持不变；`--name=value` 归一化成 `--name`，值交给 flag_value 取。
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
            flags.append(token.split("=", 1)[0])
        elif token.startswith("-") and len(token) > 1:
            for ch in token[1:]:
                flags.append(f"-{ch}")

    # 白名单校验。报错必须点名是哪个参数、以及它是不是属于另一条命令 ——
    # 只印「Input contains illegal fields」时，用户无从判断是自己拼错还是用错命令。
    for flag in flags:
        if flag in ALLOWED_FLAGS:
            continue
        # 静默模式：整段解释对脚本没用，给一行可匹配的即可
        if quiet.is_silent():
            quiet.unknown("flag", flag)
            sys.exit(1)
        # 保留 "illegal" 这个词：随机回归用它在断言里识别「参数被拒」这一类结果。
        if flag in UPGRADE_ONLY_FLAGS:
            package = first_package_token(input_string) or "<package>"
            steplog.fail(
                f"illegal option {flag} for `wave {command}`: "
                f"it only applies to `wave upgrade`",
                extra=f"you ran: {(shown or input_string).strip()}",
                hint=[f"`{flag}` removes the older versions *after* upgrading to the latest one,",
                      "so it needs a command that installs and prunes in one go.",
                      "Did you mean:",
                      f"  wave upgrade {package} {flag}"])
        if flag in OTHER_COMMAND_FLAGS:
            steplog.fail(
                f"illegal option {flag} for `wave {command}`: "
                f"it belongs to {OTHER_COMMAND_FLAGS[flag]}",
                extra=f"you ran: {(shown or input_string).strip()}",
                hint=["Did you mean:",
                      f"  {OTHER_COMMAND_FLAGS[flag]}",
                      f"see `{OTHER_COMMAND_FLAGS[flag].split()[1]} --help` for the rest"])
        steplog.fail(
            f"illegal option {flag} for `wave {command}`",
            extra=f"you ran: {(shown or input_string).strip()}",
            hint=f"`wave {command} --help` lists the flags this command accepts")

    return flags


def flag_value(input_string, name):
    # 取旗标的值，`--name value` 与 `--name=value` 都支持；没有该旗标时返回 None。
    tokens = input_string.split()
    for index, token in enumerate(tokens):
        if token == name:
            return tokens[index + 1] if index + 1 < len(tokens) else ""
        if token.startswith(name + "="):
            return token[len(name) + 1:]
    return None


# 这些旗标后面跟的是一个「值」，那个值不是包名。
# 少了 --max-time 时，`wave install --max-time 1min jq` 会把 `1min` 当成包名。
FLAGS_TAKING_VALUE = ("--limit-rate", "--proxy", "--ver", "--max-time")


def package_index(words):
    # 第一个真正的包名在 words 里的下标（跳过旗标与取值位置），没有则 None。
    skip_next = False
    for index, word in enumerate(words):
        if skip_next:
            skip_next = False
            continue
        if word in FLAGS_TAKING_VALUE:
            skip_next = True
            continue
        if word.startswith("-"):
            continue
        return index
    return None


def first_package_token(input_string):
    # 取第一个真正的包名（跳过 flag 和带值的旗标后面的值），
    # 这样 `wave install --unlink wget@1.25.0` 与 `wave install wget@1.25.0 --unlink` 等价
    words = input_string.split()[2:]
    index = package_index(words)
    return None if index is None else words[index]


def parse_timeout(input_string, flags):
    # `--max-time` 的秒数；没有这个旗标时用 DEFAULT_TIMEOUT，取值不合法就报错退出。
    # 单独提出来，是因为 upgrade 要在「下载之前」先用它去取版本列表。
    if "--max-time" not in flags:
        return DEFAULT_TIMEOUT

    raw_timeout = flag_value(input_string, "--max-time")
    if raw_timeout is None or raw_timeout == "":
        print(f"{RED_BOLD}🌊 Error: --max-time needs a value, e.g. --max-time=1min.{RESET}")
        sys.exit(1)

    parsed_timeout = _parse_duration(raw_timeout)
    if parsed_timeout is None:
        print(f"{RED_BOLD}🌊 Error: cannot parse --max-time value '{raw_timeout}'.{RESET}")
        print(f"{RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.{RESET}")
        sys.exit(1)
    return parsed_timeout


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
        "timeout": DEFAULT_TIMEOUT,
        # 4.0 只从 Bottle 存储取二进制，url 字段平时不读；
        # 只有这个开关会让安装绕开 Bottle，直接回上游取（含依赖）。
        "install_from_source": "--install-from-source" in flags,
    }

    # 1. --skip-ssl 安全询问
    if "--skip-ssl" in flags:
        print('🌊 You selected --skip-ssl, this will skip SSL certificate verification, which may cause security risks. Are you sure?')
        try:
            confirm = input().strip()
        except (EOFError, KeyboardInterrupt):
            # 非交互（CI / 脚本里 stdin 是 /dev/null）读不到答复：按拒绝处理，
            # 也就是不跳过 SSL 校验 —— 缺省往安全的方向倒。
            confirm = ""
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
        rate_str = flag_value(input_string, "--limit-rate")
        if rate_str:
            config["limit_rate"] = _parse_rate_limit(rate_str)

    # 4.1 超时（--max-time）：请求与读取两个阶段都用它
    config["timeout"] = parse_timeout(input_string, flags)

    # 5. 代理
    if "--proxy" in flags:
        proxy_value = flag_value(input_string, "--proxy")
        if proxy_value is not None:
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

    steplog.detail(f"GET {domains.redact_url(url)}")
    if existing_size:
        steplog.detail(f"resume: {existing_size} bytes already on disk")
    if config["limit_rate"]:
        steplog.detail(f"rate limit {config['limit_rate'] / 1024:.0f} KiB/s")
    if config["proxy"]:
        steplog.detail(f"proxy {config['proxy']}")
    steplog.detail(f"timeout {config['timeout']}s, saving to {temp_path.name}")

    download_success = False
    while not download_success:
        try:
            # 超时同时约束「连接」与「两次读取之间」：只给一个数字时 requests 会让
            # 两者都取该值，因此 --max-time 对「连上了但不动」的下载同样有效。
            response = requests.get(url, timeout=config["timeout"], **request_kwargs)

            if response.status_code == 416:
                download_success = True
                break
            elif response.status_code == 404:
                steplog.fail(
                    f"payload not found: {display_name}",
                    request=url,
                    response="404 Not Found",
                    hint=["the index lists this payload but the mirror does not have it",
                          "ask the administrator to re-sync the mirror, or use "
                          "--install-from-source to fetch it from upstream"])
            elif response.status_code not in (200, 206):
                steplog.fail(
                    f"download failed: {display_name}",
                    request=url,
                    response=f"HTTP {response.status_code}",
                    hint="usually the mirror is temporarily unavailable; retry later. "
                         "If it keeps failing, contact the administrator.")

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
                # disable=True 让 rich 不启动实时渲染（进度条是噪音）；
                # 下载循环仍在这个 with 里，progress.update 变成无操作。
                with Progress(*progress_columns, console=console,
                              disable=quiet.is_silent()) as progress:
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
                            if config["verbose"] and not quiet.is_silent():
                                print(".", end="", flush=True)
                if config["verbose"] and not quiet.is_silent():
                    print(" ")

            download_success = True
            break

        except (ConnectionError, Timeout) as e:
            # 超时或连接失败：每次都询问是否重试，不再直接放弃
            # 失败原因必须留下（这是错误，不是噪音）；问题本身可以被静默掉，
            # 因为静默模式下没有人能回答，问出来只会让人以为卡住了。
            print(f"{RED_BOLD}🌊 Download failed: {e}{RESET}")
            if quiet.is_silent():
                retry = ""
            else:
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
            steplog.fail(
                f"download failed: {display_name}",
                request=url,
                response=f"HTTP {status_code}",
                hint="check the network, the proxy (--proxy) and the mirror, then retry")

        except Exception as e:
            steplog.fail(
                f"download error: {display_name}",
                request=url,
                response=str(e),
                hint=["check the network and the proxy (--proxy)",
                      "for certificate problems, --skip-ssl bypasses verification (insecure)"])

    return temp_path


# -------------------- 获取最高版本（GitHub API） --------------------

def detect_arch():
    # 索引按 arm64 / amd64 分目录，目录名与 platform.machine() 并不一一对应
    machine = platform.machine().lower()
    if machine in ["arm64", "aarch64"]:
        return "arm64"
    if machine in ["x86_64", "amd64"]:
        return "amd64"
    print(f"{RED_BOLD}🌊 Error: Unknown Arch!{RESET}")
    sys.exit(1)


def package_common_url(package_name, arch):

    return f"{domains.api_domain()}/pkg/pkginfo_{arch}/{package_name}/_{package_name}@common"


def fetch_common_fields(package_name, arch, timeout=DEFAULT_TIMEOUT):
    # 包名与 bin_name 不一定相同（例如 choma -> ChOma），而 bin/ 与 links/ 用的是 bin_name。
    # 所以任何要「按名字找已安装版本」的命令都必须先读这个文件。
    url = package_common_url(package_name, arch)
    steplog.detail(f"GET {domains.redact_url(url)}")
    try:
        response = requests.get(url, timeout=timeout)
        if response.status_code != 200:
            steplog.fail(
                f"cannot read the @common metadata for {package_name}",
                request=url,
                response=f"HTTP {response.status_code}",
                hint=[f"check the package exists: `wave search {package_name}`",
                      "check MACWAVE_API_DOMAIN points at <mirror>/MacWave/infosource"])
    except SystemExit:
        raise
    except Exception as e:
        steplog.fail("error while reading the @common metadata",
                     request=url, response=str(e),
                     hint="check the network and any --proxy setting, then retry")

    return parse_common_fields(response.text)


def suggest_package_name(package_name, arch, timeout=DEFAULT_TIMEOUT):
    # 404 时翻一次镜像的名字清单，找最接近的包名。
    #
    # 打错包名是最常见的失败（treee / tree、rg / rgs），而原来的报错只会说
    # 「读不到版本清单」—— 用户得自己意识到是拼写错了。这里只在 404 时多发一个请求，
    # 拿不到清单就安静放弃，绝不影响正常路径。
    try:
        names_url = domains.index_list_url(arch)
        response = requests.get(names_url, timeout=timeout, headers=github_api_headers(names_url))
        if response.status_code != 200:
            return None
        names = domains.listing_names(response.text)
        if not names:
            return None
        matches = difflib.get_close_matches(package_name, names, n=1, cutoff=0.6)
        return matches[0] if matches else None
    except Exception:
        return None


def fetch_max_version(package_name, arch, timeout=DEFAULT_TIMEOUT):
    # 版本清单：默认走 GitHub API，设了索引镜像时读镜像自己的清单（见 domains.index_list_url）
    api_url = domains.index_list_url(arch, package_name)
    steplog.detail(f"GET {domains.redact_url(api_url)}")
    try:
        response = requests.get(api_url, timeout=timeout, headers=github_api_headers(api_url))
        if response.status_code != 200:
            hint = []
            if response.status_code == 404:
                # 拼错包名远比镜像配错常见，所以先猜名字，猜到了就放在第一条
                close = suggest_package_name(package_name, arch, timeout)
                if close:
                    hint.append(f"did you mean `{close}`?  try: wave info {close}")
                hint.append("search the index by part of the name: wave search <词>")
                hint.append("check MACWAVE_API_DOMAIN points at <mirror>/MacWave/infosource")
                hint.append("if every package is missing, the mirror has no versions lists "
                            "yet (see docs/MIRROR-SETUP.md)")
            else:
                hint.append("check the network and any --proxy setting, then retry")
            steplog.fail(
                f"cannot read the version list for {package_name}",
                request=api_url,
                response=f"HTTP {response.status_code}",
                hint=hint)

        file_list = domains.listing_names(response.text)
        versions = []
        for fname in file_list:
            if fname.endswith("@common"):
                continue
            if "@" in fname:
                versions.append(fname.split("@")[1])

        from pkgversionparser import get_max_version
        chosen = get_max_version(versions)
        steplog.detail(f"{len(versions)} version(s) listed, highest is {chosen}")
        return chosen
    except SystemExit:
        raise
    except Exception as e:
        steplog.fail("error while reading the version list", request=api_url, response=str(e),
                     hint="check the network and any --proxy setting, then retry")


# -------------------- 核心安装流程 --------------------

INSTALL_STEPS = [
    "parse command line",
    "resolve package name",
    "detect architecture",
    "fetch version list",
    "read package metadata",
    "read version record",
    "choose payload",
    "download",
    "verify and install",
    "install dependencies",
    "relocate and link",
]


def handle_install(input_string):
    # 参数解析
    steplog.reset()
    steplog.plan(INSTALL_STEPS)

    # 先解析旗标、打开追踪，再报第一步 —— 否则 -v 自己的这一步会被漏掉
    config = handle_download_args(input_string)
    steplog.set_verbose(config["verbose"])

    steplog.begin("parse command line")
    steplog.detail(f"args {input_string.strip() or '(empty)'}")
    steplog.detail(f"install dir {BASE_DIR}")
    steplog.trace_domains()

    # 1. 解析包名
    steplog.begin("resolve package name")
    raw_pkg = first_package_token(input_string)
    if not raw_pkg:
        steplog.fail(
            "no package name on the command line",
            extra=f"you entered: {input_string.strip() or '(empty)'}",
            hint="usage: wave install <package>, for example wave install jq")

    if "@" in raw_pkg:
        ParsePkgName = raw_pkg.split("@")[0]
    else:
        ParsePkgName = raw_pkg

    # 包名会同时进入 URL 与文件路径，先过白名单（剔除 / \ % @ 空白等）
    ParsePkgName = require_safe_token(ParsePkgName, "package name")
    steplog.detail(f"package {ParsePkgName}")

    # 2. 获取架构
    steplog.begin("detect architecture")
    ARCH = detect_arch()
    steplog.detail(f"architecture {ARCH}")

    # 3. 解析版本号（只看包名 token，避免 --proxy 里的 user:pass@host 被误认）
    steplog.begin("fetch version list")
    ver_flag = flag_value(input_string, "--ver")
    ParsePkgVersion = None
    if "@" in raw_pkg:
        if ver_flag is not None:
            steplog.fail(
                "the package name carries a version and --ver was given too",
                extra=f"package {raw_pkg}, --ver {ver_flag}",
                hint="keep only one, e.g. wave install jq@1.8.2 or wave install jq --ver 1.8.2")
        ParsePkgVersion = raw_pkg.split("@", 1)[1].strip()
        steplog.detail(f"version from the package name: {ParsePkgVersion}")
    elif ver_flag is not None:
        if not ver_flag:
            steplog.fail("--ver was given without a version number",
                         hint="for example: wave install jq --ver 1.8.2")
        ParsePkgVersion = ver_flag
        steplog.detail(f"version from --ver: {ParsePkgVersion}")
    else:
        quiet.say("🌊 Fetching version info...")
        ParsePkgVersion = fetch_max_version(ParsePkgName, ARCH)
        quiet.say("🌊 Version info fetched successfully.")

    # 版本号同样会进 URL 与目录名：`%`、`/`、`..` 这类一律拒绝
    ParsePkgVersion = require_safe_token(ParsePkgVersion, "package version")
    steplog.detail(f"selected version {ParsePkgVersion}")

    # 4. 获取 bin_name（从 @common 文件）
    steplog.begin("read package metadata")
    common_fields = fetch_common_fields(ParsePkgName, ARCH, config["timeout"])
    bin_name = get_field(common_fields, "bin_name")
    if not bin_name:
        steplog.fail(
            f"the @common file for {ParsePkgName} has no bin_name field",
            request=package_common_url(ParsePkgName, ARCH),
            response="200, but the expected field is missing",
            hint="this is an index data defect; please report it to the administrator")

    # bin_name 来自远端 @common，却要当目录名与文件名用，必须过白名单
    bin_name = require_safe_token(bin_name, "bin_name")
    steplog.detail(f"binary name {bin_name}")

    # 5. 获取 URL 和 SHA256（deps 也写在该版本文件里）
    steplog.begin("read version record")
    pkg_version_url = f"{domains.api_domain()}/pkg/pkginfo_{ARCH}/{ParsePkgName}/_{ParsePkgName}@{ParsePkgVersion}"
    steplog.detail(f"GET {domains.redact_url(pkg_version_url)}")
    try:
        resp = requests.get(pkg_version_url, timeout=config["timeout"])
        if resp.status_code != 200:
            if config["verbose"]:
                print(resp.text)
            if resp.status_code == 404:
                steplog.fail(
                    f"the mirror has no version record for {ParsePkgName}@{ParsePkgVersion}",
                    request=pkg_version_url,
                    response="404 Not Found",
                    hint=[f"run `wave search {ParsePkgName}` to see the available versions",
                          "check MACWAVE_API_DOMAIN points at <mirror>/MacWave/infosource"])
            else:
                steplog.fail(
                    "could not read the version record",
                    request=pkg_version_url,
                    response=f"HTTP {resp.status_code}",
                    hint="usually the network or the mirror is temporarily unavailable; "
                         "retry later. -v shows the raw response.")
    except Exception as e:
        steplog.fail("error while reading the version record",
                     request=pkg_version_url,
                     response=str(e),
                     hint="check the network and any --proxy setting, then retry")

    sha_match = re.search(r'sha256:\s*"([^"]+)"', resp.text)
    file_match = re.search(r'file:\s*"([^"]+)"', resp.text)
    url_match = re.search(r'url:\s*"([^"]+)"', resp.text)
    steplog.detail(f"200, {len(resp.text)} bytes; "
                   f"sha256 {'present' if sha_match else 'missing'}, "
                   f"file {'present' if file_match else 'missing'}")

    # 没有校验值就必须拒绝安装：索引记录是信任的起点，缺了 sha256 就无法确认
    # 下载到的内容与索引声明的一致。HTTPS 只保护传输，不保护产物。
    if not sha_match:
        steplog.fail(
            f"the version record for {ParsePkgName}@{ParsePkgVersion} has no sha256",
            request=pkg_version_url,
            extra=resp.text.strip()[:400],
            hint=["without a checksum the download cannot be verified, so it is refused",
                  "HTTPS protects the transfer, not the artefact -- this is an index "
                  "data defect; please report it to the administrator"])

    ParsePkgSHA256 = sha_match.group(1)

    if not re.fullmatch(r"[0-9a-f]{64}", ParsePkgSHA256):
        steplog.fail(
            f"the sha256 for {ParsePkgName}@{ParsePkgVersion} is malformed",
            request=pkg_version_url,
            extra=f"got {ParsePkgSHA256!r}",
            hint="expected 64 lowercase hex characters; this is an index data defect, "
                 "please report it to the administrator")

    # 5.1 解析 deps 字段（写在版本文件里，可能多行），缺失视为无依赖
    dep_refs = get_deps(parse_common_fields(resp.text))

    # 6. 从哪儿取、文件叫什么，交给 domains.resolve_payload 决定。
    #
    #    4.0 从 GHCR 取（一个包一个仓库名，版本即 tag，架构在 OCI index 里），
    #    url 字段全程不读 —— 它留着是给人和 2.x-3.x 看的上游线索。
    #    唯一的例外是 --install-from-source：绕开 registry 直接装上游那份。
    steplog.begin("choose payload")
    payload = domains.resolve_payload(
        "bottle", ParsePkgName, ParsePkgVersion, ARCH,
        upstream_filename=file_match.group(1) if file_match else "",
        upstream_url=url_match.group(1) if url_match else "",
        from_source=config.get("install_from_source", False))

    # 文件名会被当路径用，来自远端数据，必须过白名单
    original_filename = require_safe_filename(payload["filename"], "file name")
    steplog.detail(f"upstream file {file_match.group(1) if file_match else '(no file field)'}")
    steplog.detail(f"stored file {original_filename}")
    steplog.detail(f"source {domains.redact_url(payload['url'])}")
    if dep_refs:
        steplog.detail(f"dependencies {', '.join(dep_refs)}")

    # 7. 下载
    steplog.begin("download")
    DOWNLOAD_TMP.mkdir(parents=True, exist_ok=True)
    temp_path = DOWNLOAD_TMP / f"{original_filename}.partial"
    assert_inside(temp_path, DOWNLOAD_TMP, "download path")

    download_file(payload["url"], temp_path, config, input_string, bin_name)

    # 8. 删掉 .partial 后缀
    final_download_path = DOWNLOAD_TMP / original_filename
    assert_inside(final_download_path, DOWNLOAD_TMP, "download path")
    temp_path.rename(final_download_path)

    # 9. 拼接长字符串并传给 pkginstaller.sh（同时带上依赖列表）
    steplog.begin("verify and install")
    steplog.detail("extract / verify sha256 / place / relocate Mach-O is done by pkginstaller.sh")
    target_dir = BASE_DIR / "bin" / f"{bin_name}@{ParsePkgVersion}"
    assert_inside(target_dir, BASE_DIR / "bin", "install target")
    steplog.detail(f"target dir {target_dir}")
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
        quiet.show(result)
        if result.returncode != 0:
            steplog.fail(
                "the install shell stage failed (extract / verify / place)",
                extra=(result.stdout or "").strip()[-800:],
                hint=["the output above comes from pkginstaller.sh and usually names the cause",
                      "if it stops at sha256, the mirror content disagrees with the index; "
                      "contact the administrator"])
    except Exception as e:
        steplog.fail("could not run pkginstaller.sh", extra=str(e),
                     hint="check the install tree is complete; the official installer can repair it")

    # 10. 安装依赖（递归处理依赖的依赖，进度条与软件包一致）
    if dep_refs:
        steplog.begin("install dependencies")
        steplog.detail(f"{len(dep_refs)} dependencies to resolve")
        install_dependencies(dep_refs, ARCH, config, input_string,
                             ("pkg", bin_name, ParsePkgVersion))

    # 11. 路径替换：依赖与软件包都就位后统一做一遍
    #     （必须放最后：先装的依赖可能引用后装的依赖，提前替换会解析不到）
    steplog.begin("relocate and link")
    transfer_installed_artifacts(target_dir)

    # 12. 把不带版本号的软链接指到刚装好的版本（--unlink 可跳过）
    if "--unlink" not in input_string:
        try:
            from linker import link_package
            if link_package(bin_name, ParsePkgVersion):
                quiet.say(f"🌊 Linked {bin_name} -> {bin_name}@{ParsePkgVersion}")
        except Exception as error:
            print(f"{YELLOW}🌊 Warning: could not create the unversioned link ({error}).{RESET}")


if __name__ == "__main__":
    try:
        input_string = " ".join(sys.argv[1:])
        handle_install(input_string)
    except KeyboardInterrupt:
        quiet.say("🌊 Operation cancelled by user.")
        quiet.say("🌊 You can use -C to resume the download next time.")
        sys.exit(130)
