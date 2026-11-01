#!/usr/bin/env python3

# timeouts.py
# 三档超时的唯一来源：连接、读数据、总时长。
#
# 为什么要有三个，而不是一个数字：
#
#   requests 的 timeout=(connect, read) 只管两件事 —— TCP/TLS 握手多久算失败，
#   以及两次收到数据之间最多能等多久。它**不管总时长**：一个一直有数据回来的
#   慢速传输可以永远跑下去。所以「卡在握手」和「下载太慢」是两种病，得两种药。
#
#   --connect-timeout   对应 curl 的同名选项，只卡握手。服务器活着但握手卡死时，
#                       这一档是唯一能救命的 —— 只设 --max-time 时，握手会跟
#                       数据一样傻等那么久。
#   --content-time      连上之后，等下一块数据的上限。防「连上了但服务器不回东西」。
#   --max-time          整次操作的总时长。防「一块一块慢慢喂，永远下不完」。
#
# 三个都可以单独给。都没给时用 DEFAULT_* 的保守值。

import time


DEFAULT_MAX_TIME = 30       # 总时长（秒）；与历史行为一致
DEFAULT_CONNECT = 10        # 握手；本机连国内镜像通常 < 1s
DEFAULT_CONTENT = 30        # 等数据；与旧的可读超时一致


class Budget:
    """一次操作的时限组合。传给 requests 时自动变成 (connect, read) 元组。"""

    __slots__ = ("connect", "content", "total", "_deadline")

    def __init__(self, connect=DEFAULT_CONNECT, content=DEFAULT_CONTENT,
                 total=DEFAULT_MAX_TIME):
        self.connect = connect
        self.content = content
        self.total = total
        self._deadline = None

    # ---- requests 只要这一个属性 ----

    @property
    def request_timeout(self):
        """requests 接受 (connect, read)。

        read 取 min(content, 剩余总时长)：总时长快用完时不该再等一整个 content，
        否则「总时长」形同虚设。
        """
        read = self.content
        left = self.remaining()
        if left is not None:
            read = max(0.1, min(read, left))
        return (self.connect, read)

    # ---- 总时长 ----

    def start(self):
        self._deadline = time.monotonic() + self.total
        return self

    def remaining(self):
        if self._deadline is None:
            return None
        return max(0.0, self._deadline - time.monotonic())

    def expired(self):
        left = self.remaining()
        return left is not None and left <= 0

    def __repr__(self):
        return (f"Budget(connect={self.connect}, content={self.content}, "
                f"total={self.total})")


# -------------------- 从命令行取值 --------------------

def _parse_duration(text):
    """curl 风格的时长：40 / 40s / 1min / 1min20s / 2h / 250ms。无单位按秒。"""
    if text is None:
        return None
    raw = text.strip().lower()
    if not raw:
        return None

    import re
    # 单位必须长优先：`1min` 若先匹配单字母 `m`，剩下的 `in` 就无解了
    pattern = re.compile(r"(\d+(?:\.\d+)?)(hrs|hr|h|mins|min|ms|secs|sec|s|m)?")
    units = {
        None: 1, "s": 1, "sec": 1, "secs": 1,
        "m": 60, "min": 60, "mins": 60,
        "h": 3600, "hr": 3600, "hrs": 3600,
        "ms": 0.001,
    }

    total = 0.0
    position = 0
    matched = False
    while position < len(raw):
        match = pattern.match(raw, position)
        if not match or match.end() == position:
            return None
        value, unit = match.group(1), match.group(2)
        total += float(value) * units.get(unit, 1)
        position = match.end()
        matched = True

    if not matched or total <= 0:
        return None
    return total


# 旗标名 → Budget 字段
FLAG_FIELDS = {
    "--max-time": "total",
    "--connect-timeout": "connect",
    "--content-time": "content",
}


def flag_value(input_string, name):
    """取旗标的值，`--name value` 与 `--name=value` 都支持；没有则返回 None。"""
    tokens = input_string.split()
    for index, token in enumerate(tokens):
        if token == name:
            return tokens[index + 1] if index + 1 < len(tokens) else ""
        if token.startswith(name + "="):
            return token[len(name) + 1:]
    return None


def from_command_line(input_string, fail=None):
    """从命令行拼出 Budget；取值不合法时调用 fail(旗标, 原值)。

    fail 由调用方给，因为 lib/ 不该依赖 pkg/ 的报错格式。
    """
    values = {}
    for flag, field in FLAG_FIELDS.items():
        raw = flag_value(input_string, flag)
        if raw is None:
            continue
        parsed = _parse_duration(raw)
        if parsed is None:
            if fail is not None:
                fail(flag, raw)
            parsed = getattr(Budget(), field)     # 退回默认值
        values[field] = parsed

    # 没给 --max-time 时，总时长只保证不小于 --content-time ——
    # 否则 `--content-time=1min` 会被默认的 30 秒总时长悄悄压回 30 秒，
    # 用户显式放宽的时限等于没写。
    #
    # 但不把 connect 加进来：默认值下 10+30 会把总时长撑到 40 秒，
    # 悄悄改变了「默认 30 秒」这个既有行为。默认就是默认。
    if "total" not in values:
        values["total"] = max(DEFAULT_MAX_TIME,
                              values.get("content", DEFAULT_CONTENT))
    return Budget(**values)
