#!/usr/bin/env python3

# random_test.py
# 随机化端到端回归（CI 用）。设计要点：
#
#   1. 每次随机挑一个「安装目录方案」（含 33% 概率的自定义方案 ~/test dir），
#      自己把脚本部署进去，跑完无论成败都清理干净。
#   2. 从 infosource 的 pkginfo_<arch> 里随机抽 10~20 个软件包（必含 wget），
#      下载体积超过 40MB 的包重抽；逐个 install → 校验 → uninstall。
#   3. 指定版本号 / 不指定版本号各占一半，但两组都必须落在 [5, 15] 内，否则重抽。
#      指定版本号的包里，1~2 个给「不存在的版本」，1~2 个给「非法版本」，其余正常。
#   4. 三种特殊模式各至少一次：-C 断点续传（随机打断 0~3 次，含进度条渲染）、
#      --skip-ssl（提示 + 正常下载）、--limit-rate（全程限速监测 + 结尾复核平均速度）。
#   4b. 每个普通安装另有 5% 概率在 Mach-O 重定向（surfboard/transfer.sh）中途被 SIGINT 打断，
#       只要求「不崩 + 再装一次能收敛到正确状态」。打断会真的杀掉 install_name_tool，
#       所以有可能留下半改写的 Mach-O——这正是要观察的。
#   5. 固定命令覆盖：list / search / info / selfupdate / link / linkquery / unlink 各 5 次。
#   6. 5 个非法命令；裸 -h/--help/-V/--version 以及它们带非法参数的形式。
#   7. 任何命令都可能有 10% 概率被插入非法参数。
#   8. 等效参数的长/短形式随机（-h/--help、-V/--version、-a/--all、-C/--continue、-v/--verbose）。
#   9. 随机池排除 test_* 测试夹具；单个产物体积上限 40MB。
#
# 安全约束：只清理本次运行亲手创建的目录；已存在的配置目录（可能是一份真实安装）
# 与已存在的非空安装目录一律拒绝覆盖并直接报错。
#
# 用法：
#   python3 scripts/random_test.py [--dry-run] [--keep] [--seed N] [--count N]
#                                  [--packages a,b,c] [--infosource DIR] [--limit-rate 400K]
#
# --dry-run 只做选择与参数生成并把计划打出来，不碰网络、不执行 wave（本地自测用）。

import argparse
import json
import os
import pty
import random
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

try:
    import requests
except ImportError:
    requests = None


# -------------------- 可调参数 --------------------

PKG_COUNT_MIN = 10
PKG_COUNT_MAX = 20
MAX_ARTIFACT_BYTES = 40 * 1024 * 1024        # 超过这个体积的包重抽
SPECIFIED_MIN = 5                            # 「指定版本号」的包数下限
SPECIFIED_MAX = 15                           # 「指定版本号」的包数上限
CUSTOM_DIR_PROBABILITY = 0.33                # 抽到 `~/test dir` 的概率
ILLEGAL_ARG_PROBABILITY = 0.10               # 任何命令插入非法参数的概率
ALWAYS_PACKAGES = ("wget",)
COMMAND_BATTERY = {
    "list": 5,
    "search": 5,
    "info": 5,
    "selfupdate": 5,
    "link": 5,
    "linkquery": 5,
    "unlink": 5,
}
ILLEGAL_COMMAND_COUNT = 5
HELP_VERSION_CASES = 8
BOGUS_VERSION_COUNT = (1, 2)                 # 不存在 / 非法版本各 1~2 个

NONEXISTENT_VERSIONS = ("999.999.999", "0.0.0-does-not-exist", "12345.6789.0")
ILLEGAL_VERSIONS = ("not-a-version", "1.0.0-!!!", "..%2f..%2fetc%2fpasswd", "v1.2.3@beta")

ILLEGAL_FLAGS = ("--bogus", "-Z", "--no-such-flag", "-Q", "--definitely-not-a-flag")

# 限速校验容差：token bucket 每次最多多放 8192 字节，所以瞬时值放宽
LIMIT_RATE_INSTANT_TOLERANCE = 1.5
LIMIT_RATE_OVERALL_TOLERANCE = 1.25

RESUME_INTERRUPT_ROUNDS = (0, 3)             # -C 的随机打断次数范围
RESUME_MIN_SECONDS = 2.0                     # 至少下这么久才允许打断（避开元数据阶段）
TRANSFER_INTERRUPT_PROBABILITY = 0.05        # Mach-O 重定向中途打断的概率
RESUME_MIN_BYTES = 512 * 1024                # 断点续传：至少下了这么多才打断
RESUME_RATE_LIMIT = "300K"                   # 断点续传时故意限速，否则下载太快根本来不及打断

SIZE_PROBE_TIMEOUT = 8                       # 单次 HEAD 超时
SIZE_PROBE_BUDGET_SECONDS = 60               # 探体积总预算；用尽就按「体积未知」放行
HEARTBEAT_SECONDS = 30                       # 长命令心跳间隔
PTY_FEED_SECONDS = 2.0                       # pty 里定期喂空行，避免 wave 的 input() 没人应答而挂死
RESUME_MIN_ARTIFACT = 5 * 1024 * 1024        # 断点续传挑体积够大的包
SKIP_SSL_MAX_ARTIFACT = 3 * 1024 * 1024      # --skip-ssl 挑小包，跑两遍不拖时间
LIMIT_RATE_MIN_ARTIFACT = 2 * 1024 * 1024    # 限速测试挑够大的包才测得出速度

REPO_DIR = Path(__file__).resolve().parent.parent
ARCH_MAP = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64", "amd64": "amd64"}


# -------------------- 结果记录 --------------------

class Report:
    def __init__(self):
        self.passed = 0
        self.failed = []
        self.warned = []
        self.skipped = []

    def ok(self, label):
        self.passed += 1
        print(f"  PASS  {label}")

    def fail(self, label, detail=""):
        self.failed.append((label, detail))
        print(f"  FAIL  {label}" + (f"  <- {detail}" if detail else ""))

    def warn(self, label, detail=""):
        self.warned.append((label, detail))
        print(f"  WARN  {label}" + (f"  <- {detail}" if detail else ""))

    def skip(self, label, detail=""):
        self.skipped.append((label, detail))
        print(f"  SKIP  {label}" + (f"  <- {detail}" if detail else ""))

    def check(self, label, condition, detail=""):
        if condition:
            self.ok(label)
        else:
            self.fail(label, detail)
        return bool(condition)


def banner(text):
    print("")
    print(f"===== {text} =====")


# -------------------- 安装目录方案 --------------------

MARKER_NAME = ".macwave-random-test"


class Layout:
    """一次运行使用的安装目录 + 配置目录，以及需要清理的东西。

    created_* 只在 setup_environment 真正创建了对应目录时才置位；
    cleanup 只删自己创建的东西，绝不碰已存在的目录（这条曾经踩过坑）。
    """

    def __init__(self, name, base_dir, home_dir, config_dir):
        self.name = name
        self.base_dir = base_dir
        self.home_dir = home_dir          # 传给子进程的 HOME（配置目录就在它下面）
        self.config_dir = config_dir
        self.created_base = False
        self.created_config = False
        self.created_home = False

    @property
    def env(self):
        env = dict(os.environ)
        env["HOME"] = str(self.home_dir)
        return env

    @property
    def version_file(self):
        return self.config_dir / "VERSION.json"

    @property
    def partial_dir(self):
        return self.base_dir / "downloads" / "tmp"


def choose_layout(rng, config_dir_override=None):
    """随机挑一种安装目录方案；自定义方案（~/test dir）占 33%。"""
    home = Path(os.path.expanduser("~"))
    runner_temp = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir()))
    token = f"{rng.randrange(16**8):08x}"

    standard = [
        # 1. 常规随机：候选父目录里随机挑一个，拼随机目录名
        ("random-user-local", home / ".local" / f"macwave-{token}", home),
        ("random-runner-temp", runner_temp / f"macwave-{token}", home),
        ("random-tmp", Path(tempfile.gettempdir()) / f"macwave-{token}", home),
        # 2. 安装目录 + 配置目录都随机（换个 HOME 就换了 ~/.config/macwave_config）
        ("random-home-and-base", home / ".macwave-{token}".replace("{token}", token),
         Path(tempfile.gettempdir()) / f"mwhome-{token}"),
        # 3. 难缠路径：带空格、带中文、深层嵌套
        ("path-with-space", home / f"macwave test {token}", home),
        ("path-with-unicode", home / f"macwave 测试 {token}" / "deep" / "deeper" / "base", home),
    ]

    if rng.random() < CUSTOM_DIR_PROBABILITY:
        name, base, home_dir = "custom-test-dir", home / "test dir", home
    else:
        name, base, home_dir = rng.choice(standard)

    config_dir = (Path(config_dir_override).expanduser() if config_dir_override
                  else home_dir / ".config" / "macwave_config")
    print(f"🌊 layout: {name}")
    print(f"🌊   base_dir   = {base}")
    print(f"🌊   HOME       = {home_dir}")
    if home_dir != home:
        print("🌊   （配置目录随 HOME 一起随机）")
    return Layout(name, base, home_dir, config_dir)


def setup_environment(layout):
    """把仓库脚本部署到随机安装目录，并写好 config.json / VERSION.json。

    安全约束（务必要守住，否则会删掉用户自己或真实安装目录里的东西）：
      - 已存在的配置目录一律不碰：那可能是一份真实安装，直接报错让调用方换地方。
      - 安装目录已存在且非空、又不带本测试的标记文件时，拒绝删除。
    """
    system_config = Path("/opt/macwave_config")
    if system_config.exists():
        raise RuntimeError(
            f"{system_config} 存在，系统级配置会盖住随机配置；请先移除它再跑本测试")

    if layout.config_dir.exists() and any(layout.config_dir.iterdir()):
        raise RuntimeError(
            f"{layout.config_dir} 已存在且非空，可能是一份真实安装，拒绝覆盖。"
            f"请用 --config-dir 指向一个空目录，或使用随机 HOME 的目录方案")

    if layout.base_dir.exists():
        if any(layout.base_dir.iterdir()) and not (layout.base_dir / MARKER_NAME).exists():
            raise RuntimeError(
                f"{layout.base_dir} 已存在且不是本测试创建的目录，拒绝清空它")

    real_home = Path(os.path.expanduser("~"))
    if layout.home_dir != real_home:
        layout.home_dir.mkdir(parents=True, exist_ok=True)
        layout.created_home = True

    shutil.rmtree(layout.base_dir, ignore_errors=True)
    for name in ("bin", "links", "pkg", "surfboard", "lib", "deps", "downloads/tmp"):
        (layout.base_dir / name).mkdir(parents=True, exist_ok=True)
    (layout.base_dir / MARKER_NAME).write_text("created by scripts/random_test.py\n")
    layout.created_base = True

    for src, dst in (
        (REPO_DIR / "pkg", layout.base_dir / "pkg"),
        (REPO_DIR / "surfboard", layout.base_dir / "surfboard"),
        (REPO_DIR / "lib", layout.base_dir / "lib"),
    ):
        for item in src.iterdir():
            if item.suffix in (".py", ".sh"):
                shutil.copy2(item, dst / item.name)

    shutil.copy2(REPO_DIR / "lib" / "wave.py", layout.base_dir / "lib" / "wave")

    for target in list((layout.base_dir / "lib").glob("*")) + \
                  list((layout.base_dir / "pkg").glob("*.sh")) + \
                  list((layout.base_dir / "surfboard").glob("*.sh")) + \
                  [layout.base_dir / "lib" / "wave"]:
        target.chmod(0o755)

    layout.config_dir.mkdir(parents=True, exist_ok=True)
    layout.created_config = True
    (layout.config_dir / "config.json").write_text(
        json.dumps({"base_dir": str(layout.base_dir)}, indent=2))
    (layout.config_dir / "VERSION.json").write_text(
        json.dumps({"version": installed_version_for_selfupdate()}, indent=2))

    print(f"🌊 deployed scripts into {layout.base_dir}")


def installed_version_for_selfupdate():
    """让 selfupdate 走「已是最新」的短路分支，避免随机测试真的去更新安装目录。

    真的自更新由 scripts/selfupdate_test.sh 专门覆盖；这里只关心命令的反应。
    """
    url = "https://raw.githubusercontent.com/MacWaveOrg/configdata/main/versiondata/latest_version"
    try:
        if requests is not None:
            text = requests.get(url, timeout=20).text
        else:
            import urllib.request
            with urllib.request.urlopen(url, timeout=20) as response:
                text = response.read().decode()
        match = re.search(r'version:\s*"([^"]+)"', text)
        if match:
            return match.group(1)
    except Exception:
        pass
    return "3.0.1"


def cleanup(layout, keep=False):
    """只删本次 setup_environment 亲手创建的东西；没创建过就一个字节都不动。"""
    if keep:
        print(f"🌊 --keep: 保留 {layout.base_dir}")
        return
    if layout.created_base and layout.base_dir.exists():
        shutil.rmtree(layout.base_dir, ignore_errors=True)
        print(f"🌊 removed {layout.base_dir}")
    if layout.created_config and layout.config_dir.exists():
        shutil.rmtree(layout.config_dir, ignore_errors=True)
        print(f"🌊 removed {layout.config_dir}")
    if layout.created_home and layout.home_dir.exists():
        shutil.rmtree(layout.home_dir, ignore_errors=True)
        print(f"🌊 removed {layout.home_dir}")


# -------------------- infosource 数据 --------------------


def locate_infosource(explicit):
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    if os.environ.get("INFOSOURCE_DIR"):
        candidates.append(Path(os.environ["INFOSOURCE_DIR"]))
    candidates += [REPO_DIR / "infosource-data", REPO_DIR / "infosource"]
    for candidate in candidates:
        if (candidate / "pkg").is_dir():
            return candidate
    raise RuntimeError("找不到 infosource 数据（试过 --infosource、$INFOSOURCE_DIR、"
                       "infosource-data/、infosource/）")


def detect_arch():
    machine = os.uname().machine.lower()
    if machine not in ARCH_MAP:
        raise RuntimeError(f"未知架构: {machine}")
    return ARCH_MAP[machine]


def load_catalog(source, arch):
    """{包名: {版本: (url, sha256, bin_name, deps)}}，从本地 infosource 检出读。"""
    root = source / "pkg" / f"pkginfo_{arch}"
    if not root.is_dir():
        raise RuntimeError(f"{root} 不存在")

    catalog = {}
    for pkg_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        name = pkg_dir.name
        common = pkg_dir / f"_{name}@common"
        if not common.is_file():
            continue
        fields = parse_fields(common.read_text())
        bin_name = first(fields, "bin_name")
        if not bin_name:
            continue

        versions = {}
        for entry in sorted(pkg_dir.glob(f"_{name}@*")):
            version = entry.name.split("@", 1)[1]
            if version == "common":
                continue
            version_fields = parse_fields(entry.read_text())
            url = first(version_fields, "url")
            if not url:
                continue
            versions[version] = (url, first(version_fields, "sha256") or "", bin_name,
                                 get_deps(version_fields))
        if versions:
            catalog[name] = versions
    return catalog


def parse_fields(text):
    """与 surfboard/depsinstaller.py 的 DSL 规则一致。"""
    fields = {}
    current_key = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        head = line.split('"', 1)[0]
        if ':' in head:
            current_key = head.split(':', 1)[0].strip()
            fields.setdefault(current_key, [])
            value_text = line[len(head):]
        else:
            if current_key is None:
                continue
            value_text = line
        for value in re.findall(r'"([^"]*)"', value_text):
            fields[current_key].append(value)
    return fields


def first(fields, key, default=None):
    values = fields.get(key)
    return values[0] if values else default


def get_deps(fields):
    return [value for value in fields.get("depends", fields.get("deps", [])) if value.strip()]


def max_version(versions):
    """复用仓库自己的版本排序，避免在这里另造一套规则。"""
    sys.path.insert(0, str(REPO_DIR / "pkg"))
    try:
        from pkgversionparser import get_max_version
        return get_max_version(list(versions))
    finally:
        sys.path.pop(0)


class Tee:
    """同时写原 stdout 与日志文件；CI 里靠它把整轮日志落盘给 artifact 上传。"""

    def __init__(self, *streams):
        self.streams = streams

    def write(self, data):
        for stream in self.streams:
            stream.write(data)
            stream.flush()
        return len(data)

    def flush(self):
        for stream in self.streams:
            stream.flush()

    def isatty(self):
        return False


def start_heartbeat(label, interval=HEARTBEAT_SECONDS):
    """长命令期间定期打点，避免 CI 日志出现无法解释的长时间空白。"""
    stop = threading.Event()
    started = time.monotonic()

    def beat():
        while not stop.wait(interval):
            print(f"  … still running: {label} ({time.monotonic() - started:.0f}s)", flush=True)

    thread = threading.Thread(target=beat, daemon=True)
    thread.start()
    return stop


class SizeProber:
    """HEAD 探体积，带缓存、短超时和总预算。

    预算用尽或探测失败都返回 None（按「体积未知」放行）——宁可跑慢一点，
    也不能像最初那样在 CI 里静默等几十分钟。
    """

    def __init__(self, timeout=SIZE_PROBE_TIMEOUT, budget=SIZE_PROBE_BUDGET_SECONDS):
        self.timeout = timeout
        self.budget = budget
        self.spent = 0.0
        self.cache = {}
        self.exhausted = False

    def size(self, url, label=""):
        if url in self.cache:
            return self.cache[url]

        if self.spent >= self.budget:
            if not self.exhausted:
                self.exhausted = True
                print(f"🌊 探体积预算 {self.budget:.0f}s 用尽，剩余包按「体积未知」放行", flush=True)
            self.cache[url] = None
            return None

        started = time.monotonic()
        size = self._probe(url)
        elapsed = time.monotonic() - started
        self.spent += elapsed
        self.cache[url] = size
        shown = f"{size / 1048576:.1f}MB" if size is not None else "未知"
        print(f"🌊 probing {label or url}: {shown} ({elapsed:.1f}s)", flush=True)
        return size

    def _probe(self, url):
        try:
            if requests is not None:
                response = requests.head(url, allow_redirects=True, timeout=self.timeout)
                length = response.headers.get("Content-Length")
                if length is None or response.status_code >= 400:
                    return None
                return int(length)
            import urllib.request
            request = urllib.request.Request(url, method="HEAD")
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                length = response.headers.get("Content-Length")
                return int(length) if length else None
        except Exception:
            return None


# -------------------- 计划（选择 + 参数生成） --------------------


class PackagePlan:
    def __init__(self, name, bin_name, versions, mode="normal"):
        self.name = name
        self.bin_name = bin_name
        self.versions = versions
        self.mode = mode               # normal / resume / skip-ssl / limit-rate
        self.specified = False         # 是否在命令行里指定版本号
        self.version = None            # 指定时用哪个版本
        self.bogus = None              # None / "nonexistent" / "illegal"
        self.artifact_bytes = None

    @property
    def token(self):
        return f"{self.name}@{self.version}" if self.specified else self.name


def select_packages(rng, catalog, report, count_override=None, explicit=None,
                    prober=None, include_test=False):
    """抽 10~20 个包，必含 wget，超过 40MB 的重抽。

    test_* 是 format_test.sh 的测试夹具，默认不进随机池。
    """
    pool = sorted(name for name in catalog
                  if include_test or not name.startswith("test"))
    if explicit:
        wanted = [name for name in explicit if name in catalog]
        missing = [name for name in explicit if name not in catalog]
        if missing:
            raise RuntimeError(f"指定的包不在数据里: {', '.join(missing)}")
        target = len(wanted)
    else:
        target = count_override or rng.randint(PKG_COUNT_MIN, PKG_COUNT_MAX)
        wanted = []

    for name in ALWAYS_PACKAGES:
        if name in catalog and name not in wanted:
            wanted.append(name)

    candidates = [name for name in pool if name not in wanted]
    rng.shuffle(candidates)

    plans = []
    for name in wanted:
        plans.append(make_plan(name, catalog[name]))

    attempts = 0
    max_attempts = max(4 * target, 40)
    while len(plans) < target and candidates and attempts < max_attempts:
        name = candidates.pop()
        attempts += 1
        plan = make_plan(name, catalog[name])
        url = plan.versions[max_version(plan.versions)][0]
        size = prober.size(url, label=name) if prober else None
        plan.artifact_bytes = size
        if size is not None and size > MAX_ARTIFACT_BYTES:
            report.skip(f"package {name}", f"{size / 1048576:.1f}MB > 40MB，重抽")
            continue
        plans.append(plan)

    if not (count_override or explicit) and len(plans) < PKG_COUNT_MIN:
        raise RuntimeError(f"可用包不足：只凑到 {len(plans)} 个")
    return plans


def make_plan(name, versions):
    return PackagePlan(name, versions[max_version(versions)][2], versions)


def assign_versions(rng, plans, report):
    """指定/不指定版本号各占一半，但两组都必须落在 [5, 15] 内。"""
    count = len(plans)
    low = max(SPECIFIED_MIN, count - SPECIFIED_MAX)
    high = min(SPECIFIED_MAX, count - SPECIFIED_MIN)
    if low > high:
        raise RuntimeError(f"{count} 个包无法满足「指定/不指定各 {SPECIFIED_MIN}~{SPECIFIED_MAX}」")
    specified = rng.randint(low, high)

    chosen = rng.sample(plans, specified)
    for plan in plans:
        plan.specified = plan in chosen
        # 无论是否在命令行里写版本号，都要记下「预期装出来的版本」：
        # 不指定时安装器取的就是最高版本，后续校验目录名要用它。
        plan.version = max_version(plan.versions)

    # 指定版本号的包里：1~2 个不存在的版本、1~2 个非法版本，其余正常
    order = chosen[:]
    rng.shuffle(order)
    low, high = BOGUS_VERSION_COUNT
    nonexistent = order[:rng.randint(low, high)]
    illegal = order[len(nonexistent):len(nonexistent) + rng.randint(low, high)]
    for plan in nonexistent:
        plan.bogus = "nonexistent"
        plan.version = rng.choice(NONEXISTENT_VERSIONS)
    for plan in illegal:
        plan.bogus = "illegal"
        plan.version = rng.choice(ILLEGAL_VERSIONS)

    print(f"🌊 {count} 个包：指定版本号 {specified} 个"
          f"（其中不存在 {len(nonexistent)}、非法 {len(illegal)}），不指定 {count - specified} 个")
    return plans


def assign_modes(rng, plans, prober):
    """三种特殊模式各至少一次，各自挑合适的包。体积走 prober 的缓存，不会重复探测。"""
    remaining = [plan for plan in plans if not plan.bogus]
    rng.shuffle(remaining)

    def take(predicate, mode, description):
        for plan in remaining:
            size = plan.artifact_bytes
            if size is None and prober is not None:
                size = prober.size(plan.versions[max_version(plan.versions)][0], label=plan.name)
                plan.artifact_bytes = size
            if size is not None and predicate(size):
                plan.mode = mode
                remaining.remove(plan)
                print(f"🌊 {mode}: {plan.name} ({size / 1048576:.1f}MB)")
                return True
        print(f"🌊 跳过特殊模式 {mode}：{description}", flush=True)
        return False

    take(lambda size: size >= RESUME_MIN_ARTIFACT, "resume", "没有 ≥5MB 的包可做断点续传")
    take(lambda size: size <= SKIP_SSL_MAX_ARTIFACT, "skip-ssl", "没有 ≤3MB 的包可做 --skip-ssl")
    take(lambda size: size >= LIMIT_RATE_MIN_ARTIFACT, "limit-rate", "没有 ≥2MB 的包可做 --limit-rate")
    return plans


# -------------------- wave 调用 --------------------


class Wave:
    def __init__(self, layout, report, limit_rate):
        self.layout = layout
        self.report = report
        self.limit_rate = limit_rate
        self.entry = REPO_DIR / "lib" / "wave.py"
        self.commands = 0

    def _begin(self, argv):
        self.commands += 1
        label = f"wave {' '.join(argv)}"
        print(f"▶ [{self.commands}] {label}", flush=True)
        return label

    def _end(self, label, returncode, started, output=""):
        mark = "✔" if returncode == 0 else "✘"
        print(f"{mark} {label} rc={returncode} ({time.monotonic() - started:.1f}s)", flush=True)
        if returncode != 0 and output:
            tail = " | ".join(line.strip() for line in output.splitlines() if line.strip())[-300:]
            print(f"    输出尾部: {tail}", flush=True)

    def run(self, argv, timeout=1800, stdin=None, env_extra=None):
        label = self._begin(argv)
        env = self.layout.env
        if env_extra:
            env.update(env_extra)
        started = time.monotonic()
        stop = start_heartbeat(label)
        try:
            result = subprocess.run(
                [sys.executable, str(self.entry), *argv],
                input=stdin, capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            print(f"  ✘ {label} 超时（{timeout}s）", flush=True)
            raise
        finally:
            stop.set()
        self._end(label, result.returncode, started, (result.stdout or "") + (result.stderr or ""))
        return result

    def partial_path(self, url):
        return self.layout.partial_dir / (url.split("/")[-1] + ".partial")

    def run_inline(self, argv, timeout=30):
        label = f"binary {Path(argv[0]).name} {' '.join(argv[1:])}".strip()
        started = time.monotonic()
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                                env=self.layout.env)
        self._end(label, result.returncode, started, (result.stdout or "") + (result.stderr or ""))
        return result

    def run_in_pty(self, argv, timeout=1800, on_tick=None, tick=0.25, interrupt_when=None):
        """在 pty 里跑 wave，这样 rich 的进度条才会真正渲染；可中途发 SIGINT。

        期间定期往 pty 喂一个空行：wave 在下载失败时会 input() 问是否重试，
        pty 里没人应答会一直阻塞到 timeout，那是最难排查的一种"挂死"。
        """
        label = self._begin(argv)
        started = time.monotonic()
        stop = start_heartbeat(label)
        master, slave = pty.openpty()
        env = self.layout.env
        env["COLUMNS"] = "100"
        proc = subprocess.Popen([sys.executable, str(self.entry), *argv],
                                stdin=slave, stdout=slave, stderr=slave,
                                env=env, start_new_session=True, close_fds=True)
        os.close(slave)
        chunks = []
        deadline = started + timeout
        next_tick = time.monotonic()
        next_feed = time.monotonic() + PTY_FEED_SECONDS
        interrupted = False
        try:
            while True:
                if time.monotonic() > deadline:
                    os.killpg(proc.pid, signal.SIGKILL)
                    break
                readable, _, _ = select.select([master], [], [], 0.05)
                if readable:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        data = b""
                    chunks.append(data.decode("utf-8", "replace"))
                now = time.monotonic()
                if on_tick and now >= next_tick:
                    try:
                        on_tick()
                    except Exception:
                        pass
                    next_tick = now + tick
                if now >= next_feed:
                    try:
                        os.write(master, b"\n")
                    except OSError:
                        pass
                    next_feed = now + PTY_FEED_SECONDS
                if interrupt_when and proc.poll() is None and interrupt_when():
                    os.killpg(proc.pid, signal.SIGINT)
                    interrupted = True
                    interrupt_when = None
                if proc.poll() is not None:
                    # 进程退出后再把缓冲区读干净
                    while select.select([master], [], [], 0.05)[0]:
                        try:
                            data = os.read(master, 65536)
                        except OSError:
                            break
                        if not data:
                            break
                        chunks.append(data.decode("utf-8", "replace"))
                    break
        finally:
            os.close(master)
            stop.set()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()

        output = "".join(chunks)
        self._end(label, proc.returncode or 0, started, output)
        return PtyResult(output, proc.returncode or 0,
                         bool(PROGRESS_PATTERN.search(output)), interrupted)


# -------------------- 断言辅助 --------------------


TRACEBACK = "Traceback (most recent call last)"
# 这些标记说明是 api.github.com 的问题（未认证 60 次/小时），不是 MacWave 的 bug
API_FAILURE_MARKERS = ("API rate limit exceeded", "rate limit", "HTTP 403", "HTTP 429",
                       "Cannot fetch package list")


def no_traceback(output):
    return TRACEBACK not in output


def is_rate_limited(result):
    """接受 CompletedProcess / PtyResult / 字符串，判断是不是 GitHub API 侧的问题。"""
    if isinstance(result, str):
        text = result
    elif hasattr(result, "as_result"):
        text = result.as_result.stdout or ""
    else:
        text = (getattr(result, "stdout", "") or "") + (getattr(result, "stderr", "") or "")
    lowered = text.lower()
    return any(marker.lower() in lowered for marker in API_FAILURE_MARKERS)


def describe(result):
    text = (result.stdout or "") + (result.stderr or "")
    return " | ".join(line.strip() for line in text.splitlines() if line.strip())[:300]


def expect(checks, result, rc, label, must_contain=(), must_not_contain=()):
    """统一断言：退出码 + 关键输出 + 不许抛栈。"""
    out = (result.stdout or "") + (result.stderr or "")
    checks.check(f"{label}: exit={rc}", result.returncode == rc,
                 f"实际 {result.returncode} :: {describe(result)}")
    checks.check(f"{label}: 无 Python 栈回溯", no_traceback(out), describe(result))
    for needle in must_contain:
        checks.check(f"{label}: 输出含 {needle!r}", needle in out, describe(result))
    for needle in must_not_contain:
        checks.check(f"{label}: 输出不含 {needle!r}", needle not in out, describe(result))


# -------------------- 阶段 1：随机包的安装循环 --------------------


def install_token(plan):
    return plan.token


def random_flag(rng, short, long):
    return rng.choice((short, long))


def maybe_illegal_arg(rng):
    return rng.choice(ILLEGAL_FLAGS) if rng.random() < ILLEGAL_ARG_PROBABILITY else None


def uninstall_token(plan):
    """卸载要用 bin_name：安装目录是 bin/<bin_name>@<版本>，
    包名和 bin_name 不一定相同（例如 choma -> ChOma）。"""
    return f"{plan.bin_name}@{plan.version}" if plan.specified else plan.bin_name


def phase_install_cycle(wave, rng, plans, checks):
    banner("阶段 1：随机软件包 install → 校验")
    installed = []
    for plan in plans:
        label = f"install {install_token(plan)}"
        argv = ["install", install_token(plan)]

        if plan.mode == "limit-rate":
            argv += ["--limit-rate", wave.limit_rate]
        elif plan.mode == "skip-ssl":
            argv += ["--skip-ssl"]
        elif plan.mode == "resume":
            argv += [random_flag(rng, "-C", "--continue")]

        illegal = maybe_illegal_arg(rng)
        if illegal:
            argv.append(illegal)

        if plan.bogus:
            # 负向用例：不存在的版本 / 非法版本都必须干净失败
            result = wave.run(argv)
            if is_rate_limited(result):
                checks.skip(label, "GitHub API 侧失败（限流/403），跳过断言")
                continue
            checks.check(f"{label}（{plan.bogus}）: 退出码非 0", result.returncode != 0,
                         describe(result))
            checks.check(f"{label}（{plan.bogus}）: 无 Python 栈回溯",
                         no_traceback((result.stdout or "") + (result.stderr or "")),
                         describe(result))
            continue

        if illegal:
            result = wave.run(argv)
            expect(checks, result, 1, f"{label} + 非法参数 {illegal}",
                   must_contain=("illegal",))
            continue

        if plan.mode == "resume":
            ok = run_resume_case(wave, rng, plan, checks)
        elif plan.mode == "skip-ssl":
            ok = run_skip_ssl_case(wave, plan, checks)
        elif plan.mode == "limit-rate":
            ok = run_limit_rate_case(wave, plan, checks)
        elif rng.random() < TRANSFER_INTERRUPT_PROBABILITY:
            ok = run_transfer_interrupt_case(wave, plan, checks)
        else:
            ok = run_plain_install(wave, plan, checks)

        if ok:
            installed.append(plan)

    return installed


def run_plain_install(wave, plan, checks):
    label = f"install {plan.token}"
    result = wave.run(["install", plan.token])
    if is_rate_limited(result):
        checks.skip(label, "GitHub API 侧失败（限流/403），跳过断言")
        return False
    expect(checks, result, 0, label,
           must_contain=("Successfully installed",),
           must_not_contain=("Server does not support resume",))
    return verify_installed(wave, plan, checks, label)


def verify_installed(wave, plan, checks, label):
    """装完之后的硬断言：目录、软链接、SHA256 校验、二进制能跑、list 能看到。"""
    bin_dir = wave.layout.base_dir / "bin" / f"{plan.bin_name}@{plan.version}"
    link = wave.layout.base_dir / "links" / plan.bin_name

    ok = True
    ok &= checks.check(f"{label}: 目录 {bin_dir.name} 存在", bin_dir.is_dir(), str(bin_dir))
    ok &= checks.check(f"{label}: 不带版本号的链接存在", link.is_symlink(), str(link))

    listed = wave.run(["list"])
    ok &= checks.check(f"{label}: list 里有它", f"{plan.bin_name}@{plan.version}" in listed.stdout,
                       describe(listed))

    ok &= binary_runs(wave, plan, checks, label)
    return bool(ok)


def binary_runs(wave, plan, checks, label):
    """二进制至少要能起来；dyld 报错说明路径替换没做对，必须失败。"""
    link = wave.layout.base_dir / "links" / plan.bin_name
    if not link.exists():
        return True
    for extra in ("--version", "-V", "--help"):
        try:
            result = wave.run_inline([str(link), extra], timeout=30)
        except Exception as error:
            checks.warn(f"{label}: 执行 {plan.bin_name} {extra} 失败", str(error))
            continue
        text = result.stdout + result.stderr
        if has_dyld_error(text):
            mismatch = dependency_symbol_mismatch(text)
            if mismatch:
                symbol, library = mismatch
                checks.warn(f"{label}: {plan.bin_name} 缺符号 {symbol}（{library} 没导出，"
                            "疑似 infosource 包数据不匹配，非路径重定向问题）", text[:200])
                return True
            checks.fail(f"{label}: {plan.bin_name} 有未解析的动态库", text[:200])
            return False
        if result.returncode == 0:
            checks.ok(f"{label}: {plan.bin_name} {extra} 可执行")
            return True
    checks.warn(f"{label}: 没找到可用的 --version/-V/--help 调用方式（不算失败）")
    return True


def run_transfer_interrupt_case(wave, plan, checks):
    """Mach-O 重定向（transfer.sh）中途打断：允许留半成品，但必须能再装一次收敛。

    打断会连 install_name_tool 一起杀掉，所以可能留下半改写的 Mach-O。
    这里不判定「半成品」本身是失败（只 WARN 记录），硬性要求是：
      - 进程干净退出（无栈回溯）
      - 重新 install 能装到完整正确（SHA256 通过、二进制能跑、list 能看到）
    """
    label = f"install {plan.token}（重定向中打断）"
    banner(f"Mach-O 重定向中途打断：{plan.name}")

    result = wave.run_in_pty(["install", plan.token], interrupt_when=transfer_watcher(),
                             timeout=1800)
    if not result.interrupted:
        checks.warn(f"{label}: 没抓到 transfer.sh 的窗口，本轮按普通安装校验")
        expect(checks, result.as_result, 0, f"install {plan.token}",
               must_contain=("Successfully installed",))
        return verify_installed(wave, plan, checks, f"install {plan.token}")

    checks.check(f"{label}: 退出码非 0", result.returncode != 0, f"实际 {result.returncode}")
    checks.check(f"{label}: 无 Python 栈回溯", no_traceback(result.output),
                 describe_text(result.output))
    if "Operation cancelled by user." not in result.output and result.returncode != 130:
        checks.warn(f"{label}: 没看到取消提示", describe_text(result.output))

    # 打断后的残留：现状会留下半个 bin/ 目录且被 `wave list` 显示出来，先记录不判定
    half_dir = wave.layout.base_dir / "bin" / f"{plan.bin_name}@{plan.version}"
    listed = wave.run(["list"])
    half_listed = f"{plan.bin_name}@{plan.version}" in listed.stdout
    if half_dir.exists() or half_listed:
        checks.warn(f"{label}: 打断后留下半装状态",
                    f"bin 目录={half_dir.exists()} list 可见={half_listed}")

    # 恢复：再装一次必须完全正确
    recovery = wave.run(["install", plan.token])
    if is_rate_limited(recovery):
        checks.skip(f"{label} → 重新 install", "GitHub API 侧失败（限流/403）")
        return False
    expect(checks, recovery, 0, f"{label} → 重新 install",
           must_contain=("Successfully installed",))
    return verify_installed(wave, plan, checks, f"{label} → 重新 install")


def transfer_watcher(interval=1.0):
    """节流过的 transfer.sh 观察器：run_in_pty 每 50ms 会问一次，别每次都去 ps。"""
    state = {"next": 0.0}

    def watch():
        now = time.monotonic()
        if now < state["next"]:
            return False
        state["next"] = now + interval
        return transfer_running()

    return watch


def transfer_running():
    """surfboard/transfer.sh 是否正在跑（用进程表判断，transfer.sh 自己不打进度）。"""
    try:
        listing = subprocess.run(["ps", "-Ao", "command="],
                                 capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return False
    return "transfer.sh" in listing


def run_resume_case(wave, rng, plan, checks):
    """-C 断点续传：随机打断 0~3 次，每次都要接着上次的字节继续，最后完整装好。"""
    rounds = rng.randint(*RESUME_INTERRUPT_ROUNDS)
    flag = random_flag(rng, "-C", "--continue")
    label = f"install {plan.token} {flag}"
    banner(f"-C 断点续传：{plan.name}（计划打断 {rounds} 次）")

    url = plan.versions[plan.version][0]
    partial = wave.partial_path(url)
    interrupted_bytes = 0
    actual_rounds = 0

    for index in range(rounds):
        start_size = partial.stat().st_size if partial.exists() else 0
        started = time.monotonic()
        # 打断轮故意限速：不限速时 12MB 的包不到 1 秒就下完了，根本来不及打断
        # （上一轮 CI 就是这样，计划打断 1 次，实际 0 次）。
        result = wave.run_in_pty(
            ["install", plan.token, flag, "--limit-rate", RESUME_RATE_LIMIT],
            interrupt_when=lambda: (partial.exists()
                                    and partial.stat().st_size >= start_size + RESUME_MIN_BYTES
                                    and time.monotonic() - started >= RESUME_MIN_SECONDS),
            timeout=1800)
        if not result.interrupted:
            # 还没轮到打断就已经装完了（包小或网快），后面不必再打断
            break
        actual_rounds += 1
        checks.check(f"-C 第 {actual_rounds} 次打断: 退出码非 0", result.returncode != 0,
                     f"实际 {result.returncode}")
        checks.check(f"-C 第 {actual_rounds} 次打断: 无 Python 栈回溯",
                     no_traceback(result.output), describe_text(result.output))
        checks.check(f"-C 第 {actual_rounds} 次打断: 进度条有渲染", result.progress_rendered,
                     f"pty 输出里没看到百分比：{result.output[-200:]}")
        if not partial.exists():
            checks.fail(f"-C 第 {actual_rounds} 次打断: .partial 应保留", str(partial))
            return False
        size = partial.stat().st_size
        checks.check(f"-C 第 {actual_rounds} 次打断: .partial 未回退（{size} ≥ {interrupted_bytes}）",
                     size >= interrupted_bytes,
                     f"回退了 {interrupted_bytes - size} 字节（服务器不支持 Range？）")
        interrupted_bytes = size

    watched = {"min_size": interrupted_bytes}

    def watch():
        if partial.exists():
            watched["min_size"] = min(watched["min_size"], partial.stat().st_size)

    result = wave.run_in_pty(["install", plan.token, flag], on_tick=watch, timeout=1800)
    text = result.output
    checks.check("-C 续传没有重头开始（.partial 从未回退）",
                 watched["min_size"] >= interrupted_bytes,
                 f"最小 {watched['min_size']} < 打断时 {interrupted_bytes}（服务器不支持 Range？）")
    checks.check("-C 没有出现“服务器不支持续传”提示",
                 "Server does not support resume" not in text, describe_text(text))
    checks.check("-C 续传进度条有渲染", result.progress_rendered, text[-200:])
    expect(checks, result.as_result, 0, f"{label}（续传）",
           must_contain=("Successfully installed",))
    if actual_rounds == 0:
        checks.warn(f"{label}: 实际打断 0 次（本轮只验证了 -C 的正常下载）")
    return verify_installed(wave, plan, checks, label)


def run_skip_ssl_case(wave, plan, checks):
    """--skip-ssl：既要看到安全提示，也要能正常下载。"""
    banner(f"--skip-ssl：{plan.name}")
    ok = True
    for answer, expect_skip in (("n", False), ("y", True)):
        label = f"install {plan.token} --skip-ssl (answer={answer})"
        argv = ["install", plan.token, "--skip-ssl"]
        result = wave.run(argv, stdin=f"{answer}\n")
        expect(checks, result, 0, label, must_contain=("You selected --skip-ssl",))
        if answer == "n":
            checks.check(f"{label}: 回答 n 时不跳过校验",
                         "SHA256 verification passed!" in (result.stdout + result.stderr),
                         describe(result))
        if not verify_installed(wave, plan, checks, label):
            ok = False
        # 每次装完都卸掉，下一轮才是干净的首次安装
        wave.run(["uninstall", uninstall_token(plan)])
    return ok


def run_limit_rate_case(wave, plan, checks):
    """--limit-rate：全程采样看是否超速，结尾再用 体积/时间 复核全程平均速度。"""
    banner(f"--limit-rate {wave.limit_rate}：{plan.name}")
    url = plan.versions[plan.version][0]
    partial = wave.partial_path(url)
    limit = parse_rate(wave.limit_rate)

    samples = []
    watched = {"last_size": 0, "last_time": None}

    def sample():
        if not partial.exists():
            return
        now = time.monotonic()
        size = partial.stat().st_size
        if watched["last_time"] is None:
            watched["last_time"] = now
            watched["last_size"] = size
            return
        delta_t = now - watched["last_time"]
        if delta_t < 0.2:
            return
        samples.append((now, size, (size - watched["last_size"]) / delta_t))
        watched["last_time"] = now
        watched["last_size"] = size

    started = time.monotonic()
    result = wave.run_in_pty(["install", plan.token, "--limit-rate", wave.limit_rate],
                             on_tick=sample, tick=0.2, timeout=1800)
    elapsed = time.monotonic() - started
    total_bytes = plan.artifact_bytes or 0

    expect(checks, result.as_result, 0, f"install {plan.token} --limit-rate",
           must_contain=("Successfully installed",))

    if limit and samples:
        steady = [rate for stamp, size, rate in samples if rate > 0]
        peak = max(steady) if steady else 0
        checks.check(
            f"--limit-rate {wave.limit_rate}: 瞬时未超速（峰值 {peak / 1024:.0f}K/s，"
            f"容差 x{LIMIT_RATE_INSTANT_TOLERANCE}）",
            peak <= limit * LIMIT_RATE_INSTANT_TOLERANCE,
            f"峰值 {peak / 1024:.0f}K/s > {limit * LIMIT_RATE_INSTANT_TOLERANCE / 1024:.0f}K/s")

    if limit and total_bytes and elapsed > 1:
        average = total_bytes / elapsed
        checks.check(
            f"--limit-rate {wave.limit_rate}: 全程平均未超速"
            f"（{total_bytes / 1048576:.1f}MB / {elapsed:.1f}s = {average / 1024:.0f}K/s）",
            average <= limit * LIMIT_RATE_OVERALL_TOLERANCE,
            f"{average / 1024:.0f}K/s > {limit * LIMIT_RATE_OVERALL_TOLERANCE / 1024:.0f}K/s")
    else:
        checks.warn("--limit-rate: 缺少体积信息，跳过全程平均速度校验")

    return verify_installed(wave, plan, checks, f"install {plan.token} --limit-rate")


def parse_rate(text):
    text = text.strip().upper()
    multipliers = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}
    try:
        if text[-1] in multipliers:
            return float(text[:-1]) * multipliers[text[-1]]
        return float(text)
    except (ValueError, IndexError):
        return None


# -------------------- 阶段 2：固定命令覆盖 --------------------


def predict(cmd, argv, installed, links):
    """按实测行为预测 (退出码, 必须包含的输出)。

    installed 是已安装的名字集合，links 是当前存在「不带版本号链接」的名字集合。
    预测必须跟着链接状态走，否则 unlink 之后 linkquery 会被误判成失败。
    """
    words = argv[1:]
    if "-h" in words or "--help" in words:
        return 0, ("usage:",)

    if cmd == "list":
        return 0, ()
    if cmd == "search":
        if not words:
            return 1, ("Missing search query.",)
        return 0, ()
    if cmd == "info":
        operands = [w for w in words if not w.startswith("-")]
        if not operands or not operands[0].partition("@")[0]:
            return 1, ("Missing package name.",)
        return 0, ()
    if cmd == "selfupdate":
        return 0, ()

    operands = [w for w in words if not w.startswith("-")]
    everything = any(w in ("-a", "--all") for w in words)

    if cmd == "link":
        if not operands and not everything:
            return 1, ("Nothing to link",)
        return 0, ()
    if cmd == "unlink":
        if not operands and not everything:
            return 1, ("Nothing to unlink",)
        return 0, ()
    if cmd == "linkquery":
        if not operands and not everything:
            return 1, ("Missing package name",)
        if operands and not everything:
            name = operands[0].partition("@")[0]
            if name not in links:
                return 1, ("is not linked",)
        return 0, ()
    raise AssertionError(cmd)


def apply_link_state(cmd, argv, installed, links):
    """命令跑完后更新 harness 侧的链接状态，供后续 predict 使用。"""
    words = argv[1:]
    if "-h" in words or "--help" in words:
        return
    operands = [w for w in words if not w.startswith("-")]
    everything = any(w in ("-a", "--all") for w in words)

    if cmd == "link":
        if everything:
            links.update(installed)
        elif operands:
            name = operands[0].partition("@")[0]
            if name in installed:
                links.add(name)
    elif cmd == "unlink":
        if everything:
            links.clear()
        elif operands:
            links.discard(operands[0].partition("@")[0])


def phase_command_battery(wave, rng, checks, installed, links):
    """list/search/info/selfupdate/link/linkquery/unlink 各 5 次。install/uninstall 不在此处。"""
    banner("阶段 2：固定命令覆盖（各 5 次）")
    names = sorted(installed) or ["wget"]
    for cmd, times in COMMAND_BATTERY.items():
        for _ in range(times):
            argv = [cmd]
            if cmd == "search":
                argv.append(rng.choice(names))
            elif cmd in ("info", "link", "linkquery", "unlink"):
                if rng.random() < 0.25:
                    argv.append(random_flag(rng, "-a", "--all"))
                else:
                    target = rng.choice(names)
                    argv.append(f"{target}{rng.choice(('', '@latest'))}")
            illegal = maybe_illegal_arg(rng)
            if illegal:
                argv.append(illegal)

            expected_rc, must_contain = predict(cmd, argv, installed, links)
            label = f"wave {' '.join(argv)}"
            result = wave.run(argv, timeout=300)
            apply_link_state(cmd, argv, installed, links)
            if is_rate_limited(result):
                checks.skip(label, "GitHub API 侧失败（限流/403），跳过断言")
                continue
            expect(checks, result, expected_rc, label, must_contain=must_contain)


# -------------------- 阶段 3：卸载循环 --------------------


def phase_uninstall_cycle(wave, rng, installed_plans, checks):
    banner("阶段 3：随机软件包 uninstall")
    for plan in installed_plans:
        argv = ["uninstall", uninstall_token(plan)]
        if rng.random() < 0.3:
            argv.append(random_flag(rng, "-v", "--verbose"))
        illegal = maybe_illegal_arg(rng)
        if illegal:
            argv.append(illegal)
        label = f"uninstall {plan.token}"
        result = wave.run(argv)
        expect(checks, result, 0, label, must_contain=("Successfully uninstalled",))

        bin_dir = wave.layout.base_dir / "bin" / f"{plan.bin_name}@{plan.version}"
        link = wave.layout.base_dir / "links" / plan.bin_name
        checks.check(f"{label}: 目录已删除", not bin_dir.exists(), str(bin_dir))
        checks.check(f"{label}: 不带版本号的链接已删除", not link.exists(), str(link))


def phase_global_invariants(wave, checks):
    """全局残留检查。前面已经失败过时降级为 WARN，避免一个失败引出一串假失败。"""
    banner("阶段 4：全局不变量")
    strict = not checks.failed

    def verify(label, ok, detail=""):
        if ok:
            checks.ok(label)
        elif strict:
            checks.fail(label, detail)
        else:
            checks.warn(label, f"{detail}（前面已有失败，可能是它留下的）")

    deps_left = [p for p in (wave.layout.base_dir / "deps").glob("*/*") if p.is_dir()]
    verify("依赖被级联清干净", not deps_left, ", ".join(str(p) for p in deps_left[:5]))

    downloads = [p for p in wave.layout.partial_dir.glob("*") if p.is_file()]
    verify("下载临时目录没有残留", not downloads,
           ", ".join(p.name for p in downloads[:5]))

    links = list((wave.layout.base_dir / "links").glob("*"))
    verify("links/ 没有残留", not links, ", ".join(p.name for p in links[:5]))

    bins = list((wave.layout.base_dir / "bin").glob("*"))
    verify("bin/ 没有残留", not bins, ", ".join(p.name for p in bins[:5]))


# -------------------- 阶段 5：非法命令与帮助 --------------------


def phase_illegal_and_help(wave, rng, checks):
    banner("阶段 5：非法命令 / -h / -V（含非法参数）")
    junk = ["frobnicate", "--frobnicate", "installx", "@", "linkquery!!", "uninstall!"]
    for command in rng.sample(junk, ILLEGAL_COMMAND_COUNT):
        label = f"wave {command}"
        result = wave.run([command], timeout=120)
        expect(checks, result, 1, label, must_contain=("Unknown command",))

    cases = [("-h", "usage:"), ("--help", "usage:"), ("-V", "MacWave"), ("--version", "MacWave")]
    for flag, needle in cases[:HELP_VERSION_CASES // 2]:
        label = f"wave {flag}"
        result = wave.run([flag], timeout=120)
        expect(checks, result, 0, label, must_contain=(needle,))
    for flag, needle in cases[:HELP_VERSION_CASES // 2]:
        illegal = rng.choice(ILLEGAL_FLAGS)
        label = f"wave {flag} {illegal}"
        result = wave.run([flag, illegal], timeout=120)
        expect(checks, result, 0, label, must_contain=(needle,))


# -------------------- pty 执行 --------------------


class PtyResult:
    def __init__(self, output, returncode, progress_rendered, interrupted=False):
        self.output = output
        self.returncode = returncode
        self.progress_rendered = progress_rendered
        self.interrupted = interrupted

    @property
    def as_result(self):
        return subprocess.CompletedProcess([], self.returncode, self.output, "")


PROGRESS_PATTERN = re.compile(r"\d+\s*%")


def describe_text(text):
    return " | ".join(line.strip() for line in text.splitlines() if line.strip())[:300]


# dyld 的报错有固定形状。不能只搜 "dyld"：像 ipsw 这种工具自带 dyld 子命令，
# 它的 --help 输出里就有这个词，会把正常安装误判成"未解析动态库"。
DYLD_ERROR_MARKERS = ("Library not loaded:", "Reason: image not found", "Symbol not found:",
                      "not loaded from")


def has_dyld_error(text):
    if any(marker in text for marker in DYLD_ERROR_MARKERS):
        return True
    return any(line.startswith("dyld:") or line.startswith("dyld[")
               for line in text.splitlines())


def dependency_symbol_mismatch(text):
    """dyld 报「符号找不到」、且缺符号的库来自 deps/ 时，判定为包数据不匹配。

    库确实被装好、也指对了（否则报的是 image not found），只是它没导出那个符号：
    例如 tmux 需要 ncurses 的新符号，而 @common 里声明的依赖版本没有它。
    这属于 infosource 的数据问题，不是 MacWave 的路径重定向出错，所以记为警告。
    """
    symbol = library = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("dyld") and "Symbol not found:" in line:
            symbol = line.split("Symbol not found:", 1)[1].strip()
        elif line.startswith("Expected in:"):
            rest = line.split("Expected in:", 1)[1].strip()
            # 形如 "<UUID> /path/to/lib.dylib"，路径里可能有空格，所以只剥掉 UUID
            if rest.startswith("<") and ">" in rest:
                rest = rest.split(">", 1)[1].strip()
            library = rest
    if symbol and library and "/deps/" in library:
        return symbol, library
    return None


# -------------------- 主流程 --------------------


def parse_args():
    parser = argparse.ArgumentParser(description="MacWave 随机化端到端回归")
    parser.add_argument("--dry-run", action="store_true",
                        help="只做包选择与参数生成并把计划打出来，不执行任何 wave 命令"
                             "（仍会 HEAD 探体积，除非再加 --no-size-probe）")
    parser.add_argument("--keep", action="store_true", help="跑完保留安装目录（调试用）")
    parser.add_argument("--seed", type=int, help="随机种子（复现用）")
    parser.add_argument("--count", type=int, help="覆盖 10~20 的包数（调试用）")
    parser.add_argument("--packages", help="指定包名（逗号分隔，调试用）")
    parser.add_argument("--infosource", help="infosource 检出目录")
    parser.add_argument("--config-dir", help="覆盖配置目录（默认随 HOME 走）")
    parser.add_argument("--include-test-packages", action="store_true",
                        help="把 test_* 测试夹具也放进随机池")
    parser.add_argument("--no-size-probe", action="store_true",
                        help="跳过 HEAD 探体积（离线自测用，40MB 上限失效）")
    parser.add_argument("--log-file", help="把整轮日志同时写一份到该文件（CI 用它上传 artifact）")
    parser.add_argument("--limit-rate", default="400K", help="--limit-rate 用的速率")
    parser.add_argument("--transfer-interrupt-probability", type=float,
                        default=TRANSFER_INTERRUPT_PROBABILITY,
                        help="Mach-O 重定向中途打断的概率（默认 0.05；调试可设 1）")
    return parser.parse_args()


def print_plan(plans):
    banner("计划")
    for plan in plans:
        version = plan.version if plan.specified else "(latest)"
        size = f"{plan.artifact_bytes / 1048576:.1f}MB" if plan.artifact_bytes else "?"
        bogus = f" [{plan.bogus}]" if plan.bogus else ""
        print(f"  {plan.name:<14} {str(version):<24} {size:>8}  mode={plan.mode:<10}{bogus}",
              flush=True)


def main():
    args = parse_args()
    global TRANSFER_INTERRUPT_PROBABILITY
    TRANSFER_INTERRUPT_PROBABILITY = args.transfer_interrupt_probability

    original_stdout = sys.stdout
    log_handle = None
    if args.log_file:
        log_handle = open(args.log_file, "a", buffering=1, encoding="utf-8")
        sys.stdout = Tee(original_stdout, log_handle)

    seed = args.seed if args.seed is not None else random.randrange(2 ** 31)
    rng = random.Random(seed)
    print(f"🌊 MacWave random regression (seed={seed})", flush=True)
    print(f"🌊 复现：--seed {seed}", flush=True)

    checks = Report()
    layout = choose_layout(rng, config_dir_override=args.config_dir)
    try:
        source = locate_infosource(args.infosource)
        arch = detect_arch()
        print(f"🌊 infosource: {source} (arch: {arch})", flush=True)
        catalog = load_catalog(source, arch)
        print(f"🌊 候选包 {len(catalog)} 个", flush=True)

        prober = None if args.no_size_probe else SizeProber()
        explicit = args.packages.split(",") if args.packages else None
        plans = select_packages(rng, catalog, checks, args.count, explicit,
                                prober=prober, include_test=args.include_test_packages)
        assign_versions(rng, plans, checks)
        if not args.dry_run:
            assign_modes(rng, plans, prober)
        print_plan(plans)

        if args.dry_run:
            print(f"🌊 dry-run 结束：{len(plans)} 个包，未执行任何 wave 命令", flush=True)
            return 0

        setup_environment(layout)
        wave = Wave(layout, checks, args.limit_rate)

        installed = phase_install_cycle(wave, rng, plans, checks)
        names = {plan.bin_name for plan in installed}
        phase_command_battery(wave, rng, checks, names, set(names))
        phase_uninstall_cycle(wave, rng, installed, checks)
        phase_global_invariants(wave, checks)
        phase_illegal_and_help(wave, rng, checks)
        print_summary(seed, layout, checks)
    except Exception as error:
        print(f"🌊 Error: 随机回归无法继续：{error}", flush=True)
        checks.fail("run", str(error))
        print_summary(seed, layout, checks)
    finally:
        cleanup(layout, keep=args.keep)
        if log_handle is not None:
            sys.stdout.flush()
            sys.stdout = original_stdout
            log_handle.close()

    return 1 if checks.failed else 0


def print_summary(seed, layout, checks):
    banner("结果")
    print(f"🌊 seed={seed}  layout={layout.name}", flush=True)
    print(f"🌊 PASS {checks.passed} / FAIL {len(checks.failed)} / "
          f"WARN {len(checks.warned)} / SKIP {len(checks.skipped)}", flush=True)
    for label, detail in checks.failed:
        print(f"  ✗ {label}" + (f"  <- {detail}" if detail else ""), flush=True)
    for label, detail in checks.warned:
        print(f"  ! {label}" + (f"  <- {detail}" if detail else ""), flush=True)
    for label, detail in checks.skipped:
        print(f"  - {label}" + (f"  <- {detail}" if detail else ""), flush=True)


if __name__ == "__main__":
    sys.exit(main())
