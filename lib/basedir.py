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

import sys

from configpaths import load_base_dir, to_tilde

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
RESET = '\033[0m'


def render(base_dir, raw=False):
    text = str(base_dir)
    if raw:
        # 不折成 ~：`~` 只在词首且未加引号时才展开，
        # `cd "$(wave basedir --raw)"` 会把它当字面量。脚本要的是绝对路径。
        return text
    return f"🌊 {to_tilde(text)}"


def parse_args(words):
    raw = False
    for word in words:
        if word == "--raw":
            raw = True
        elif word in ("-s", "--silent", "-S", "--show-error"):
            sys.stderr.write(f"{RED_BOLD}🌊 Error: {word} cannot be used with basedir{RESET}\n")
            sys.stderr.write(
                f"{GREEN}🌊 basedir always prints a path; use --raw for the bare value{RESET}\n")
            sys.exit(1)
        else:
            sys.stderr.write(f"{RED_BOLD}🌊 Error: unknown option {word}{RESET}\n")
            sys.stderr.write(f"{GREEN}🌊 wave basedir --help{RESET} lists the flags it accepts\n")
            sys.exit(1)
    return raw


def handle_basedir(input_string=""):
    words = input_string.split()
    # 分发层传进来的是 "wave basedir …"，把头两个词剥掉
    if words and words[0] == "wave":
        words = words[1:]
    if words and words[0] == "basedir":
        words = words[1:]

    raw = parse_args(words)
    print(render(load_base_dir(), raw=raw))
    return 0


if __name__ == "__main__":
    sys.exit(handle_basedir())
