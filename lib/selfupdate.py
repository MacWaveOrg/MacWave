#!/usr/bin/env python3

# selfupdate.py

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'


# -------------------- 常量 --------------------

from configpaths import VERSION_FILE_NAME, config_dir_candidates, find_config_dir
import domains

FETCH_TIMEOUT = 30
UPDATE_TIMEOUT = 1800


# -------------------- 超时 --------------------

def max_time(input_string):
    # `--max-time` 从**原始命令行**里取（规则见 pkginstaller._parse_duration），
    # 本层只用它约束自己的请求；同一个值原样交给 selfupdate.sh，由那边再解析一次。
    # 中间不替任何人算好，命令行怎么写就怎么生效。
    # 返回 (原始文本, 秒数)：没有该旗标时原始文本为空、秒数取默认。
    if not input_string:
        return "", FETCH_TIMEOUT

    from pkginstaller import _parse_duration, flag_value

    raw = flag_value(input_string, "--max-time") or ""
    if not raw:
        return "", FETCH_TIMEOUT

    seconds = _parse_duration(raw)
    if seconds is None:
        print(f"{RED_BOLD}🌊 Error: cannot parse --max-time value '{raw}'.{RESET}")
        print(f"{RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.{RESET}")
        sys.exit(1)
    return raw, seconds


def curl_seconds(timeout):
    # curl 的 --max-time 收小数，但 0 表示「不限」，所以至少给 1 秒
    return max(1, int(round(timeout)))


# -------------------- 版本数据 --------------------

def fetch_text(url, timeout=FETCH_TIMEOUT):
    # 优先用标准库；本地 Python 缺根证书（macOS 常见）时改走 curl
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read().decode()
    except (urllib.error.URLError, UnicodeDecodeError, OSError):
        pass

    result = subprocess.run(['curl', '-fsSL',
                             '--max-time', str(curl_seconds(timeout)),
                             '--retry', '2', '--retry-delay', '2', '--retry-connrefused',
                             url],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout


def fetch_version_data(timeout=FETCH_TIMEOUT):
    return fetch_text(domains.selfupdate_latest_url(), timeout)


def run_script(environment, overall_timeout):
    # 编排脚本（lib/selfupdate.sh）随安装树一起发布，文件下载由它再去取
    # macwavedata/<版本>/update_commands.sh 完成。
    #
    # **必须从临时副本执行**：更新过程会覆盖 lib/selfupdate.sh 自己，而 bash 是
    # 边读边执行的，被覆盖的正文会让运行中的脚本读到半截内容。复制一份再跑，
    # 覆盖就发生在「已经读完的副本」之外，不影响本次执行。
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "selfupdate.sh")

    print("🌊 Preparing the update script for this version...")

    try:
        with open(source, encoding="utf-8") as stream:
            text = stream.read()
    except OSError:
        print(f"{RED_BOLD}🌊 Error: Cannot read the update script.{RESET}")
        print(f"{RED_BOLD}🌊 {source}{RESET}")
        sys.exit(1)

    handle, path = tempfile.mkstemp(prefix="macwave-selfupdate-", suffix=".sh")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
        return subprocess.run(['/bin/bash', path], env=environment, timeout=overall_timeout)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def version_data(text):
    # 4.0 的版本数据是 macwavedata/latest.toml，平铺的 key = "value"。
    # 3.x 那种「冒号 + 可选 update_command 块」的格式随 files_info 一起退休了。
    try:
        return domains.parse_simple_toml(text)
    except ValueError as error:
        print(f"{RED_BOLD}🌊 Error: The version data is not valid TOML ({error}).{RESET}")
        sys.exit(1)


def version_key(value):
    # 只比较数字段（2.3 -> [2, 3, 0, 0]），避免依赖 packaging
    parts = [int(part) for part in re.findall(r'\d+', str(value))]
    while len(parts) < 4:
        parts.append(0)
    return parts


def version_file():
    # 配置目录可能在上一次升级里被迁移（见 update_commands.sh 里的迁移步骤），
    # 所以每次都重新解析一遍，不要用模块级常量。
    config_dir = find_config_dir()
    if config_dir is not None:
        return config_dir / VERSION_FILE_NAME
    return config_dir_candidates()[0] / VERSION_FILE_NAME


def installed_version():
    path = version_file()
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text()).get("version")
    except (ValueError, OSError):
        return None


# -------------------- 主流程 --------------------

def handle_selfupdate(input_string=""):
    if find_config_dir() is None:
        print(f"{RED_BOLD}🌊 Error: MacWave is not installed. Run lib/install.sh first.{RESET}")
        sys.exit(1)

    max_time_raw, timeout = max_time(input_string)
    install_python_from_source = "--install-python-from-source" in input_string.split()

    print("🌊 Fetching the latest version...")

    text = fetch_version_data(timeout)
    if text is None:
        print(f"{RED_BOLD}🌊 Error: Cannot reach the MacWave version data.{RESET}")
        print(f"{RED_BOLD}🌊 {domains.selfupdate_latest_url()}{RESET}")
        sys.exit(1)

    data = version_data(text)
    latest = data.get("version", "")
    if not latest:
        print(f"{RED_BOLD}🌊 Error: The version data has no 'version' field.{RESET}")
        sys.exit(1)

    print(f"🌊 Latest version found: {latest}")

    current = installed_version()
    if current and version_key(current) >= version_key(latest):
        print(f"{GREEN}🌊 MacWave is already up to date (current: {current}).{RESET}")
        sys.exit(0)

    if current:
        print(f"🌊 Updating MacWave from {current} to {latest}...")
    else:
        print(f"{YELLOW}🌊 No installed version found, updating to {latest}...{RESET}")

    # 分支与目标版本通过环境变量传给 selfupdate.sh，避免脚本自己去猜。
    # --max-time 也这样传：原样传文本，让脚本自己解析（它才是真正发请求的那一层）。
    environment = dict(os.environ)
    environment["MACWAVE_UPDATE_VERSION"] = latest
    if data.get("branch"):
        environment["MACWAVE_UPDATE_BRANCH"] = data["branch"]
    if install_python_from_source:
        # 解释器默认从我们自己的 Python 仓库取；这个开关让 selfupdate.sh 回上游取
        environment["MACWAVE_INSTALL_PYTHON_FROM_SOURCE"] = "1"
    if max_time_raw:
        environment["MACWAVE_MAX_TIME"] = max_time_raw

    # 一轮更新要串行下载十几个文件，每个最多重试几次；单次超时被调大时，
    # 整体上限也要跟着放大，否则会在一半的地方被这里杀掉。
    overall_timeout = max(UPDATE_TIMEOUT, int(timeout) * 20)

    try:
        result = run_script(environment, overall_timeout)
    except subprocess.TimeoutExpired:
        print(f"{RED_BOLD}🌊 Error: The update command timed out.{RESET}")
        sys.exit(1)

    if result.returncode != 0:
        print(f"{RED_BOLD}🌊 Error: The update command failed (exit code {result.returncode}).{RESET}")
        sys.exit(1)

    # 下载由 update_commands.sh 完成，它可能在某些路径上吞掉非零退出码，
    # 所以这里以 VERSION.json 的实际内容为准，避免误报成功
    final = installed_version()
    if not final or version_key(final) < version_key(latest):
        print(f"{RED_BOLD}🌊 Error: The update did not complete (still on {final or 'unknown'}).{RESET}")
        sys.exit(1)

    print("")
    print(f"{GREEN}🌊 MacWave has been updated to {final}!{RESET}")

    # wave.py 会被覆盖，但当前进程已经加载完了，直接退出即可
    sys.exit(0)


if __name__ == "__main__":
    handle_selfupdate()
