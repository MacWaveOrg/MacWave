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


def options_from(input_string):
    """公共旗标走唯一的解析入口（cli/common.py）。

    与 install 的差别只剩「拿了值怎么用」：这里把三档超时的**原始文本**原样交给
    selfupdate.sh（它才是真正发请求的一层），预算则留给本层取版本数据时用。
    --proxy 由 wave.py 在分发前写进环境变量，子脚本的 curl 直接继承。

    返回 common.Options。
    """
    import common
    return common.parse(input_string or "")


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

# 最近一次取数失败的原因（诊断用）：返回值是 None，而「为什么」正是要分诊的东西。
LAST_ERROR = ""


def fetch_text(url, budget, raws=()):
    # 优先用标准库；本地 Python 缺根证书（macOS 常见）时改走 curl。
    # 带凭据的 URL 直走 curl：urllib 不认 user:pass@，会把它当主机名，白失败一次。
    #
    # 但 urllib 只有一个 socket 超时（连接与每次读共用），分不出三档。所以**只要
    # 命令行里给了任意一档超时就走 curl** —— 只有它能把三档分别表达出来。
    # 没给任何一档时照旧优先标准库，默认行为与以前一致。
    global LAST_ERROR

    LAST_ERROR = ""
    if not raws and not domains._has_userinfo(url):
        try:
            with urllib.request.urlopen(url, timeout=budget.total,
                                        **tls.urlopen_kwargs()) as response:
                return response.read().decode()
        except (urllib.error.URLError, UnicodeDecodeError, OSError) as error:
            LAST_ERROR = str(error)

    argv = ['curl', '-fsSL', '--retry', '2', '--retry-delay', '2',
            '--retry-connrefused', *curl_limit_args(budget), *tls.curl_flags(), url]
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        # curl 的 stderr 里带着真正的证书原因（"certificate has expired" 之类），
        # 比 urllib 那句 "CERTIFICATE_VERIFY_FAILED" 更好分诊；有就用它。
        LAST_ERROR = (result.stderr or "").strip() or LAST_ERROR
        return None
    return result.stdout


def fetch_version_data(budget, raws=(), url=None):
    return fetch_text(url or domains.selfupdate_latest_url(), budget, raws)


# 探针里的构建号字段名与已发布的 macwavedata/latest.toml 一致（`build_number`）。
# `build` 只作为读入时的兜底，不再写进任何文档或数据。
BUILD_KEYS = ("build_number", "build")


def data_build(data):
    """探针里的构建号；两个键都认，是为了不因为一次改名把已有数据读丢。"""
    for key in BUILD_KEYS:
        value = data.get(key, "")
        if value:
            return value
    return ""


def probe_is_newer(data, current, current_build):
    """这份探针里的版本比本机新吗（版本优先，版本相同看构建号）。"""
    return versioncompare.newer_release(data.get("version", ""), data_build(data),
                                        current, current_build)


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
#
# 4.6.0 的改动：项目许可证从 MIT 换成 Apache-2.0（新增第 35 条），协议因此在
# 2026-11-24 重新落款。许可证的变更改变了使用者手里的权利，所以必须重新征求同意，
# 不能沿用 4.4.0 那条记录。
AGREEMENT_ID = "2026-11-24"
AGREEMENT_URL = "https://macwave.org/#agreement"

# 从这一版起，安装包随版本带上新协议文本。装的是**这一版或更早**的人，同意过的是
# 旧文本，自更新时要问一次；装的是更新的版本，说明 install.sh 已经问过了
# （install.sh 里那道「Have you read and agreed」），不必再问。
#
# 这个判断方式比「读 VERSION.json 里记的协议号」更省事：4.4.0 之前的安装里根本没有
# 那个字段，而它们的共同点正是「版本号 ≤ 4.4.0」。比 4.4.0 新的安装一定来自一个
# 问过新协议的安装器 —— 这条推理对每一版都一样，所以每次改协议只改这个常量。
#
# 4.6.0：许可证换成 Apache-2.0 的那一版。装着 4.5.x 及更早的人自更新时会被问一次；
# 装 4.6.0 的人是 install.sh 问过并记下的，不会重问。
AGREEMENT_INTRODUCED_IN = "4.6.0"

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


# -------------------- 试运行 --------------------

DRY_RUN_FLAG = "--dry-run"


def wants_dry_run(input_string):
    return DRY_RUN_FLAG in (input_string or "").split()


def report_dry_run(current, latest, data, options, overall_timeout,
                   channel=versioncompare.CHANNEL_STABLE, crossed=False):
    """`--dry-run`：把「会做什么」打印出来，然后什么都不做。

    只读：本地版本、刚取到的版本数据、命令行里的旗标。**不**问协议、**不**写
    AGREEMENT.json、**不**建临时脚本、**不**跑 selfupdate.sh —— 所以它在任何机器上
    都能安全地跑一遍（代价只有一次取 latest.toml 的 GET）。
    """
    budget = options.timeouts

    def line(label, text):
        print(f"🌊   {label:<12} {text}")

    print(f"🌊 Dry run: MacWave would be updated from {current or 'unknown'} to {latest}.")

    if channel == versioncompare.CHANNEL_RC:
        line("channel", "rc (testing builds, follows rcdata/latest.toml)")
    else:
        line("channel", "stable")
    if data_build(data):
        line("build", data_build(data))
    if crossed:
        line("switch", "RC → stable as a *full* install (every file replaced)")
    if data.get("branch"):
        line("branch", data["branch"])
    if _is_cross_major(current, latest):
        # selfupdate.sh 不跨大版本；这里只是提前说清楚，免得用户以为 dry run 会装上去
        line("version", "this is a cross-major update: lib/selfupdate.sh refuses those, "
                        "reinstall from the release page instead")
    if not agreement_needs_consent(current):
        line("agreement", "not needed (already recorded, or this install already carries it)")
    elif _is_cross_major(current, latest):
        # 跨大版本本来就要重装，selfupdate 不会问协议 —— 说出来，别让人以为漏了一问
        line("agreement", "not asked: a cross-major update needs a reinstall, not selfupdate")
    else:
        line("agreement", f"would be asked ({AGREEMENT_ID}); accepting would record it in "
                          f"{AGREEMENT_FILE_NAME}")
    line("skip-ssl", "on" if tls.enabled() else "off")
    raws = ", ".join(f"{flag} {value}" for flag, value in options.timeout_raws.items())
    line("timeouts", f"connect {budget.connect:g}s, content {budget.content:g}s, "
                     f"total {budget.total:g}s" + (f" (from {raws})" if raws else " (defaults)"))
    if options.install_python_from_source:
        line("python", "fetched from its upstream URL")
    line("script", f"a temporary copy of lib/selfupdate.sh, overall timeout {overall_timeout}s")

    print(f"{GREEN}🌊 Nothing was downloaded and nothing was changed.{RESET}")


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


def installed_build():
    """本机的构建号（`323R1250` 这种）。4.4 之前的安装里没有这个字段，返回 None。"""
    path = version_file()
    if not path.exists():
        return None
    try:
        record = json.loads(path.read_text())
        return record.get("build_number") or record.get("build")
    except (ValueError, OSError):
        return None


# -------------------- 主流程 --------------------

def handle_selfupdate(input_string=""):
    if find_config_dir() is None:
        print(f"{RED_BOLD}🌊 Error: MacWave is not installed. Run lib/install.sh first.{RESET}")
        sys.exit(1)

    # 自更新会替换安装树里的程序文件：与装包/卸载互斥，否则两边同时写 pkg/ 与 lib/。
    # --dry-run 只看不动，不占锁。
    if wants_dry_run(input_string):
        return _handle_selfupdate_locked(input_string)
    from lock import tree_lock
    with tree_lock("selfupdate"):
        return _handle_selfupdate_locked(input_string)


def _handle_selfupdate_locked(input_string=""):

    # 先看本机装的是什么，再决定要不要联网 —— 判断渠道不需要网络，
    # 早退一步就少一次「Fetching the latest version...」之后的失败。
    #
    # 渠道由「装的是什么」推出来，客户端不记任何额外状态：
    #   -rc            → RC 渠道，读 rcdata/latest.toml，只跟 RC
    #   beta/alpha/dev → 仍然拒绝（它们没有自己的探针，跟正式版走会混分支）
    #   其余           → 正式渠道
    current = installed_version()
    current_build = installed_build()
    channel = versioncompare.channel_for(current)
    if channel == versioncompare.CHANNEL_BETA:
        refuse_on_prerelease(current)

    options = options_from(input_string)
    timeout_raws = options.timeout_raws
    budget = options.timeouts
    install_python_from_source = options.install_python_from_source
    dry_run = wants_dry_run(input_string)

    print("🌊 Fetching the latest version...")

    data = None
    crossed_from_rc = False
    if channel == versioncompare.CHANNEL_RC:
        text = fetch_version_data(budget, timeout_raws, domains.selfupdate_rc_latest_url())
        if text is not None:
            candidate = version_data(text)
            if probe_is_newer(candidate, current, current_build):
                data = candidate
            # 否则 RC 渠道没有更新的构建，接着看正式版 —— 渠道收尾之后，
            # 正式版就是出路（走全量，见下面 MACWAVE_FULL_INSTALL）。

    if data is None:
        stable_url = domains.selfupdate_latest_url()
        text = fetch_version_data(budget, timeout_raws, stable_url)
        if text is None:
            print(f"{RED_BOLD}🌊 Error: Cannot reach the MacWave version data.{RESET}")
            print(f"{RED_BOLD}🌊 {domains.redact_url(stable_url)}{RESET}")
            # 证书过期 / 自签 / 链不完整 / 主机名不匹配 / 纯网络：五种的下一步不同
            explained = tls.explain(LAST_ERROR, stable_url)
            if explained is not None:
                for index, line in enumerate([explained[0]] + explained[1]):
                    prefix = "🌊 Next      " if index == 0 else "🌊           "
                    print(f"{RED_BOLD}{prefix}{line}{RESET}")
            sys.exit(1)
        data = version_data(text)
        crossed_from_rc = (channel == versioncompare.CHANNEL_RC
                           and probe_is_newer(data, current, current_build))
    latest = data.get("version", "")
    latest_build = data_build(data)
    if not latest:
        print(f"{RED_BOLD}🌊 Error: The version data has no 'version' field.{RESET}")
        sys.exit(1)

    if channel == versioncompare.CHANNEL_RC:
        print("🌊 Channel: RC (testing builds) — updates follow rcdata/latest.toml")
    else:
        print("🌊 Channel: stable")
    print(f"🌊 Latest version found: {latest}"
          + (f" (build {latest_build})" if latest_build else ""))

    if not probe_is_newer(data, current, current_build):
        where = f"build {current_build}" if current_build else "no build number"
        print(f"{GREEN}🌊 MacWave is already up to date (current: {current}, {where}).{RESET}")
        if dry_run:
            print("🌊 Dry run: nothing would be downloaded or changed.")
        sys.exit(0)

    if channel == versioncompare.CHANNEL_RC and not crossed_from_rc:
        print("🌊 The RC channel has no newer build, and the stable release is not newer either.")

    if crossed_from_rc:
        print(f"{YELLOW}🌊 The RC channel has no newer build; the stable release "
              f"{latest} is newer.{RESET}")
        print(f"{YELLOW}🌊 Moving to it as a full install: every file is replaced, so no "
              f"RC and stable files end up in the same tree.{RESET}")

    # 试运行在**问协议之前**结束：它既不该弹询问，也不该写 AGREEMENT.json。
    # 这一段的判断全是只读的（版本比较、协议是否已记录）。
    if dry_run:
        report_dry_run(current, latest, data, options,
                       max(UPDATE_TIMEOUT, int(budget.total) * 20),
                       channel=versioncompare.channel_for(latest),
                       crossed=crossed_from_rc)
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
    # 编排脚本还要自己取一份 latest.toml（验签与哈希都对着那份），所以渠道也得传，
    # 否则它会去读正式版探针，验的是另一份数据。
    environment["MACWAVE_UPDATE_CHANNEL"] = versioncompare.channel_for(latest)
    if latest_build:
        environment["MACWAVE_UPDATE_BUILD"] = latest_build
    if crossed_from_rc:
        # 跨渠道必须全量：增量按目标分支的文件列表铺，盖在 RC 树上就是两条线混装。
        environment["MACWAVE_FULL_INSTALL"] = "1"
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
    final_build = installed_build()
    reached = bool(final) and version_key(final) >= version_key(latest) and (
        version_key(final) != version_key(latest)
        or not versioncompare.is_newer_build(latest_build, final_build))
    if not reached:
        print(f"{RED_BOLD}🌊 Error: The update did not complete (still on "
              f"{final or 'unknown'}"
              f"{f', build {final_build}' if final_build else ''}).{RESET}")
        sys.exit(1)

    print("")
    print(f"{GREEN}🌊 MacWave has been updated to {final}"
          f"{f' (build {final_build})' if final_build else ''}!{RESET}")

    # wave.py 会被覆盖，但当前进程已经加载完了，直接退出即可
    sys.exit(0)


if __name__ == "__main__":
    handle_selfupdate()
