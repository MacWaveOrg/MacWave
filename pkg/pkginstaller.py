#!/usr/bin/env python3

# pkginstaller.py

import os
import sys
import json
import shutil
import time
import platform
import subprocess
import difflib
import re
from pathlib import Path


# -------------------- 颜色定义 --------------------

RED = '\033[31m'
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
import tls
import flags as flags_module
import timeouts
import quiet
import steplog
from suggest import closest_name, name_examples


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
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    print(f"{RED_BOLD}🌊 Please install it using: pip3 install requests{RESET}")
    sys.exit(1)

try:
    # 这里只为了确认 packaging 可用：真正用到它的是 pkgversionparser，
    # 但那条路要等到比较版本号时才会走到，而缺依赖应当在启动时就说清楚。
    # 导入后的名字不参与计算，所以显式标 F401。
    from packaging.version import parse as parse_version, InvalidVersion  # noqa: F401
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

# 时长解析只有一份实现，在 lib/timeouts.py —— 它被 lib/ 与 surfboard/ 共用，
# 放在 pkg/ 会让 lib/selfupdate.py 反过来依赖 pkg/。这里保留名字给旧调用方。
from timeouts import _parse_duration  # noqa: E402,F401


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
    "--connect-timeout", "--content-time",
    "--install-from-source",
    "-F", "--force",
}

# 只对 upgrade 有意义的参数。单列出来是为了在 install 里用错时能说清原因，
# 而不是丢一句「illegal fields」让人自己猜。
UPGRADE_ONLY_FLAGS = {
    "-X", "--remove-old-version", "--remove-old-versions", "--rov",
}

# 其余命令独有的参数：用错时指到正确的那条命令（值要能直接照着敲）
# 值是一组可以照着敲的命令：同一个旗标可能属于好几条命令（-a 同时属于
# upgrade 与 link 系），只说其中一个会把人引到错误的那条上。
OTHER_COMMAND_FLAGS = {
    "-a": ("wave upgrade --all", "wave link --all"),
    "--all": ("wave upgrade --all", "wave link --all"),
}

def _parse_dotted_version(text):
    """把 "12.1" / "10.15.7" 解析成可比较的整数元组，不合法则返回 None。

    位数不同也能比：(10, 15) < (10, 15, 7) 成立，正是「10.15 早于 10.15.7」的意思。
    """
    parts = text.strip().split(".")
    if not 1 <= len(parts) <= 3:
        return None
    if not all(part.isdigit() for part in parts):
        return None
    return tuple(int(part) for part in parts)


def current_macos_version():
    """本机 macOS 版本元组；非 macOS 或读不到时返回 None。"""
    if sys.platform != "darwin":
        return None
    return _parse_dotted_version(platform.mac_ver()[0] or "")


def confirm_min_os(record_text, pkg_name, pkg_version, force=False):
    """版本记录声明了 min_os 且本机低于它时，警告并问一句。返回是否继续安装。

    **实验性，4.3 转正。** 这是兼容性提示，不是安全边界：声明偏保守与声明准确
    两种情况都有 —— jq@1.8.2 声明 14.0 却在 12.7.6 上实测照常输出 jq-1.8.2，
    pandoc@3.13 声明 15.0 则可能真用到新 API。客户端分辨不了，所以把选择交给
    用户：只有明确答复 y/Y 才继续，其它一律中止。

    字段还没在索引里普及，缺失时静默跳过。读不到本机版本（非 darwin）也跳过。
    """
    match = re.search(r'min_os:\s*"([^"]*)"', record_text)
    if not match:
        return True

    required = _parse_dotted_version(match.group(1))
    if required is None:
        steplog.detail(f"min_os {match.group(1)!r} is not a dotted version, ignored")
        return True

    running = current_macos_version()
    if running is None or running >= required:
        return True

    declared = ".".join(str(part) for part in required)
    actual = ".".join(str(part) for part in running)
    steplog.detail(f"min_os {declared} > running {actual}")

    warning = (f"{YELLOW}🌊 Warning: {pkg_name}@{pkg_version} declares macOS "
               f"{declared} or later, this machine is {actual}.{RESET}")

    # -F/--force 越过询问，但警告照打 —— -s 时连警告一起静默（fd 上其实已经指向
    # /dev/null 了，这里显式判断是让意图写在代码里，不依赖那层副作用）。
    if force:
        if not quiet.is_silent():
            print(warning)
        return True

    # -s 问不到答复，直接拒绝，不询问。原因由调用点的 steplog.fail 输出：
    # 纯 -s 时 fd 已指向 /dev/null（一个字节都不出去），-sS 时才留着错误。
    if quiet.is_silent():
        return False

    print(warning)
    print("🌊          It may still work — that declaration is the build-time")
    print("🌊          minimum, not a guarantee.")
    print("🌊 Continue installing anyway? [y/N]")
    try:
        answer = input().strip()
    except (EOFError, KeyboardInterrupt):
        # 非交互（CI / 脚本里 stdin 是 /dev/null）读不到答复：同样按中止处理。
        answer = ""
    return answer in ("Y", "y")


def confirm_skip_ssl(flags):
    """`--skip-ssl` 的安全询问，并同步 lib/tls.py 的状态。返回是否允许跳过校验。

    单独提出来是因为 `upgrade --all` 也要问：它在确认之前就要先取索引里的名字清单，
    若只在 handle_install 里问，那一次请求就享受不到这个旗标。已经授权过就不再问，
    批量升级因此只问一次。
    """
    if tls.enabled():
        return True
    allowed = False
    if "--skip-ssl" in flags:
        if quiet.is_silent():
            # 静默模式不提问，也**不**改走「按拒绝处理」那条路：
            # 用户已经把旗标写出来了，那就是他的意思（与 -X 同一条原则）。
            # 若这里默默拒绝，装失败时会抛一个 SSL 错误，而用户以为自己已经跳过了。
            allowed = True
        else:
            print('🌊 You selected --skip-ssl, this will skip SSL certificate verification, which may cause security risks. Are you sure?')
            try:
                confirm = input().strip()
            except (EOFError, KeyboardInterrupt):
                # 非交互（CI / 脚本里 stdin 是 /dev/null）读不到答复：按拒绝处理，
                # 也就是不跳过 SSL 校验 —— 缺省往安全的方向倒。
                confirm = ""
            allowed = confirm in ("Y", "y")

    # 询问有结论之后才真正开关：答应（或静默模式）就授权，否则撤销请求，
    # 保证下游任何一处都不会在用户拒绝后仍关掉校验。
    if allowed:
        tls.grant()
    else:
        tls.revoke()
    return allowed


def _flag_pointer(text, flag):
    """把「you ran:」做成两行：命令行原样，下面用 ^ 指向出错的旗标。

    与 lib/help.py 里「未知命令」的呈现方式一致 —— 命令行长的时候（好几个旗标
    加限速加超时），只靠整行变红看不出是哪一段出的问题。

    位置必须按词边界找，不能用 str.find：`--ver` 会命中 `--verbose`，`--connect-time`
    若写成子串匹配也会先撞上前缀更长的写法。caret 只覆盖旗标本身，不含 `=<值>`。
    """
    label = "you ran: "
    if not flag or not text:
        return label + text

    offset = None
    for match in re.finditer(re.escape(flag) + r"(?==|\s|$)", text):
        start = match.start()
        if start == 0 or text[start - 1].isspace():
            offset = start
            break
    if offset is None:
        return label + text

    # steplog._emit 会把整行包进 RED_BOLD。命令行若跟着一起红，「只让出错的那段
    # 显眼」就无从谈起 —— 所以先 RESET 回默认色，再单独把旗标标红，其余照旧。
    tail = text[offset + len(flag):]
    shown = f"{text[:offset]}{RED}{flag}{RESET}{tail}"
    carets = " " * (len(label) + offset) + "^" * len(flag)
    return f"{RESET}{label}{shown}\n{RED}{carets}"


def parse_flags(input_string, command="install", shown=None):
    """校验旗标白名单。

    command: 报错时说的命令名。upgrade 复用这个函数，报错必须说 `wave upgrade`，
             不能让用户以为自己在用 install。
    shown:   报错里「you ran:」要回显的命令行。upgrade 传的是用户真实输入 ——
             它内部会构造一条 `wave install placeholder …` 的探针去复用白名单，
             那条探针只该用于解析，不该出现在给用户看的文案里。
    """
    # 词法交给 flags.tokens：单独的 "-" 表示参数结束、`--name=value` 归一化成
    # `--name`（值交给 flag_value 取）、`-abc` 拆成 -a -b -c。这三条规则的唯一
    # 实现在 lib/flags.py，别在这里再写一遍。
    found = flags_module.tokens(input_string.split(" "))

    # 白名单校验。报错必须点名是哪个参数、以及它是不是属于另一条命令 ——
    # 只印「Input contains illegal fields」时，用户无从判断是自己拼错还是用错命令。
    for flag in found:
        if flag in ALLOWED_FLAGS:
            continue
        # 静默模式：整段解释对脚本没用，给一行可匹配的即可。
        # 但要分清两种「不接受」：拼错了，还是这条命令不认它。
        if quiet.is_silent():
            description = flags_module.describe(flag)
            if description:
                quiet.misplaced(flag, description)
            else:
                quiet.unknown("flag", flag)
            sys.exit(1)
        # 保留 "illegal" 这个词：随机回归用它在断言里识别「参数被拒」这一类结果。
        if flag in UPGRADE_ONLY_FLAGS:
            package = first_package_token(input_string) or "<package>"
            steplog.fail(
                f"illegal option {flag} for `wave {command}`: "
                f"it only applies to `wave upgrade`",
                extra=_flag_pointer((shown or input_string).strip(), flag),
                hint=[f"`{flag}` removes the older versions *after* upgrading to the latest one,",
                      "so it needs a command that installs and prunes in one go.",
                      "Did you mean:",
                      f"  {GREEN}wave upgrade {package} {flag}{RESET}"],
                usage=True)
        if flag in OTHER_COMMAND_FLAGS:
            commands = OTHER_COMMAND_FLAGS[flag]
            steplog.fail(
                f"illegal option {flag} for `wave {command}`: "
                f"it belongs to {', '.join(f'`{item}`' for item in commands)}",
                extra=_flag_pointer((shown or input_string).strip(), flag),
                hint=["Did you mean:"] + [f"  {GREEN}{item}{RESET}" for item in commands]
                     + [f"{GREEN}`wave {commands[0].split()[1]} --help`{RESET} lists the rest"],
                usage=True)
        # 拼错时给一个候选再报错。--connect-time 与 --connect-timeout 只差三个
        # 字母，只说 "illegal option" 等于让用户自己回去翻 --help；
        # 候选只从**当前命令的白名单**里取，所以不会推荐一条这里不接受的长参数。
        suggestion = difflib.get_close_matches(flag, sorted(ALLOWED_FLAGS), n=1, cutoff=0.6)
        hint = []
        if suggestion:
            hint.append(f"Did you mean {GREEN}{suggestion[0]}{RESET}?")
        hint.append(f"{GREEN}`wave {command} --help`{RESET} lists the flags this command accepts")
        steplog.fail(
            f"illegal option {flag} for `wave {command}`",
            extra=_flag_pointer((shown or input_string).strip(), flag),
            hint=hint,
            usage=True)

    return found


from timeouts import flag_value  # noqa: E402,F401  —— 单一实现，见 lib/timeouts.py


# 这些旗标后面跟的是一个「值」，那个值不是包名。
# 少了 --max-time 时，`wave install --max-time 1min jq` 会把 `1min` 当成包名。
FLAGS_TAKING_VALUE = ("--limit-rate", "--proxy", "--ver", "--max-time",
                      "--connect-timeout", "--content-time")


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


def _reject_bad_duration(flag, raw):
    print(f"{RED_BOLD}🌊 Error: cannot parse {flag} value '{raw}'.{RESET}")
    print(f"{RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.{RESET}")
    sys.exit(1)


def parse_timeout(input_string, flags):
    """三档超时（连接 / 读数据 / 总时长），见 lib/timeouts.py。

    单独提出来，是因为 upgrade 要在「下载之前」先用它去取版本列表 ——
    那时还没有 config 字典。
    """
    for flag in timeouts.FLAG_FIELDS:
        if flag in flags:
            value = flag_value(input_string, flag)
            if value is None or value == "":
                print(f"{RED_BOLD}🌊 Error: {flag} needs a value, e.g. {flag}=1min.{RESET}")
                sys.exit(1)
    return timeouts.from_command_line(input_string, fail=_reject_bad_duration)


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
        "timeout": timeouts.Budget(),
        # 4.0 只从 Bottle 存储取二进制，url 字段平时不读；
        # 只有这个开关会让安装绕开 Bottle，直接回上游取（含依赖）。
        "install_from_source": "--install-from-source" in flags,
        # 索引声明的最低系统版本高于本机时，跳过询问直接装。
        "force": "-F" in flags or "--force" in flags,
    }

    # 1. --skip-ssl 安全询问
    config["skip_ssl_verify"] = confirm_skip_ssl(flags)

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

    # 4.1 三档超时：--connect-timeout 管握手，--content-time 管等数据，
    # --max-time 管整次操作。只给 --max-time 时，握手与读数据都退回默认的短值，
    # 这样「防止卡在握手」不需要额外旗标也能生效。
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
    # 统一走 lib/tls.py：询问在 handle_download_args 里已经有结论，
    # 这里不再自己判断 config["skip_ssl_verify"]，避免两处各说各的。
    request_kwargs.update(tls.request_kwargs())

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
            response = requests.get(url, timeout=config["timeout"].request_timeout, **request_kwargs)

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


def _as_request_timeout(value):
    """既接受裸秒数，也接受 Budget —— 调用方有的地方已经在用后者。"""
    return value.request_timeout if isinstance(value, timeouts.Budget) else value


def fetch_common_fields(package_name, arch, timeout=DEFAULT_TIMEOUT):
    # 包名与 bin_name 不一定相同（例如 choma -> ChOma），而 bin/ 与 links/ 用的是 bin_name。
    # 所以任何要「按名字找已安装版本」的命令都必须先读这个文件。
    url = package_common_url(package_name, arch)
    steplog.detail(f"GET {domains.redact_url(url)}")
    try:
        response = requests.get(url, timeout=_as_request_timeout(timeout),
                                **tls.request_kwargs())
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


def fetch_package_names(arch, timeout=DEFAULT_TIMEOUT):
    """索引里的全部包名。列不出来（网络 / 镜像没有清单）时返回 None。

    返回值区分的是**两类完全不同的问题**，报错要据此分开说：
      None   → 名字清单都拿不到，是网络或镜像配置的事，别再猜包名
      []     → 清单是空的，镜像还没生成 versions
      [...]  → 有清单，于是能判断「这个名字在不在里面」
    """
    names_url = domains.index_list_url(arch)
    try:
        response = requests.get(names_url, timeout=_as_request_timeout(timeout),
                                headers=github_api_headers(names_url), **tls.request_kwargs())
    except Exception as error:
        steplog.detail(f"package list failed: {error}")
        return None
    if response.status_code != 200:
        steplog.detail(f"package list HTTP {response.status_code}")
        return None
    return [name for name in domains.listing_names(response.text, dirs_only=True) if name]


def _explain_missing_version_list(package_name, arch, api_url, timeout):
    """`<包名>/versions` 404 时分清三件事，报错只报其中一件。

    三种原因的话术完全不同，混成一句「读不到版本清单」会让用户去查 GitHub 和镜像 ——
    而绝大多数情况只是包名打错了：

      名字清单拿不到      → 网络 / MACWAVE_API_DOMAIN / 镜像没生成清单
      名字不在清单里      → 包名错（最常见）；给出近似名与几个同类示例
      名字在、清单却 404  → 镜像缺这一份，数据问题

    这一步只多发一个请求，且只在 404 时发生。
    """
    names = fetch_package_names(arch, timeout)

    if names is None:
        steplog.fail(
            f"cannot reach the package list, so {package_name} cannot be checked",
            request=api_url,
            hint=["check MACWAVE_API_DOMAIN points at <mirror>/MacWave/infosource",
                  "if every package fails this way, the mirror has no versions lists "
                  "yet (see docs/MIRROR-SETUP.md)",
                  "check the network and any --proxy setting, then retry"])

    if not names:
        steplog.fail(
            f"the package list is empty, so {package_name} cannot be checked",
            request=api_url,
            hint=["the mirror has not generated its versions lists yet "
                  "(see docs/MIRROR-SETUP.md)",
                  "ask the administrator to re-run scripts/build_versions_index.py"])

    folded = {name.casefold() for name in names}
    if package_name.casefold() not in folded:
        close = closest_name(package_name, names)
        examples, label = name_examples(package_name, names)
        hint = []
        if close:
            # 建议先 `wave info`：它只读、不装任何东西，用户想核对版本也方便。
            # 直接给 `wave upgrade` 是错的 —— 这里同时服务 install 与 upgrade 两条路。
            hint.append(f"did you mean `{close}`?  try: wave info {close}")
        # 这一句是整段提示的目的：把「名字错」与「网络 / 镜像挂了」分开。
        # 用户看到「HTTP 404」时的第一反应是去查 GitHub 和镜像，而那通常不是原因。
        hint.append(f"the name was checked against all {len(names)} package name(s) "
                    f"in the index, so this is not a network or mirror problem")
        if examples:
            hint.append(f"{label}: " + ", ".join(examples))
        hint.append("list every match for part of a name: wave search <part of a name>")
        steplog.fail(f"no package named '{package_name}' in the index", hint=hint)

    # 名字确实存在，只是镜像没提供它的版本清单
    steplog.fail(
        f"the index has no version list for {package_name}",
        request=api_url,
        response="HTTP 404",
        hint=["the package name is right; the mirror is missing this file",
              "ask the administrator to re-run scripts/build_versions_index.py on the mirror",
              "if every package is like this, the mirror has no versions lists yet "
              "(see docs/MIRROR-SETUP.md)"])


def fetch_max_version(package_name, arch, timeout=DEFAULT_TIMEOUT):
    # 版本清单：默认走 GitHub API，设了索引镜像时读镜像自己的清单（见 domains.index_list_url）
    api_url = domains.index_list_url(arch, package_name)
    steplog.detail(f"GET {domains.redact_url(api_url)}")
    try:
        response = requests.get(api_url, timeout=_as_request_timeout(timeout),
                                headers=github_api_headers(api_url),
                                **tls.request_kwargs())
        if response.status_code != 200:
            if response.status_code == 404:
                _explain_missing_version_list(package_name, arch, api_url, timeout)
            steplog.fail(
                f"cannot read the version list for {package_name}",
                request=api_url,
                response=f"HTTP {response.status_code}",
                hint="check the network and any --proxy setting, then retry")

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


def _invoked_as():
    """用户敲的那个名字：`wave`，而不是 `wave.py`。报错里的命令要能直接照抄。"""
    name = Path(sys.argv[0]).name
    return "wave" if name.startswith("wave") else name


def _launcher_path():
    """启动器的绝对路径。

    `sudo wave install` 经常跑不通：sudo 默认 env_reset，PATH 被换成它自己的
    默认值，而 wave 在 <base_dir>/links 里 —— 那是用户自己加进 PATH 的目录。
    报错里给全路径，用户复制就能跑，不必先猜「为什么 command not found」。
    """
    launcher = BASE_DIR / "lib" / "wave"
    return str(launcher) if launcher.exists() else _invoked_as()


def handle_install(input_string):
    # 参数解析
    steplog.reset()
    steplog.plan(INSTALL_STEPS)

    # 先解析旗标、打开追踪，再报第一步 —— 否则 -v 自己的这一步会被漏掉
    config = handle_download_args(input_string)
    steplog.set_verbose(config["verbose"])

    # 系统级安装（装到 /opt、/usr/local）时安装树归 root:<管理员组>、775：
    # 管理员组成员直接写得进去，**不需要 sudo**。剩下的写不进去的人只有两类 ——
    # 不在管理员组里的普通用户，以及别的机器上搬过来的、组不对的旧安装。
    #
    # 不在这里先说清楚的话，报错会发生在下载那一步，还被归因成「网络或代理问题」——
    # 实测过：`Permission denied: .../downloads/tmp/xxx.partial`，提示全跑偏。
    if not os.access(BASE_DIR, os.W_OK):
        steplog.fail(
            f"no write permission on {BASE_DIR}",
            response=f"running as uid {os.getuid()}; this tree is owned by root and writable "
                     f"only by its group",
            hint=["packages can be installed by an administrator; give the full path "
                  "(sudo has its own PATH):",
                  f"  sudo {_launcher_path()} install <package>",
                  "everyone else can still run the installed packages",
                  "or reinstall into ~/.local/macwave to manage packages without sudo"])

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
        # 必须把解析好的 Budget 传下去：不传就用 DEFAULT_TIMEOUT（30 秒），
        # 于是 --connect-timeout / --content-time / --max-time 对这条命令的
        # 第一个请求完全无效 —— 而这正是最容易卡住的那个请求。
        ParsePkgVersion = fetch_max_version(ParsePkgName, ARCH, config["timeout"])
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
        resp = requests.get(pkg_version_url, timeout=config["timeout"].request_timeout,
                            **tls.request_kwargs())
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

    # 5.2 实验性：版本记录可以声明 min_os，低于它时警告并问一句（4.3 转正）。
    # 放在下载之前：答复是「不装」时不该先花带宽。
    if not confirm_min_os(resp.text, ParsePkgName, ParsePkgVersion, config["force"]):
        steplog.fail(
            f"not installing {ParsePkgName}@{ParsePkgVersion}: "
            "it declares a newer macOS than this machine runs",
            request=pkg_version_url,
            hint=["nothing was downloaded or installed",
                  "run it again and answer y at the prompt to install anyway",
                  f"`wave info {ParsePkgName}` shows the declaration"])

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
