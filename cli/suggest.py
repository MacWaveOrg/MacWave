#!/usr/bin/env python3

# suggest.py
# 「你是不是想敲……」的两类建议，都只在这里实现一次。
#
#   命令名：`wave instal jq`     → did you mean: wave install jq
#   包名  ：`wave install treee` → did you mean `tree`?
#
# 两类共用同一个思路（先查语义误用表，再按相似度猜），但判据不同：
# 命令名只有十几个候选、误用清单很短，可以用高阈值硬猜；
# 包名有上百个、用户可能只记得一半，只能给「最像的一个」并且宁可不说。

import difflib


# -------------------- 命令名 --------------------

# 常见误输入 → 正确的命令。
#
# 只收真的会有人这么打的几条，不做通用拼写纠正：/usr/bin 里那些包管理器的叫法
# （apt update、yum update、dnf update）会让人顺手打 `wave update`，而这里只有 upgrade。
# 猜错比不猜更让人困惑，所以宁可少提示。
MISTYPED = {
    "update":  "upgrade",
    "updates": "upgrade",
    "remove":  "uninstall",
    "delete":  "uninstall",
    "rm":      "uninstall",
    "ls":      "list",
    "find":    "search",
    "show":    "info",
}

# 拼写纠错的阈值。0.7 是下限：再低会把 `li` 猜成 list。
SPELL_CUTOFF = 0.7
# 首字母不同时，要求更高的相似度才认。
#
# 数字是穷举所有命令的**单字母错误**（删一个 / 换一个 / 插一个，共 4670 种）测出来的：
#
#   首字母必须相同        猜对 85.6%   猜错 0.2%   不猜 14.2%
#   首字母不同需 ≥0.9     猜对 91.7%   猜错 0.3%   不猜  8.1%
#   首字母不同需 ≥0.83    猜对 98.1%   猜错 0.3%   不猜  1.6%
#   无约束                猜对 99.6%   猜错 0.4%   不猜  0.0%
#
# 取 0.83：几乎全中，同时挡住 `inst` → list（`inst` 是 install 的缩写，
# 相似度 0.75，被这条卡掉；而真正的单字母笔误都在 0.83 以上）。
FIRST_CHAR_RATIO = 0.83


def spell_command(word, commands):
    """按拼写从命令表里猜一个；猜不到返回 None。

    与 MISTYPED 分工不同：那张表收的是**语义上**的误用（`update` 是 apt 的叫法），
    这里管的是**手滑**（`instal` 少一个 l）。
    """
    matches = difflib.get_close_matches(word, sorted(commands), n=1, cutoff=SPELL_CUTOFF)
    if not matches:
        return None
    best = matches[0]
    if best[0] == word[0]:
        return best
    # 首字母都不一样还硬猜，风险最高的就是「缩写」被当成笔误
    # （`inst` 与 `list` 相似度 0.75）。要求更高才认。
    ratio = difflib.SequenceMatcher(None, word, best).ratio()
    return best if ratio >= FIRST_CHAR_RATIO else None


def command(words, commands):
    """首词打错时给出完整改法：只换掉那个词，其余参数与旗标原样保留。

    返回 (改好的命令行, 打错的词, 正确命令)；不认识就返回 None。

    先查 MISTYPED（语义误用），再按拼写猜。顺序不能反：`update` 与 `selfupdate`
    的相似度是 0.75，先跑拼写会把它猜成 selfupdate，而用户想的是 upgrade。
    """
    if not words:
        return None
    wrong = words[0]
    right = MISTYPED.get(wrong) or spell_command(wrong, commands)
    if right is None or right not in commands:
        return None
    return " ".join(["wave", right] + words[1:]), wrong, right


# -------------------- 包名 --------------------

# 包名的两个判据取并集，缺一不可：
#   ratio >= NAME_RATIO  长名字打错一两个字母（treee -> tree）
#   edit distance <= 1   短名字打错一个字母（xk -> sk 的 ratio 只有 0.50）
# 只用 ratio 时 `xk` 拿不到任何建议；只用距离时 `htpz -> htop`（距离 2）会漏。
# 距离判据同时挡住 ratio 恰好也是 0.50 的误报：`curl -> ncdu` 距离 4，不成立。
NAME_RATIO = 0.6


def edit_distance(left, right):
    """Levenshtein 距离：把 left 改成 right 要几次增/删/换。"""
    previous = list(range(len(right) + 1))
    for i, char_left in enumerate(left, 1):
        current = [i]
        for j, char_right in enumerate(right, 1):
            current.append(min(previous[j] + 1,          # 删
                               current[j - 1] + 1,        # 增
                               previous[j - 1] + (char_left != char_right)))
        previous = current
    return previous[-1]


def closest_name(query, names):
    """从名字清单里挑最像的一个；都不像就返回 None。

    排除与 query 完全相同的名字：`wave latest treee` 打出「did you mean treee」
    只会让人更困惑。

    与网络无关，所以可以单独测 —— 这条路径只在 404 时才会走到，
    平时怎么用都不会碰，坏了也没人发现。install / latest 共用这一份。
    """
    folded = query.casefold()
    candidates = []
    for name in names or []:
        if name.casefold() == folded:
            continue
        ratio = difflib.SequenceMatcher(None, query, name).ratio()
        distance = edit_distance(query, name)
        if ratio >= NAME_RATIO or distance <= 1:
            candidates.append((distance, -ratio, name))
    if not candidates:
        return None
    # 先看谁改得最少，再比相似度；同分时按名字排序，保证结果稳定可测
    candidates.sort()
    return candidates[0][2]


def name_examples(query, names, limit=5):
    """给几个真存在、又和打错的名字有点关系的包名，帮用户找回来。

    优先同首字母的（`htpz` → 一堆 `h*`），没有就给清单开头几个。
    返回的第二个值表示这批示例是哪一种，提示语要据此换措辞 —— 否则会出现
    「names starting with a: jq, tree, wget」这种自相矛盾的话。
    """
    prefix = query[:1].casefold()
    same_letter = sorted(name for name in names or [] if name[:1].casefold() == prefix)
    if same_letter:
        return same_letter[:limit], f"names starting with '{prefix}'"
    return sorted(names or [])[:limit], "some names in the index"


if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    print("🌊 It is used internally by the other MacWave modules.")
    import sys
    sys.exit(1)
