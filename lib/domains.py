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
#   | MACWAVE_PYTHON_DATA           | 独立 CPython 解释器                       |
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
from urllib.parse import quote


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
    # 默认指向 GitHub Releases：它的下载路径 /<tag>/<资产> 与静态镜像的 /<包名>/<文件> 同形，
    # 所以国内镜像站只要 rsync 出同一棵树即可。指向仓库文件会被 git 的 100 MiB 硬限拦住。
    "bottle":     "https://github.com/MacWaveOrg/Bottle/releases/download",
    "deps":       "https://github.com/MacWaveOrg/Deps/releases/download",
    "core":       "https://raw.githubusercontent.com/MacWaveOrg/MacWave",
      # 解释器单独一个仓库：体积（每架构约 26 MB）与发布节奏都和自更新数据不同
    "python":     "https://raw.githubusercontent.com/MacWaveOrg/Python/main",
    "selfupdate": "https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/main",
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
# 4.0 的二进制不再取自上游，而是取自我们自己的存储。存储形态的选择标准只有一条：
# **国内镜像站要能用 rsync + nginx 原样提供**（清华 / 中科大 / 阿里镜像的都是普通文件树），
# 这是「国内连 GitHub 慢」的唯一实际解法。
#
# 所以地址形状被刻意设计成「域名之后是一条纯文件路径」：
#
#   <域名>/<包名>/<包名>@<版本>.<架构><扩展名>
#
# 默认域名指向 GitHub Releases，它的下载路径恰好也是 /<tag>/<资产>：
#
#   默认：https://github.com/MacWaveOrg/Bottle/releases/download/jq/jq%401.7.1.arm64
#   镜像：https://mirror.example.cn/MacWave/bottle/jq/jq%401.7.1.arm64
#                                  ↑ 域名之后完全相同
#
# 于是换镜像只是换一个环境变量，镜像站不需要理解任何协议。
# 镜像路径里的 MacWave/ 是为了让镜像域名能被多个产品共用（LinuxWave 将来用
# /LinuxWave），所以它不是固定前缀，而是环境变量值的一部分。
#
# 为什么用 Releases 而不是仓库里的文件：git 有 100 MiB 单文件硬限，而 ollama 已有
# 172.9 MB 的产物；Releases 单文件上限 2 GiB，且官方明确不限制总量与下载带宽。
#
# 字节**原样搬运，不重打包**：校验值因此与上游一致，可直接用官方 SHA256。
# 代价是压缩格式不统一，所以扩展名取自索引的 file 字段（上游那份文件的名字）。
#
# 架构必须写进文件名：arm64 与 amd64 是两条同名同版本的索引记录，去掉架构就会撞名。

# 多段扩展名要先试，否则 `.tar.gz` 会被当成 `.gz`
ARCHIVE_SUFFIXES = (".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.z",
                    ".tgz", ".tbz2", ".txz", ".zip", ".tar", ".gz", ".bz2", ".xz",
                    ".conda", ".pkg", ".dmg")


def require_domain(kind):
    # 二进制没有「上游」可回落了，域名缺失就只能报错，并且说清怎么设。
    value = domain(kind)
    if not value:
        print(f"{RED_BOLD}🌊 Error: {ENV_NAME[kind]} is not set.{RESET}")
        print(f"{RED_BOLD}🌊 MacWave 4.0 downloads {DESCRIPTION[kind]} from its own mirror; "
              f"set {ENV_NAME[kind]} to that address.{RESET}")
        sys.exit(1)
    return value


def payload_suffix(upstream_filename):
    # 上游文件名 → 扩展名。裸可执行文件没有扩展名，返回空串（这是合法情况，不是缺陷）。
    lowered = upstream_filename.lower()
    for suffix in ARCHIVE_SUFFIXES:
        if lowered.endswith(suffix):
            return upstream_filename[len(upstream_filename) - len(suffix):]
    return ""


def payload_filename(name, version, arch, upstream_filename):
    # <包名>@<版本>.<架构><扩展名>。落盘也用它，因为 pkgunzip.sh 靠扩展名选解压器。
    return f"{name}@{version}.{arch}{payload_suffix(upstream_filename)}"


def payload_url(kind, name, filename):
    # 域名之后只有 <包名>/<文件名>，好让静态镜像原样复制这棵树。
    # 文件名里的 @ 与 + 必须编码（GitHub 给的规范地址就是 %40 / %2B），
    # nginx 会把 %40 解码回 @ 去找文件，所以禁态镜像无需任何特殊处理。
    return f"{require_domain(kind)}/{name}/{quote(filename)}"


def resolve_payload(kind, name, version, arch, upstream_filename, upstream_url, from_source):
    # 唯一决定「从哪儿取、文件叫什么」的地方，软件包与依赖共用。
    #
    #   from_source=False（默认）：从我们自己的存储取，url 一个字都不看。
    #   from_source=True（--install-from-source）：回到 3.x 的做法 ——
    #                              读 url，直接回上游取，按 URL 末段命名。
    if from_source:
        if not upstream_url:
            print(f"{RED_BOLD}🌊 Error: --install-from-source needs the url field, "
                  f"but {name}@{version} has none.{RESET}")
            print(f"{RED_BOLD}🌊 This is a data defect; please report it to the administrator.{RESET}")
            sys.exit(1)

        if not upstream_url.startswith("https://"):
            if upstream_url.startswith("http://"):
                print(f"{RED_BOLD}🌊 ParsePkgURL using HTTP! That's insecure, "
                      f"Please contact the administrator.{RESET}")
            else:
                print(f"{RED_BOLD}🌊 ParsePkgURL Invalid, Please contact the administrator.{RESET}")
            sys.exit(1)

        return {"transport": "https", "url": upstream_url,
                "filename": upstream_url.split("/")[-1]}

    if not upstream_filename:
        print(f"{RED_BOLD}🌊 Error: No file field for {name}@{version}.{RESET}")
        print(f"{RED_BOLD}🌊 MacWave 4.0 mirrors the upstream bytes verbatim, so the index "
              f"must name the file to tell zip from tar.gz from a bare executable.{RESET}")
        print(f"{RED_BOLD}🌊 This is a data defect; please report it to the administrator.{RESET}")
        sys.exit(1)

    filename = payload_filename(name, version, arch, upstream_filename)
    return {"transport": "https",
            "url": payload_url(kind, name, filename),
            "filename": filename}


# -------------------- 自更新 --------------------
#
# 自更新数据只有两件东西，都按版本平铺在 macwavedata/ 下：
#
#   macwavedata/latest.toml             哪个版本是最新的（version 字段兼作指针）
#   macwavedata/<版本>/update_commands.sh   该版本「下载哪些文件、放到哪里」
#
# 为什么要两个分开：latest.toml 每次发版都变，update_commands.sh 按版本冻结。
# 把「当前该装哪个版本」和「那个版本具体怎么装」混在一个文件里，就没法让装了
# 旧版本的用户继续用他们那份说明 —— 而旧版本仍在运行。

def selfupdate_latest_url():
    return f"{selfupdate_domain()}/macwavedata/latest.toml"


def selfupdate_commands_url(version):
    # 一个版本一份，随版本冻结。它同时承担三件事：下载哪些文件、放到哪里、
    # 以及目录结构变更时的迁移（见 docs/MIRROR-SETUP.md 之外的 docs/CODE-MAP.md）。
    return f"{selfupdate_domain()}/macwavedata/{version}/update_commands.sh"


# -------------------- 自带解释器 --------------------
#
# 与自更新数据分开一个仓库，因为它有自己的体积（每架构约 26 MB）和发布节奏。
#
#   pythondata/latest.toml          哪个版本是最新的
#   pythondata/<版本>/python_url.toml   各架构的**上游**地址与校验值
#   pythondata/<版本>/<文件名>          我们自己托管的那份（默认从这里取）
#
# python_url.toml 记的是上游地址，默认不用 —— 只有 --install-python-from-source
# 才直接回上游取。文件名取上游地址的末段，所以两条路径共用同一个名字。

def python_data_domain():
    return domain("python")


def python_latest_url():
    return f"{python_data_domain()}/pythondata/latest.toml"


def python_url_toml_url(version):
    return f"{python_data_domain()}/pythondata/{version}/python_url.toml"


def python_archive_url(version, filename):
    # 默认从我们自己的存储取同一份字节；文件名与上游一致，所以校验值可以复用。
    return f"{python_data_domain()}/pythondata/{version}/{filename}"


# -------------------- 极简 TOML 读取 --------------------
#
# 客户端只读两种固定形状的 toml，所以不引入第三方解析器：
#   - 平铺的 key = "value"（latest.toml）
#   - 带 [section] 的分组（python_url.toml）
# 只支持字符串值与分组，遇到别的形式直接报错 —— 静默忽略会让人以为配置生效了。

def parse_simple_toml(text):
    values = {}
    section = ""

    for raw_line in (text or "").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        key, separator, value = line.partition("=")
        if not separator:
            continue
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[f"{section}.{key}" if section else key] = value

    return values


def fetch_text(url, timeout=30):
    # 优先标准库；本地 Python 缺根证书（macOS 常见）时改走 curl。
    import subprocess
    import urllib.error
    import urllib.request

    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read().decode()
    except (urllib.error.URLError, UnicodeDecodeError, OSError):
        pass

    result = subprocess.run(["curl", "-fsSL", "--max-time", str(max(1, int(timeout))),
                             "--retry", "2", "--retry-delay", "2", "--retry-connrefused", url],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout


# -------------------- 二进制包（Bottle / Deps） --------------------
#
# 4.0 的二进制不再取自上游，而是取自我们自己的存储。存储形态的选择标准只有一条：
# **国内镜像站要能用 rsync + nginx 原样提供**（清华 / 中科大 / 阿里镜像的都是普通文件树），
# 这是「国内连 GitHub 慢」的唯一实际解法。
#
# 所以地址形状被刻意设计成「域名之后是一条纯文件路径」：
#
#   <域名>/<包名>/<包名>@<版本>.<架构><扩展名>
#
# 默认域名指向 GitHub Releases，它的下载路径恰好也是 /<tag>/<资产>：
#
#   默认：https://github.com/MacWaveOrg/Bottle/releases/download/jq/jq%401.7.1.arm64
#   镜像：https://mirror.example.cn/MacWave/bottle/jq/jq%401.7.1.arm64
#                                  ↑ 域名之后完全相同
#
# 于是换镜像只是换一个环境变量，镜像站不需要理解任何协议。
# 镜像路径里的 MacWave/ 是为了让镜像域名能被多个产品共用（LinuxWave 将来用
# /LinuxWave），所以它不是固定前缀，而是环境变量值的一部分。
#
# 为什么用 Releases 而不是仓库里的文件：git 有 100 MiB 单文件硬限，而 ollama 已有
# 172.9 MB 的产物；Releases 单文件上限 2 GiB，且官方明确不限制总量与下载带宽。
#
# 字节**原样搬运，不重打包**：校验值因此与上游一致，可直接用官方 SHA256。
# 代价是压缩格式不统一，所以扩展名取自索引的 file 字段（上游那份文件的名字）。
#
# 架构必须写进文件名：arm64 与 amd64 是两条同名同版本的索引记录，去掉架构就会撞名。

# 多段扩展名要先试，否则 `.tar.gz` 会被当成 `.gz`
ARCHIVE_SUFFIXES = (".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.z",
                    ".tgz", ".tbz2", ".txz", ".zip", ".tar", ".gz", ".bz2", ".xz",
                    ".conda", ".pkg", ".dmg")


def require_domain(kind):
    # 二进制没有「上游」可回落了，域名缺失就只能报错，并且说清怎么设。
    value = domain(kind)
    if not value:
        print(f"{RED_BOLD}🌊 Error: {ENV_NAME[kind]} is not set.{RESET}")
        print(f"{RED_BOLD}🌊 MacWave 4.0 downloads {DESCRIPTION[kind]} from its own mirror; "
              f"set {ENV_NAME[kind]} to that address.{RESET}")
        sys.exit(1)
    return value


def payload_suffix(upstream_filename):
    # 上游文件名 → 扩展名。裸可执行文件没有扩展名，返回空串（这是合法情况，不是缺陷）。
    lowered = upstream_filename.lower()
    for suffix in ARCHIVE_SUFFIXES:
        if lowered.endswith(suffix):
            return upstream_filename[len(upstream_filename) - len(suffix):]
    return ""


def payload_filename(name, version, arch, upstream_filename):
    # <包名>@<版本>.<架构><扩展名>。落盘也用它，因为 pkgunzip.sh 靠扩展名选解压器。
    return f"{name}@{version}.{arch}{payload_suffix(upstream_filename)}"


def payload_url(kind, name, filename):
    # 域名之后只有 <包名>/<文件名>，好让静态镜像原样复制这棵树。
    # 文件名里的 @ 与 + 必须编码（GitHub 给的规范地址就是 %40 / %2B），
    # nginx 会把 %40 解码回 @ 去找文件，所以禁态镜像无需任何特殊处理。
    return f"{require_domain(kind)}/{name}/{quote(filename)}"


def resolve_payload(kind, name, version, arch, upstream_filename, upstream_url, from_source):
    # 唯一决定「从哪儿取、文件叫什么」的地方，软件包与依赖共用。
    #
    #   from_source=False（默认）：从我们自己的存储取，url 一个字都不看。
    #   from_source=True（--install-from-source）：回到 3.x 的做法 ——
    #                              读 url，直接回上游取，按 URL 末段命名。
    if from_source:
        if not upstream_url:
            print(f"{RED_BOLD}🌊 Error: --install-from-source needs the url field, "
                  f"but {name}@{version} has none.{RESET}")
            print(f"{RED_BOLD}🌊 This is a data defect; please report it to the administrator.{RESET}")
            sys.exit(1)

        if not upstream_url.startswith("https://"):
            if upstream_url.startswith("http://"):
                print(f"{RED_BOLD}🌊 ParsePkgURL using HTTP! That's insecure, "
                      f"Please contact the administrator.{RESET}")
            else:
                print(f"{RED_BOLD}🌊 ParsePkgURL Invalid, Please contact the administrator.{RESET}")
            sys.exit(1)

        return {"transport": "https", "url": upstream_url,
                "filename": upstream_url.split("/")[-1]}

    if not upstream_filename:
        print(f"{RED_BOLD}🌊 Error: No file field for {name}@{version}.{RESET}")
        print(f"{RED_BOLD}🌊 MacWave 4.0 mirrors the upstream bytes verbatim, so the index "
              f"must name the file to tell zip from tar.gz from a bare executable.{RESET}")
        print(f"{RED_BOLD}🌊 This is a data defect; please report it to the administrator.{RESET}")
        sys.exit(1)

    filename = payload_filename(name, version, arch, upstream_filename)
    return {"transport": "https",
            "url": payload_url(kind, name, filename),
            "filename": filename}


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


def selfupdate_script_url(version, entry=""):
    # 4.0：更新脚本按版本冻结，`selfupdate/selfupdate_<版本>.sh`。
    # 版本数据里可以用 selfupdate_script 字段指向别的位置（比如换布局时不改代码）。
    entry = (entry or "").strip().strip("/")
    if entry:
        return f"{selfupdate_domain()}/{entry}"
    return f"{selfupdate_domain()}/selfupdate/selfupdate_{version}.sh"


def python_manifest_url():
    return f"{python_domain()}/pythondata/latest_python"


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    sys.exit(1)
