#!/usr/bin/env python3

# mirrorinfo.py
# `wave mirror` —— 打印当前生效的镜像配置。
#
# 存在的理由：装了镜像之后，用户真正想知道的是「这次用的是镜像还是官方地址」。
# 以前只能靠 echo 一堆环境变量，默认值、哪些没设、哪些带凭据全靠自己分辨。
#
# 几条硬性约定：
#   - 未设置也要打印默认值，不能留空 —— 空值看不出「没设」还是「设成了空」。
#   - 密码一律打印固定 6 个星号，与真实长度无关，否则星号个数会泄露长度。
#   - --show-password 才打印真实密码；--hide-user 把用户名也盖掉。
#     这两个旗标只对「带凭据的地址」有意义，其余行原样输出。
#   - 输出格式互斥：同时给两个就报错，避免「哪个生效」靠猜。

import json
import os
import sys

import domains


# -------------------- 颜色定义 --------------------

RED_BOLD = '\033[1;31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
PURPLE = '\033[35m'
RESET = '\033[0m'

# 固定 6 个：不随密码长度变化，避免从星号个数推断长度
MASK = "******"

PIP_ENV = "MACWAVE_PIP_INDEX"
PIP_DEFAULT = "https://pypi.org/simple"
PIP_NAME = "pip"

NOT_CONFIGURED = "(not configured)"

FORMATS = ("json", "yaml", "toml", "raw")


# -------------------- 地址拆解 --------------------

def split_userinfo(value):
    # 把 https://user:pass@host/path 拆成 (基础地址, 用户名, 密码)。
    # 没有 userinfo 时返回 (原值, None, None)，调用方据此判断「是否需要认证」。
    scheme, sep, rest = value.partition("://")
    if not sep:
        return value, None, None
    userinfo, at, host = rest.rpartition("@")
    if not at:
        return value, None, None
    user, colon, password = userinfo.partition(":")
    return f"{scheme}://{host}", user, (password if colon else "")


def rebuild(base, user, password):
    scheme, _, host = base.partition("://")
    return f"{scheme}://{user}:{password}@{host}"


def masked_url(value, show_password=False, hide_user=False):
    base, user, password = split_userinfo(value)
    if user is None:
        return value
    shown_user = MASK if hide_user else user
    shown_password = password if show_password else MASK
    return rebuild(base, shown_user, shown_password)


# -------------------- 收集 --------------------

def collect(show_password=False, hide_user=False):
    # 返回每一行的信息。value 已经是「该打印成什么」，调用方不必再判断脱敏。
    rows = []

    for kind in domains.ENV_NAME:
        value = domains.domain(kind)
        base, user, password = split_userinfo(value) if value else ("", None, None)

        if not value:
            source = "unset"
        elif domains.is_custom(kind):
            source = "env"
        else:
            source = "default"

        rows.append({
            "name": kind,
            "env": domains.ENV_NAME[kind],
            "source": source,
            "requires_auth": user is not None,
            "user": (MASK if hide_user else user) if user is not None else None,
            "value": masked_url(value, show_password, hide_user) if value else NOT_CONFIGURED,
        })

    pip = (os.environ.get(PIP_ENV) or "").strip()
    rows.append({
        "name": PIP_NAME,
        "env": PIP_ENV,
        "source": "env" if pip else "default",
        "requires_auth": False,
        "user": None,
        "value": pip or PIP_DEFAULT,
    })

    return rows


# -------------------- 渲染 --------------------

def as_table(rows):
    # 标签与来源两列按最宽的内容对齐，地址列自然跟随 —— 与 help 的做法一致。
    name_width = max(len(row["name"]) for row in rows)
    source_width = max(len(row["source"]) for row in rows)
    lines = []
    for row in rows:
        auth = f" {YELLOW}(auth){RESET}" if row["requires_auth"] else ""
        lines.append(
            f"  {row['name']:<{name_width}}  {row['source']:<{source_width}}  {row['value']}{auth}")
    return "\n".join(lines)


def as_json(rows):
    return json.dumps({"mirrors": rows}, indent=2, ensure_ascii=False)


def as_toml(rows):
    blocks = []
    for row in rows:
        lines = ["[[mirror]]"]
        for key, value in row.items():
            if value is None:
                continue
            if isinstance(value, bool):
                lines.append(f"{key} = {'true' if value else 'false'}")
            else:
                lines.append(f'{key} = "{value}"')
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def as_yaml(rows):
    lines = ["mirrors:"]
    for row in rows:
        first = True
        for key, value in row.items():
            if value is None:
                continue
            rendered = ('true' if value else 'false') if isinstance(value, bool) \
                else json.dumps(value, ensure_ascii=False)
            lines.append(f"{'  - ' if first else '    '}{key}: {rendered}")
            first = False
    return "\n".join(lines)


def as_raw(rows):
    # 逐行写全地址，不用 $B 之类的前缀变量：
    # 这样任何一行都能单独替换（例如只把 bottle 指向另一台机器），
    # 也不会因为改漏了前缀而让所有行一起错。
    lines = ["# MacWave mirror"]
    for row in rows:
        if row["source"] == "unset":
            # 空值 export 会把变量清掉，用注释占位更安全
            lines.append(f'# {row["env"]}  {NOT_CONFIGURED}')
            continue
        lines.append(f'export {row["env"]}="{row["value"]}"')
    return "\n".join(lines)


RENDERERS = {
    "table": as_table,
    "json": as_json,
    "yaml": as_yaml,
    "toml": as_toml,
    "raw": as_raw,
}


# -------------------- 参数解析 --------------------

FLAGS = {"--show-password", "--hide-user", *[f"--{name}" for name in FORMATS]}


def parse_args(words):
    for word in words:
        if word.startswith("-") and word not in FLAGS:
            print(f"{RED_BOLD}🌊 Error: unknown option {word}{RESET}")
            print(f"{YELLOW}🌊 Next      wave mirror --help lists the flags it accepts{RESET}")
            sys.exit(1)

    chosen = [name for name in FORMATS if f"--{name}" in words]
    if len(chosen) > 1:
        given = ", ".join(f"--{name}" for name in chosen)
        print(f"{RED_BOLD}🌊 Error: choose one output format, got: {given}{RESET}")
        print(f"{YELLOW}🌊 Next      --json, --yaml, --toml and --raw are mutually exclusive{RESET}")
        sys.exit(1)

    return {
        "format": chosen[0] if chosen else "table",
        "show_password": "--show-password" in words,
        "hide_user": "--hide-user" in words,
    }


# -------------------- 入口 --------------------

def handle_mirror(input_string=""):
    words = input_string.split()
    if words and words[0] == "wave":
        words = words[1:]
    if words and words[0] == "mirror":
        words = words[1:]

    options = parse_args(words)
    rows = collect(options["show_password"], options["hide_user"])

    if options["format"] != "table":
        print(RENDERERS[options["format"]](rows))
        sys.exit(0)

    print(f"{PURPLE}Mirror configuration{RESET}")
    print()
    print(as_table(rows))
    print()
    print(f"{GREEN}🌊 env = set by MACWAVE_*_DOMAIN, default = built-in address, "
          f"unset = nothing to point at yet{RESET}")
    if any(row["requires_auth"] for row in rows):
        if options["show_password"]:
            print(f"{YELLOW}🌊 Passwords are shown in full (--show-password){RESET}")
        else:
            print(f"{YELLOW}🌊 Passwords are masked; --show-password prints them, "
                  f"--hide-user also masks the user name{RESET}")
    sys.exit(0)


if __name__ == "__main__":
    try:
        handle_mirror(" ".join(sys.argv[1:]))
    except KeyboardInterrupt:
        print("\n🌊 Operation cancelled by user.")
        sys.exit(130)
