#!/usr/bin/env python3

# confirm.py

# 不可逆操作的三段式确认。目前只有 `wave basedir --set` 用，但它是通用的：
# 任何「搬走整棵树 / 删掉整棵树」这类动作都该走同一条路。
#
# 三段是**故意各自打一遍**的，不是一句 y/n：
#
#   1. 整行打字 `Yes` —— 拦住"手滑回车"。默认答案永远是"不做"。
#   2. 手工输入**当前**安装路径 —— 逼用户先说出东西现在在哪，
#      确认他动的是自己以为的那棵树（而不是看到别人机器上的输出就照抄）。
#   3. 逐字核对一句话 —— 把目标路径也打进手。只有全对才继续。
#
# 第三段逐字符渲染：未输入的字是灰色，输对变黑，输错的那一位变红且**不前进**
# （所以打字快也跳不过去）。这一段的意义不在于"再问一次"，而在于用户必须
# 一个字母一个字母地读完那句话 —— 里面包含目标路径。
#
# 为什么不用 `input()` 做第三段：`input()` 会把整行回显成一样的样子，
# 用户看不出自己打错在哪里；逐字符才能"错在哪一位就在哪一位变红"。
#
# 终端约束：三条都要求 stdin 与 stdout 都是 tty。没有 tty（管道、CI、
# `< /dev/null`）时一律拒绝 —— 这类操作没有"非交互也能做"的正当理由，
# 而且回显样式在非 tty 上等于一串乱码。

import codecs
import os
import sys
import termios
import time


RED_BOLD = "\033[1;31m"
GREEN = "\033[32m"
GRAY = "\033[90m"
RESET = "\033[0m"
CLEAR_LINE = "\r\033[2K"

# 输错那一刻的停留时间。太短看不见，太长像卡住。
WRONG_HOLD_SECONDS = 0.35


class NotConfirmed(Exception):
    """用户没有完成某一段确认。`reason` 直接面向用户，英文、可执行。"""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def _require_tty():
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise NotConfirmed(
            "this needs an interactive terminal: standard input or output is not a tty")


def _read_line(prompt):
    """读一整行（回车结束）。EOF / Ctrl-C 都算"没确认"。

    **必须从文件描述符直接读，不能用 input()/sys.stdin.readline()**：Python 的
    文本层会一次读走一大块到自己的缓冲区里，第三段改用 os.read 逐字节读时那些
    字节已经被吞掉，于是它永远等不到输入（实测：喂完三行，进程挂住）。
    终端的规范模式本身会回显、并在一行结束时才返回，所以逐字节读到 \n 即可。
    """
    sys.stdout.write(prompt)
    sys.stdout.flush()

    fd = sys.stdin.fileno()
    data = bytearray()
    while True:
        try:
            chunk = os.read(fd, 1)
        except KeyboardInterrupt:
            sys.stdout.write("\n")
            sys.stdout.flush()
            raise NotConfirmed("cancelled")
        if not chunk:
            raise NotConfirmed("cancelled (end of input)")
        if chunk == b"\n":
            break
        data += chunk
    return data.decode("utf-8", "replace").rstrip("\r")


def require_exact_word(word, warning_lines):
    """第 1 段：红字警告 + 必须原样打出 `word`。"""
    _require_tty()

    print(f"{RED_BOLD}{'=' * 66}{RESET}")
    for line in warning_lines:
        print(f"{RED_BOLD}{line}{RESET}")
    print(f"{RED_BOLD}{'=' * 66}{RESET}")
    print(f"Type {word} exactly (capital Y) to continue; anything else aborts.")

    answer = _read_line("> ")
    if answer != word:
        raise NotConfirmed(
            f'expected exactly "{word}" and got {answer!r}; nothing was changed')


def require_exact_path(expected):
    """第 2 段：手工输入**当前**安装路径，必须与它一致。"""
    _require_tty()

    print()
    print("Now type the current install path, so it is clear which tree you are "
          "moving:")
    print(f"{GRAY}{expected}{RESET}   (do not copy from above: type it)")
    print("Path:")

    answer = _read_line("> ")
    if answer != expected:
        raise NotConfirmed(
            f"the path you typed does not match the current install path ({expected}); "
            f"nothing was changed")


def _render(target, typed, wrong, prompt):
    """把一句话按"已输入/当前/未输入"上色后重画同一行。"""
    out = [CLEAR_LINE, prompt]
    for index, char in enumerate(target):
        if index < typed:
            out.append(RESET + char)
        elif index == typed and wrong:
            out.append(RED_BOLD + char)
        else:
            out.append(GRAY + char)
    out.append(RESET)
    sys.stdout.write("".join(out))
    sys.stdout.flush()


def require_typed_sentence(target):
    """第 3 段：逐字打出 `target`。返回 True；输不完绝不返回。"""
    _require_tty()

    print()
    print("Type the sentence below, character by character. It must match exactly,")
    print("including the path, the comma and the full stop.")
    print()

    prompt = "> "
    typed = 0
    decoder = codecs.getincrementaldecoder("utf-8")("ignore")
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)

    try:
        # 不用 tty.setcbreak()：它用 TCSAFLUSH 设置模式，会**丢弃已排队的输入**。
        # 用户提前敲/粘贴的字符会被吞掉，表现为"打了没反应"。TCSADRAIN 只等输出
        # 排空，输入原样保留 —— 与还原时同一个 flag。
        mode = termios.tcgetattr(fd)
        mode[3] &= ~(termios.ECHO | termios.ICANON)
        termios.tcsetattr(fd, termios.TCSADRAIN, mode)

        while True:
            _render(target, typed, False, prompt)

            raw = os.read(fd, 1)
            if not raw:
                raise NotConfirmed("cancelled (end of input)")

            if raw == b"\x03":  # Ctrl-C
                raise NotConfirmed("cancelled")
            if raw in (b"\r", b"\n"):
                if typed == len(target):
                    sys.stdout.write("\n")
                    sys.stdout.flush()
                    return True
                raise NotConfirmed(
                    f"the sentence was not complete ({typed} of {len(target)} "
                    f"characters); nothing was changed")
            if raw in (b"\x7f", b"\x08"):  # Backspace / Delete
                if typed > 0:
                    typed -= 1
                continue

            char = decoder.decode(raw)
            if not char:
                continue  # 多字节字符还没收全

            expected = target[typed] if typed < len(target) else None
            if char == expected:
                typed += 1
                continue

            # 输错：这一位变红，停一下让用户看见，然后不前进（也就不可能蒙混过关）
            _render(target, typed, True, prompt)
            time.sleep(WRONG_HOLD_SECONDS)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def confirmation_sentence(new_path):
    """第 3 段要用户逐字打出的那句话。路径必须原样出现在里面。"""
    return f"Yes, I confirm switching basedir to {new_path}."


def confirm_basedir_switch(old_path, new_path):
    """三段确认一次跑完。任何一段没过都抛 NotConfirmed。"""
    require_exact_word("Yes", [
        "WARNING: you are about to copy the whole MacWave install tree",
        f"    from  {old_path}",
        f"    to    {new_path}",
        "Running packages keep pointing at the old tree until your PATH changes,",
        "and the old tree is NOT deleted for you.",
    ])

    require_exact_path(str(old_path))
    require_typed_sentence(confirmation_sentence(str(new_path)))

    print(f"{GREEN}🌊 Confirmed.{RESET}")
