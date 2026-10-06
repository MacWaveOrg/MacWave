#!/bin/bash

# sandbox_test.sh
# 安装器 / 卸载器的端到端回归，全程跑在**隔离沙箱**里：
# 宿主除了沙箱目录以外的地方一个字节都不会被写。
#
# 做法：
#   1. 在临时目录里搭一份离线镜像，只把 BASE_URL / CONFIGDATA_URL 两行改成
#      file:// 路径，因此整个过程**不需要网络**；
#   2. 用 macOS 自带的 sandbox-exec 起一个「默认拒绝、只允许写沙箱目录」的沙箱，
#      在里头跑安装 / 卸载的各种路径，逐条断言。
#
# 为什么不是 LinuxWave 那样的 unshare：macOS 没有用户命名空间，也没有可用来
# bind mount 的挂载点。这里用的是 macOS 特有的等价手段（sandbox-exec）。
#
# 覆盖：安装目录选项 → 配置落位 → PATH 写入 → 参数校验 → 协议顺序与拒绝后的
#       回滚 → 安装中途失败的指引 → 卸载确认语义（无终端 / y / n / --force）→
#       卸载器自删 → 软链接回归。
#
# 与 LinuxWave 版本的**范围差异**（因为沙箱是「拒绝写沙箱外」而非影子副本）：
#   · 用户级安装（选项 1、家目录内的自定义目录）端到端跑通；
#   · 系统级目录（/opt/macwave、/usr/local/macwave、家目录外的自定义目录）
#     不允许真的写入，改为断言「选中的安装目录与配置目录正确」——安装会在
#     越过沙箱边界时失败，而失败指引里会打印这两个路径。
#   · 没有共享安装（那是 Linux 专有功能），因此也没有账号删除那一组断言。
#
# 前置条件：macOS（sandbox-exec）、curl、python3（且 requests / packaging / rich
# 已装，否则安装器会去跑 pip，而 pip 写不到沙箱外）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

skip() {
    echo -e "${YELLOW}🌊 SKIP: $1${RESET}"
    SKIPPED=$((SKIPPED + 1))
}

# check <描述> <实际> <期望>
check() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

# contains <描述> <文件> <关键字>
contains() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        pass "$1"
    else
        fail "$1 ('$3' not found in output)"
    fi
}

# count_in <文件> <关键字> —— grep -c 无匹配时会同时输出 0 并返回 1，
# 直接接 `|| echo 0` 会拼出两行 "0"，所以统一走这里
count_in() {
    if [[ ! -f "$1" ]]; then
        echo 0
        return 0
    fi
    grep -cF -- "$2" "$1" 2>/dev/null || true
}


# 目录菜单的项数随架构变化：Intel 多一个 /usr/local/macwave。
# 每行是「--dir-option= 后面的值 / 安装目录 / 配置目录 / 显示路径」；自定义项要把
# 目录一起带上（否则 --silent 下会以「缺路径」提前退出，走不到沙箱边界）。
case "$(uname -m)" in
    x86_64|amd64)
        CUSTOM_OPTION=4
        SYSTEM_LEVEL_ROWS="2 /opt/macwave /opt/macwave_config /opt/macwave
3 /usr/local/macwave /opt/macwave_config /usr/local/macwave
4=/opt/macwave_custom /opt/macwave_custom /opt/macwave_config /opt/macwave_custom"
        ;;
    *)
        CUSTOM_OPTION=3
        SYSTEM_LEVEL_ROWS="2 /opt/macwave /opt/macwave_config /opt/macwave
3=/opt/macwave_custom /opt/macwave_custom /opt/macwave_config /opt/macwave_custom"
        ;;
esac


# ==========================================================
# 内层：已经在沙箱里，跑场景
# ==========================================================

install_run() {
    /bin/bash -c "$(cat "$OFFLINE_INSTALLER")" -- "$@" > "$OUT" 2>&1
    return $?
}

uninstall_run() {
    /bin/bash -c "$(cat "$SANDBOX_DIR/source-uninstall.sh")" -- "$@" > "$OUT" 2>&1
    return $?
}

# 卸载器以文件方式运行成功时会自删，所以每次都要重新放一份
uninstall_copy_fresh() {
    cp "$SANDBOX_DIR/source-uninstall.sh" "$SCRATCH/uninstall.sh"
}

# pty 驱动：macOS 的 script(1) 不能可靠地把输入喂给子进程的 /dev/tty，
# 所以交互断言直接用 python 开伪终端。
run_on_pty() {
    HOME="$FAKE_HOME" python3 "$SANDBOX_DIR/pty_drive.py" pty "$1" -- /bin/bash "$2" "${@:3}"
}

# 没有控制终端的情形（CI / < /dev/null）
run_without_tty() {
    HOME="$FAKE_HOME" python3 "$SANDBOX_DIR/pty_drive.py" notty -- /bin/bash "$@"
}

# 清掉上一场景留下的安装痕迹
reset_state() {
    rm -rf "$FAKE_HOME/.local/macwave" "$FAKE_HOME/.config/macwave_config"
    rm -rf "$FAKE_HOME/my-macwave" "$FAKE_HOME/.zshrc" "$FAKE_HOME/.bashrc" "$FAKE_HOME/.profile"
    rm -f "$OUT"
}

tree_version() {
    python3 -c "import json,sys;print(json.load(open('$1')).get('version',''))" 2>/dev/null
}

tree_base_dir() {
    python3 -c "import json,sys;print(json.load(open('$1')).get('base_dir',''))" 2>/dev/null
}

# 系统级安装只断言落位：沙箱不允许写沙箱外，安装必然在这一步失败，
# 而失败指引会把选中的 BASE_DIR / CONFIG_DIR 打出来。
scenario_system_dirs() {
    echo ""
    echo "========== 1b. 系统级目录的落位（越过沙箱边界即失败） =========="

    local arg dir cfg display rc
    while read -r arg dir cfg display; do
        [[ -z "$arg" ]] && continue
        reset_state
        install_run --silent "--dir-option=$arg"
        rc=$?
        check "--dir-option=$arg 在沙箱外应失败" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)" "yes"
        contains "  --dir-option=$arg 失败时给出指引" "$OUT" "Installation did not finish"
        contains "  --dir-option=$arg 选中 $display" "$OUT" "$dir"
        contains "  --dir-option=$arg 配置目录 $cfg" "$OUT" "$cfg"
        check "  --dir-option=$arg 未留下半成品" \
            "$([[ -e "$dir" ]] && echo yes || echo no)" "no"
    done <<< "$SYSTEM_LEVEL_ROWS"
}

scenario_install_dirs() {
    echo ""
    echo "========== 1a. 用户级安装目录（端到端） =========="

    reset_state
    install_run --silent --dir-option=1
    check "选项 1 安装成功" "$?" "0"
    check "选项 1 安装树就位" "$([[ -d "$FAKE_HOME/.local/macwave" ]] && echo yes || echo no)" "yes"
    check "选项 1 文件数 20" \
        "$(find "$FAKE_HOME/.local/macwave" -type f 2>/dev/null | wc -l | tr -d ' ')" "20"
    check "选项 1 配置在 ~/.config/macwave_config" \
        "$(tree_base_dir "$FAKE_HOME/.config/macwave_config/config.json")" "$FAKE_HOME/.local/macwave"
    check "选项 1 入口可执行" \
        "$([[ -x "$FAKE_HOME/.local/macwave/lib/wave" ]] && echo yes || echo no)" "yes"
    check "选项 1 VERSION.json 版本与脚本一致" \
        "$(tree_version "$FAKE_HOME/.config/macwave_config/VERSION.json")" \
        "$(sed -n 's/^MACWAVE_VERSION="\(.*\)"$/\1/p' "$OFFLINE_INSTALLER")"
    check "选项 1 写入了 PATH" "$(count_in "$FAKE_HOME/.zshrc" "$FAKE_HOME/.local/macwave")" "1"
    check "选项 1 不碰系统级配置" \
        "$([[ -e /opt/macwave_config ]] && echo yes || echo no)" "no"

    # 家目录内的自定义目录：无需提权，走的是同一条用户级分支
    reset_state
    install_run --silent "--dir-option=$CUSTOM_OPTION=$FAKE_HOME/my-macwave"
    check "家目录内自定义目录安装成功" "$?" "0"
    check "自定义目录安装树就位" "$([[ -d "$FAKE_HOME/my-macwave" ]] && echo yes || echo no)" "yes"
    check "自定义目录的配置落在用户级" \
        "$(tree_base_dir "$FAKE_HOME/.config/macwave_config/config.json")" "$FAKE_HOME/my-macwave"
}

scenario_cli_errors() {
    echo ""
    echo "========== 2. 参数校验 =========="

    reset_state
    install_run --silent "--dir-option=$CUSTOM_OPTION"
    check "--silent 下自定义项缺路径应报错" "$?" "1"

    reset_state
    install_run --silent --dir-option=9
    check "--dir-option=9 越界应报错" "$?" "1"

    reset_state
    install_run --bogus-flag
    check "未知参数应报错" "$?" "1"

    reset_state
    install_run --silent "--dir-option=$CUSTOM_OPTION=../evil"
    check "自定义目录拒绝路径穿越" "$?" "1"

    # 给非自定义项传目录：照抄另一架构的编号时最危险的用法
    reset_state
    install_run --silent "--dir-option=1=/tmp/x"
    check "非自定义项带目录应报错" "$?" "1"

    reset_state
    install_run --help
    check "--help 退出码为 0" "$?" "0"
    contains "--help 列出菜单" "$OUT" "other (enter custom directory)"
}

scenario_agreement() {
    echo ""
    echo "========== 3. 许可协议：顺序与拒绝后的回滚 =========="

    reset_state
    install_run --silent --dir-option=1
    local n_agree n_done
    n_agree=$(grep -n "Please read the agreement" "$OUT" | head -1 | cut -d: -f1)
    n_done=$(grep -n "Installation complete" "$OUT" | head -1 | cut -d: -f1)
    # 先宣布「安装完成」再问协议，不同意的用户会看到自相矛盾的输出
    check "协议询问在「安装完成」之前" \
        "$([[ -n "$n_agree" && -n "$n_done" && "$n_agree" -lt "$n_done" ]] && echo yes || echo no)" "yes"

    # 交互式：先选目录（1），再拒绝协议（n）
    reset_state
    run_on_pty $'1\nn\n' "$OFFLINE_INSTALLER" > "$OUT" 2>&1
    check "拒绝协议后退出码非 0" "$?" "1"
    check "拒绝协议后安装树被回滚" \
        "$([[ -e "$FAKE_HOME/.local/macwave" ]] && echo yes || echo no)" "no"
    check "拒绝协议后配置目录被回滚" \
        "$([[ -e "$FAKE_HOME/.config/macwave_config" ]] && echo yes || echo no)" "no"
    # 否则会留下一个指向已删除目录的 PATH
    check "拒绝协议后 rc 里的 PATH 被回滚" "$(count_in "$FAKE_HOME/.zshrc" "macwave")" "0"
}

scenario_mid_failure() {
    echo ""
    echo "========== 4. 安装中途失败：给出指引且不误删 =========="

    local victim="$MIRROR_BASE/lib/help.py" rc
    mv "$victim" "$victim.off"
    reset_state
    install_run --silent --dir-option=1
    rc=$?
    check "中途失败时退出码非 0" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)" "yes"
    contains "失败时说明安装未完成" "$OUT" "Installation did not finish"
    contains "失败时给出实际路径" "$OUT" "$FAKE_HOME/.local/macwave"
    contains "失败时说明没有删除任何东西" "$OUT" "Nothing was removed"
    contains "失败时给出重试指引" "$OUT" "run the installer again"
    # 升级安装时删掉安装树会把用户原有的可用安装一起毁掉
    check "失败时不自动删配置" \
        "$([[ -d "$FAKE_HOME/.config/macwave_config" ]] && echo yes || echo no)" "yes"
    mv "$victim.off" "$victim"

    reset_state
    install_run --silent --dir-option=1
    check "修好后重跑可自愈" "$?" "0"
    check "自愈后文件数 20" \
        "$(find "$FAKE_HOME/.local/macwave" -type f | wc -l | tr -d ' ')" "20"
    check "正常安装不误报失败指引" "$(count_in "$OUT" "did not finish")" "0"
}

scenario_uninstall_confirm() {
    echo ""
    echo "========== 5. 卸载确认语义 =========="

    # 5.1 无终端：必须拒绝，不能把 EOF 当成同意
    reset_state
    install_run --silent --dir-option=1
    run_without_tty "$SANDBOX_DIR/source-uninstall.sh" > "$OUT" 2>&1
    check "无终端时退出码非 0" "$([[ "$?" -ne 0 ]] && echo yes || echo no)" "yes"
    check "无终端时什么都不删" \
        "$([[ -e "$FAKE_HOME/.local/macwave" ]] && echo yes || echo no)" "yes"
    contains "无终端时提示改用 --force" "$OUT" "--force"

    # 5.2 回答 n → 取消
    install_run --silent --dir-option=1
    uninstall_copy_fresh
    run_on_pty n "$SCRATCH/uninstall.sh" > "$OUT" 2>&1
    check "答 n 时取消卸载" \
        "$([[ -e "$FAKE_HOME/.local/macwave" ]] && echo yes || echo no)" "yes"
    contains "答 n 时输出已取消" "$OUT" "Uninstall cancelled"

    # 5.3 回答 y → 删除
    install_run --silent --dir-option=1
    uninstall_copy_fresh
    run_on_pty y "$SCRATCH/uninstall.sh" > "$OUT" 2>&1
    check "答 y 时卸载完成" \
        "$([[ -e "$FAKE_HOME/.local/macwave" ]] && echo no || echo yes)" "yes"

    # 5.4 --force：无需终端
    reset_state
    install_run --silent --dir-option=1
    uninstall_run --force
    check "--force 无人值守卸载成功" "$?" "0"
    check "--force 后安装树已删" \
        "$([[ -e "$FAKE_HOME/.local/macwave" ]] && echo yes || echo no)" "no"
    check "--force 后配置已删" \
        "$([[ -e "$FAKE_HOME/.config/macwave_config" ]] && echo yes || echo no)" "no"
    check "--force 后 rc 里的 PATH 已清" "$(count_in "$FAKE_HOME/.zshrc" "macwave")" "0"

    # 5.5 --remove-user 只为与 LinuxWave 的参数兼容，不该出错
    reset_state
    install_run --silent --dir-option=1
    uninstall_run --force --remove-user
    check "--force --remove-user 仍成功" "$?" "0"
}

scenario_self_delete() {
    echo ""
    echo "========== 6. 卸载器自删（\$0 的取值） =========="

    reset_state
    install_run --silent --dir-option=1
    check "安装成功（自删场景前置）" "$?" "0"
    uninstall_copy_fresh
    /bin/bash "$SCRATCH/uninstall.sh" --force > "$OUT" 2>&1
    check "以文件方式运行时自删" "$([[ -e "$SCRATCH/uninstall.sh" ]] && echo yes || echo no)" "no"

    # 用文档推荐的 /bin/bash -c 运行时 $0 是解释器自身；曾经这里会把 /bin/bash 删掉
    reset_state
    install_run --silent --dir-option=1
    uninstall_run --force
    check "以 /bin/bash -c 运行卸载成功" "$?" "0"
    check "以 /bin/bash -c 运行不误删解释器" "$([[ -x /bin/bash ]] && echo yes || echo no)" "yes"

    # $0 是 `--` 时（带参数的推荐写法）也不该自删或报错
    reset_state
    install_run --silent --dir-option=1
    /bin/bash -c "$(cat "$SANDBOX_DIR/source-uninstall.sh")" -- --force > "$OUT" 2>&1
    check "带参数的推荐写法卸载成功" "$?" "0"
    check "带参数的推荐写法不误删解释器" "$([[ -x /bin/bash ]] && echo yes || echo no)" "yes"
}

scenario_confinement() {
    echo ""
    echo "========== 7. 沙箱自检（这一组失败说明隔离没生效） =========="

    if /bin/bash -c "mkdir -p /opt/macwave_confinement_probe" 2>/dev/null; then
        rm -rf /opt/macwave_confinement_probe 2>/dev/null || true
        fail "沙箱外(/opt)可写——隔离没有生效，其余断言都不可信"
    else
        pass "沙箱外(/opt)不可写，隔离生效"
    fi

    if /bin/bash -c "touch '$SANDBOX_DIR/probe.txt'" 2>/dev/null; then
        pass "沙箱内可写"
    else
        fail "沙箱内不可写——隔离过严，安装器根本跑不起来"
    fi
}

scenario_link_regression() {
    echo ""
    echo "========== 8. 软链接回归（复用 link_test.sh） =========="

    reset_state
    install_run --silent --dir-option=1
    check "安装成功（软链接回归前置）" "$?" "0"

    if [[ ! -f "$MIRROR_BASE/scripts/link_test.sh" ]]; then
        skip "link_test.sh 不在镜像里"
        return
    fi
    (
        cd "$MIRROR_BASE"
        HOME="$FAKE_HOME" bash scripts/link_test.sh
    ) > "$OUT" 2>&1
    check "link_test.sh 全部通过" "$(count_in "$OUT" "FAIL")" "0"
    check "link_test.sh 有跑过断言" \
        "$([[ "$(count_in "$OUT" "PASS")" -gt 0 ]] && echo yes || echo no)" "yes"
}

run_scenarios() {
    reset_state
    scenario_install_dirs
    scenario_system_dirs
    scenario_cli_errors
    scenario_agreement
    scenario_mid_failure
    scenario_uninstall_confirm
    scenario_self_delete
    scenario_confinement
    scenario_link_regression

    echo ""
    echo "=========================================="
    echo "🌊 Passed: $PASSED"
    echo "🌊 Failed: $FAILED"
    echo "🌊 Skipped: $SKIPPED"
    echo "=========================================="

    [[ "$FAILED" -gt 0 ]] && exit 1
    exit 0
}

if [[ -n "${SANDBOX_INNER:-}" ]]; then
    OFFLINE_INSTALLER="$SANDBOX_DIR/install-offline.sh"
    MIRROR_BASE="$SANDBOX_DIR/mirror/base"
    FAKE_HOME="$SANDBOX_DIR/home"
    SCRATCH="$SANDBOX_DIR/scratch"
    OUT="$SANDBOX_DIR/output.txt"
    # 外层是 `exec sandbox-exec`，它自己的 EXIT 陷阱不会执行，所以清理要挂在这里
    trap 'rm -rf "$SANDBOX_DIR"' EXIT INT TERM
    run_scenarios
fi


# ==========================================================
# 外层：搭沙箱，然后在内层重跑自己
# ==========================================================

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo -e "${RED_BOLD}🌊 Error: this harness relies on macOS sandbox-exec.${RESET}"
    echo "🌊 On Linux use the unshare-based harness from LinuxWave instead."
    exit 1
fi

for tool in sandbox-exec curl python3; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo -e "${RED_BOLD}🌊 Error: '$tool' is required.${RESET}"
        exit 1
    fi
done

# 下面会把整个仓库拷进沙箱当离线镜像。脚本可能被复制到别处执行，那时 REPO_DIR
# 会指向别的目录——不先确认身份，就会把一个无关（甚至巨大）的目录整个打包进来。
for marker in lib/install.sh lib/uninstall.sh lib/wave.py scripts/link_test.sh; do
    if [[ ! -f "$REPO_DIR/$marker" ]]; then
        echo -e "${RED_BOLD}🌊 Error: $REPO_DIR does not look like the MacWave repository.${RESET}"
        echo "🌊 Missing: $marker"
        echo "🌊 Run it from the repository: bash scripts/sandbox_test.sh"
        exit 1
    fi
done

# 安装器会在缺依赖时跑 pip，而 pip 写不到沙箱外。缺了就在这里说清楚，
# 免得后面收到一堆「中途失败」的假失败。
for mod in requests packaging rich; do
    if ! python3 -c "import $mod" 2>/dev/null; then
        echo -e "${RED_BOLD}🌊 Error: python3 is missing '$mod'.${RESET}"
        echo "🌊 The installer would try to pip install it, which the sandbox forbids."
        echo "🌊 Install it first: pip3 install $mod"
        exit 1
    fi
done

SANDBOX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macwave-sandbox.XXXXXX")"
SANDBOX_DIR="$(cd "$SANDBOX_DIR" && pwd -P)"      # 解析 /tmp -> /private/tmp，沙箱规则要真实路径
cleanup() {
    rm -rf "$SANDBOX_DIR"
}
# INT/TERM 也接上：中断留下的沙箱目录不小（镜像 + 安装树），别攒着
trap cleanup EXIT INT TERM

echo "🌊 Sandbox: $SANDBOX_DIR"
echo "🌊 Nothing outside this directory will be written."
echo ""

# ---------- 1. 离线镜像 ----------
mkdir -p "$SANDBOX_DIR/mirror/base" "$SANDBOX_DIR/mirror/configdata"
tar -C "$REPO_DIR" -cf - \
    --exclude=.git --exclude=.github --exclude=.templates \
    --exclude=.vscode --exclude=.codex --exclude=.pycharm \
    --exclude=__pycache__ --exclude=.DS_Store . \
    | tar -C "$SANDBOX_DIR/mirror/base" -xf -

CONFIGDATA_SRC="${MACWAVE_CONFIGDATA:-$(dirname "$REPO_DIR")/configdata}"
if [[ -f "$CONFIGDATA_SRC/versiondata/files_info" ]]; then
    tar -C "$CONFIGDATA_SRC" -cf - --exclude=.git --exclude=.DS_Store . \
        | tar -C "$SANDBOX_DIR/mirror/configdata" -xf -
    echo "🌊 Using the real files_info from $CONFIGDATA_SRC"
else
    # 没有 configdata 分支时按仓库结构生成一份，好让脚本在单分支检出下也能跑
    mkdir -p "$SANDBOX_DIR/mirror/configdata/versiondata"
    {
        echo "/"
        for d in lib pkg surfboard; do
            echo "    $d/"
            for f in "$REPO_DIR/$d"/*; do
                [[ -f "$f" ]] || continue
                base="$(basename "$f")"
                # 安装器与卸载器不装自己——真实的 files_info 也是这样
                [[ "$base" == "install.sh" || "$base" == "uninstall.sh" ]] && continue
                echo "        $base"
            done
        done
    } > "$SANDBOX_DIR/mirror/configdata/versiondata/files_info"
    echo -e "${YELLOW}🌊 configdata branch not found; generated files_info from the repo tree.${RESET}"
    echo -e "${YELLOW}🌊 Set MACWAVE_CONFIGDATA=<path> to test the real one.${RESET}"
fi

# 只改两行 URL，其余与真实安装器逐字节一致
sed -e "s|^BASE_URL=.*|BASE_URL=\"file://$SANDBOX_DIR/mirror/base\"|" \
    -e "s|^CONFIGDATA_URL=.*|CONFIGDATA_URL=\"file://$SANDBOX_DIR/mirror/configdata\"|" \
    "$REPO_DIR/lib/install.sh" > "$SANDBOX_DIR/install-offline.sh"
cp "$REPO_DIR/lib/uninstall.sh" "$SANDBOX_DIR/source-uninstall.sh"
cp "${BASH_SOURCE[0]}" "$SANDBOX_DIR/sandbox_test.sh"

if [[ "$(diff <(sed -e 's|^BASE_URL=.*|X|' -e 's|^CONFIGDATA_URL=.*|Y|' "$REPO_DIR/lib/install.sh") \
               <(sed -e 's|^BASE_URL=.*|X|' -e 's|^CONFIGDATA_URL=.*|Y|' "$SANDBOX_DIR/install-offline.sh") \
          | wc -l | tr -d ' ')" != "0" ]]; then
    echo -e "${RED_BOLD}🌊 Error: the offline installer differs from lib/install.sh beyond the URLs.${RESET}"
    exit 1
fi

# ---------- 2. pty 驱动 ----------
# macOS 的 script(1) 不能可靠地把输入喂给子进程的 /dev/tty（read 会成功但回复为空），
# 所以交互断言用 python 直接开伪终端。
cat > "$SANDBOX_DIR/pty_drive.py" << 'PYEOF'
#!/usr/bin/env python3
"""Drive an interactive script: `pty <reply> -- <cmd>...` or `notty -- <cmd>...`."""
import os
import pty
import select
import subprocess
import sys
import time

mode = sys.argv[1]
rest = sys.argv[2:]
if rest and rest[0] == "--":
    rest = rest[1:]

if mode == "notty":
    # 自成会话且没有控制终端：/dev/tty 打不开，也就是 CI / < /dev/null 的情形
    proc = subprocess.run(rest, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          start_new_session=True)
    sys.stdout.write(proc.stdout.decode("utf-8", "replace"))
    sys.exit(proc.returncode)

if mode != "pty":
    sys.exit("usage: pty_drive.py pty <reply> -- <cmd>... | pty_drive.py notty -- <cmd>...")

reply = rest[0]
argv = rest[1:]
if argv and argv[0] == "--":
    argv = argv[1:]

pid, fd = pty.fork()
if pid == 0:                                  # 子进程：这个 pty 成为它的控制终端
    os.execvp(argv[0], argv)

time.sleep(0.4)                               # 等子进程走到提示符
os.write(fd, reply.encode())

chunks = []
while True:
    try:
        r, _, _ = select.select([fd], [], [], 5)
    except InterruptedError:
        continue
    if not r:
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    chunks.append(data)

# 子进程若卡在读取上（例如被拒绝的 tty 操作），别让整个测试挂住
deadline = time.time() + 5
status = None
while time.time() < deadline:
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        break
    time.sleep(0.1)
if status is None:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)

sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(status))
PYEOF
chmod +x "$SANDBOX_DIR/pty_drive.py"

# ---------- 3. 沙箱规则 ----------
# 默认拒绝，只放开：读所有、写沙箱目录与 /dev、以及进程自身需要的那些权限。
# 于是「写到 /opt」这类越界行为会硬失败，而不是悄悄改坏宿主的系统目录。
cat > "$SANDBOX_DIR/profile.sb" << SBEOF
(version 1)
(deny default)
(allow process*)
(allow signal)
(allow file-read*)
(allow file-write* (subpath "$SANDBOX_DIR"))
(allow file-write* (subpath "/dev"))
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm)
(allow file-ioctl)
SBEOF

# bash 的 here-document 在配合函数/内建以外的命令时要落一个真实临时文件，位置写死在
# /tmp（即 /private/tmp），不看 TMPDIR——安装器写 config.json / VERSION.json 正是这样。
# 放开这个公共临时目录，沙箱目录本身也在它下面。
echo "(allow file-write* (subpath \"/private/tmp\"))" >> "$SANDBOX_DIR/profile.sb"

# BSD 的 mktemp（不给模板时）同样不看 TMPDIR，而是固定用 _CS_DARWIN_USER_TEMP_DIR，
# 安装器取文件清单时就是这么用的。那是当前用户自己的私有临时目录。
DARWIN_USER_TEMP_DIR="$(cd "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)" && pwd -P)"
if [[ -n "$DARWIN_USER_TEMP_DIR" ]]; then
    echo "(allow file-write* (subpath \"$DARWIN_USER_TEMP_DIR\"))" >> "$SANDBOX_DIR/profile.sb"
fi

mkdir -p "$SANDBOX_DIR/home" "$SANDBOX_DIR/scratch" "$SANDBOX_DIR/tmp" "$SANDBOX_DIR/bin"
chmod 700 "$SANDBOX_DIR/home" "$SANDBOX_DIR/scratch"

# 替身 sudo：沙箱里既没有真提权、也不需要。安装器用 sudo 只做两件事——探测能否提权
# （`sudo -n true` / `sudo -v`），以及在系统级目录里建目录。前者要让它通过，才能走到
# 我们真正想断言的那一步（越过沙箱边界失败）；后者照常失败。
cat > "$SANDBOX_DIR/bin/sudo" << 'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -v|-n|-k|--non-interactive|--validate) shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || exit 0
exec "$@"
STUB
chmod +x "$SANDBOX_DIR/bin/sudo"

# ---------- 4. 进沙箱跑 ----------
export SANDBOX_DIR
exec sandbox-exec -f "$SANDBOX_DIR/profile.sb" /bin/bash -c '
    set -u
    export SANDBOX_INNER=1
    export HOME="$SANDBOX_DIR/home"
    export TMPDIR="$SANDBOX_DIR/tmp"
    export SHELL=/bin/zsh
    export LC_ALL=en_US.UTF-8
    export PATH="$SANDBOX_DIR/bin:$PATH"
    cd "$SANDBOX_DIR"
    exec /bin/bash "$SANDBOX_DIR/sandbox_test.sh"
'
