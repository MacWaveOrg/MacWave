#!/usr/bin/env python3

# steplog.py
# 安装流程的「步骤追踪」，供 -v 使用。
#
# 目标只有一个：出错时不必读代码就能判断卡在哪一步、请求的是哪个地址、
# 服务端回了什么、接下来该做什么。所以每一处失败都用 fail() 报告，
# 它会把「步骤名 + 请求 + 响应 + 下一步」一次打全。
#
# 正常情况下（不加 -v）只保留原有的那几行进度输出；一旦失败，仍会打印
# 出错的步骤与建议 —— 定位问题不该以开 -v 为前提。
#
# 与其他模块的关系：本模块不 import domains（domains 反过来 import 本模块），
# 需要取域名或脱敏时在函数内部延迟 import，避免循环依赖。

import sys


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
YELLOW = '\033[33m'
DIM = '\033[2m'
RESET = '\033[0m'


# -------------------- 状态 --------------------

_verbose = False
_total = 0
_index = 0
_current = ""
_notes = []


def set_verbose(enabled):
    global _verbose
    _verbose = bool(enabled)


def is_verbose():
    return _verbose


def reset():
    global _total, _index, _current, _notes
    _total = 0
    _index = 0
    _current = ""
    _notes = []


def plan(steps):
    # steps 是这一趟要走的步骤名列表，只为算「4/10」这种序号。
    global _total
    _total = len(steps)


def begin(name):
    # 进入一步：-v 时打一行标题，同时记下它，后面 fail() 直接引用。
    global _index, _current
    _index += 1
    _current = name
    if _verbose:
        counter = f"{_index}/{_total}" if _total else str(_index)
        print(f"{DIM}🌊 [{counter}] {name}{RESET}")


def detail(message):
    # 某一步的细节：只在 -v 下出现。
    if _verbose:
        print(f"{DIM}      · {message}{RESET}")


def note(message):
    # 留给结尾汇总用的一句话。
    _notes.append(message)


def step_label():
    if not _current:
        return ""
    counter = f"{_index}/{_total}" if _total else str(_index)
    return f"第 {counter} 步（{_current}）"


def _redact(url):
    from domains import redact_url
    return redact_url(url)


def fail(reason, request=None, response=None, hint=None, extra=None):
    # 统一的失败出口：步骤号、请求、响应、原因、下一步，一次说清。
    print(f"{RED_BOLD}🌊 Error: {reason}{RESET}")

    if request:
        print(f"{RED_BOLD}🌊 请求   {_redact(request)}{RESET}")
    if response:
        print(f"{RED_BOLD}🌊 响应   {response}{RESET}")
    if extra:
        for line in extra.splitlines():
            print(f"{RED_BOLD}🌊        {line}{RESET}")

    label = step_label()
    if label:
        print(f"{YELLOW}🌊 位置   {label}{RESET}")

    if hint:
        lines = hint if isinstance(hint, (list, tuple)) else str(hint).splitlines()
        for i, line in enumerate(lines):
            prefix = "🌊 下一步 " if i == 0 else "🌊        "
            print(f"{YELLOW}{prefix}{line}{RESET}")

    sys.exit(1)


def trace_domains():
    # -v 时列出每个数据来源的实际取值：镜像地址、来自环境变量还是默认值、是否带凭据。
    if not _verbose:
        return

    from domains import ENV_NAME, domain, is_custom, redact_url, _has_userinfo

    print(f"{DIM}      --- 数据来源 ---{RESET}")
    for kind in ENV_NAME:
        value = domain(kind)
        if not value:
            print(f"{DIM}      · {kind:<11} 未配置{RESET}")
            continue
        origin = "环境变量" if is_custom(kind) else "默认值"
        auth = "（含凭据）" if _has_userinfo(value) else ""
        print(f"{DIM}      · {kind:<11} {origin}  {redact_url(value)}{auth}{RESET}")


# -------------------- 可直接运行（自检） --------------------

if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    sys.exit(1)
