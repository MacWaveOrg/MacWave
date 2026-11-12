#!/usr/bin/env python3

# silent.py
# `-s / --silent` 与 `-S / --show-error` 的全部实现。
#
# 两段，共用同一份状态（_silent / _show_error）与同一张命令清单
# （SILENT_COMMANDS）：
#
#   A. 参数层   strip() / apply()
#               拿到用户敲的那串词之后要做的判断：哪些命令能静默、怎么把旗标
#               从 argv 里剥掉、剥完怎么落到运行期开关。**只被 wave.py 调用**，
#               而且必须在分发之前跑完。
#   B. 运行期   say() / ask() / show() / silence_everything() / machine_readable()
#               全仓唯一的输出闸门。pkg/、surfboard/ 里的模块都用它。
#
# 为什么合成一个模块：这两半本来就共享状态与命令清单，拆成 quiet.py + silent.py
# 时「哪些命令能静默」要跨两个文件保持一致，读 `-s` 的完整行为得来回跳。合起来
# 之后，从 argv 到 fd 重定向全在一个文件里，`-s` 的实现只有一处可看。
#
# 运行期三条约定：
#   1. say() 只用于「成功了，顺便告诉你一声」这类噪音。错误一律继续用原来的
#      print(f"...Error...")，不改成 say —— 静默只压噪音，不压错误。
#   2. ask() 在静默模式下**不读 stdin**，直接返回 default。否则提示语被吞掉、
#      input() 还在等，表现是命令看起来卡死。返回 None 让调用方走「非交互」
#      分支，那些分支本来就选了保守的默认值（不重试、不删旧版本）。
#   3. 静默优先于啰嗦。-s 与 -v 同时给时，-v 被关掉（见 wave.py 的调度）。
#   4. 单给 -s 时连错误一起吞掉（与 curl 一致），退出码是唯一的信号；
#      想留错误就加 -S / --show-error。这条由 silence_everything() 在 fd 层实现，
#      所以不用改那几十处 print —— 子进程的输出也一并消失。

import os
import re
import sys

import flags


# ==================== A. 参数层 ====================

# `-s` 只对「有过程可安静」的命令有意义。list / latest / search / info / mirror
# 存在的目的就是打印，给它们 -s 只会得到一片空白 —— 那不是静默，是把命令废掉。
# 所以这些命令上出现 -s 直接报错，比让它默默什么都不输出好。
#
# **这份名单是权威**，flags.COMMAND_FLAGS 里那份是给它做提示文案用的副本；
# scripts/flags_test.sh 比对两边。加一条能静默的命令时，两处都要改。
SILENT_COMMANDS = {"install", "upgrade", "uninstall", "link", "unlink", "selfupdate"}


def strip(words):
    """把 `-s` / `--silent` / `-S` / `--show-error` 从 argv 里拿掉。

    返回 (剩下的 words, 是否静默, 是否保留错误)。写法与 upgrader 处理 -X 一致：

        wave install jq -s          单个
        wave install jq --silent    长写法
        wave upgrade jq -sX         合并（s 与 X 都在这一簇里）
        wave upgrade jq -CsX        合并里夹着别的短旗标
        wave install jq -sS         静默但保留错误（curl 的 -sS）

    只处理单横线短旗标簇，`--skip-ssl` 这类长旗标不受影响（`s`/`S` 不在
    `--` 开头的那一类里找）。包名不以 `-` 开头，所以不会被误伤。
    """
    silent = False
    show_error = False
    kept = []
    for word in words:
        if word == "--silent":
            silent = True
            continue
        if word == "--show-error":
            show_error = True
            continue
        cluster = flags.short_cluster(word)
        if cluster is not None:
            # 大写 S 与小写 s 各管一件事，顺序无关：-sS 与 -Ss 等价
            silent = silent or "s" in cluster
            show_error = show_error or "S" in cluster
            remaining = flags.remove_short(word, "sS")
            if remaining is not None:
                if remaining:
                    kept.append(remaining)
                continue
        kept.append(word)
    return kept, silent, show_error


def apply(words, command):
    """剥掉静默旗标、把结论落到下面的运行期开关，返回剩下该交给 handler 的 words。

    位置必须在分发之前，而且必须**从 argv 里拿掉**这两个旗标：各 handler 的旗标
    白名单里没有它们（按命令各自校验，加进去要改十几处），留着的话
    `wave install jq -s` 会报「illegal option -s」。

    静默优先于啰嗦：同时给了 -v，-v 会被各模块的 verbose 判定挡掉。
    """
    words, is_silent, show_error = strip(words)
    if not is_silent:
        return words

    if command not in SILENT_COMMANDS:
        # 拒绝得早一点，并且用和「旗标写错」同一种形状，脚本好处理。
        # 不能说 unknown —— -s 真实存在，只是不适用于只读命令。
        # 这句话由 flags.describe 生成，别在这里另拼一份：命令清单存在
        # flags.COMMAND_FLAGS 里，与下面的 SILENT_COMMANDS 由 flags_test.sh
        # 钉着不许走散。
        misplaced("-s", flags.describe("-s") or "-s is not available here")
        sys.exit(1)

    # 单给 -s 时连错误一起吞（curl 语义）；-sS 才留错误。
    set_silent(True, show_error=show_error)
    if show_error:
        # -sS：输出给脚本读，一律不带 🌊（见下面的 machine_readable）
        machine_readable()
    else:
        silence_everything()

    # 子脚本（pkginstaller.sh、depsmanager.sh…）也要知道：它们的输出虽然由
    # Python 重印，但 update_commands 那类直接写终端的脚本只能靠环境变量。
    os.environ["MACWAVE_SILENT"] = "1"
    return words


# ==================== B. 运行期 ====================

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


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    sys.exit(1)
