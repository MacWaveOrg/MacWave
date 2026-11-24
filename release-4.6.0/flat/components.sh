#!/bin/bash

# components.sh
# 运行时组件清单的唯一读取入口 —— 清单本身在 scripts/components.txt。
#
# 为什么要有它：加一个顶层组件目录（比如把传输层从 lib/ 拆成 net/）时，「装进安装树、
# 加进 sys.path、拷进测试沙箱」这三件事原先分散在二十多处硬编码里。漏一处的后果不是
# 报错，而是得到一个缺目录的安装树 —— 在用户机器上表现为某条命令 ImportError，在本机
# 表现为一条毫不相干的测试突然变红。
#
# 用法（在测试脚本里，SCRIPT_DIR 已就绪）：
#
#   source "$SCRIPT_DIR/components.sh"
#   copy_components "$BASE"                              # 全部组件拷进沙箱
#   export MACWAVE_COMPONENT_PATHS="$(component_paths)"   # 给内嵌 python 用
#
# 内嵌 python 那边：
#
#   sys.path[:0] = os.environ["MACWAVE_COMPONENT_PATHS"].split(os.pathsep)

COMPONENT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPONENT_FILE="$COMPONENT_REPO/scripts/components.txt"

# 逐行输出组件名：去掉注释与空行，保持文件里的顺序。
# 注意用 sed 而不是 tr -d '[:space:]' —— tr 会把换行一起删掉，三条并成一条
# `libpkgsurfboard`，而且这种错误在 `for` 循环里表现成「一个不存在的目录」。
components() {
    sed -e 's/#.*//' "$COMPONENT_FILE" | sed -e 's/[[:space:]]//g' | grep -v '^$'
}

# 资源目录（man/、info/）：装进安装树但不进 sys.path。清单在 scripts/assets.txt。
assets() {
    sed -e 's/#.*//' "$COMPONENT_REPO/scripts/assets.txt" | sed -e 's/[[:space:]]//g' | grep -v '^$'
}

# 把全部组件目录拷进 <目标目录>。资源目录一起拷 —— 测试沙箱里要跑
# `wave manual`，缺了 man/ 与 info/ 它就找不到自己的文件。
copy_components() {
    local dest="$1" name
    for name in $(components) $(assets); do
        cp -R "$COMPONENT_REPO/$name" "$dest/"
    done
}

# 仓库里各组件目录的绝对路径，用 : 连接（给 PYTHONPATH / sys.path 用）
component_paths() {
    local out="" name
    for name in $(components); do
        out="${out:+$out:}$COMPONENT_REPO/$name"
    done
    printf '%s' "$out"
}

# 内嵌 python 段很多，逐个传参容易漏。source 之后两个变量就在环境里：
#   MACWAVE_COMPONENT_PATHS  绝对路径，冒号分隔 → split(os.pathsep)
#   MACWAVE_COMPONENT_NAMES  目录名，空格分隔       → split()
MACWAVE_COMPONENT_PATHS="$(component_paths)"
MACWAVE_COMPONENT_NAMES="$(components)"
export MACWAVE_COMPONENT_PATHS MACWAVE_COMPONENT_NAMES
