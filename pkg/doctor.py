#!/usr/bin/env python3

# doctor.py

# `wave doctor` —— 只读体检：把安装树里「已经坏了、但平时没人会发现」的地方找出来。
#
# 为什么需要：真出问题时用户看到的是下游症状 —— `jq: command not found`、
# `dyld: Library not loaded`、`wave uninstall x` 说「没装」。原因可能是一周前一次
# 被打断的安装，而那时没有任何东西提醒过。这里把这几种状态集中检查一遍。
#
# 设计上的三条：
#
#   1. **只读**。不修、不删、不改字节。每条发现后面给出该跑哪条 `wave` 命令 ——
#      与 `brew doctor` 学到的最有用的一点：发现的价值在于「下一步做什么」。
#   2. **退出码 = 发现的问题数**，0 表示全绿。可以进脚本、进 CI。
#   3. **拿不准就说拿不准**。位置无关性用 `transfer.sh --check` 的三态：
#      0 相对 / 1 绝对 / 2 判断不了（缺 otool）。2 记成 note，不当成坏包。
#
# 慢检查排在最后（逐个产物扫 Mach-O 是这里唯一的重活），让前几项先给出结论。

import os
import subprocess
import sys

from configpaths import load_base_dir
import silent

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
RESET = '\033[0m'

BASE_DIR = load_base_dir()
BIN_DIR = BASE_DIR / "bin"
LINKS_DIR = BASE_DIR / "links"
DEPS_DIR = BASE_DIR / "deps"
DOWNLOAD_TMP = BASE_DIR / "downloads" / "tmp"
COMPONENTS = ("cli", "config", "lib", "net", "pkg", "surfboard")
TREE_MARKER = ".is_a_tree"

TRANSFER_SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "surfboard", "transfer.sh")


# -------------------- 发现 --------------------

class Finding:
    """一条发现。severity 只有两档：problem 计入退出码，note 只是提醒。"""

    def __init__(self, check, text, fix="", severity="problem"):
        self.check = check
        self.text = text
        self.fix = fix
        self.severity = severity

    def line(self):
        return f"{self.text} — {self.fix}" if self.fix else self.text


def _installed_dirs():
    """[(包名, 版本)]，按名字排序。只看 bin/<名>@<版本> 这一层。"""
    if not BIN_DIR.is_dir():
        return []
    pairs = []
    for entry in sorted(os.listdir(str(BIN_DIR))):
        if "@" not in entry or not (BIN_DIR / entry).is_dir():
            continue
        name, _, version = entry.partition("@")
        if name and version:
            pairs.append((name, version))
    return pairs


def _highest(versions):
    from versioncompare import get_max_version
    return get_max_version(versions)


# -------------------- 检查项 --------------------

def check_base_dir():
    """安装根存在、可写 —— 「装不上包」最常见的原因是这里。"""
    findings = []
    if not BASE_DIR.is_dir():
        return [Finding("base-dir", f"install root {BASE_DIR} is missing",
                        "run the installer again (lib/install.sh)")]
    if not os.access(str(BASE_DIR), os.W_OK):
        findings.append(Finding("base-dir", f"install root {BASE_DIR} is not writable",
                                "fix the permissions of that directory, or run "
                                "'sudo <base>/lib/wave doctor'"))
    return findings


def check_tree():
    """六个组件目录齐不齐 —— 缺一个就是半装状态，wave 会 ImportError。"""
    missing = [name for name in COMPONENTS if not (BASE_DIR / name).is_dir()]
    if not missing:
        return []
    return [Finding("tree", f"component(s) missing from the install tree: {', '.join(missing)}",
                    "run 'wave selfupdate' to repair the install tree")]


def check_installed():
    """每个 bin/<名>@<版本>/ 里真的有那个可执行文件吗。"""
    findings = []
    for name, version in _installed_dirs():
        directory = BIN_DIR / f"{name}@{version}"
        if (directory / TREE_MARKER).is_file():
            target = directory / "bin" / name
        else:
            target = directory / name
        if target.exists():
            continue
        findings.append(Finding("installed", f"{name}@{version} has no {target.name}",
                                f"wave reinstall {name}@{version}"))
    for entry in sorted(os.listdir(str(BIN_DIR))):
        if entry.endswith(".bak"):
            findings.append(Finding("installed", f"leftover backup directory bin/{entry}",
                                    "delete it once you are sure the package works"))
    return findings


def check_links():
    """links/ 里的悬空链接，以及该有却没有的不带版本号链接。"""
    findings = []
    if not LINKS_DIR.is_dir():
        if _installed_dirs():
            findings.append(Finding("links", "the links/ directory is missing",
                                    "wave link --all"))
        return findings

    linked = {}
    for entry in sorted(os.listdir(str(LINKS_DIR))):
        path = LINKS_DIR / entry
        if not path.is_symlink():
            continue
        if not os.path.exists(str(path)):
            findings.append(Finding("links", f"links/{entry} points at something that is gone",
                                    f"wave link {entry.partition('@')[0]}"))
            continue
        if "@" in entry:
            continue
        linked[entry] = os.readlink(str(path))

    by_name = {}
    for name, version in _installed_dirs():
        by_name.setdefault(name, []).append(version)
    for name, versions in sorted(by_name.items()):
        if name in linked:
            continue
        findings.append(Finding("links", f"{name} is installed but has no unversioned link",
                                f"wave link {name}"))
    return findings


def check_dependencies():
    """deps/ 里没有人引用的树（.depped_* 一个都没有）。"""
    findings = []
    if not DEPS_DIR.is_dir():
        return findings
    for owner in sorted(os.listdir(str(DEPS_DIR))):
        owner_dir = DEPS_DIR / owner
        if not owner_dir.is_dir():
            continue
        for entry in sorted(os.listdir(str(owner_dir))):
            version_dir = owner_dir / entry
            if not version_dir.is_dir():
                continue
            marks = [name for name in os.listdir(str(version_dir))
                     if name.startswith(".depped_")]
            if marks:
                continue
            findings.append(Finding("dependencies",
                                    f"deps/{owner}/{entry} is not referenced by anything",
                                    f"wave uninstall {owner} (then it is removed with the "
                                    f"package that pulled it in)"))
    return findings


def check_downloads():
    """下载暂存目录里的残渣。只是提醒：install/uninstall 会自己清理。"""
    if not DOWNLOAD_TMP.is_dir():
        return []
    partials = [name for name in os.listdir(str(DOWNLOAD_TMP)) if name.endswith(".partial")]
    if not partials:
        return []
    return [Finding("downloads",
                    f"{len(partials)} unfinished download(s) in downloads/tmp",
                    "they are removed automatically once they are 7 days old",
                    severity="note")]


def check_position():
    """已装产物是否已经是位置无关的（@loader_path）。三态：坏、好、判断不了。"""
    if not os.path.isfile(TRANSFER_SCRIPT):
        return []
    from transferrer import all_installed_dirs, position_independence

    findings = []
    unknown = []
    for label, path in all_installed_dirs():
        state = position_independence(path)
        if state is None:
            unknown.append(label)
            continue
        if state:
            continue
        package = label.split("/")[-1].partition("@")[0]
        findings.append(Finding("position",
                                f"{label} still names an absolute install path",
                                f"wave transfer {package}"))
    if unknown and not findings:
        findings.append(Finding("position",
                                f"cannot inspect {len(unknown)} artifact(s) "
                                f"(otool or non-Darwin platform)",
                                "nothing to do; position independence was not checked",
                                severity="note"))
    return findings


CHECKS = (
    ("base-dir", check_base_dir, "install root exists and is writable"),
    ("tree", check_tree, "the six component directories are present"),
    ("installed", check_installed, "every version directory has its executable"),
    ("links", check_links, "unversioned links exist and point at something"),
    ("dependencies", check_dependencies, "no dependency tree is orphaned"),
    ("downloads", check_downloads, "downloads/tmp is not full of abandoned partials"),
    ("position", check_position, "installed artifacts no longer name an absolute path"),
)


# -------------------- 输出 --------------------

def _report(findings, raw=False):
    problems = [item for item in findings if item.severity == "problem"]
    if raw:
        for item in findings:
            print(f"{item.severity}\t{item.check}\t{item.line()}")
        return problems

    if not findings:
        print(f"{GREEN}🌊 No problems found in {len(CHECKS)} checks.{RESET}")
        return problems

    for check, _function, _description in CHECKS:
        current = [item for item in findings if item.check == check]
        if not current:
            continue
        print(f"🌊 {check}")
        for item in current:
            colour = RED_BOLD if item.severity == "problem" else YELLOW
            print(f"{colour}🌊   {item.text}{RESET}")
            if item.fix:
                print(f"🌊   fix: {item.fix}")

    notes = len(findings) - len(problems)
    summary = f"{len(problems)} problem(s) found"
    if notes:
        summary += f", {notes} note(s)"
    print()
    print(f"{RED_BOLD}🌊 Doctor: {summary}.{RESET}" if problems
          else f"{YELLOW}🌊 Doctor: no problems, {notes} note(s).{RESET}")
    return problems


# -------------------- 命令入口 --------------------

def handle_doctor(input_string=""):
    words = input_string.split()[2:]

    if "--list-checks" in words:
        for name, _function, description in CHECKS:
            print(f"{name}\t{description}")
        return

    raw = "--raw" in words
    for word in words:
        if word.startswith("-") and word not in ("--raw", "--list-checks"):
            print(f"{RED_BOLD}🌊 Error: unknown flag '{word}'.{RESET}")
            print(f"{RED_BOLD}🌊 Try: wave doctor [--raw] [--list-checks]{RESET}")
            sys.exit(1)

    if not raw:
        silent.say(f"🌊 Examining {BASE_DIR} ...")

    findings = []
    for name, function, _description in CHECKS:
        selected = [word for word in words if not word.startswith("-")]
        if selected and name not in selected:
            continue
        if not raw:
            silent.say(f"🌊 Checking {name} ...")
        findings.extend(function())

    problems = _report(findings, raw=raw)
    sys.exit(len(problems))


if __name__ == "__main__":
    handle_doctor(" ".join(sys.argv[1:]))
