#!/usr/bin/env python3

# help_zh.py
# 中文手册的**说明文字**（`info wave-zh` / `man wave-zh` / `wave manual --zh`）。
#
# 只放翻译，不放结构：命令名、旗标写法、`<占位符>`、示例命令行全是代码片段，
# 一律从 cli/help.py 原样取用，不在这里重复一遍 —— 重复就会走散。
#
# 键必须与 help.py 里的**逐字相同**（`GLOBAL_FLAGS[i][0]` 与
# `COMMAND_HELP[cmd]["flags"][i][0]`）。scripts/docs_test.sh 会逐项比对：
#
#   少一条  → 中文手册里那个旗标没有解释，读者以为是漏印
#   多一条  → 英文那边已经改名或删掉了，这里留着的是幽灵
#
# 所以加旗标时改两处，测试会拦。

# 与 help.GLOBAL_FLAGS 的旗标写法一一对应
GLOBAL_FLAGS_ZH = {
    "-s, --silent": "完全不输出，只靠退出码表达结果（压过 -v；适用于 install / upgrade / uninstall / link / unlink / selfupdate）",
    "-S, --show-error": "与 -s 同用时，命令失败仍打印错误（不带 🌊，方便脚本解析）",
    "-C, --continue": "断点续传",
    "--proxy <string>": "HTTP/HTTPS 代理（例如 http://127.0.0.1:8080）",
    "--skip-ssl": "跳过 SSL 证书校验（不安全）",
    "--limit-rate <string>": "限速（例如 200K、1M、5M；不输入单位默认 B）",
    "--max-time <string>": "单次请求最大时长（40s、1min、1min20s、2h；不输入单位默认 s）",
    "--connect-timeout <string>": "握手最大时长",
    "--content-time <string>": "接收数据的最大时长",
    "--ver <string>": "安装指定版本（仅 install；`--ver=1.0` 这种写法也认）",
    "-F, --force": "当前 macOS 版本低于软件包声明要求时仍继续安装",
    "--install-python-from-source": "从上游地址取自带的 Python，而不是 MacWave 自己的仓库",
    "MACWAVE_PIP_INDEX": "环境变量。Python 依赖的 pip 源，默认 pypi.org/simple",
}

# 与 help.COMMAND_HELP 一一对应：命令 → {desc, flags:{旗标写法: 说明}}
COMMANDS_ZH = {
    "install": {
        "desc": "安装一个软件包，或它的某个指定版本。",
        "flags": {
            "-C, --continue": "断点续传",
            "--proxy <string>": "HTTP/HTTPS 代理（例如 http://127.0.0.1:8080）",
            "--skip-ssl": "跳过 SSL 证书校验（不安全）",
            "--limit-rate <string>": "限速（例如 200K、1M、5M；不输入单位默认 B）",
            "--max-time <string>": "单次请求最大时长（40s、1min、1min20s、2h；不输入单位默认 s）",
            "--connect-timeout <string>": "握手最大时长",
            "--content-time <string>": "接收数据的最大时长",
            "--unlink": "取消此软件包不带版本号的软链接",
            "-F, --force": "当前 macOS 版本低于软件包声明要求时仍继续安装",
            "-v, --verbose": "详细模式",
        },
    },
    "upgrade": {
        "desc": "把软件包升级到最新版本；使用 --all 可升级所有已装包，旧版本会被保留。"
                "使用 -X, --remove-old-versions 可升级同时移除旧版。",
        "flags": {
            "-a, --all": "升级所有有新版本的已装包",
            "-X, --remove-old-versions": "升级同时移除旧版",
            "-C, --continue": "断点续传",
            "--proxy <string>": "HTTP/HTTPS 代理（例如 http://127.0.0.1:8080）",
            "--skip-ssl": "跳过 SSL 证书校验（不安全）",
            "--limit-rate <string>": "限速（例如 200K、1M、5M；不输入单位默认 B）",
            "--max-time <string>": "单次请求最大时长（40s、1min、1min20s、2h；不输入单位默认 s）",
            "--connect-timeout <string>": "握手最大时长",
            "--content-time <string>": "接收数据的最大时长",
            "-F, --force": "当前 macOS 版本低于软件包声明要求时仍继续安装",
            "-v, --verbose": "详细模式",
        },
    },
    "shellenv": {
        "desc": "打印一段把 MacWave 的目录加到 PATH 前面的 shell 代码。在 shell 配置里 "
                "eval 一次即可；它自己什么也不改。",
        "flags": {},
    },
    "mirror": {
        "desc": "显示每一类数据实际获取地址，包括仍在使用内置默认值的项。",
        "flags": {
            "--json": "以 JSON 格式输出配置",
            "--yaml": "以 YAML 格式输出配置",
            "--toml": "以 TOML 格式输出配置",
            "--raw": "输出 export 行",
            "--only-set": "配合 --raw：只导出用户改过的源（MACWAVE_*_DOMAIN 变量），"
                          "其余继续走内置默认值",
            "--show-password": "输出真实密码",
            "--hide-user": "隐藏用户名",
        },
    },
    "latest": {
        "desc": "将本机已装的版本与索引里的最新版本比较，不下载。",
        "flags": {
            "-a, --all": "检查每个已装软件包",
            "--max-time <string>": "单次请求最大时长（40s、1min、1min20s、2h；不输入单位默认 s）",
            "--connect-timeout <string>": "握手最大时长",
            "--content-time <string>": "接收数据的最大时长",
            "-v, --verbose": "详细模式",
        },
    },
    "uninstall": {
        "desc": "卸载某个包的一个版本。不带版本号的链接会自动退到剩下的最高版本，"
                "并在最后一个版本被卸载时一起消失。",
        "flags": {
            "--unlink": "取消此软件包不带版本号的软链接",
        },
    },
    "list": {
        "desc": "列出已安装的软件包及其版本。",
        "flags": {},
    },
    "search": {
        "desc": "在软件包索引（线上）里搜索。",
        "flags": {},
    },
    "info": {
        "desc": "显示作者、简介、主页，以及已安装版本与索引里的可用版本。",
        "flags": {
            "--json": "以 JSON 格式输出",
            "--yaml": "以 YAML 格式输出",
            "--toml": "以 TOML 格式输出",
            "--raw": "输出原格式",
        },
    },
    "selfupdate": {
        "desc": "把 MacWave 自身更新到自更新仓库里发布的版本。",
        "flags": {
            "--max-time <string>": "单次请求最大时长（40s、1min、1min20s、2h；不输入单位默认 s）",
            "--connect-timeout <string>": "握手最大时长",
            "--content-time <string>": "接收数据的最大时长",
            "--install-python-from-source": "从上游地址取自带的 Python，而不是 MacWave 自己的仓库",
        },
    },
    "link": {
        "desc": "创建一个不带版本号的快捷方式，或把它改指到另一个已安装版本。"
                "之后的安装与卸载会自动维护它。",
        "flags": {
            "--all, -a": "对所有已装包生效",
        },
    },
    "unlink": {
        "desc": "删掉那个不带版本号的快捷方式。之后再卸载也不会重新创建。",
        "flags": {
            "--all, -a": "对所有已装包生效",
        },
    },
    "linkquery": {
        "desc": "显示那个不带版本号的快捷方式指向哪个版本。",
        "flags": {
            "--all, -a": "对所有已装包生效",
        },
    },
    "version": {
        "desc": "打印当前安装的 MacWave 版本。",
        "flags": {},
    },
    "manual": {
        "desc": "显示完整手册（与 man / info 里的是同一份内容），可按命令名只看一节。",
        "flags": {
            "--zh": "输出中文版",
            "--color": "给标题与旗标上色（默认纯文本）",
        },
    },
}


# -------------------- `wave -h --zh` 那几节 --------------------
#
# 结构完全照 cli/help.OVERVIEW 走，这里只提供「节标题 + 每条说明」。
# 缺条目会直接抛 KeyError（而不是悄悄漏印），scripts/docs_test.sh 也会比对。

OVERVIEW_TITLES = {
    "commands": "命令",
    "flags": "旗标",
    "global": "全局旗标（任何命令都能用）",
    "special": "特殊旗标",
    "links": "不带版本号的链接",
}

OVERVIEW_DESC = {
    "commands": {
        "install": "安装软件包（最新版本）",
        "upgrade": "把软件包升级到最新版本",
        "uninstall": "卸载软件包",
        "list": "列出已安装的软件包",
        "search": "在软件包索引（线上）里搜索",
        "info": "显示软件包的详细信息",
        "selfupdate": "把 MacWave 自身更新到最新版本",
        "link": "给已装软件包创建不带版本号的链接",
        "unlink": "删除那些不带版本号的链接",
        "linkquery": "查看不带版本号的链接指向哪个版本",
        "mirror": "显示各类数据实际从哪个地址取",
        "latest": "显示哪些软件包有新版本",
        "shellenv": "打印把 MacWave 加进 PATH 的 shell 代码",
        "manual": "显示完整手册（与 man、info 里的是同一份）",
    },
    "flags": {
        "-h, --help": "查看任意命令的帮助",
        "-V, --version": "打印版本信息",
        "-v, --verbose": "详细模式",
    },
    "special": {
        "wave install <pkgname>@<version>": "下载某个指定版本的软件包",
        "--unlink": "取消此软件包不带版本号的软链接",
        "-X, --remove-old-versions": "升级同时移除旧版",
        "--all, -a": "对所有已装包生效（upgrade / link / unlink / linkquery）",
    },
    "links": {
        "wave link <name>": "把软件包链接到它已装的最高版本",
        "wave linkquery <name>": "查看 <name> 链接到了哪个版本（例如 🌊 ffmpeg@9.0）",
        "wave unlink <name>": "删掉那个链接",
    },
}
OVERVIEW_DESC["global"] = GLOBAL_FLAGS_ZH

OVERVIEW_NOTES = {
    "links": "链接在安装时创建、卸载时重新指向；--unlink 不会留下指向空的链接。",
}


def overview():
    """按 cli/help.OVERVIEW 的结构给出中文版；缺一条就抛 KeyError。"""
    import help as help_en

    sections = []
    for section in help_en.OVERVIEW:
        section_id = section["id"]
        rows = []
        for kind, spec, _english in section["rows"]:
            desc = OVERVIEW_DESC[section_id][spec]
            rows.append((kind, spec, desc))
        sections.append({"id": section_id,
                         "title": OVERVIEW_TITLES[section_id],
                         "rows": rows})
    return sections
