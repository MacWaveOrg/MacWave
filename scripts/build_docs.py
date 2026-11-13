#!/usr/bin/env python3

# build_docs.py
# 由 cli/help.py 与 cli/help_zh.py 生成 man 页与 info 文件。
#
#   python3 scripts/build_docs.py            # 就地重写 man/ 与 info/
#   python3 scripts/build_docs.py --check    # 只比对，不一致就非零退出
#
# 为什么生成而不是手写：15 条命令、近 90 条旗标，两种语言就是近 200 段说明。
# 手写的副本不会报错，只会在某次加旗标之后悄悄落后 —— 读者照着过时的手册敲，
# 得到的却是「unknown option」。scripts/docs_test.sh 就是把这里当唯一来源在守。
#
# 生成物是**纯文本**：man 走 roff，info 走 Info 格式，都不含 ANSI 颜色。
# 颜色只出现在 `wave manual --color`（那里的输出到 TTY，可以按需上色），
# 往 .info 里塞转义码会让 `info wave > notes.txt` 得到一堆 ^[[1m。

import argparse
import sys
import unicodedata
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
# 手册要读的是 cli/（help、help_zh）与 config/（help.py 要 VERSION_FILE）。
# 用 components.txt 的全量路径，与其它脚本同一套规则，避免下次加目录又漏。
sys.path.insert(0, str(SCRIPT_DIR))
from components import paths as component_paths  # noqa: E402

sys.path[:0] = [str(path) for path in component_paths(REPO_DIR)]

import help as help_en           # noqa: E402
import help_zh as zh             # noqa: E402

MAN_DIR = REPO_DIR / "man" / "man1"
INFO_DIR = REPO_DIR / "info"

# 手册里的命令顺序。与 `wave -h` 的 Commands 一段保持一致，`manual` 排在最后
# （它是看手册的命令，本身没什么可讲的）。COMMAND_HELP 里出现而这里没列的命令
# 会让下面 assert 直接失败 —— 加命令忘了改这里，比生成一份缺章节的手册好。
ORDER = ["install", "upgrade", "uninstall", "list", "search", "info",
         "selfupdate", "link", "unlink", "linkquery", "mirror", "latest",
         "shellenv", "version", "manual"]

# 每个语言一份静态散文。放在这里而不是 help.py：这些句子只属于手册，
# `wave -h` 里不出现，写进 help.py 只会让那个模块背着没人读的段落。
PROSE = {
    "en": {
        "product": "MacWave",
        "tagline": "a package manager for macOS software developers",
        "description": (
            "MacWave installs each package into its own versioned directory under the "
            "install root, keeps every version side by side, and maintains unversioned "
            "links so a package can be called with or without a version. Packages are "
            "fetched from a mirror or from MacWave's own bottle store; nothing is "
            "compiled on the user's machine."),
        "commands": "COMMANDS",
        "global_flags": "GLOBAL FLAGS",
        "environment": "ENVIRONMENT",
        "files": "FILES",
        "examples": "EXAMPLES",
        "see_also": "SEE ALSO",
        "options": "OPTIONS",
        "synopsis": "SYNOPSIS",
        "name": "NAME",
        "description_short": "DESCRIPTION",
        "manual_full": "the complete manual",
        "manual_flag": "--zh to read the Chinese edition",
        "env_rows": [
            ("MACWAVE_API_DOMAIN", "package index prefix (default: the public mirror)"),
            ("MACWAVE_BOTTLE_DOMAIN", "package payload prefix"),
            ("MACWAVE_DEPS_DOMAIN", "dependency payload prefix"),
            ("MACWAVE_MIRROR", "set to 1 to make the mirror defaults explicit"),
            ("MACWAVE_PIP_INDEX", "pip index for the Python dependencies"),
            ("MACWAVE_TEST", "treat this directory as the filesystem root (for tests)"),
        ],
        "files_rows": [
            ("~/.config/macwave_config/config.json", "user-level install location"),
            ("/opt/macwave_config/config.json", "system-level install location (takes priority)"),
            ("<base_dir>/man/man1", "these man pages"),
            ("<base_dir>/info", "the info manual (wave.info, wave-zh.info)"),
        ],
        "files_dir": "wave",
    },
    "zh": {
        "product": "MacWave",
        "tagline": "macOS 开发者用的软件包管理器",
        "description": (
            "MacWave 把每个软件包装进安装根目录下、带版本号的独立目录，各版本并存，"
            "并维护一个不带版本号的链接，让同一个包既能带版本号、也能不带版本号调用。"
            "软件包从镜像或 MacWave 自己的存储取得，不在用户机器上编译任何东西。"),
        "commands": "命令",
        "global_flags": "全局旗标",
        "environment": "环境变量",
        "files": "相关文件",
        "examples": "示例",
        "see_also": "另见",
        "options": "选项",
        "synopsis": "用法",
        "name": "名称",
        "description_short": "说明",
        "manual_full": "完整手册",
        "manual_flag": "加 --zh 看中文版",
        "env_rows": [
            ("MACWAVE_API_DOMAIN", "软件包索引的地址前缀（默认用公共镜像）"),
            ("MACWAVE_BOTTLE_DOMAIN", "软件包主体的地址前缀"),
            ("MACWAVE_DEPS_DOMAIN", "依赖产物的地址前缀"),
            ("MACWAVE_MIRROR", "设为 1 时让镜像默认值显式生效"),
            ("MACWAVE_PIP_INDEX", "Python 依赖的 pip 源"),
            ("MACWAVE_TEST", "把这个目录当作文件系统根（供测试用）"),
        ],
        "files_rows": [
            ("~/.config/macwave_config/config.json", "用户级安装位置"),
            ("/opt/macwave_config/config.json", "系统级安装位置（优先）"),
            ("<base_dir>/man/man1", "这些 man 页"),
            ("<base_dir>/info", "info 手册（wave.info、wave-zh.info）"),
        ],
        "files_dir": "wave",
    },
}


def display_width(text):
    """按显示宽度算：CJK 全角记 2 列，组合字符记 0 列。

    不这么算，中文在 72 列折行时会变成参差不齐的锯齿 —— 因为 len() 数的是字符，
    而终端排的是列。
    """
    total = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        total += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return total


def _atoms(text):
    """切成不可再分的原子：西文单词一个原子，CJK 一个字一个原子，空格单独一个。

    不这么切，折行只能两种错法：按字符切会把单词切断（`a` / `re seconds`），
    按空格切则中文整段不断（中文没有空格）。
    """
    atoms = []
    buffer_text = ""
    for char in text:
        if char == " ":
            if buffer_text:
                atoms.append(buffer_text)
                buffer_text = ""
            atoms.append(" ")
        elif unicodedata.east_asian_width(char) in ("W", "F"):
            if buffer_text:
                atoms.append(buffer_text)
                buffer_text = ""
            atoms.append(char)
        else:
            buffer_text += char
    if buffer_text:
        atoms.append(buffer_text)
    return atoms


# 这些字符不能出现在行首：中文的句读符号与闭括号、西文的同一类。
# 不加这条，折行会把「……旧版」和「。」拆成两行（实测中文 info 菜单里就是这样）。
# 允许它们让那一行超出 width 一两个字符 —— 比另起一行孤零零一个标点好看得多。
NO_BREAK_BEFORE = set("。，、；：！？）」』】》〉”’,.;:!?)]}%")


def wrap(text, width):
    """按显示宽度折行；不拆英文单词，中文可任意处断。

    折行由我们自己做完，不留给 info/man 临时折 —— info 在窄终端里会用反斜杠标折行，
    把一行切得很碎（实测 stty cols 40）。
    """
    lines = []
    for paragraph in text.split("\n"):
        if not paragraph.strip():
            lines.append("")
            continue
        line = ""
        for atom in _atoms(paragraph):
            if atom == " ":
                if line:
                    line += " "
                continue
            atom_width = display_width(atom)
            if (line.strip() and display_width(line) + atom_width > width
                    and atom not in NO_BREAK_BEFORE):
                lines.append(line.rstrip())
                line = atom
            else:
                line += atom
        if line.strip():
            lines.append(line.rstrip())
    return lines


def roff_escape(text):
    """roff 里反斜杠是转义起点；行首的 . 与 ' 会被当成宏。"""
    return text.replace("\\", "\\e")


def roff_label(text):
    """旗标/命令写法用 `\\-` 表示字面连字符。

    roff 里裸 `-` 在部分输出设备上会渲染成别的字符，复制粘贴回来就不是那条旗标了。
    """
    return roff_escape(text).replace("-", "\\-")


def roff_body(text, width=72):
    """一段说明 → 若干 roff 正文行，带缩进与折行。"""
    out = []
    for line in wrap(text, width):
        if line:
            if line.startswith(".") or line.startswith("'"):
                line = "\\&" + line
            out.append(roff_escape(line))
        else:
            out.append(".PP")
    return "\n".join(out)


def roff_table(title, rows, kind, width=72):
    """`.SH title` + 若干 `.TP` 词条；kind 决定旗标用 .B 还是命令用 .B。"""
    if not rows:
        return ""
    out = [f".SH {title}"]
    for label, desc in rows:
        out.append(".TP")
        out.append(f".B {roff_label(label)}")
        body = roff_body(desc, width)
        if body:
            out.append(body)
    return "\n".join(out) + "\n"


def man_header(title, section, product, purpose):
    # 刻意不写日期：生成器要能被 `--check` 逐字节比对，任何「今天生成」的字段
    # 都会让第二天重新生成时整篇都不一样。
    return (f'.TH {title.upper()} {section} "" "{roff_escape(product)}" '
            f'"{roff_escape(purpose)}"\n')


def man_overview(lang):
    prose = PROSE[lang]
    commands = COMMAND_TEXT[lang]
    title = "wave" if lang == "en" else "wave-zh"
    out = [man_header(title, 1, prose["product"], "MacWave Manual")]

    out.append(".SH " + prose["name"])
    out.append(f"wave \\- {roff_escape(prose['tagline'])}")

    out.append(".SH " + prose["synopsis"])
    out.append(".B wave")
    out.append("\\fIcommand\\fR [\\fIpackage\\fR] [\\fIflags\\fR]")

    out.append(".SH " + prose["description_short"])
    out.append(roff_body(prose["description"]))

    out.append(roff_table(prose["commands"],
                          [(name, commands[name]["desc"]) for name in ORDER], "command"))

    out.append(roff_table(prose["global_flags"], GLOBAL_TEXT[lang], "flag"))

    out.append(".SH " + prose["examples"])
    examples = []
    seen = set()
    for name in ORDER:
        for example in COMMAND_ENTRY[name]["examples"][:1]:
            if example not in seen:
                seen.add(example)
                examples.append(example)
    out.append(".nf")
    out.append("\n".join(roff_escape(item) for item in examples))
    out.append(".fi")

    out.append(".SH " + prose["environment"])
    for name, desc in prose["env_rows"]:
        out.append(".TP")
        out.append(f".B {roff_label(name)}")
        out.append(roff_body(desc))

    out.append(".SH " + prose["files"])
    for name, desc in prose["files_rows"]:
        out.append(".TP")
        out.append(f".B {roff_label(name)}")
        out.append(roff_body(desc))

    out.append(".SH " + prose["see_also"])
    others = "wave-manual(1)" if lang == "en" else "wave-manual-zh(1)"
    out.append(f"{others}, info(1), wave(1)\\&" if lang == "en" else others)
    return "\n".join(item for item in out if item) + "\n"


def man_command(name, lang):
    prose = PROSE[lang]
    text = COMMAND_TEXT[lang][name]
    title = f"wave-{name}" if lang == "en" else f"wave-{name}-zh"
    out = [man_header(title, 1, prose["product"], "MacWave Manual")]

    out.append(".SH " + prose["name"])
    out.append(f"{roff_escape(title)} \\- {roff_escape(text['desc'].splitlines()[0])}")

    out.append(".SH " + prose["synopsis"])
    out.append(".B " + roff_label(COMMAND_ENTRY[name]["usage"]))

    out.append(".SH " + prose["description_short"])
    out.append(roff_body(text["desc"]))

    rows = [(spec, desc) for spec, desc in text["flags"]]
    if rows:
        out.append(roff_table(prose["options"], rows, "flag"))

    examples = COMMAND_ENTRY[name]["examples"]
    if examples:
        out.append(".SH " + prose["examples"])
        out.append(".nf")
        out.append("\n".join(roff_escape(item) for item in examples))
        out.append(".fi")

    out.append(".SH " + prose["see_also"])
    out.append("wave(1)" if lang == "en" else "wave-zh(1)")
    return "\n".join(item for item in out if item) + "\n"


def info_header(file_name, node, prev, next_node, up):
    parts = [f"File: {file_name}", f"Node: {node}"]
    if next_node:
        parts.append(f"Next: {next_node}")
    if prev:
        parts.append(f"Prev: {prev}")
    if up:
        parts.append(f"Up: {up}")
    return "\x1f\n" + ", ".join(parts) + "\n\n"


def info_paragraphs(rows, width=72):
    """info 正文：折好行、段落间空一行。"""
    blocks = []
    for label, desc in rows:
        blocks.append(f"  {label}")
        blocks.extend("      " + line if line else "" for line in wrap(desc, width - 6))
        blocks.append("")
    return "\n".join(blocks)


def info_file(lang):
    prose = PROSE[lang]
    file_name = "wave.info" if lang == "en" else "wave-zh.info"
    commands = COMMAND_TEXT[lang]

    out = [info_header(file_name, "Top", None, None, "(dir)")]
    out.append(wrap(prose["description"], 72))
    out.append("")
    out.append("* Menu:")
    out.append("")
    for name in ORDER:
        # info 不会替菜单项折行，长描述会把整屏撑成一条横线，所以自己折
        wrapped = wrap(commands[name]["desc"], 60)
        out.append(f"* {name}::\t{wrapped[0]}")
        for extra in wrapped[1:]:
            out.append("        " + extra)
    out.append("")
    out.append(f"* {prose['global_flags']}::")
    out.append("")
    out.append(f"  {prose['manual_full']}。{prose['manual_flag']}")
    out.append("")

    out.append(info_header(file_name, prose["global_flags"], None, None, "Top"))
    out.append(info_paragraphs(GLOBAL_TEXT[lang]))
    out.append("")

    for index, name in enumerate(ORDER):
        prev = ORDER[index - 1] if index else None
        next_node = ORDER[index + 1] if index + 1 < len(ORDER) else None
        text = commands[name]
        out.append(info_header(file_name, name, prev, next_node, "Top"))
        out.append(wrap(text["desc"], 72))
        out.append("")
        if text["flags"]:
            out.append(info_paragraphs(text["flags"]))
        out.append("Examples:")
        out.append("")
        for example in COMMAND_ENTRY[name]["examples"]:
            out.append("     " + example)
        out.append("")

    flat = []
    for block in out:
        if isinstance(block, list):
            flat.extend(block)
        else:
            flat.append(block)
    return "\n".join(flat).rstrip() + "\n"


def build_tables():
    """把英文与中文拼成统一形状：{lang: {命令: {desc, flags}}}。"""
    en = {}
    for name, entry in help_en.COMMAND_HELP.items():
        en[name] = {"desc": entry["desc"], "flags": list(entry["flags"])}
    cn = {}
    for name, entry in zh.COMMANDS_ZH.items():
        cn[name] = {"desc": entry["desc"],
                    "flags": list(entry["flags"].items())}

    missing = set(help_en.COMMAND_HELP) - set(zh.COMMANDS_ZH)
    extra = set(zh.COMMANDS_ZH) - set(help_en.COMMAND_HELP)
    if missing or extra:
        raise SystemExit(f"🌊 Error: 中文表与英文表的命令集合不一致："
                         f"缺 {sorted(missing)}，多 {sorted(extra)}")
    unknown = [name for name in help_en.COMMAND_HELP if name not in ORDER]
    if unknown:
        raise SystemExit(f"🌊 Error: 这些命令没排进 ORDER：{sorted(unknown)}"
                         f"（加命令时同步 scripts/build_docs.py 的 ORDER）")

    global_rows = {"en": list(help_en.GLOBAL_FLAGS),
                   "zh": list(zh.GLOBAL_FLAGS_ZH.items())}
    if {spec for spec, _ in global_rows["en"]} != {spec for spec, _ in global_rows["zh"]}:
        raise SystemExit("🌊 Error: 全局旗标的中英文清单不一致")
    return {"en": en, "zh": cn}, global_rows


COMMAND_TEXT, GLOBAL_TEXT = build_tables()
COMMAND_ENTRY = help_en.COMMAND_HELP


def outputs():
    """{相对路径: 内容}，覆盖 man/ 与 info/ 下的全部生成物。"""
    files = {}
    for lang in ("en", "zh"):
        files[f"man/man1/{'wave' if lang == 'en' else 'wave-zh'}.1"] = man_overview(lang)
        for name in ORDER:
            suffix = "" if lang == "en" else "-zh"
            files[f"man/man1/wave-{name}{suffix}.1"] = man_command(name, lang)
        files["info/wave.info" if lang == "en" else "info/wave-zh.info"] = info_file(lang)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="only compare; exit non-zero when a file is stale")
    args = parser.parse_args()

    stale = []
    for relative, content in sorted(outputs().items()):
        path = REPO_DIR / relative
        if args.check:
            current = path.read_text(encoding="utf-8") if path.exists() else None
            if current != content:
                stale.append(relative)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    if args.check:
        if stale:
            print("🌊 These generated docs are stale:", file=sys.stderr)
            for name in stale:
                print(f"     {name}", file=sys.stderr)
            print("🌊 Run: python3 scripts/build_docs.py", file=sys.stderr)
            return 1
        print(f"🌊 Docs up to date ({len(outputs())} files).")
        return 0

    print(f"🌊 Wrote {len(outputs())} files under man/ and info/.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
