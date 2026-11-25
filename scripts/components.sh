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

# ==========================================
# 会"真装真卸"的测试用的沙箱
# ==========================================
#
# 有一类测试必须跑真实的安装流程（下载、落盘、写 VERSION.json、级联删依赖），
# 它们以前直接读 /opt/macwave_config 或 ~/.config/macwave_config 里的 base_dir，
# 于是「跑一次测试」= 「把现有安装改一遍」。2026-11-24 就是这么把一台机器的
# VERSION.json 写成了 4.0.1/TEST（selfupdate_test），所以这类测试必须在自己的
# 树里跑。
#
# 用法：
#   source "$SCRIPT_DIR/components.sh"
#   sandbox_install_tree "$(mktemp -d)/root" 4.0.0
#   # 之后用 $SANDBOX_BASE / $SANDBOX_CONFIG_FILE / $SANDBOX_VERSION_FILE
#
# 组件是**拷**进去的，不是软链：这些测试会往树里写文件，软链会把改动写回仓库。
sandbox_install_tree() {
    # 沙箱里的客户端版本要高于索引里任何一个 min_client_version，否则测的是
    # 「你的客户端太旧」那条错误路径（2026-11-25：gwget 写了 4.5.0，
    # 沙箱还写 1.0，deps_test 因此红了两条线）。
    local root="$1" version="${2:-4.99.0}" component
    SANDBOX_BASE="$root/opt/macwave"
    SANDBOX_CONFIG_DIR="$root/opt/macwave_config"
    mkdir -p "$SANDBOX_BASE" "$SANDBOX_CONFIG_DIR"
    # 与 install.sh 建的那几个目录对齐：link / uninstall 之类的测试会直接往
    # bin/、links/、downloads/tmp 里放东西，缺一个就 "No such file or directory"。
    mkdir -p "$SANDBOX_BASE"/{bin,links,pkg,surfboard,lib,downloads/tmp}

    for component in $(components) $(assets); do
        [ -d "$COMPONENT_REPO/$component" ] || continue
        mkdir -p "$SANDBOX_BASE/$component"
        cp -R "$COMPONENT_REPO/$component"/. "$SANDBOX_BASE/$component"/ 2>/dev/null || true
    done

    SANDBOX_CONFIG_FILE="$SANDBOX_CONFIG_DIR/config.json"
    SANDBOX_VERSION_FILE="$SANDBOX_CONFIG_DIR/VERSION.json"
    printf '{"base_dir": "%s"}\n' "$SANDBOX_BASE" > "$SANDBOX_CONFIG_FILE"
    printf '{\n  "version": "%s"\n}\n' "$version" > "$SANDBOX_VERSION_FILE"

    # MACWAVE_TEST 让 configpaths 把 root 当 /：配置目录、安装目录都落在里面。
    export MACWAVE_TEST="$root"
}
