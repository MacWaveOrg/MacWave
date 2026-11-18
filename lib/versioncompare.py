#!/usr/bin/env python3

# versioncompare.py
# MacWave 全项目版本号解析、比较、排序的**唯一实现**。
#
# 以前这里有三份：lib/versioncompare.py（MacWave 自身版本）、
# pkg/pkgversionparser.py（软件包版本）、surfboard/depsversionparser.py（依赖版本）。
# 三份的规则各写各的，同一个版本串在「自身版本」与「包版本」两条路上可能给出相反
# 的结论 —— 那种分歧最后表现为「指针说已最新、客户端说该升级」这种最难查的状态。
# 现在合成一份，两个领域都调用 _parse()。
#
# 为什么不能只比数字段：版本号不是数字串。把 `4.4.0-beta1` 读成 [4, 4, 0, 1]，
# 于是它比 `4.4.0` = [4, 4, 0, 0] **大** —— 一个 beta 排在正式版之上。后果是实打
# 实的：装过 beta 的人永远等不到正式版（selfupdate 认为已经最新），而且这种错只在
# 「有预发布版本」时才显形，平时怎么测都看不出来。
#
# 所以序用 PEP 440（packaging），它给的是：
#
#     4.4.0.dev1 < 4.4.0a1 < 4.4.0b1 < 4.4.0rc1 < 4.4.0 < 4.4.1
#
# `packaging` 已经是硬依赖（见 pyproject.toml 与 lib/configerror.py 的自检），
# 所以这里直接用它，不再自造一套「差不多」的比较。
#
# 软件包还有一类历史写法（`procursus` / `macwaveteam` / `Xteam` 后缀），先在这里
# 归一化成 `X.Y.Z.N` 再比较，避免它们退化成「读不出数字 = 0」。

import logging
import re

from packaging.version import InvalidVersion, Version


_ZERO = Version("0")

# 社区特有的版本后缀。命中后由 safe_parse_special_version() 归一化。
_SPECIAL_RE = re.compile(r"(procursus|macwaveteam|team|Xteam)", re.IGNORECASE)


def is_special_version(value):
    """版本号是否带社区特有后缀（procursus / macwaveteam / Xteam …）。"""
    return bool(_SPECIAL_RE.search(str(value)))


def _pad_release(base):
    """两段版本补成三段，于是 `1.0` 与 `1.0.0` 等价。"""
    return base + ".0" if base.count(".") == 1 else base


def extract_special_info(value):
    """从特殊版本号中提取基础数字和后缀编号。"""
    text = str(value)
    info = {"base": None, "suffix_type": None, "suffix_num": 0}

    # `1.0-procursus7` 或 `2.1.5-procursus7`
    proc_match = re.search(r"(\d+\.\d+(?:\.\d+)?)[-_]?procursus(\d+)", text, re.IGNORECASE)
    if proc_match:
        info["base"] = _pad_release(proc_match.group(1))
        info["suffix_type"] = "procursus"
        info["suffix_num"] = int(proc_match.group(2))
        return info

    # `1.0-macwaveteam2` 或 `1.0-Xteam2`
    team_match = re.search(
        r"(\d+\.\d+(?:\.\d+)?)[-_]?(?:macwaveteam|Xteam)(\d+)", text, re.IGNORECASE
    )
    if team_match:
        info["base"] = _pad_release(team_match.group(1))
        info["suffix_type"] = "macwaveteam"
        info["suffix_num"] = int(team_match.group(2))
        return info

    # 兜底：只取数字主体，后缀编号记 0
    base_match = re.search(r"(\d+\.\d+(?:\.\d+)?)", text)
    if base_match:
        info["base"] = _pad_release(base_match.group(1))
        info["suffix_type"] = "unknown"
        info["suffix_num"] = 0
        return info

    return None


def safe_parse_special_version(value):
    """把特殊版本号归一化成 X.Y.Z.N 后解析；无法识别时退回 0.0.0。"""
    info = extract_special_info(str(value))
    if not info:
        logging.warning(f"Invalid special version string '{value}', falling back to 0.0.0")
        return Version("0.0.0")
    return Version(f"{info['base']}.{info['suffix_num']}")


def handle_pre_release(value):
    """给 `-alpha` / `-beta` / `-rc` 这类没编号的预发布补上 0，使之可解析。"""
    text = str(value)
    text = re.sub(r"-(alpha|beta|rc)$", r"-\1 0", text)
    return text.replace(" 0", "0")


def _parse(value):
    """所有版本号解析的唯一入口。"""
    text = str(value).strip()
    if is_special_version(text):
        return safe_parse_special_version(text)

    text = handle_pre_release(text)
    try:
        return Version(text)
    except InvalidVersion:
        pass

    # 不是合法 PEP 440：取出前三个数字段当作版本号（`1.8.2_1` → `1.8.2`，
    # 读不出数字就当成 0）。这么做是因为报错要指向真正的问题 —— 版本数据里写了
    # 个怪字符串时，比较不该先崩，让上层给出「版本无效」这种能看懂的提示。
    parts = re.findall(r"\d+", text)[:3]
    if not parts:
        return _ZERO
    return Version(".".join(parts))


def version(value):
    """把版本串解析成可比较的 Version。"""
    return _parse(value)


def safe_parse_pkg_version(value):
    """软件包版本解析（含社区后缀与预发布补全），返回可比较的 Version。"""
    return _parse(value)


def sort_key(value):
    """给 sorted() / max() 用的键。"""
    return _parse(value)


def compare(left, right):
    """-1 / 0 / 1。"""
    a, b = _parse(left), _parse(right)
    return (a > b) - (a < b)


def is_prerelease(value):
    """是不是预发布版（`4.4.0-beta2`、`4.4.0rc1`、`4.4.0.dev1` …）。

    beta 与正式版走**不同的分支**，所以 `wave selfupdate` 不能碰 beta —— 它按
    latest.toml 里的 branch 取文件，那是一条正式版分支，把它的增量盖在一棵 beta
    树上就成了两条线混在一起（2026-11-15 那次事故的成因）。判定放在这里，
    与版本比较同一处，shell 侧那份见 lib/selfupdate.sh 的 is_prerelease()。
    """
    return _parse(value).is_prerelease


def is_newer(candidate, current):
    """candidate 是否比 current 新。current 为空视为「没装」，一律算新。"""
    if not current:
        return True
    return _parse(candidate) > _parse(current)


def sort_versions(versions, reverse=True):
    """按版本序排序；默认从高到低。"""
    return sorted(versions, key=_parse, reverse=reverse)


def get_max_version(versions):
    """取最高版本；空输入返回 None。"""
    if not versions:
        return None
    return sort_versions(versions)[0]


def main():
    test_versions = [
        "1.0.0-rc", "1.0.0", "2.1.5-procursus7", "1.0-Xteam1",
        "1.0.0-alpha", "1.0.0-beta", "1.0.0-rc1",
    ]
    print("原始版本列表:", test_versions)
    print("排序后的版本:", sort_versions(test_versions))
    print("最高版本:", get_max_version(test_versions))


if __name__ == "__main__":
    main()
