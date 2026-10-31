#!/usr/bin/env python3

# quiet.py
# `-s / --silent` 的唯一开关。
#
# 为什么需要一个模块而不是给每个 print 加 if：静默的边界必须只有一处定义。
# 散落在各处的 `if not silent:` 迟早会有一处写反，而写反的后果是「该安静的时候
# 刷屏」或「该报错的时候什么都看不见」——后者更糟，所以错误输出**不经过这里**。
#
# 三条约定：
#   1. say() 只用于「成功了，顺便告诉你一声」这类噪音。错误一律继续用原来的
#      print(f"...Error...")，不改成 say —— 静默只压噪音，不压错误。
#   2. ask() 在静默模式下**不读 stdin**，直接返回 None。否则提示语被吞掉、
#      input() 还在等，表现是命令看起来卡死。返回 None 让调用方走「非交互」
#      分支，那些分支本来就选了保守的默认值（不重试、不删旧版本）。
#   3. 静默优先于啰嗦。-s 与 -v 同时给时，-v 被关掉（见 wave.py 的调度）。

import sys


_silent = False


def set_silent(enabled):
    global _silent
    _silent = bool(enabled)


def is_silent():
    return _silent


def say(message=""):
    """噪音。静默时不打印。"""
    if not _silent:
        print(message)


def say_file(stream, message=""):
    """指定流向的噪音（少数地方要写到 stderr）。"""
    if not _silent:
        print(message, file=stream)


def show(result):
    """把「捕获下来准备重印的子进程输出」按规矩输出。

    成功时是噪音，静默就丢掉；失败时必须留下 —— 那是排查的唯一线索。
    """
    text = (getattr(result, "stdout", "") or "").strip()
    if not text:
        return
    if not _silent or getattr(result, "returncode", 0) != 0:
        print(text)


def ask(prompt="", default=None):
    """问一句。静默模式不读 stdin，直接返回 default。

    返回 None 表示「没有人能回答」，调用方应走非交互分支。
    """
    if _silent:
        return default
    try:
        return input(prompt)
    except (EOFError, KeyboardInterrupt):
        return default


def unknown(kind, value):
    """静默模式下的「命令 / 旗标写错」出口：一行、可被脚本 grep。

    非静默时的输出是「报错 + 可能建议 + 整篇帮助」，那对人是好事，
    对脚本是灾难 —— 所以静默给它一个固定形状：

        wave: unknown command: update
        wave: unknown flag: -q
    """
    print(f"wave: unknown {kind}: {value}", file=sys.stderr)


def flush():
    try:
        sys.stdout.flush()
    except Exception:
        pass
