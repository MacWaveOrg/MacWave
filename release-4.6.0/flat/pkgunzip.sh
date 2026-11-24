#!/bin/bash

# pkgunzip.sh - 负责解压预编译软件包（压缩包）
# 用法: bash pkgunzip.sh <压缩包路径> <解压目录>
#
# 安全规则（SECURITY.md / AGENTS.md）：解压出来的**符号链接**必须逐个检查目标是否
# 落在 base_dir 之外，除了 /bin /sbin /usr/bin /usr/sbin /usr/lib /usr/libexec
# /System /Library/Apple 这几处（SIP 保护，且不含隐私文件）。越界链接要拒绝。
#
# 本脚本目前**没有**这道检查，各分支能把越界链接解出来。改这里时按上面规则处理：
# 落点在 base_dir 内或上述系统位置 → 放行；其它 → 拒绝并指出是哪个成员、指向哪里。

set -e

# 颜色定义
RED_BOLD='\033[1;31m'
RESET='\033[0m'

ARCHIVE_PATH="$1"
EXTRACT_DIR="$2"

if [[ -z "$ARCHIVE_PATH" || -z "$EXTRACT_DIR" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Missing archive path or extract directory.${RESET}"
    exit 1
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo -e "${RED_BOLD}🌊 Error: Archive file not found: $ARCHIVE_PATH${RESET}"
    exit 1
fi

# 确保解压目录存在
mkdir -p "$EXTRACT_DIR"

# 根据文件后缀选择解压命令
case "$ARCHIVE_PATH" in
    *.zip)
        unzip -q "$ARCHIVE_PATH" -d "$EXTRACT_DIR"
        ;;
    *.tar.gz|*.tgz)
        tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.tar.bz2|*.tbz2)
        tar -xjf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.tar.xz|*.txz)
        tar -xJf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.tar)
        tar -xf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    *.gz)
        gzip -dk "$ARCHIVE_PATH" -c > "$EXTRACT_DIR/$(basename "${ARCHIVE_PATH%.gz}")"
        ;;
    *.bz2)
        bzip2 -dk "$ARCHIVE_PATH" -c > "$EXTRACT_DIR/$(basename "${ARCHIVE_PATH%.bz2}")"
        ;;
    *.xz)
        # macOS 不自带 xz 命令，改用 Python 标准库 lzma（裸 .xz，非 .tar.xz）
        python3 - "$ARCHIVE_PATH" "$EXTRACT_DIR/$(basename "${ARCHIVE_PATH%.xz}")" << 'PYEOF'
import lzma
import shutil
import sys

with lzma.open(sys.argv[1], 'rb') as source, open(sys.argv[2], 'wb') as target:
    shutil.copyfileobj(source, target)
PYEOF
        ;;
    *.conda)
        # .conda 是 conda 的第二种包格式：本质是个 zip，里面装两个 zstd 压缩的 tar，
        # pkg-*.tar.zst 才是要落盘的载荷，info-*.tar.zst 只是元数据。
        # zstd 用 Python 3.14 的标准库 compression.zstd（macOS 不自带 zstd 命令）。
        python3 - "$ARCHIVE_PATH" "$EXTRACT_DIR" << 'PYEOF'
import os
import sys
import tarfile
import zipfile

try:
    from compression import zstd
except ImportError:
    print("🌊 Error: .conda packages need Python 3.14 or newer.", file=sys.stderr)
    sys.exit(1)

archive_path, extract_dir = sys.argv[1], sys.argv[2]

with zipfile.ZipFile(archive_path) as archive:
    payloads = [name for name in archive.namelist()
                if os.path.basename(name).startswith('pkg-') and name.endswith('.tar.zst')]
    if not payloads:
        print("🌊 Error: no pkg-*.tar.zst found inside the .conda archive.", file=sys.stderr)
        sys.exit(1)

    with archive.open(payloads[0]) as raw:
        with zstd.ZstdFile(raw, 'rb') as decompressed:
            # filter='tar'：保留符号链接（conda 包里大量使用），但仍会挡掉
            # `../` 这类危险**路径**。
            #
            # 注意它**不检查链接目标**：实测 Python 3.15 下，
            #   filter='tar'   → `lib/x -> /Users/someone/.ssh/id_rsa` 照样解出来
            #   filter='data'  → 拒绝（AbsoluteLinkError），但 conda 包要用的合法
            #                    链接会一起被拒，所以不能直接换
            # 也就是说越界链接的检测必须**解压之后**自己做一遍，不能指望 filter。
            #
            # 规则见 SECURITY.md「Symbolic links: the rule and its one exception」与
            # AGENTS.md「安全：符号链接不得跳出 base_dir」：任何解析后落在 base_dir
            # 之外的链接都要拒绝，只有 /bin /sbin /usr/bin /usr/sbin /usr/lib
            # /usr/libexec /System /Library/Apple 例外（SIP 保护且不含隐私文件）。
            # 下面这些 shell 分支（unzip / tar）连 `../` 都靠工具自己，更没有链接检查。
            with tarfile.open(fileobj=decompressed, mode='r|') as tar:
                tar.extractall(extract_dir, filter='tar')
PYEOF
        ;;
    *)
        echo -e "${RED_BOLD}🌊 Error: Unsupported archive format: $ARCHIVE_PATH${RESET}"
        exit 1
        ;;
esac

echo "🌊 Extraction successful!"
exit 0
