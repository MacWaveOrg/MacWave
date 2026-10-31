#!/usr/bin/env python3

# latest.py
# `wave latest` —— 看某个（或所有）软件包有没有更新。只报告，不下载任何东西。

import concurrent.futures as futures
import difflib
import os
import sys

# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
ORANGE = '\033[38;5;197m'
RESET = '\033[0m'

# -------------------- 依赖与配置 --------------------

from configpaths import load_base_dir, require_safe_token
import domains
import tls
import steplog

try:
    import requests
except ImportError:
    print(f"{RED_BOLD}🌊 Error: 'requests' library is not installed.{RESET}")
    sys.exit(1)

BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"
LINKS_DIR = BASE_DIR / "links"

# 并发取版本清单。装了几十个包时逐个串行会让「看一眼有没有更新」变成等半分钟。
MAX_WORKERS = 8

UPDATE = "update available"
CURRENT = "up to date"
AHEAD = "local is newer"
MISSING = "not installed"
UNKNOWN = "not in the index"
NO_LIST = "no version list"
READ_FAIL = "cannot read the index"


# -------------------- 查询 --------------------

def headers(url):
    # 与 pkg/pkginstaller.py 一致：只有 api.github.com 需要 token（缓解未认证限流）
    from pkginfohelper import github_api_headers
    return github_api_headers(url)


def fetch_names(arch, timeout):
    """索引里的全部包名，一行一个。列不出来时返回 None，调用方退回「按已装的名字直接查」。"""
    url = domains.index_list_url(arch)
    try:
        response = requests.get(url, timeout=timeout.request_timeout,
                                headers=headers(url), **tls.request_kwargs())
    except Exception as error:
        steplog.detail(f"package list failed: {error}")
        return None
    if response.status_code != 200:
        steplog.detail(f"package list HTTP {response.status_code}")
        return None
    return [name for name in domains.listing_names(response.text, dirs_only=True) if name]


def fetch_versions(package_name, arch, timeout):
    """返回 (版本号列表, 错误说明)。404 时版本列表为空、错误说明为 HTTP 404。"""
    url = domains.index_list_url(arch, package_name)
    steplog.detail(f"GET {domains.redact_url(url)}")
    try:
        response = requests.get(url, timeout=timeout.request_timeout,
                                headers=headers(url), **tls.request_kwargs())
    except Exception as error:
        return [], str(error)[:120]
    if response.status_code != 200:
        return [], f"HTTP {response.status_code}"

    versions = []
    for name in domains.listing_names(response.text):
        if name.endswith("@common"):
            continue
        if "@" in name:
            versions.append(name.split("@")[1])
    return versions, None


def highest(versions):
    from pkgversionparser import sort_versions
    if not versions:
        return None
    return sort_versions(versions)[0]


def installed_versions(bin_name):
    bin_name = require_safe_token(bin_name, "package name")
    if not BIN_DIR.is_dir():
        return []
    prefix = f"{bin_name}@"
    found = []
    for entry in BIN_DIR.iterdir():
        if entry.is_dir() and entry.name.startswith(prefix):
            version = entry.name[len(prefix):]
            if version:
                found.append(version)
    from pkgversionparser import sort_versions
    return sort_versions(found)


def linked_version(bin_name):
    # links/<名称> 指向 bin/<名称>@<版本>；没链接或指向别处时返回 None
    bin_name = require_safe_token(bin_name, "package name")
    link = LINKS_DIR / bin_name
    if not link.is_symlink():
        return None
    directory = os.path.basename(os.path.dirname(os.readlink(link)))
    if "@" not in directory:
        return None
    name, _, version = directory.partition("@")
    return version if name == bin_name and version else None


def installed_bin_names():
    if not BIN_DIR.is_dir():
        return []
    names = set()
    for entry in BIN_DIR.iterdir():
        if not entry.is_dir() or "@" not in entry.name:
            continue
        name, _, version = entry.name.partition("@")
        if name and version:
            names.add(name)
    return sorted(names)


# -------------------- 包名解析 --------------------

def resolve_package_name(bin_name, names):
    # bin/ 与 links/ 用的是 bin_name，索引里的是包名，两者不一定相同（choma -> ChOma）。
    # 名字清单已经在手，先精确、再忽略大小写，都不中就当它同名 —— 查不到会显示 UNKNOWN。
    if not names:
        return bin_name
    if bin_name in names:
        return bin_name
    folded = bin_name.casefold()
    for candidate in names:
        if candidate.casefold() == folded:
            return candidate
    return bin_name


def suggest_package_name(package_name, names):
    # 排除同名：叫 wget 的包在名字清单里时，"did you mean wget" 只会让人更困惑
    candidates = [name for name in names or []
                  if name.casefold() != package_name.casefold()]
    matches = difflib.get_close_matches(package_name, candidates, n=1, cutoff=0.6)
    return matches[0] if matches else None


# -------------------- 组装每一行 --------------------

def build_row(display_name, latest, problem):
    installed = installed_versions(display_name)
    linked = linked_version(display_name)
    # 「当前」= 已装的最高版本。真正在跑的是不带版本号的那个链接，
    # 两者不一致时单独附注 —— 常见情况一致，输出不该为此长出噪音。
    current = installed[0] if installed else None

    from pkgversionparser import safe_parse_pkg_version as version_key

    # 「名字不在索引里」和「名字在、但没给它出清单」是两件事，提示完全不同。
    # 这里先按 404 一律记成 UNKNOWN，由调用方在手上有名字清单时改判成 NO_LIST。
    if problem is not None:
        status = UNKNOWN if problem == "HTTP 404" else READ_FAIL
        return {"name": display_name, "current": current, "linked": linked,
                "latest": None, "status": status, "problem": problem}

    if latest is None:
        return {"name": display_name, "current": current, "linked": linked,
                "latest": None, "status": NO_LIST, "problem": None}

    if current is None:
        status = MISSING
    elif version_key(current) < version_key(latest):
        status = UPDATE
    elif version_key(current) == version_key(latest):
        status = CURRENT
    else:
        status = AHEAD

    return {"name": display_name, "current": current, "linked": linked,
            "latest": latest, "status": status, "problem": None}


# -------------------- 输出 --------------------

STATUS_COLOR = {
    UPDATE: YELLOW,
    CURRENT: GREEN,
    AHEAD: ORANGE,
    MISSING: YELLOW,
    UNKNOWN: RED_BOLD,
    NO_LIST: RED_BOLD,
    READ_FAIL: RED_BOLD,
}

DASH = "—"


def render(rows, arch):
    name_width = max(len(row["name"]) for row in rows)
    current_width = max(len(row["current"] or DASH) for row in rows)
    latest_width = max(len(row["latest"] or DASH) for row in rows)

    for row in rows:
        name = f"{GREEN}{row['name']:<{name_width}}{RESET}"
        current = f"{row['current'] or DASH:<{current_width}}"
        color = STATUS_COLOR.get(row["status"], "")
        latest = row["latest"] or DASH

        if row["latest"] is None:
            marker = " " * (latest_width + 2)
        elif row["status"] == CURRENT:
            marker = f"{GREEN}= {latest:<{latest_width}}{RESET}"
        elif row["status"] == AHEAD:
            marker = f"{ORANGE}← {latest:<{latest_width}}{RESET}"
        else:
            marker = f"{YELLOW}→ {latest:<{latest_width}}{RESET}"

        note = ""
        if row["linked"] and row["linked"] != row["current"]:
            note = f"   (linked: {row['linked']})"

        print(f"🌊 {name}  {current}  {marker}  {color}{row['status']}{RESET}{note}")


def summarize(rows):
    outdated = [row["name"] for row in rows if row["status"] == UPDATE]
    total = len(rows)

    if not outdated:
        print(f"\n{GREEN}🌊 All {total} package(s) are up to date.{RESET}")
        return 0

    print(f"\n{YELLOW}🌊 {len(outdated)} of {total} package(s) have an update. "
          f"Run: wave upgrade <name>{RESET}")
    return len(outdated)


# -------------------- 参数 --------------------

ACCEPTED_HELP = [
    "wave latest <name>     show the current and the newest version of one package",
    "wave latest --all      the same for every installed package",
    "optional: --max-time=<时长>   -v/--verbose",
]


def reject_flag(flag):
    steplog.fail(f"illegal option {flag} for `wave latest`",
                 hint=ACCEPTED_HELP)


def split_arguments(input_string):
    """返回 (是否 --all, [包名...], 超时原值或 None, 是否 --verbose)。"""
    words = input_string.split()[2:]
    everything = False
    names = []
    timeout_raw = None
    verbose = False

    position = 0
    while position < len(words):
        word = words[position]
        position += 1

        if word == "-" or not word.startswith("-"):
            # 单独一个 - 之后全是名字，与 install 的约定一致
            if word != "-":
                names.append(word)
            continue

        if word.startswith("--"):
            flag, has_value, value = word.partition("=")
            if flag == "--max-time":
                if not has_value:
                    value = words[position] if position < len(words) else ""
                    position += 1
                timeout_raw = value
            elif flag == "--all":
                everything = True
            elif flag == "--verbose":
                verbose = True
            else:
                reject_flag(flag)
            continue

        # -av 这类合并短选项
        for letter in word[1:]:
            if letter == "a":
                everything = True
            elif letter == "v":
                verbose = True
            else:
                reject_flag(f"-{letter}")

    return everything, names, timeout_raw, verbose


def resolve_timeout(input_string, timeout_raw):
    """latest 也认三档超时；它自己只解析 --max-time 的值，其余交给 parse_timeout。"""
    from pkginstaller import parse_timeout
    from timeouts import FLAG_FIELDS
    present = [flag for flag in FLAG_FIELDS if flag in input_string.split()]
    budget = parse_timeout(input_string, present)
    budget.start()
    return budget


# -------------------- 入口 --------------------

def handle_latest(input_string):
    everything, names, timeout_raw, verbose = split_arguments(input_string)
    steplog.set_verbose(verbose)
    timeout = resolve_timeout(input_string, timeout_raw)

    from pkginstaller import detect_arch
    arch = detect_arch()

    if everything and names:
        steplog.fail("wave latest takes either a package name or --all, not both",
                     hint=["wave latest <name>", "wave latest --all"])

    if not everything and not names:
        steplog.fail("Missing package name.",
                     hint=["wave latest <name>", "wave latest --all"])

    if everything:
        targets = installed_bin_names()
        if not targets:
            print("🌊 No packages installed yet.")
            return 0
        # 名称清单一次就够：既用来把 bin_name 对到包名，也用来解释查不到的那些
        index_names = fetch_names(arch, timeout)
        packages = [resolve_package_name(bin_name, index_names) for bin_name in targets]
    else:
        raw = names[0]
        if "@" in raw:
            steplog.fail(f"wave latest reports the newest version; drop the '@{raw.partition('@')[2]}'",
                         hint=[f"wave latest {raw.partition('@')[0]}",
                               f"wave info {raw}"])
        package_name = require_safe_token(raw, "package name")
        targets = [package_name]
        packages = [package_name]
        index_names = None

    def task(pair):
        display_name, package_name = pair
        versions, problem = fetch_versions(package_name, arch, timeout)
        return build_row(display_name, highest(versions), problem)

    pairs = list(zip(targets, packages))
    if len(pairs) == 1:
        rows = [task(pairs[0])]
    else:
        with futures.ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(pairs))) as pool:
            rows = list(pool.map(task, pairs))

    if not everything:
        # 单个包：查不到就是错，先把话说清楚，不必先打一行全是破折号的表
        row = rows[0]
        if row["status"] in (UNKNOWN, NO_LIST, READ_FAIL):
            report_failure(row, arch, timeout)
        render(rows, arch)
        return 0

    # --all：名字清单在手，可以分清「索引里没这个名字」和「有名字但没出清单」。
    # 这两种都只能显示成一行，但说法不同 —— 前者要提示拼写，后者指向镜像的清单。
    folded = {name.casefold() for name in index_names or []}
    for row in rows:
        if row["status"] == UNKNOWN and row["name"].casefold() in folded:
            row["status"] = NO_LIST

    render(rows, arch)
    summarize(rows)
    return 0


def report_failure(row, arch, timeout):
    """单个包查不到时，把原因说到能直接动手的程度。"""
    name = row["name"]
    index_names = fetch_names(arch, timeout)

    if index_names is not None:
        folded = {candidate.casefold() for candidate in index_names}
        if name.casefold() not in folded:
            close = suggest_package_name(name, index_names)
            hint = []
            if close:
                hint.append(f"did you mean `{close}`?  try: wave latest {close}")
            hint.append("search the index by part of the name: wave search <词>")
            steplog.fail(f"{name} is not in the index", hint=hint)
        # 名字在清单里，却读不到它的版本清单 —— 问题在清单本身，不在拼写
        steplog.fail(f"the index has no version list for {name}",
                     response=row["problem"] or "empty list",
                     hint=["if every package is like this, the mirror has no versions "
                           "lists yet (see docs/MIRROR-SETUP.md)"])

    # 连名字清单都拿不到：只能是网络或地址问题，别再猜包名
    steplog.fail(f"cannot read the version list for {name}",
                 response=row["problem"] or "empty list",
                 hint="check the network and any --proxy setting, then retry")


def main():
    try:
        handle_latest("wave latest " + " ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)


if __name__ == "__main__":
    main()
