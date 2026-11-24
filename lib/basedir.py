#!/usr/bin/env python3

# basedir.py
# `wave basedir` —— 打印 MacWave 的安装根目录（配置文件里的 base_dir）。
#
# 存在的理由：这个路径目前只能靠打开 config.json 才看得到，而它是「包装在哪、
# 链接放在哪、卸载会删什么」的唯一答案，排查问题的第一件事就是它。
#
# 两个形态：
#   wave basedir           → 🌊 ~/.local/macwave      （家目录折成 ~）
#   wave basedir --raw     → /Users/you/.local/macwave（不折，给脚本用）
#
# `--raw` 只去掉 🌊 与颜色，不改变内容 —— 与 `wave mirror --raw`（只打值）一致。
#
# 刻意不接 `-s/--silent`：这条命令存在的目的就是输出，静默它等于把命令废掉，
# 与 `wave list -s` 被拒绝是同一条理由（见 cli/silent.py 的说明）。真给了就明确
# 报错，而不是静默忽略 —— 被忽略时用户会以为「生效了、只是没输出」。
#
# 系统级优先、其次用户级 —— 顺序由 configpaths 决定，这里不重复实现。

import json
import os
import shutil
import subprocess
import sys

from configpaths import (CONFIG_FILE_NAME, find_config_dir, load_base_dir,
                         to_tilde)

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
RESET = '\033[0m'

# 这些目录本身不能当安装根（子目录可以，例如 /opt/macwave）。
# 与 lib/install.sh 的 `_forbidden` 是同一份判断，改一处要改两处 ——
# 名字照抄那边，方便对照。
RESERVED_ROOTS = (
    "/bin", "/sbin", "/usr", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec",
    "/usr/local", "/usr/share", "/opt", "/etc", "/var", "/tmp", "/private",
    "/System", "/Library", "/Applications", "/Users", "/Volumes", "/Network",
)


def render(base_dir, raw=False):
    text = str(base_dir)
    if raw:
        # 不折成 ~：`~` 只在词首且未加引号时才展开，
        # `cd "$(wave basedir --raw)"` 会把它当字面量。脚本要的是绝对路径。
        return text
    return f"🌊 {to_tilde(text)}"


def parse_args(words):
    raw = False
    target = None
    dry_run = False
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--raw":
            raw = True
        elif word in ("-n", "--dry-run"):
            dry_run = True
        elif word == "--set":
            if index + 1 >= len(words):
                sys.stderr.write(
                    f"{RED_BOLD}🌊 Error: --set needs a directory{RESET}\n")
                sys.stderr.write(
                    f"{GREEN}🌊 wave basedir --set ~/apps/macwave{RESET}\n")
                sys.exit(1)
            target = words[index + 1]
            index += 1
        elif word.startswith("--set="):
            target = word.split("=", 1)[1]
        elif word in ("-s", "--silent", "-S", "--show-error"):
            sys.stderr.write(f"{RED_BOLD}🌊 Error: {word} cannot be used with basedir{RESET}\n")
            sys.stderr.write(
                f"{GREEN}🌊 basedir always prints a path; use --raw for the bare value{RESET}\n")
            sys.exit(1)
        else:
            sys.stderr.write(f"{RED_BOLD}🌊 Error: unknown option {word}{RESET}\n")
            sys.stderr.write(f"{GREEN}🌊 wave basedir --help{RESET} lists the flags it accepts\n")
            sys.exit(1)
        index += 1
    return raw, target, dry_run


def _error(message, hints=()):
    sys.stderr.write(f"{RED_BOLD}🌊 Error: {message}{RESET}\n")
    for hint in hints:
        sys.stderr.write(f"{GREEN}🌊 {hint}{RESET}\n")
    return 1


def _resolve_target(argument):
    """把用户给的路径变成绝对路径；相对路径直接拒绝（说不清相对哪）。"""
    expanded = os.path.expanduser(argument)
    if not os.path.isabs(expanded):
        return None
    return os.path.normpath(expanded)


def _count_entries(root):
    """树里条目总数（目录 + 文件 + 符号链接），用来核对复制是否完整。"""
    total = 1
    for _dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        total += len(dirnames) + len(filenames)
    return total


def _check_target(old, new):
    """返回 (问题, 提示) 或 (None, None)。全在提问之前跑完，脚本能一眼失败。"""
    if new in RESERVED_ROOTS:
        return (f"'{new}' is a system directory, not an install directory",
                [f"pick a directory of its own, for example {new}/macwave"])
    if new == old:
        return (f"'{new}' is already the install directory", [])
    if new.startswith(old + os.sep):
        return (f"'{new}' is inside the current install directory", [])
    if old.startswith(new + os.sep):
        return (f"the current install directory is inside '{new}'", [])
    if os.path.exists(new) and os.listdir(new):
        return (f"'{new}' already exists and is not empty",
                ["choose a path that does not exist yet, or empty it first"])
    return (None, None)


def _write_base_dir(new):
    """把 config.json 的 base_dir 改成新路径；其它键原样保留。"""
    directory = find_config_dir()
    if directory is None:
        return _error("cannot find the config directory to update",
                      ["reinstall MacWave, or edit config.json by hand"])

    config_file = directory / CONFIG_FILE_NAME
    try:
        with open(config_file, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as error:
        return _error(f"cannot read {config_file}: {error}")

    data["base_dir"] = str(new)

    # 先写临时文件再 os.replace：中途断电也不会留下半份 config.json
    temp_file = config_file.with_name(config_file.name + ".new")
    try:
        with open(temp_file, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.replace(temp_file, config_file)
    except OSError as error:
        try:
            os.unlink(temp_file)
        except OSError:
            pass
        return _error(
            f"cannot write {config_file}: {error}",
            ["a system-wide install (/opt/macwave_config) needs an administrator:",
             f"  sudo wave basedir --set {new}"])
    return 0


def _copy_tree(source, target):
    """"复制整棵树"。

    APFS 上先试 `cp -Rc`（clonefile：写时复制，几乎瞬间、不占第二份磁盘）；不支持
    或被拒（非 APFS 卷、外接 HFS+、网络盘）就退回 shutil.copytree —— 行为与以前完全
    一样，只是慢、要占双份空间。

    返回 "cloned" / "copied"；失败返回 None。`cp` 失败时可能已经建了半个目录，
    先删掉再回退，否则 copytree 会因为目标已存在而失败。
    """
    if sys.platform == "darwin":
        result = subprocess.run(["cp", "-Rc", source, target],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode == 0:
            return "cloned"
        shutil.rmtree(target, ignore_errors=True)

    try:
        shutil.copytree(source, target, symlinks=True)
    except OSError:
        return None
    return "copied"


def _human_size(total):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if total < 1024 or unit == "GiB":
            return f"{total:.0f} {unit}" if unit == "B" else f"{total:.1f} {unit}"
        total /= 1024.0
    return f"{total:.1f} GiB"


def _tree_size(root):
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                if not os.path.islink(path):
                    total += os.path.getsize(path)
            except OSError:
                continue
    return total


def switch_base_dir(argument, dry_run=False):
    """`wave basedir --set <path>`：把整棵安装树复制到新位置并改写配置。

    刻意分三段确认（见 cli/confirm.py）：这是一次不可逆的搬家，打错一个字
    都不该继续。所有本地校验都排在提问之前 —— 路径不合法时不该先让人打三遍字。

    `--dry-run` 只走校验与预检，把"会复制多少、会改哪个配置文件"打出来就返回。
    它**不提问**：预览的意义是能在脚本里跑，提问等于把人挡在外面。
    """
    from lock import tree_lock

    old = load_base_dir()
    new = _resolve_target(argument)
    if new is None:
        return _error(f"'{argument}' is not an absolute path",
                      ["give a full path, e.g. wave basedir --set ~/apps/macwave"])

    problem, hints = _check_target(str(old), new)
    if problem:
        return _error(problem, hints)

    # 从这里开始到搬完都要独占安装树：别人同时在装包的话，复制出来的树是半截的。
    with tree_lock("basedir --set"):
        return _switch_base_dir_locked(argument, old, new, dry_run)


def _switch_base_dir_locked(argument, old, new, dry_run):
    from confirm import NotConfirmed, confirm_basedir_switch

    # 预检：还留着绝对路径的产物搬走就加载不到库，先要求把它们迁移成相对形式。
    import transferrer
    offenders = transferrer.absolute_artifacts()
    if offenders:
        sys.stderr.write(
            f"{RED_BOLD}🌊 {len(offenders)} installed artifact(s) still name an "
            f"absolute path and would break after the move:{RESET}\n")
        for label, _path in offenders[:10]:
            sys.stderr.write(f"{RED_BOLD}🌊   {label}{RESET}\n")
        if len(offenders) > 10:
            sys.stderr.write(f"{RED_BOLD}🌊   ... and {len(offenders) - 10} more{RESET}\n")
        return _error(
            "nothing was moved",
            ["run wave transfer --all first: it rewrites those references to "
             "@loader_path so the tree can live anywhere",
             "wave transfer --all --dry-run shows what would change"])

    if dry_run:
        config_dir = find_config_dir()
        config_file = (config_dir / CONFIG_FILE_NAME) if config_dir else "(not found)"
        print("🌊 Dry run: nothing is copied and config.json is not changed.")
        print(f"🌊   from          {old}")
        print(f"🌊   to            {new}")
        print(f"🌊   entries       {_count_entries(str(old))}")
        print(f"🌊   size          {_human_size(_tree_size(str(old)))}")
        print(f"🌊   config file   {config_file}")
        print(f"🌊   artifacts     all {len(transferrer.all_installed_dirs())} are "
              f"position-independent")
        print("🌊 Drop --dry-run to run the three confirmations and do it.")
        return 0

    try:
        confirm_basedir_switch(str(old), new)
    except NotConfirmed as refusal:
        return _error(refusal.reason, ["nothing was changed"])

    print(f"🌊 Copying {to_tilde(str(old))} -> {to_tilde(new)} ...")
    how = _copy_tree(str(old), new)
    if how is None:
        return _error(f"copy failed: could not create {to_tilde(new)}",
                      [f"the old tree is untouched; remove {to_tilde(new)} and retry"])
    if how == "cloned":
        print("🌊       used APFS clone: instant, and no second copy on disk")

    expected = _count_entries(str(old))
    actual = _count_entries(new)
    if actual != expected:
        return _error(
            f"the copy looks incomplete: {actual} entr(ies) at the new path, "
            f"{expected} at the old one",
            [f"the old tree is untouched; remove {to_tilde(new)} and retry"])

    code = _write_base_dir(new)
    if code != 0:
        return code

    print(f"{GREEN}🌊 base_dir is now {to_tilde(new)}{RESET}")
    print("🌊 Next:")
    print(f"🌊   1. open a new terminal (or fix the PATH line in your shell rc) so "
          f"'wave' resolves under {to_tilde(new)}")
    print(f"🌊   2. once everything works, delete the old tree yourself: "
          f"rm -rf '{old}'")
    print("🌊 The old tree was left in place on purpose.")
    return 0


def handle_basedir(input_string=""):
    words = input_string.split()
    # 分发层传进来的是 "wave basedir …"，把头两个词剥掉
    if words and words[0] == "wave":
        words = words[1:]
    if words and words[0] == "basedir":
        words = words[1:]

    raw, target, dry_run = parse_args(words)
    if target is not None:
        return switch_base_dir(target, dry_run=dry_run)
    print(render(load_base_dir(), raw=raw))
    return 0


if __name__ == "__main__":
    sys.exit(handle_basedir())
