#!/usr/bin/env python3

# domains.py
# MacWave 4.0 起，所有对外地址都由环境变量决定，代码里不再出现字面量。
#
# 为什么：以前每个软件包只有一条指向上游的 URL，下载压力与可用性都押在别人的
# 服务器上。4.0 把这些内容搬到自己管理的仓库（Bottle / Deps），于是「从哪儿取」
# 变成一件需要能整体替换的事 —— 换镜像、换存储后端、换 CDN 都只改环境变量。
#
#   | 变量                          | 含义                                     |
#   | MACWAVE_API_DOMAIN            | 索引（软件包与依赖的元数据）              |
#   | MACWAVE_BOTTLE_DOMAIN         | 预编译二进制包（Bottle）                  |
#   | MACWAVE_DEPS_DOMAIN           | 依赖的二进制包                            |
#   | MACWAVE_CORE_DOMAIN           | MacWave 自身文件                          |
#   | MACWAVE_PYTHON_DOMAIN         | 独立 CPython 解释器                       |
#   | MACWAVE_SELFUPDATE_DOMAIN     | 自更新信息（版本号、文件清单、迁移脚本）   |
#   | MACWAVE_PKG_SOURCECODE_DOMAIN | 软件包源码（预留，暂未使用）               |
#
# 刻意不提供 `wave mirror` 之类的命令：镜像就是一组环境变量（同 Homebrew 的
# HOMEBREW_*_DOMAIN），放在 shell 配置或 CI 里即可，不需要 MacWave 参与。
#
# DEFAULTS 里仍是 3.x 在用的地址，所以一个都不设时行为与 3.x 完全一致。
# 新仓库（Selfupdate / Bottle / Deps）建好以后，只需要改这张表。

import json
import os
import sys


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'


# -------------------- 变量与默认值 --------------------

ENV_NAME = {
    "api":        "MACWAVE_API_DOMAIN",
    "bottle":     "MACWAVE_BOTTLE_DOMAIN",
    "deps":       "MACWAVE_DEPS_DOMAIN",
    "core":       "MACWAVE_CORE_DOMAIN",
    "python":     "MACWAVE_PYTHON_DOMAIN",
    "selfupdate": "MACWAVE_SELFUPDATE_DOMAIN",
    "sourcecode": "MACWAVE_PKG_SOURCECODE_DOMAIN",
}

DESCRIPTION = {
    "api":        "package and dependency index",
    "bottle":     "prebuilt binary packages",
    "deps":       "dependency binaries",
    "core":       "MacWave's own files",
    "python":     "the bundled CPython interpreter",
    "selfupdate": "self-update data",
    "sourcecode": "package source code (reserved)",
}

DEFAULTS = {
    "api":        "https://raw.githubusercontent.com/MacWaveOrg/infosource/main",
    # 空 = 还没搬过来：仍然用索引记录里的 url 字段，也就是 3.x 的行为
    "bottle":     "",
    "deps":       "",
    "core":       "https://raw.githubusercontent.com/MacWaveOrg/MacWave",
    "python":     "https://raw.githubusercontent.com/MacWaveOrg/configdata/main",
    "selfupdate": "https://raw.githubusercontent.com/MacWaveOrg/configdata/main",
    # 预留：源码包的位置定了以后再接上
    "sourcecode": "",
}

# 允许的协议：https 是常态；file 给离线安装与测试用；http 只接受回环地址
ALLOWED_SCHEMES = ("https", "file")
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1", "[::1]")


# -------------------- 校验 --------------------

def _fail(kind, message):
    print(f"{RED_BOLD}🌊 Error: {ENV_NAME[kind]}: {message}{RESET}")
    print(f"{RED_BOLD}🌊 It should look like https://mirror.example.com/macwave "
          f"({DESCRIPTION[kind]}).{RESET}")
    sys.exit(1)


def _validate(kind, value):
    # 这些值会被拼进 URL、写进错误信息，也可能被 shell 脚本当参数用，
    # 所以宁可拒绝得早一点：空白、控制字符、引号、$ 与反引号一律不收。
    for bad in (' ', '\t', '\n', '\r', '"', "'", '`', '$', '\\'):
        if bad in value:
            _fail(kind, f"contains a {bad!r} character: {value!r}")

    scheme, separator, rest = value.partition("://")
    if not separator or not rest:
        _fail(kind, f"missing a scheme: {value!r}")

    scheme = scheme.lower()
    if scheme in ALLOWED_SCHEMES:
        return value

    # 明文 http 只给本机镜像（测试、离线环境）；远处的镜像必须走 https
    if scheme == "http":
        host = rest.split("/")[0].split(":")[0]
        if host in LOOPBACK_HOSTS:
            return value
        _fail(kind, f"plain HTTP is only allowed for loopback mirrors: {value!r}")

    _fail(kind, f"unsupported scheme {scheme!r}")


def domain(kind):
    # 解析一个域名：环境变量优先，其次是 DEFAULTS；两处都为空时返回 ""，
    # 由调用方按「该内容还没有搬过来」处理（例如继续读索引里的 url 字段）。
    if kind not in ENV_NAME:
        raise KeyError(kind)

    value = (os.environ.get(ENV_NAME[kind]) or "").strip()
    if not value:
        value = DEFAULTS[kind]
    if not value:
        return ""

    # 末尾斜杠一律去掉，拼路径时不用再关心有没有写
    value = value.rstrip("/")
    return _validate(kind, value)


def is_custom(kind):
    # 用户是否显式设了这个变量。镜像站与默认站的能力不一定相同（见 index_list_url）。
    return bool((os.environ.get(ENV_NAME[kind]) or "").strip())


# -------------------- 各域名 --------------------

def api_domain():
    return domain("api")


def bottle_domain():
    return domain("bottle")


def deps_domain():
    return domain("deps")


def core_domain():
    return domain("core")


def python_domain():
    return domain("python")


def selfupdate_domain():
    return domain("selfupdate")


def sourcecode_domain():
    return domain("sourcecode")


# -------------------- 索引 --------------------

def index_list_url(arch, package_name=None):
    # 「列出版本 / 列出软件包」这件事目前走 GitHub 的 contents API，它属于
    # api.github.com，与索引本身的地址不是一台机器，镜像站无法等价提供。
    #
    # 所以：设了 MACWAVE_API_DOMAIN（也就是在用镜像）时，要求镜像自己提供一份清单——
    #   <api>/pkg/pkginfo_<arch>/versions           → 一行一个包名
    #   <api>/pkg/pkginfo_<arch>/<包名>/versions     → 一行一个版本号
    # 没设时仍用 GitHub API，行为与 3.x 一致。
    # 4.0 的索引协议定稿后，这里改成只读镜像那一份。
    path = f"pkg/pkginfo_{arch}"
    if package_name:
        path = f"{path}/{package_name}"

    if is_custom("api"):
        return f"{api_domain()}/{path}/versions"

    return f"https://api.github.com/repos/MacWaveOrg/infosource/contents/{path}?ref=main"


def listing_names(text, dirs_only=False):
    # 上面两种来源的返回形式不同：GitHub API 是 JSON 数组，镜像是纯文本一行一条。
    # 统一成「名字列表」，具体怎么解读（去掉 @common、取 @ 后面当版本号）交给调用方。
    # dirs_only 只对 JSON 有意义：列软件包时要的是目录，列版本时那些是文件。
    text = (text or "").strip()
    if not text:
        return []

    if text.startswith("["):
        try:
            entries = json.loads(text)
        except ValueError:
            return []
        names = []
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            if dirs_only and entry.get("type") != "dir":
                continue
            names.append(entry.get("name", ""))
        return names

    return [line.strip() for line in text.splitlines() if line.strip()]


# -------------------- 二进制包（Bottle / Deps） --------------------
#
# 4.0 的存储布局还没定（GHCR 的方案另议），所以这两个函数是**唯一的占位点**：
#   <域名>/<名字>/<版本>/<架构>/<上游文件名>
# 定稿后只改这两个函数。没设域名时一律回落到索引里的 url 字段，
# 于是「设不设」都不影响现在的安装。

def bottle_url(package_name, package_version, arch, upstream_url):
    base = bottle_domain()
    if not base:
        return upstream_url
    filename = upstream_url.split("/")[-1]
    return f"{base}/{package_name}/{package_version}/{arch}/{filename}"


def dep_url(dep_name, dep_version, arch, upstream_url):
    base = deps_domain()
    if not base:
        return upstream_url
    filename = upstream_url.split("/")[-1]
    return f"{base}/{dep_name}/{dep_version}/{arch}/{filename}"


# -------------------- 自更新 --------------------

def selfupdate_version_url():
    return f"{selfupdate_domain()}/versiondata/latest_version"


def selfupdate_files_url(entry=""):
    # 文件清单。3.x 的清单写在 versiondata/files_info，一份清单管所有版本；
    # 4.0 改成每个版本一份（selfupdate/files_info_<版本>），因为清单必须与
    # 它描述的代码完全对应 —— 共用一份时，任何新增文件都会让还在用旧分支的
    # 用户下载到 404。
    entry = (entry or "").strip().strip("/")
    if entry:
        return f"{selfupdate_domain()}/{entry}"
    return f"{selfupdate_domain()}/versiondata/files_info"


def selfupdate_updatedata_url(version, filename):
    return f"{selfupdate_domain()}/updatedata/{version}/{filename}"


def selfupdate_script_url(version):
    # 4.0：更新脚本按版本冻结，`selfupdate/selfupdate_<版本>.sh`。
    return f"{selfupdate_domain()}/selfupdate/selfupdate_{version}.sh"


def python_manifest_url():
    return f"{python_domain()}/pythondata/latest_python"


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    sys.exit(1)
