#!/bin/bash
# MacWave Uninstaller
# 卸载 MacWave 及清理环境配置

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
        READ_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_DIR/config.json')).get('base_dir', ''))" 2>/dev/null)
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
    if [[ "$DIR" == "$HOME"* ]]; then
        echo "🌊 Removing $DIR..."
        rm -rf "$DIR"
    else
        echo "🌊 Removing $DIR (with sudo)..."
        sudo rm -rf "$DIR"
    fi
done

# 删除配置目录（系统级与用户级都可能存在）
for CONFIG_DIR in "$SYSTEM_CONFIG_DIR" "$USER_CONFIG_DIR"; do
    if [ -d "$CONFIG_DIR" ]; then
        if [[ "$CONFIG_DIR" == "$HOME"* ]]; then
            echo "🌊 Removing $CONFIG_DIR..."
            rm -rf "$CONFIG_DIR"
        else
            echo "🌊 Removing $CONFIG_DIR (with sudo)..."
            sudo rm -rf "$CONFIG_DIR"
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
        python3 - "$RC_FILE" "${BASE_DIRS[@]}" << 'PYEOF'
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
        # 兜底：注释行缺失时，仍按旧版写法删掉 macwave 的 PATH 行
        sed -i '' -e '/export PATH=".*macwave\//d' \
                  -e '/setenv PATH .*macwave\//d' "$RC_FILE" 2>/dev/null || true
        echo "🌊 Removed MacWave PATH entries from $RC_FILE"
    fi
done

echo ""
echo "🌊 MacWave has been uninstalled."
echo "🌊 Please restart your terminal to apply changes."

# ========== 删除自身脚本 ==========
# 只有「脚本确实来自一个文件」时才有自己可删。用文档推荐的
# `/bin/bash -c "$(curl ...)"` 运行时，$0 是解释器路径（无参数）或 `--`（带参数），
# 直接 rm 会把 /bin/bash 删掉，所以这里逐条排除后再按内容确认一次。
if [[ -f "$0" && "$0" != "$BASH" && "$0" != --* ]] \
   && grep -q "MacWave Uninstaller" "$0" 2>/dev/null; then
    rm -f "$0"
fi
exit 0
