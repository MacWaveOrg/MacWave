#!/usr/bin/env python3

# manual.py
# `wave manual [<command>] [--zh] [--color]` —— 在终端里看完整手册。
#
# 内容与 man/、info/ 下的是同一份：都由 cli/help.py + cli/help_zh.py 生成。
# 为什么还要这条命令：macOS 没有 `info`（要装 texinfo），`man` 又得先 eval
# shellenv 把 MANPATH 带上 —— 两个前提都满足的人不多，于是手册等于没装。
# 这条命令不依赖任何外部二进制。
#
# 输出默认是**纯文本**：`wave manual > notes.txt` 得到的就是能读的文件。
# 只有显式给 `--color` 才上色 —— 与 `-s` 下的机器可读输出不许带 🌊 同一条原则：
# 装饰只在人看得见的时候才出现，而且要人自己要求。

import sys

from configpaths import load_base_dir


# 与 `wave -h` 同一套配色：标题紫、旗标青、占位符黄、命令绿。
PURPLE = '\033[35m'
CYAN = '\033[36m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
BOLD = '\033[1m'
RESET = '\033[0m'

WIDTH = 78
INDENT = 2
GAP = 2


def _paint(text, color, enabled):
    return f"{color}{text}{RESET}" if enabled and color else text


def _wrap(text, width):
    """按空格折行。手册正文是英文/中文混排，这里不追求两端对齐，只保证不超宽。"""
    words_in = text.split()
    lines = []
    current = ""
    for word in words_in:
        if not current:
            current = word
        elif len(current) + 1 + len(word) <= width:
            current += " " + word
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def _section(title, rows, color):
    """一行一个 (标签, 说明)，说明折行后与标签左对齐。"""
    if not rows:
        return []
    labels = [label for label, _ in rows]
    width = max(len(label) for label in labels)
    out = ["", _paint(f"{title}:", PURPLE, color)]
    for label, desc in rows:
        pad = " " * (width - len(label) + GAP)
        wrapped = _wrap(desc, WIDTH - INDENT - width - GAP)
        first = wrapped[0] if wrapped else ""
        out.append(f"{' ' * INDENT}{_paint(label, CYAN, color)}{pad}{first}")
        for extra in wrapped[1:]:
            out.append(f"{' ' * (INDENT + width + GAP)}{extra}")
    return out


def _overview(lang, color):
    import help as help_en

    sections, notes = help_en.overview_for(lang)
    out = [_paint(help_en.USAGE_LINE[lang], BOLD, color), ""]
    out.append(help_en.TAGLINE[lang])
    for section in sections:
        rows = [(spec, desc) for _kind, spec, desc in section["rows"]]
        out.extend(_section(section["title"], rows, color))
        if section["id"] in notes:
            out.append(f"{' ' * INDENT}{notes[section['id']]}")
    return out


def _one_command(command, lang, color):
    import help as help_en

    if command not in help_en.COMMAND_HELP:
        return None
    entry = help_en.COMMAND_HELP[command]
    desc, flags = help_en.command_text(command, lang)
    labels = help_en.COMMAND_HELP_LABELS[lang]

    out = [_paint(entry["usage"], BOLD, color), ""]
    out.extend(_wrap(desc, WIDTH))
    out.extend(_section(labels["flags"], flags, color))
    if entry["examples"]:
        out.append("")
        out.append(_paint(f"{labels['examples']}:", PURPLE, color))
        for example in entry["examples"]:
            out.append(f"{' ' * INDENT}{example}")
    return out


def parse_args(words):
    """返回 (命令或 None, 语言, 是否上色)。旗标写在命令前后都认。

    与其它命令不同，这里不校验「未知旗标」：手册命令本身无害，多一个没被认出的
    词就当成命令名去查，查不到再给一句明确的提示 —— 比一句「illegal option」有用。
    """
    lang = "zh" if "--zh" in words else "en"
    color = "--color" in words
    rest = [word for word in words if word not in ("--zh", "--color")]
    return (rest[0] if rest else None), lang, color


def handle_manual(input_string):
    words = input_string.split()[2:]
    command, lang, color = parse_args(words)

    if command is not None:
        body = _one_command(command, lang, color)
        if body is None:
            print(f"🌊 Error: no manual section for {command!r}.", file=sys.stderr)
            print("🌊 Next      wave manual            lists every section", file=sys.stderr)
            return 1
    else:
        body = _overview(lang, color)

    text = "\n".join(body).rstrip()
    # 分页器只在「真的是终端」时才起：重定向到文件时 pager 会把内容吞给自己。
    if sys.stdout.isatty():
        _page(text)
    else:
        print(text)
    return 0


def _page(text):
    """交给 less（若在），否则直接打印。

    less 的 -R 让颜色码被当成颜色而不是乱码；FILE 为空时 less 走 stdin。
    """
    import os
    import shutil
    import subprocess

    pager = shutil.which("less")
    if not pager:
        print(text)
        return
    env = dict(os.environ)
    # 已经是 less 的管道里再起 less 没意义
    if env.get("LESS"):
        env["LESS"] = env["LESS"] + " -R"
    else:
        env["LESS"] = "-R"
    try:
        subprocess.run([pager], input=text.encode("utf-8"), env=env, check=False)
    except OSError:
        print(text)


def show_hint():
    """安装完成后的「怎么查手册」那两行 —— 由 install.sh 之类调用。"""
    base = load_base_dir()
    print(f"  {base / 'man' / 'man1'}   man wave   (needs MANPATH from: "
          f"eval \"$({base / 'lib' / 'wave'} shellenv)\")")
    print(f"  {base / 'info'}   info wave   (needs texinfo), or: wave manual")
