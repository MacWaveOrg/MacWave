#!/usr/bin/env python3

# configpaths.py
# 解析 MacWave 的配置目录。
#
# 安装目录决定配置写在哪：
#   - 系统级（/opt/macwave、/usr/local/macwave 等需要 sudo 的目录）
#     → /opt/macwave_config
#   - 用户级（~/.local/macwave 等无需 sudo 的目录）
#     → ~/.config/macwave_config
#
# 读取时系统级优先：只要 /opt/macwave_config/config.json 存在就用它，
# 否则才回落到 ~/.config/macwave_config —— 也就是优先跑系统级的 MacWave。

import json
import os
import sys
import unicodedata
from pathlib import Path

# 环境变量的名字只有一处（config/envvar.py）。本文件是它的同层邻居，
# 也是「测试根」这条路径上唯一的读取者。
import envvar


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
RESET = '\033[0m'


# -------------------- 测试根（隔离） --------------------

def _resolve_test_root():
    # MACWAVE_TEST 指向一个目录时，程序把这个目录当作 /：所有绝对路径都挂到它
    # 下面，HOME 也搬进去，于是配置目录、安装目录、下载缓存全落在里面，完全不
    # 碰真实系统。没设置时（正常使用）一切照旧。
    raw = os.environ.get(envvar.TEST_ROOT)
    if not raw:
        return None

    if raw == "~" or raw.startswith("~/"):
        real_home = os.environ.get("HOME") or str(Path.home())
        raw = real_home + raw[1:]

    root = Path(raw)
    if not root.is_absolute():
        root = Path.cwd() / root
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


TEST_ROOT = _resolve_test_root()

if TEST_ROOT is not None:
    # HOME 一起搬进测试根：~/.config/macwave_config、~/.local/macwave 都该隔离。
    # 子进程（bash 脚本）继承这个 HOME，所以整条链路都在测试根里。
    _real_home = Path(os.environ.get("HOME") or Path.home())
    _test_home = TEST_ROOT / (_real_home.relative_to("/") if _real_home.is_absolute() else "home")
    _test_home.mkdir(parents=True, exist_ok=True)
    os.environ["HOME"] = str(_test_home)
    # 子进程（含 shell 脚本）继承 HOME，也就继承了这份重定向 —— 不必再导出
    # 任何「测试根在哪」的变量，那些脚本自己读 MACWAVE_TEST。


def rooted(path):
    # 把绝对路径映射到测试根之下；没开测试模式时原样返回。
    # 例如 /opt/macwave_config → $MACWAVE_TEST/opt/macwave_config
    path = Path(path)
    if TEST_ROOT is None or not path.is_absolute():
        return path
    return TEST_ROOT / path.relative_to("/")


# -------------------- 代理（--proxy） --------------------
#
# `--proxy` 的解析与「写进环境变量」都搬到 cli/common.py 了：它是公共旗标，
# 必须与三档超时、--skip-ssl 走同一条路径，否则 install 校验、selfupdate 静默忽略。
# 这里不再提供 proxy_value_from / apply_proxy_from_command_line —— 留着它们就等于
# 留了第二条解析路径。

# -------------------- 配置目录候选 --------------------

CONFIG_FILE_NAME = "config.json"
VERSION_FILE_NAME = "VERSION.json"

SYSTEM_CONFIG_DIR = rooted("/opt/macwave_config")
USER_CONFIG_DIR = Path.home() / ".config" / "macwave_config"


def config_dir_candidates():
    # 系统级优先，其次用户级。4.7 起只是**兼容路径**：新装与升级都会把状态搬进
    # 安装树自己的 var/，这里留着是为了让 4.6 及更早的安装还能被读到。
    return [SYSTEM_CONFIG_DIR, USER_CONFIG_DIR]


# -------------------- 安装树自带的状态（4.7 起） --------------------
#
# 为什么不再用外部配置目录：
#
#   1. **base_dir 本来就是多余的**。这个文件就在 <base>/config/ 下，安装根由它
#      自己的位置决定 —— 比「去两个固定目录里找一个写着路径的 JSON」可靠得多，
#      而且不会再出现「系统级与用户级各有一份、谁优先」的问题。
#   2. **版本号也放得进树里**。它描述的就是这棵树；放在树外，同一台机器有两份
#      安装时只能靠「系统级优先」猜。
#   3. **自更新不用再为一个 JSON 申请提权**。树是 root:<管理员组> 775、目录带
#      setgid，写 <base>/var/ 与写 <base>/lib/ 是同一件事，不需要额外的 2775
#      配置目录。
#
# 形态用 `.sh` 而不是 JSON：install.sh / selfupdate.sh 是 shell 脚本，写它就一行
# heredoc（不必调 Python、也不必担心 JSON 转义）；Python 侧解析 `KEY='value'` 也
# 只是几行。两种语言都能读，JSON 做不到「shell 侧零成本」。
#
# 内容（都带引号，值里有空格/斜杠也不用转义）：
#
#   MACWAVE_BASE_DIR='/opt/macwave'
#   MACWAVE_VERSION='4.7.0'
#   MACWAVE_BUILD='328B1519'
#   MACWAVE_INSTALLED_AT='2026-11-26T08:00:00Z'
STATE_DIR_NAME = "var"
STATE_FILE_NAME = "config.sh"
LEGACY_STATE_NOTE = "config.json"


def self_install_root():
    # 本模块装在 <base>/config/configpaths.py，所以安装根是它的上两级。
    # 用 resolve() 是为了兼容经软链接调用的情况（<base>/lib/wave 就是个启动器）。
    return Path(__file__).resolve().parent.parent


def internal_state_dir():
    # 树内状态目录；<base>/var/config.sh 不存在时返回 None（老安装或开发目录）。
    #
    # MACWAVE_TEST 下 rooted() 不需要介入：测试会把组件拷进沙箱的
    # <sandbox>/opt/macwave/，self_install_root() 自然指向那里。
    base = self_install_root()
    state_dir = base / STATE_DIR_NAME
    if (state_dir / STATE_FILE_NAME).is_file():
        return state_dir
    return None


def read_state_values(state_file):
    # 解析 config.sh：只认 `KEY='value'` 与 `KEY="value"`、`KEY=value` 三种写法。
    # 不执行它 —— 这个文件由安装器生成、用户也可能手改，读比 source 安全。
    values = {}
    try:
        text = Path(state_file).read_text(encoding="utf-8")
    except OSError:
        return values
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, raw = line.partition("=")
        key = key.strip()
        raw = raw.strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
            raw = raw[1:-1]
        if key:
            values[key] = raw
    return values


def internal_base_dir():
    # 树内声明的安装根。刻意**不用**它自己的位置、而是读文件里的值：
    # 树被整体搬走后，`wave basedir --set` 会同时改写这个字段 —— 那时位置已经
    # 指向新地方了，两者本该一致；不一致时以文件里写的为准，便于人工修复。
    state_dir = internal_state_dir()
    if state_dir is None:
        return None
    value = read_state_values(state_dir / STATE_FILE_NAME).get("MACWAVE_BASE_DIR", "")
    if not value:
        return None
    return Path(value)


# -------------------- 配置读取 --------------------

def _read_base_dir(config_file):
    # 读得到合法 base_dir 就返回 Path，否则返回 None
    try:
        with open(config_file, 'r') as handle:
            base_dir = json.load(handle).get("base_dir")
        return Path(base_dir) if base_dir else None
    except Exception:
        return None


def find_config_dir():
    # 「状态文件在哪」。4.7 起优先返回树内 <base>/var（VERSION.json 也搬了进去），
    # 找不到才回落到 4.6 及更早的外部配置目录。
    state_dir = internal_state_dir()
    if state_dir is not None:
        return state_dir

    for directory in config_dir_candidates():
        if _read_base_dir(directory / CONFIG_FILE_NAME) is not None:
            return directory
    return None


def load_base_dir():
    # 读取安装根，顺序即优先级：
    #   1. MACWAVE_BASE_DIR —— 启动器用它告诉 Python「我在哪」，也便于测试注入
    #   2. 树内 <base>/var/config.sh
    #   3. 4.6 及更早的外部配置文件（/opt/macwave_config 或 ~/.config/macwave_config）
    override = os.environ.get("MACWAVE_BASE_DIR", "")
    if override:
        return Path(override)

    base_dir = internal_base_dir()
    if base_dir is not None:
        return base_dir

    for directory in config_dir_candidates():
        base_dir = _read_base_dir(directory / CONFIG_FILE_NAME)
        if base_dir is not None:
            return base_dir

    print(f"{RED_BOLD}🌊 Error: Configuration file not found or invalid.{RESET}")
    print(f"{RED_BOLD}🌊 Expected {('<install root>/' + STATE_DIR_NAME + '/' + STATE_FILE_NAME)} "
          f"next to this installation, or a legacy config.json.{RESET}")
    print(f"{RED_BOLD}🌊 Please run the install script again to reinstall MacWave.{RESET}")
    sys.exit(1)


def to_tilde(path):
    # 家目录里的路径显示成 ~/…，其余原样返回。
    # 边界必须按「整段」判断：只写 startswith(home) 会把 /Users/you2 折成 ~2。
    # 先按字面比一次；不一致再比 realpath —— macOS 的 $HOME 常是 /Users/x，
    # 而 /tmp/... 会被解析成 /private/tmp/...，字面比对会漏掉。
    home = os.path.expanduser("~").rstrip("/")
    path = str(path)
    for prefix, candidate in ((home, path),
                             (os.path.realpath(home), os.path.realpath(path))):
        if candidate == prefix:
            return "~"
        if candidate.startswith(prefix + "/"):
            return "~" + candidate[len(prefix):]
    return path


# -------------------- 名字与版本号的安全校验 --------------------
#
# 包名、版本号、可执行文件名既来自命令行，也来自远端数据（@common / deps 字段），
# 之后会被拼进 URL 和文件路径，还会以换行分隔的长字符串形式交给 shell。
#
# 这里按 **Unicode 类别** 做白名单，而不是列 ASCII 字符：这样中文、日文、带重音的
# 拉丁字母都能当包名，同时下面这些危险字符因为类别不在白名单里而自然落榜——
#   /  \              分隔符，唯一能改变目录层级的字符（Um, Po）
#   空格、NBSP          空白（Zs）——能把一个参数劈成两个
#   \n \r \t 等控制字符   （Cc）——会截断 mw_parse_info 的换行分隔协议，等价于往 shell 多塞字段
#   U+2028/U+2029      行/段分隔符（Zl/Zp）
#   $ ` ' " ; | & ( )   符号类（Sc/Sk/Po/Ps/Pe），shell 元字符
#   %  @  :  =  ,  ~ 等   标点/符号类，除非显式列进 ALLOWED_PUNCT
#
# 名字仍要过一遍 assert_inside 才能真正落盘：字符规则是早失败、报错清楚，
# 路径包含检查才是防穿越的硬保障。

# 字母、组合符号（重音）、数字。中文属 Lo，é 属 Ll（或 L+Mn），均在此列。
NAME_CATEGORIES = frozenset({
    'Lu', 'Ll', 'Lt', 'Lm', 'Lo',   # 字母
    'Mn', 'Mc', 'Me',               # 组合符号，如 e + U+0301
    'Nd', 'Nl', 'No',               # 数字
})

# 首字符必须是字母或数字：挡住开头的 -（选项注入）、. 与组合符号（同形异义伪装）。
START_CATEGORIES = frozenset({'Lu', 'Ll', 'Lt', 'Lm', 'Lo', 'Nd', 'Nl', 'No'})

ALLOWED_PUNCT = frozenset('._+-')
# 4.0 的落盘名是「包名@版本.架构.扩展名」，所以文件名多放行一个 @。
# @ 在 shell 里无特殊含义（全程引号引用），进 URL 时由 payload_url 编码成 %40。
ALLOWED_PUNCT_FILENAME = ALLOWED_PUNCT | {'@'}

# 单个路径段上限。非 ASCII 一个字最多占 4 字节，而 macOS 的 NAME_MAX 是 255 字节，
# 所以除了字符数还要卡字节数，否则长中文包名会在落盘时才炸「File name too long」。
MAX_NAME_CHARS = 128
MAX_NAME_BYTES = 200


def _category(ch):
    return unicodedata.category(ch)


def _matches(value, punct):
    value = str(value)
    if not value or len(value) > MAX_NAME_CHARS:
        return False
    if '..' in value:
        return False
    if len(value.encode('utf-8')) > MAX_NAME_BYTES:
        return False
    if _category(value[0]) not in START_CATEGORIES:
        return False
    return all(ch in punct or _category(ch) in NAME_CATEGORIES for ch in value)


def is_safe_token(value):
    return _matches(value, ALLOWED_PUNCT)


def is_safe_filename(value):
    return _matches(value, ALLOWED_PUNCT_FILENAME)


def _reject(what, value, punct):
    print(f"{RED_BOLD}🌊 Error: Unsafe {what}: {value!r}{RESET}")
    print(f"{RED_BOLD}🌊 Allowed: letters, digits, and {''.join(sorted(punct))} "
          f"(must start with a letter or digit).{RESET}")
    print(f"{RED_BOLD}🌊 Path separators, whitespace, control characters "
          f"and shell metacharacters are never allowed.{RESET}")
    sys.exit(1)


def require_safe_token(value, what):
    # 不合法直接退出：这类输入没有任何"宽松解释"的余地
    if not is_safe_token(value):
        _reject(what, value, ALLOWED_PUNCT)
    return str(value)


def require_safe_filename(value, what="file name"):
    if not is_safe_filename(value):
        _reject(what, value, ALLOWED_PUNCT_FILENAME)
    return str(value)


def _inside_failure(resolved, resolved_root, what):
    print(f"{RED_BOLD}🌊 Error: Unsafe {what} escapes {resolved_root}: {resolved}{RESET}")
    sys.exit(1)


def assert_inside(path, root, what):
    # 归一化后确认路径没有跑到 root 外面（防 ../ 与软链接穿越）。
    # 只做校验、不改写调用方的路径，避免改变既有行为。
    # **跟随**最后一段的软链接：用于会被写进去或递归删除的路径。
    #
    # 这里是路径越界规则的唯一实现。软件包**自带**的符号链接走的是另一条路：
    # 它们由解压产生，需要单独遍历整棵树、逐个解析目标 —— 规则是「解析后落在
    # base_dir 之外就拒绝」，唯一例外是 /bin /sbin /usr/bin /usr/sbin /usr/lib
    # /usr/libexec /System /Library/Apple（SIP 保护，且不含隐私文件）。
    # 详见 SECURITY.md「Symbolic links: the rule and its one exception」。
    resolved_root = Path(root).resolve()
    resolved = Path(path).resolve()
    if resolved != resolved_root and resolved_root not in resolved.parents:
        _inside_failure(resolved, resolved_root, what)
    return resolved


def assert_inside_entry(path, root, what):
    # 与 assert_inside 相同，但**不跟随**最后一段的软链接。links/ 下的链接本身就
    # 是软链接，指向 bin/ 里的可执行文件：跟随过去会把"删除/重指这个链接"这种
    # 再正常不过的操作误判成越界。只能用于"操作链接本身"、不会穿透写入的调用点。
    #
    # 选哪个：「这个链接文件本身在不在树内」用这个；「顺着它写会不会跑出去」用
    # assert_inside。两者不能互换。
    resolved_root = Path(root).resolve()
    candidate = Path(path)
    if candidate.name in ("", ".", ".."):
        _inside_failure(candidate, resolved_root, what)
    resolved = candidate.parent.resolve() / candidate.name
    if resolved != resolved_root and resolved_root not in resolved.parents:
        _inside_failure(resolved, resolved_root, what)
    return resolved


# -------------------- 产物里的符号链接 --------------------
#
# 规则（SECURITY.md「Symbolic links: the rule and its one exception」）：
# 软件包里带的符号链接，解析后必须落在 base_dir 内；落在外面一律拒绝。
#
# 为什么要单独做这件事：归档解压只过滤成员**名字**里的 `../`，与链接**目标**无关。
# 实测 Python 3.15 的 tarfile：filter='tar' 会把 `x -> /etc/hosts` 原样解出来，
# 只有 filter='data' 才拒绝（但它连 conda 包需要的合法链接一起拒）。
# unzip 与 tar 命令行同样不管目标。所以越界链接只能解压之后自己扫。
#
# 危害两头：链接指向隐私文件 → 随包附带的程序读到不该读的东西；链接指向
# MacWave 之后要写的路径（transfer.sh 的重定位改写、.part → mv、卸载的 rm -rf）
# → 以用户身份在树外写或删。
#
# 例外只给系统库位置，两个条件必须同时成立：SIP 连 root 都拒绝写这些路径，
# 且那里只有操作系统自带的二进制与库、没有用户数据。

SYSTEM_LINK_PREFIXES = (
    "/bin",
    "/sbin",
    "/usr/bin",
    "/usr/sbin",
    "/usr/lib",
    "/usr/libexec",
    "/System",
    "/Library/Apple",
)


def _under(path, prefix):
    return path == prefix or path.startswith(prefix + os.sep)


def is_system_link_target(resolved):
    """链接目标是否落在豁免的系统库位置（SIP 保护、不含隐私文件）。"""
    text = str(resolved)
    return any(_under(text, prefix) for prefix in SYSTEM_LINK_PREFIXES)


def escaping_links(root):
    """遍历 root，返回 [(链接, 解析后的目标)] —— 只在解析后落在 root 与豁免之外。

    不跟随目录软链接（否则可能绕进别的树里无限走），但**每个链接本身**都会被解析，
    包括指向目录的链接：指向树外的目录链接同样是"顺着它能读写树外"。
    悬空链接也照常判定 —— resolve() 不要求目标存在，词法上跑出 root 就算越界。
    """
    resolved_root = Path(root).resolve()
    found = []
    for dirpath, dirnames, filenames in os.walk(resolved_root, followlinks=False):
        for name in dirnames + filenames:
            candidate = Path(dirpath) / name
            if not candidate.is_symlink():
                continue
            try:
                target = Path(os.readlink(candidate))
            except OSError:
                continue
            if not target.is_absolute():
                target = candidate.parent / target
            try:
                resolved = target.resolve()
            except (OSError, RuntimeError):
                # 自我引用或过长的链：没法解析，按越界处理（拒绝比放行安全）
                found.append((candidate, target))
                continue
            if resolved != resolved_root and resolved_root not in resolved.parents:
                if not is_system_link_target(resolved):
                    found.append((candidate, resolved))
    return found


def assert_links_inside(root, what):
    """把一个树里越界的符号链接当作致命错误。返回通过检查的链接数不划算，故返回 None。"""
    offenders = escaping_links(root)
    if not offenders:
        return
    print(f"{RED_BOLD}🌊 Error: {len(offenders)} symbolic link(s) in {what} point outside "
          f"{Path(root).resolve()}{RESET}", file=sys.stderr)
    for link, target in offenders[:10]:
        print(f"   {link} -> {target}", file=sys.stderr)
    if len(offenders) > 10:
        print(f"   … and {len(offenders) - 10} more", file=sys.stderr)
    print("🌊 A link that leaves the install root can read private files, or make a later "
          "write (relocation, rename, uninstall) land outside the tree.", file=sys.stderr)
    print(f"🌊 Only these locations are exempt: {', '.join(SYSTEM_LINK_PREFIXES)}", file=sys.stderr)
    print("🌊 Refusing this payload. Report it to the index maintainer.", file=sys.stderr)
    sys.exit(1)


# -------------------- 当前生效的配置 --------------------

CONFIG_DIR = find_config_dir() or SYSTEM_CONFIG_DIR
CONFIG_FILE = CONFIG_DIR / CONFIG_FILE_NAME
VERSION_FILE = CONFIG_DIR / VERSION_FILE_NAME


if __name__ == "__main__":
    # 唯一的命令行入口：解压之后由 depsmanager.sh 调用，检查产物里的符号链接。
    #   python3 config/configpaths.py --check-links <目录> <描述，仅用于报错>
    if len(sys.argv) >= 3 and sys.argv[1] == "--check-links":
        assert_links_inside(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else sys.argv[2])
        sys.exit(0)
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    sys.exit(1)
