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
import versioncompare
import tls

FETCH_TIMEOUT = 30
UPDATE_TIMEOUT = 1800


# -------------------- 超时 --------------------

# 旗标名 → 传给 selfupdate.sh 的环境变量。原样传文本，让脚本自己再解析一次，
# 保证「命令行怎么写就怎么生效」，两边不会各算一套。
TIMEOUT_ENV = {
    "--max-time": "MACWAVE_MAX_TIME",
    "--connect-timeout": "MACWAVE_CONNECT_TIMEOUT",
    "--content-time": "MACWAVE_CONTENT_TIME",
}


def timeouts_from(input_string):
    """三档超时都从**原始命令行**里取，规则只有 net/timeouts.py 一份。

    返回 (原始文本字典, Budget)。原始文本要原样交给 selfupdate.sh —— 那才是
    真正发请求的一层，不能替它算好。
    """
    from timeouts import FLAG_FIELDS, flag_value, from_command_line

    def reject(flag, raw):
        print(f"{RED_BOLD}🌊 Error: cannot parse {flag} value '{raw}'.{RESET}")
        print(f"{RED_BOLD}🌊 Use a number of seconds or a suffix like 40s, 1min, 1min20s, 2h.{RESET}")
        sys.exit(1)

    budget = from_command_line(input_string or "", fail=reject)
    raws = {}
    for flag in FLAG_FIELDS:
        raw = flag_value(input_string or "", flag)
        if raw:
            raws[flag] = raw
    return raws, budget


def curl_seconds(timeout):
    # curl 收小数，但 0 表示「不限」，所以至少给 1 秒
    return max(1, int(round(timeout)))


def curl_limit_args(budget):
    """把 Budget 翻成 curl 的旗标。

    curl 侧一一对应：握手是 --connect-timeout，总额是 --max-time；
    「连上了多久收不到数据算失败」没有同名旗标，用 --speed-limit 1 --speed-time N
    表达 —— 阈值压到 1 字节/秒，等价于「只要还在收数据就不算超时」。
    """
    return ["--max-time", str(curl_seconds(budget.total)),
            "--connect-timeout", str(curl_seconds(budget.connect)),
            "--speed-limit", "1", "--speed-time", str(curl_seconds(budget.content))]


# -------------------- 版本数据 --------------------

def fetch_text(url, budget, raws=()):
    # 优先用标准库；本地 Python 缺根证书（macOS 常见）时改走 curl。
    # 带凭据的 URL 直走 curl：urllib 不认 user:pass@，会把它当主机名，白失败一次。
    #
    # 但 urllib 只有一个 socket 超时（连接与每次读共用），分不出三档。所以**只要
    # 命令行里给了任意一档超时就走 curl** —— 只有它能把三档分别表达出来。
    # 没给任何一档时照旧优先标准库，默认行为与以前一致。
    if not raws and not domains._has_userinfo(url):
        try:
            with urllib.request.urlopen(url, timeout=budget.total,
                                        **tls.urlopen_kwargs()) as response:
                return response.read().decode()
        except (urllib.error.URLError, UnicodeDecodeError, OSError):
            pass

    argv = ['curl', '-fsSL', '--retry', '2', '--retry-delay', '2',
            '--retry-connrefused', *curl_limit_args(budget), *tls.curl_flags(), url]
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout


def fetch_version_data(budget, raws=()):
    return fetch_text(domains.selfupdate_latest_url(), budget, raws)


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


# 版本比较只看一处（lib/versioncompare.py）。以前这里是「只比数字段」的实现，于是
# 4.4.0-beta1 被判成比 4.4.0 大 —— 装过 beta 的人永远等不到正式版。
version_key = versioncompare.sort_key


# 官方安装入口。beta 用户被拦下来之后要照着这条命令重装，所以写在这里而不是
# 只在文案里 —— 同一个地址在 install.sh 的用法注释、官网、发布说明里也有，
# 改的时候一起改。
# 命令里的 curl 也带 --max-time：这条是给用户抄的，没有超时就会一直挂着。
# scripts/net_policy_test.sh 里那条契约同样要求每个 curl 有超时 —— 打印出来的也算。
INSTALL_SH_URL = "https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh"
INSTALL_SH_TIMEOUT = "--max-time 60"
RELEASE_TAG_URL = "https://github.com/MacWaveOrg/MacWave/releases/tag"


def refuse_on_prerelease(current):
    """当前装的是 beta / rc 时，拒绝 selfupdate 并给出重装命令。

    为什么必须拒绝，而不是「让它升到正式版」：beta 与正式版在**不同分支**上，
    selfupdate 取的增量是按 latest.toml 里那条正式版分支算的。把它的文件盖在一棵
    beta 树上，得到的是两条线混在一起的安装（2026-11-15 那次 wave 启动即崩，
    就是这么来的）。重装是唯一安全的路径 —— 它走全量，且由 install.sh 重新
    决定分支。

    消息全部用 RED_BOLD：这不是用法提示，是「你什么都没装成」的失败。
    """
    print(f"{RED_BOLD}🌊 Error: MacWave {current} is a beta build, and selfupdate does not "
          f"handle beta builds.{RESET}")
    print(f"{RED_BOLD}🌊 Why       betas live on their own branch; selfupdate would mix two "
          f"lines of code in one tree.{RESET}")
    print(f"{RED_BOLD}🌊 Next      install the version you want from its Release page:{RESET}")
    print(f"{RED_BOLD}🌊           stable: /bin/bash -c \"$(curl -fsSL {INSTALL_SH_TIMEOUT} {INSTALL_SH_URL})\"{RESET}")
    print(f"{RED_BOLD}🌊           this beta: {RELEASE_TAG_URL}/v{current}{RESET}")
    print(f"{RED_BOLD}🌊 Your current installation has not been changed.{RESET}")
    sys.exit(1)


# -------------------- 用户协议 --------------------

# 协议标识 = 官网「用户协议」那一节的落款日期。改协议时改这里，**并且必须与官网
# 的落款日期一致** —— 不一致的后果是「问的是新协议、用户同意了，客户端记下的却是
# 另一个标识」，于是下次再问一遍。官网正文见 https://macwave.org/agreement/
AGREEMENT_ID = "2026-11-17"
AGREEMENT_URL = "https://macwave.org/#agreement"

# 从这一版起，安装包随版本带上新协议文本。装的是**这一版或更早**的人，同意过的是
# 旧文本，自更新时要问一次；装的是更新的版本，说明 install.sh 已经问过了
# （install.sh 里那道「Have you read and agreed」），不必再问。
#
# 这个判断方式比「读 VERSION.json 里记的协议号」更省事：4.4.0 之前的安装里根本没有
# 那个字段，而它们的共同点正是「版本号 ≤ 4.4.0」。比 4.4.0 新的安装一定来自一个
# 问过新协议的安装器。
AGREEMENT_INTRODUCED_IN = "4.4.0"

# 同意记录单独一个文件，不塞进 VERSION.json：那份文件由 update_commands.sh 与
# install.sh 写（按版本冻结、两条线的写法还不一样），把协议状态放进去会被它们覆盖掉。
AGREEMENT_FILE_NAME = "AGREEMENT.json"


def agreement_file():
    config_dir = find_config_dir()
    if config_dir is not None:
        return config_dir / AGREEMENT_FILE_NAME
    return config_dir_candidates()[0] / AGREEMENT_FILE_NAME


def recorded_agreement():
    path = agreement_file()
    if not path.exists():
        return ""
    try:
        return json.loads(path.read_text()).get("agreement", "") or ""
    except (ValueError, OSError, AttributeError):
        return ""


def agreement_needs_consent(current):
    """升级到这个版本之前，要不要问一次协议。

    只管「已经装着的版本」：全新安装由 install.sh 自己问。
    """
    if recorded_agreement() == AGREEMENT_ID:
        return False
    if not current:
        return False
    return versioncompare.version(current) <= versioncompare.version(AGREEMENT_INTRODUCED_IN)


def record_agreement():
    path = agreement_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"agreement": AGREEMENT_ID}, indent=2) + "\n")
    except OSError as error:
        # 记不下来不该让更新失败 —— 代价只是下次再问一次，比「更新到一半退出」轻。
        print(f"{YELLOW}🌊 Warning: cannot record the agreement acceptance ({error}).{RESET}")


def _wants_silence():
    # -s / --silent 会把 fd 1、2 指到 /dev/null，于是任何提示都看不见。
    # 延迟 import：selfupdate.py 也有 `python3 lib/selfupdate.py` 这条直接路径，
    # 那时 cli/ 可能不在 sys.path 上。
    try:
        import silent
    except ImportError:
        return False
    try:
        return bool(silent.is_silent())
    except AttributeError:
        return False


def _say_on_terminal(lines):
    # 静默模式下 stderr 也进了 /dev/null，只能直接写终端设备。
    # 没有终端（CI、管道）时什么都不写 —— 退出码是唯一的信号，与 -s 的约定一致。
    try:
        with open("/dev/tty", "w", encoding="utf-8") as tty:
            for line in lines:
                tty.write(line + "\n")
    except OSError:
        pass


def _refuse_agreement(current, silent):
    if silent:
        # 静默模式不能替用户同意，也不该挂在 input() 上等 —— 提示写终端，
        # 然后按「没有同意」退出。
        _say_on_terminal([
            f"🌊 Error: the user agreement was updated ({AGREEMENT_ID}) and cannot be "
            f"accepted in silent mode.",
            "🌊 Next      run `wave selfupdate` without -s to read and accept it",
            f"🌊           {AGREEMENT_URL}",
            f"🌊 Your current installation ({current}) has not been changed.",
        ])
    else:
        print(f"{RED_BOLD}🌊 Error: the updated user agreement was not accepted.{RESET}")
        print(f"{RED_BOLD}🌊 Next      your installation is unchanged; you are still on {current}.{RESET}")
        print(f"{RED_BOLD}🌊           read it when you like, then run selfupdate again:{RESET}")
        print(f"{RED_BOLD}🌊           {AGREEMENT_URL}{RESET}")
    sys.exit(1)


def _is_cross_major(current, latest):
    """这次更新是不是跨大版本。

    只用来决定**要不要问协议**，不参与拒绝：跨大版本的更新本来就装不了（要重装），
    在它上面问「同不同意新协议」纯属噪音 —— 用户答应了也还是得去官网重装。
    真正的拒绝在 lib/selfupdate.sh 里（那里才是唯一判定处，因为 selfupdate.sh 才是
    「从目标分支拉下来执行」的那一份，每个大版本自带自己的规则）。
    """
    def major_of(value):
        match = re.search(r"[0-9]+", str(value or ""))
        return match.group(0) if match else ""

    left, right = major_of(current), major_of(latest)
    return bool(left) and bool(right) and left != right


def confirm_agreement(current):
    """协议更新后的同意询问。

    不同意就中止，而不是「同意了才能继续」那种软提示：按协议第 2 条，用户可以选择
    放弃更新、继续用他已经同意的那一版 —— 中止就是那个选项。

    白名单语义与 `--skip-ssl` 一致：只有明确答复 y/Y 才继续，空回车、EOF、
    「yes」一律按拒绝处理。同意必须是明确表达，不能靠默认值。
    """
    if _wants_silence():
        _refuse_agreement(current, silent=True)

    print(f"{RED_BOLD}🌊 MacWave's user agreement has been updated ({AGREEMENT_ID}).{RESET}")
    print(f"{YELLOW}🌊 Read it here: {AGREEMENT_URL}{RESET}")
    print(f"{RED_BOLD}🌊 If you do not accept it, MacWave will not be updated and you keep "
          f"{current}.{RESET}")
    print(f"{RED_BOLD}🌊 Do you accept the updated agreement? [y/N]{RESET}")

    try:
        answer = input().strip()
    except (EOFError, KeyboardInterrupt):
        # 非交互（stdin 是 /dev/null）读不到答复：按拒绝处理，缺省往安全方向倒。
        answer = ""

    if answer not in ("y", "Y"):
        _refuse_agreement(current, silent=False)

    record_agreement()
    print(f"{GREEN}🌊 Agreement accepted ({AGREEMENT_ID}).{RESET}")


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

    # 先看本机装的是什么，再决定要不要联网 —— 判断 beta 不需要网络，
    # 早退一步就少一次「Fetching the latest version...」之后的失败。
    current = installed_version()
    if current and versioncompare.is_prerelease(current):
        refuse_on_prerelease(current)

    timeout_raws, budget = timeouts_from(input_string)
    install_python_from_source = "--install-python-from-source" in input_string.split()

    print("🌊 Fetching the latest version...")

    text = fetch_version_data(budget, timeout_raws)
    if text is None:
        print(f"{RED_BOLD}🌊 Error: Cannot reach the MacWave version data.{RESET}")
        print(f"{RED_BOLD}🌊 {domains.redact_url(domains.selfupdate_latest_url())}{RESET}")
        sys.exit(1)

    data = version_data(text)
    latest = data.get("version", "")
    if not latest:
        print(f"{RED_BOLD}🌊 Error: The version data has no 'version' field.{RESET}")
        sys.exit(1)

    print(f"🌊 Latest version found: {latest}")

    if current and version_key(current) >= version_key(latest):
        print(f"{GREEN}🌊 MacWave is already up to date (current: {current}).{RESET}")
        sys.exit(0)

    # 「确实要更新」之后才问协议：没东西可装的时候不打扰人。
    # 也正因为这个位置，问的是「要不要跨过这道门槛去做这次更新」——
    # 与协议第 2 条给的选项（放弃更新 / 继续用已同意的那一版）对得上。
    if agreement_needs_consent(current) and not _is_cross_major(current, latest):
        confirm_agreement(current)

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
    # 三档超时原样交给脚本，由它自己再解析一次
    for flag, value in timeout_raws.items():
        environment[TIMEOUT_ENV[flag]] = value
    if tls.enabled():
        # 脚本里的 curl 也要知道：-k 与 requests 的 verify=False 同义
        environment["MACWAVE_SKIP_SSL"] = "1"

    # 一轮更新要串行下载十几个文件，每个最多重试几次；单次超时被调大时，
    # 整体上限也要跟着放大，否则会在一半的地方被这里杀掉。
    overall_timeout = max(UPDATE_TIMEOUT, int(budget.total) * 20)

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
