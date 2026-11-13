#!/usr/bin/env python3

# versioncmp.py
# MacWave 自己的版本号比较 —— **唯一实现**。
#
# 为什么必须有这一处：版本号不是数字串。按数字段比会把 `4.4.0-beta1` 读成
# [4, 4, 0, 1]，于是它比 `4.4.0` = [4, 4, 0, 0] **大** —— 一个 beta 排在正式版
# 之上。后果是实打实的：装过 beta 的人永远等不到正式版（selfupdate 认为已经最新），
# 而且这种错只在「有预发布版本」时才显形，平时怎么测都看不出来。
#
# 所以改用 PEP 440（packaging），它给的序是：
#
#     4.4.0.dev1 < 4.4.0a1 < 4.4.0b1 < 4.4.0rc1 < 4.4.0 < 4.4.1
#
# `packaging` 已经是硬依赖（见 pyproject.toml 与 lib/configerror.py 的自检），
# 所以这里直接用它，不再自造一套「差不多」的比较。
#
# pkg/ 里的软件包版本比较走 pkg/pkgversionparser.py，那是另一套（包的版本可以带
# 各种历史写法），**不要**把这个模块用在包版本上；反过来也一样。

import re

from packaging.version import InvalidVersion, Version


_ZERO = Version("0")


def version(value):
    """把版本串解析成可比较的 Version。

    合法 PEP 440 直接用。不合法时退一步：取出其中的数字段当作版本号
    （`1.8.2_1` → `1.8.2`，读不出数字就当成 0）。这么做的理由是报错要指向真正
    的问题 —— 版本数据里写了个怪字符串时，比较不该先崩，让上层给出「版本无效」
    这种能看懂的提示。
    """
    text = str(value).strip()
    try:
        return Version(text)
    except InvalidVersion:
        parts = re.findall(r"\d+", text)[:3]
        if not parts:
            return _ZERO
        return Version(".".join(parts))


def sort_key(value):
    """给 sorted() / max() 用的键。"""
    return version(value)


def compare(left, right):
    """-1 / 0 / 1。"""
    a, b = version(left), version(right)
    return (a > b) - (a < b)


def is_newer(candidate, current):
    """candidate 是否比 current 新。current 为空视为「没装」，一律算新。"""
    if not current:
        return True
    return version(candidate) > version(current)
