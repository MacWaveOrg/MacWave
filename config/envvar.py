#!/usr/bin/env python3

# envvar.py

# 环境变量的**名单、默认值与说明**，只此一处。
#
# 为什么要有这个文件：这些名字与默认值原先散在四处 ——
#   net/domains.py       ENV_NAME / DEFAULTS / DESCRIPTION 三张表
#   lib/mirrorinfo.py    PIP_ENV = "MACWAVE_PIP_INDEX" 与它自己的默认值
#   config/configpaths.py 直接写 "MACWAVE_TEST" / "MACWAVE_TEST_ROOT"
#   两份 shell 脚本        再各抄一份域名默认值（它们被 curl 下来直接执行，
#                         没有本地文件可以 source，只能内联）
# 前三处走散的症状是「同一次请求在 Python 侧用一个地址、在错误信息里写另一个」，
# 而默认值与 shell 那份走散更糟：装的时候从 A 取文件、跑的时候从 B 取元数据。
#
# 分工：
#   本文件                     名字 + 默认值 + 一句话说明（数据）
#   net/domains.py             校验（协议、回环、危险字符）与拼 URL（逻辑）
#   scripts/check_domain_defaults.py  比对 shell 里那几份副本（覆盖率靠它）
#
# 约束：**不 import 任何项目模块**。lib/selfupdate.py 会被「什么都没装」的
# 解释器直接导入（测试就这么用），这条路径上只允许标准库。

import os


class Domain:
    """一个对外地址的配置项：环境变量名、无人设置时的默认值、一句话说明。"""

    __slots__ = ("name", "default", "description")

    def __init__(self, name, default, description):
        self.name = name
        self.default = default
        self.description = description

    def __repr__(self):
        return f"Domain({self.name!r}, default={self.default!r})"


# 键是内部代号（与 net/domains.py 的各 *_domain() 函数对应），值见上面。
DOMAINS = {
    "api": Domain(
        "MACWAVE_API_DOMAIN",
        "https://raw.githubusercontent.com/MacWaveOrg/infosource/HEAD",
        "package and dependency index"),
    # 默认指向 GitHub Releases：它的下载路径 /<tag>/<资产> 与静态镜像的 /<包名>/<文件>
    # 同形，所以国内镜像站只要 rsync 出同一棵树即可。指向仓库文件会被 git 的
    # 100 MiB 硬限拦住。
    "bottle": Domain(
        "MACWAVE_BOTTLE_DOMAIN",
        "https://github.com/MacWaveOrg/Bottle/releases/download",
        "prebuilt binary packages"),
    "deps": Domain(
        "MACWAVE_DEPS_DOMAIN",
        "https://github.com/MacWaveOrg/Deps/releases/download",
        "dependency binaries"),
    "core": Domain(
        "MACWAVE_CORE_DOMAIN",
        "https://raw.githubusercontent.com/MacWaveOrg/MacWave",
        "MacWave's own files"),
    # 解释器单独一个仓库：体积（每架构约 26 MB）与发布节奏都和自更新数据不同
    "python": Domain(
        "MACWAVE_PYTHON_DOMAIN",
        "https://raw.githubusercontent.com/MacWaveOrg/Python/HEAD",
        "the bundled CPython interpreter"),
    "selfupdate": Domain(
        "MACWAVE_SELFUPDATE_DOMAIN",
        "https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/HEAD",
        "self-update data"),
    # 预留：源码包的位置定了以后再接上
    "sourcecode": Domain(
        "MACWAVE_PKG_SOURCECODE_DOMAIN",
        "",
        "package source code (reserved)"),
}

# pip 的索引。不在 DOMAINS 里：它不是「MacWave 的数据源」，没有协议校验，
# 只由 install.sh / selfupdate.sh 装依赖时用，`wave mirror` 负责展示。
PIP_INDEX = "MACWAVE_PIP_INDEX"
PIP_DEFAULT = "https://pypi.org/simple"

# 测试根：设了它，整个进程把那个目录当成 /。
TEST_ROOT = "MACWAVE_TEST"
# 派生给 shell 的同一个值（Python 与 shell 都要用，名字不共用一个变量）。
TEST_ROOT_EXPORT = "MACWAVE_TEST_ROOT"


def kinds():
    """全部数据源代号，顺序与 DOMAINS 一致。"""
    return tuple(DOMAINS)


def name(kind):
    return DOMAINS[kind].name


def default(kind):
    return DOMAINS[kind].default


def description(kind):
    return DOMAINS[kind].description


def raw(kind):
    """环境变量里的原值：去空白，没设时是空字符串。

    不回落默认值、不做校验 —— 那两件事归 net/domains.py，因为「一个都不设时
    用哪个地址」和「什么样的地址算合法」是两套规则。
    """
    return (os.environ.get(name(kind)) or "").strip()
