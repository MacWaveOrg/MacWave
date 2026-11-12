#!/usr/bin/env python3

# shellenv.py
# `wave shellenv` —— 打印把 MacWave 放进 PATH 的 shell 代码，供 eval 使用。
#
#   eval "$(~/.local/macwave/lib/wave shellenv)"
#
# 为什么是命令而不是安装器直接改 rc 文件：
#   - 写进别人的 ~/.zshrc 相当于替用户做了决定，删掉时又得靠字符串匹配去猜 ——
#     猜错就是删掉别人的行（`# MacWave mirror` 这种注释就曾被误伤）。
#   - Homebrew / MacPorts 都是这个形状：一行 eval 归用户自己管，升级、换目录、
#     卸载都不用去动别人的文件。
#
# 输出只有 shell 语句，不含任何提示语：它会被 eval 执行，多一个字都是错的。
# 语言无关，中英文用户看到的是同一份。
#
# 与 lib/wave 启动器里的同名快速路径必须**逐字一致**（scripts/shellenv_test.sh 比对）：
# 那一份在 shell 层回答，不启动 Python —— 这一行每次开终端都要跑，实测 Python
# 那条路要 160ms，shell 这条 2ms。

import sys
from pathlib import Path

from configpaths import load_base_dir


# 路径里出现这些字符时无法安全嵌进双引号：宁可报错，也不要输出一段会把
# 用户的 PATH 弄坏的 shell 代码。
UNSAFE = set('"$`\\\n\r')


def render(base_dir: Path) -> str:
    dirs = [base_dir / "bin", base_dir / "links", base_dir / "lib"]

    for path in dirs:
        bad = UNSAFE & set(str(path))
        if bad:
            raise ValueError(
                f"install path contains {''.join(sorted(bad))!r}, which cannot be "
                f"embedded in a shell string: {path}"
            )

    joined = ":".join(str(path) for path in dirs)
    lib_dir = dirs[-1]
    man_dir = base_dir / "man"

    # case 守卫让这段代码可以重复 eval：嵌套的 login shell（`zsh -l` 里再 `zsh -l`）
    # 会再次执行 .zprofile，没有守卫时 PATH 会一层层堆叠同样的三个目录。
    # 已经存在时什么都不做 —— 而不是「换一份新的」，因为那份旧的可能仍有效。
    #
    # MANPATH 跟着一起发：man 页装在 <base_dir>/man/man1，不在系统的搜索路径里。
    # 不发这一句，安装完 `man wave` 只会得到 "No manual entry for wave" —— 手册
    # 装了等于没装。守卫同样按「这个目录已经在 MANPATH 里」来判断。
    return (
        f'case ":$PATH:" in\n'
        f'  *":{lib_dir}:"*) ;;\n'
        f'  *) export PATH="{joined}${{PATH:+:$PATH}}" ;;\n'
        f'esac\n'
        f'case ":${{MANPATH:-}}:" in\n'
        f'  *":{man_dir}:"*) ;;\n'
        f'  *) export MANPATH="{man_dir}${{MANPATH:+:$MANPATH}}" ;;\n'
        f'esac\n'
    )


def handle_shellenv():
    try:
        sys.stdout.write(render(load_base_dir()))
    except ValueError as exc:
        sys.stderr.write(f"🌊 Error: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(handle_shellenv())
