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
#   4. 单给 -s 时连错误一起吞掉（与 curl 一致），退出码是唯一的信号；
#      想留错误就加 -S / --show-error。这条由 silence_everything() 在 fd 层实现，
#      所以不用改那几十处 print —— 子进程的输出也一并消失。

import os
import re
import sys


_silent = False
_show_error = False


def set_silent(enabled, show_error=False):
    global _silent, _show_error
    _silent = bool(enabled)
    _show_error = bool(show_error)


def is_silent():
    return _silent


def is_show_error():
    """-S / --show-error：静默但保留错误输出。"""
    return _show_error


# -------------------- 静默时的机器可读输出 --------------------
#
# `-sS` 的输出去给脚本读（人只在失败时才看）。`🌊 ` 对脚本是噪音：每行都得多剥
# 一次，剥漏了就解析失败。所以静默模式下**所有输出一律不带 🌊**，其余文字、
# 缩进与颜色码原样保留。
#
# 为什么在流上做而不是改调用点：全仓七十多处带 🌊 的 print 散在 lib/ pkg/
# surfboard/ 三个目录，逐个改必然漏，而漏掉一处就是「-sS 的输出里还有 emoji」。
# 换一层流是唯一能保证「一律」的地方。

_ANSI_AT_START = re.compile(r"^(?:\x1b\[[0-9;]*m)*")
_ITEM = "\U0001F30A"          # 🌊


def _strip_item(line):
    # 只处理行首（可能先有几个颜色码）的 🌊 与紧跟的一个空格
    match = _ANSI_AT_START.match(line)
    head, rest = line[:match.end()], line[match.end():]
    if rest.startswith(_ITEM):
        rest = rest[len(_ITEM):]
        if rest.startswith(" "):
            rest = rest[1:]
    return head + rest


class _MachineStream:
    """包一层输出流，按行剥掉行首 🌊。

    行缓冲：攒到换行才写出，这样一次 write 的碎片不会把一行切两半。
    flush() 会把残留的半个行也写出去 —— 进度条那种不换行的写法靠它。
    """

    def __init__(self, stream):
        self._stream = stream
        self._pending = ""

    def write(self, text):
        self._pending += text
        out = []
        while "\n" in self._pending:
            line, self._pending = self._pending.split("\n", 1)
            out.append(_strip_item(line) + "\n")
        if out:
            self._stream.write("".join(out))
        return len(text)

    def flush(self):
        if self._pending:
            self._stream.write(_strip_item(self._pending))
            self._pending = ""
        self._stream.flush()

    def __getattr__(self, name):
        return getattr(self._stream, name)


def machine_readable():
    """`-sS` 时把 stdout/stderr 换成不带 🌊 的版本。"""
    if not _show_error:
        return
    sys.stdout = _MachineStream(sys.stdout)
    sys.stderr = _MachineStream(sys.stderr)


def silence_everything():
    """把 fd 1、2 指到 /dev/null —— 之后写的任何东西都不会到终端。

    为什么在 fd 层做，而不是给每个 print 加判断：全仓有七十多处错误输出，
    逐个包一层迟早漏；而且子进程（curl、bash 子脚本、进度条）根本不认
    Python 的 sys.stdout。换掉 fd 才是「一个字节都不出去」的硬保证。

    只在 `-s` 且没有 `-S` 时调用；带 `-S` 时错误必须留着，所以不换。
    """
    devnull = os.open(os.devnull, os.O_WRONLY)
    sys.stdout.flush()
    sys.stderr.flush()
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    os.close(devnull)


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


def misplaced(flag, description):
    """静默模式下的「旗标存在，但属于另一条命令」出口。

    不能用 unknown() —— 那会让人以为拼错了拼写，去反复改大小写；
    真正的原因是命令选错了。
    """
    print(f"wave: {description}", file=sys.stderr)


def flush():
    try:
        sys.stdout.flush()
    except Exception:
        pass
