#!/bin/bash

# bash 3.2 (macOS)
# 最近一次更新于：

# MacWave Uninstaller
# 卸载 MacWave 及清理环境配置

set -eE
set -u
set -o pipefail

# 退出码要有语义
# 0 = 卸载完成（包括“本来就没装”）
# 1 = 用法错误（未知参数、没有终端可确认）
# 2 = 权限不足
# 3 = 部分失败（有明确清单写 stderr）

# -------------------- 测试根（隔离） --------------------
# MACWAVE_TEST 指向一个目录时，把它当作 /：HOME 和所有系统路径都挂到它下面，
# 整条链路都落在那个目录里，完全不碰真实系统。
# 没设置时 SYS_ROOT 为空，下面 "$SYS_ROOT/opt/..." 就还是 "/opt/..."，行为不变。

SYS_ROOT=""
if [[ -n "${MACWAVE_TEST:-}" ]]; then
    _mw_root="$MACWAVE_TEST"
    if [[ "$_mw_root" == "~"* ]]; then
        _mw_root="${HOME}${_mw_root#\~}"
    fi
    mkdir -p "$_mw_root"
    SYS_ROOT="$(cd "$_mw_root" && pwd)"
    export HOME="$SYS_ROOT${HOME}"
    export MACWAVE_TEST_ROOT="$SYS_ROOT"
    mkdir -p "$HOME"
    echo "🌊 Test root: $SYS_ROOT"
fi

SYSTEM_CONFIG_DIR="$SYS_ROOT/opt/macwave_config"
USER_CONFIG_DIR="$HOME/.config/macwave_config"
ARCH=$(uname -m)

# ==========================================
# 命令行参数（批量 / 脚本化卸载）
# ==========================================

CLI_FORCE=false
CLI_REMOVE_USER=false

usage() {
    cat <<'USAGE_EOF'
MacWave uninstaller

Usage:
  uninstall.sh [options]

Options:
      --force         No confirmation prompt. Removes MacWave and its
                      configuration.
      --remove-user   Accepted for compatibility with LinuxWave. MacWave has no
                      dedicated account, so this does nothing.
      -h, --help      Show this help.

Without options the uninstaller asks once before deleting; it needs a terminal
for that, so use --force when there is none (CI, scripts).

Exit codes:
  0  Uninstalled (also when MacWave was not installed).
  1  Usage error, or no terminal available to confirm on.
  2  Permission denied: sudo could not run.
  3  Partially removed; the items left behind are listed on stderr.

Running it straight from the repository (options go after '--'):
  /bin/bash -c "$(curl -fsSL <url>)" -- --force
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            CLI_FORCE=true
            ;;
        --remove-user)
            CLI_REMOVE_USER=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "🌊 Error: unknown option '$1'. Try --help." >&2
            exit 1
            ;;
    esac
    shift
done

# 用 `/bin/bash -c "$(curl ...)"` 运行时，第一个参数会变成脚本名（$0）：
#   /bin/bash -c "$(curl ...)" --force     ← --force 成了 $0，被静默丢掉
# 正确写法是加 `--`：它结束 bash 自身的选项，后面的参数才会传进脚本。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        echo "🌊 Warning: '$0' was treated as the script name, not as an option." >&2
        echo "🌊 Put uninstaller options after '--', which ends bash's own options." >&2
        echo "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" >&2
        ;;
esac

# 默认尝试删除的路径列表
BASE_DIRS=()

# 1. 如果配置文件存在，优先读取（系统级与用户级都读，两边都卸干净）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -f "$CONFIG_DIR/config.json" ]; then
        # `|| true` 不能省：赋值语句的退出码就是命令替换的退出码，在 `set -e` 下
        # 一次坏 JSON（或没有 python3）就会让整个卸载器静默退出、一个字节都不删。
        # 路径走 argv 而不是拼进源码：目录名里的引号不会把这段 Python 弄坏。
        READ_DIR="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as handle:
        print(json.load(handle).get("base_dir", "") or "")
except Exception:
    pass
' "$CONFIG_DIR/config.json" 2>/dev/null || true)"
        if [ -n "$READ_DIR" ]; then
            BASE_DIRS+=("$READ_DIR")
        fi
    fi
done

# 2. 如果读取失败（或文件不存在），把所有可能的路径都加入列表
if [ ${#BASE_DIRS[@]} -eq 0 ]; then
    BASE_DIRS+=("$HOME/.local/macwave")
    BASE_DIRS+=("$SYS_ROOT/opt/macwave")
    # Intel Mac 才有 /usr/local/macwave
    if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "amd64" ]]; then
        BASE_DIRS+=("$SYS_ROOT/usr/local/macwave")
    fi
fi

if [[ "$CLI_REMOVE_USER" == "true" ]]; then
    echo "🌊 --remove-user: MacWave has no dedicated account, nothing to remove."
fi

if [[ "$CLI_FORCE" == "true" ]]; then
    echo "🌊 --force: uninstalling without confirmation."
else
    echo -e "\033[1;31mYou are deleting MacWave, are you sure? [Y/n]\033[0m"
    # 从 /dev/tty 读，且读不到就**中止**：
    # 删除是不可逆的，stdin 是 EOF（< /dev/null、CI、被别的命令吃掉输入）时
    # 绝不能默认当成「同意」。无人值守的场景请显式用 --force。
    # `2>/dev/null` 写在输入重定向之前：没有控制终端时打开 /dev/tty 会失败，
    # 重定向按从左到右处理，先屏蔽 stderr 才不会喷出那行原始报错。
    if ! read -n 1 -r 2>/dev/null < /dev/tty; then
        echo
        echo -e "\033[1;31m🌊 No terminal available to confirm on. Nothing was deleted.\033[0m" >&2
        echo "🌊 To uninstall non-interactively, run again with --force." >&2
        exit 1
    fi
    echo
    if [[ -n "$REPLY" && ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "🌊 Uninstall cancelled."
        exit 0
    fi
fi

# 逐个尝试删除所有可能的路径
#
# 只删「看起来确实是 MacWave 安装」的目录：base_dir 来自 config.json，而用户级
# 配置对任何以该用户身份运行的进程都可写。若不校验就拿去 `sudo rm -rf`，
# 一条被改过的 base_dir 就能把 /usr/local 或家目录整片删掉 —— 与 install.sh
# 已经堵上的那类问题同一个形状，这里也必须堵。
#
# 判据是 lib/wave.py：只有安装树有它。判不出来就不删，并说清是哪一条挡住的。
skip_reason() {
    local dir="$1"
    if [[ -z "$dir" ]]; then
        echo "empty path"
    elif [[ "$dir" != /* ]]; then
        echo "not an absolute path"
    else
        case "$dir" in
            /|/usr|/usr/local|/opt|/etc|/bin|/sbin|/System|/Library)
                echo "a system directory" ;;
            "$HOME"|"$HOME"/)
                echo "your home directory" ;;
            *)
                [[ -f "$dir/lib/wave.py" ]] || echo "not a MacWave install (no lib/wave.py)" ;;
        esac
    fi
}

# ==========================================
# 失败记账：删除要「尽量多删、最后汇总」
# ==========================================
#
# 任何一个目标删不掉，都不该让后面的目标失去机会 —— 但也不能因此假装成功：
# 没删掉的记进清单，收尾时按「2 = 权限不足 / 3 = 部分失败」退出，清单写 stderr。
# 直接在循环里裸放 `rm -rf` 时，`set -e` 会让第一次失败就此退出，退出码是 rm
# 自己的 1，配置目录与 rc 清理根本轮不到。
FAILURE_LIST=()
PERMISSION_FAILURES=0
OTHER_FAILURES=0

mw_remove() {
    # mw_remove <path> [sudo]
    # 失败不中断流程，只记账；返回值恒为 0，调用点不必判断。
    local target="$1" how="${2:-}" err=""

    if [[ "$how" == "sudo" ]]; then
        echo "🌊 Removing $target (with sudo)..."
        # 只收 rm 的 stderr，sudo 的密码提示走 /dev/tty，交互不受影响。
        if LC_ALL=C sudo rm -rf -- "$target" 2>&1; then
            return 0
        fi
        # 走到这里基本都是提权失败（拿不到密码、没有终端、sudo 不可用）。
        PERMISSION_FAILURES=$((PERMISSION_FAILURES + 1))
        FAILURE_LIST+=("$target (sudo failed)")
        echo -e "\033[1;31m🌊 Error: could not remove $target (sudo failed).\033[0m" >&2
        echo "🌊   Run this in a terminal with a password available: sudo rm -rf $target" >&2
        return 0
    fi

    echo "🌊 Removing $target..."
    # 错误文本收进变量再判断：权限问题与其它失败要给不同的退出码与下一步，
    # 而判断必须落在 C locale 的英文报错上，否则换个语言就认不出来。
    if ! err="$(LC_ALL=C rm -rf -- "$target" 2>&1)"; then
        case "$err" in
            *"Permission denied"*|*"Operation not permitted"*)
                PERMISSION_FAILURES=$((PERMISSION_FAILURES + 1))
                FAILURE_LIST+=("$target (permission denied)")
                echo -e "\033[1;31m🌊 Error: permission denied while removing $target.\033[0m" >&2
                echo "🌊   Remove it yourself with: sudo rm -rf $target" >&2
                ;;
            *)
                OTHER_FAILURES=$((OTHER_FAILURES + 1))
                FAILURE_LIST+=("$target (could not be removed)")
                echo -e "\033[1;31m🌊 Error: could not remove $target.\033[0m" >&2
                echo "🌊   $err" >&2
                echo "🌊   Remove it yourself with: sudo rm -rf $target" >&2
                ;;
        esac
    fi
    return 0
}

for DIR in "${BASE_DIRS[@]}"; do
    if [ ! -d "$DIR" ]; then
        continue
    fi
    REASON="$(skip_reason "$DIR")"
    if [[ -n "$REASON" ]]; then
        echo -e "\033[33m🌊 Skipping $DIR: $REASON.\033[0m" >&2
        echo "🌊 Nothing was deleted there. If you are sure, remove it yourself." >&2
        continue
    fi
    # 如果是系统级目录，需要 sudo
    if [[ "$DIR" == "$HOME" || "$DIR" == "$HOME"/* ]]; then
        mw_remove "$DIR"
    else
        mw_remove "$DIR" sudo
    fi
done

# 删除配置目录（系统级与用户级都可能存在）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -d "$CONFIG_DIR" ]; then
        if [[ "$CONFIG_DIR" == "$HOME" || "$CONFIG_DIR" == "$HOME"/* ]]; then
            mw_remove "$CONFIG_DIR"
        else
            mw_remove "$CONFIG_DIR" sudo
        fi
    fi
done

# 清理 PATH 配置。要处理四种写法：
#   1. 4.2.x 及更早：`# MacWave` 注释行 + 紧随其后的 export PATH
#   2. 更早的版本：只有一行 export PATH，没有注释行
#   3. 4.3 起推荐给 POSIX shell 的：`eval "$(.../lib/wave shellenv)"`
#   4. 4.3 起推荐给 csh / tcsh 的：`if ( "$PATH" !~ *".../lib"* ) setenv PATH ...`
# 只删指向**本机 MacWave 安装目录**的行；别人的配置一句都不动。
for RC_FILE in "$HOME/.zshrc" "$HOME/.zprofile" \
               "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" \
               "$HOME/.profile" \
               "$HOME/.tcshrc" "$HOME/.cshrc" "$HOME/.login"; do
    if [ -f "$RC_FILE" ]; then
        if ! python3 - "$RC_FILE" "${BASE_DIRS[@]}" << 'PYEOF'
import sys
from pathlib import Path

rc_file = Path(sys.argv[1])
install_dirs = [d for d in sys.argv[2:] if d]
kept = []
skip_next = False
for line in rc_file.read_text().splitlines():
    if line.strip() == "# MacWave":
        skip_next = True
        continue
    if skip_next and line.startswith("export PATH="):
        skip_next = False
        continue
    skip_next = False
    # shellenv 写法：一行里同时出现 lib/wave 与 shellenv 才算我们给的
    if "lib/wave" in line and "shellenv" in line:
        continue
    # csh / tcsh 写法：带 !~ 守卫的 setenv，且指向本机安装目录
    if "setenv PATH" in line and "!~" in line and any(d in line for d in install_dirs):
        continue
    kept.append(line)
rc_file.write_text("\n".join(kept) + ("\n" if kept else ""))
PYEOF
        then
            # PATH 清理是尽力而为：python3 不可用（自带解释器刚被删掉时可能如此）
            # 或文件写不进去，都还有下面的 sed 兜底。不能让它把整次卸载变成
            # exit 1 —— 那既不符合退出码契约，也会盖掉前面已经记下的结果。
            echo "🌊 Warning: could not clean $RC_FILE with python3; trying the pattern fallback." >&2
        fi
        # 兜底：注释行缺失时，仍按旧版写法删掉 macwave 的 PATH 行
        sed -i '' -e '/export PATH=".*macwave\//d' \
                  -e '/setenv PATH .*macwave\//d' "$RC_FILE" 2>/dev/null || true
        echo "🌊 Removed MacWave PATH entries from $RC_FILE"
    fi
done

echo ""
if [[ ${#FAILURE_LIST[@]} -eq 0 ]]; then
    echo "🌊 MacWave has been uninstalled."
    echo "🌊 Please restart your terminal to apply changes."
else
    echo -e "\033[1;31m🌊 MacWave is only partially removed.\033[0m" >&2
    echo "🌊 The following items could not be removed:" >&2
    for _item in "${FAILURE_LIST[@]}"; do
        echo "🌊   $_item" >&2
    done
    echo "🌊 Everything else was removed. Restart your terminal to apply the PATH change." >&2
    echo "🌊 Fix the cause above, then run the uninstaller again." >&2
fi

# ========== 删除自身脚本 ==========
# 只有「脚本确实来自一个文件」时才有自己可删。用文档推荐的
# `/bin/bash -c "$(curl ...)"` 运行时，$0 是解释器路径（无参数）或 `--`（带参数），
# 直接 rm 会把 /bin/bash 删掉，所以这里逐条排除后再按内容确认一次。
if [[ -f "$0" && "$0" != "$BASH" && "$0" != --* ]] \
   && grep -q "MacWave Uninstaller" "$0" 2>/dev/null; then
    # 删自己失败不影响「有没有卸干净」，不能让它盖掉下面的退出码。
    rm -f "$0" || true
fi

# 0 = 卸载完成（包括「本来就没装」）；2 = 权限不足；3 = 部分失败（清单已在上面）。
# 3 优先于 2：一旦有非权限类失败，光提权也解决不了，用户需要看完整清单。
if [[ "$OTHER_FAILURES" -gt 0 ]]; then
    exit 3
fi
if [[ "$PERMISSION_FAILURES" -gt 0 ]]; then
    exit 2
fi
exit 0
