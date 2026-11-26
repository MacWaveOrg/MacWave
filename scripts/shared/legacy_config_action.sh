#!/bin/bash

# legacy_config_action.sh —— 4.7 迁移「旧版外部配置目录」的**唯一判据**。
#
# 为什么单独一个文件：这段判断要在三个地方跑，而它们各自是独立的可执行脚本
# （都是被 curl 下来直接执行的，没法 source 本地文件），所以只能各带一份副本。
# 副本一定会漂移 —— 2026-11-24 就吃过「同一个判据在两处有两种写法」的亏。
# 所以正文只在这里维护，三份副本由 scripts/check_shared_blocks.py 逐字节比对，
# CI 里不一致就红。
#
# 用法：
#
#   mw_legacy_config_action <安装根> <state 文件> <旧配置目录>
#
# 输出一行，三种之一：
#
#   none            没有旧配置，或它已经不存在 —— 什么都不用做
#   other:<路径>    旧配置属于**另一份**安装 —— 一律保留，不许动
#   clear           旧配置就是这棵树的 —— 调用方可以清理它
#
# 判定规则（只在这里定义，三个调用点不得各自加条件）：
#
#   1. <state 文件> 不存在 → none。刚装/刚升级但状态还没落盘时删掉旧配置，
#      等于把这棵树的位置信息一起删了，wave 会立刻报「没装」。
#   2. 旧目录里没有 config.json → none。没有 base_dir 可读，无所谓属于谁。
#   3. 读不出 base_dir、或读出来是空 → none（读不懂就不动它）。
#   4. base_dir 与本树安装根**字面相同** → clear；否则 other:<base_dir>。
#      用字面比较而不是 realpath：树常常是个软链接（/opt/macwave 指向别的卷），
#      realpath 之后两边都可能变，反而更容易误判成「另一份安装」。
#
# >>> SHARED: legacy-config-action
mw_legacy_config_action() {
    local base_dir="$1" state_file="$2" legacy_dir="$3"

    [[ -n "$state_file" && -f "$state_file" ]] || { printf 'none\n'; return 0; }
    [[ -n "$legacy_dir" && -f "$legacy_dir/config.json" ]] || { printf 'none\n'; return 0; }

    local recorded
    recorded="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("base_dir", "") or "")
except Exception:
    print("")' "$legacy_dir/config.json" 2>/dev/null)"

    if [[ -z "$recorded" ]]; then
        printf 'none\n'
        return 0
    fi
    if [[ "$recorded" == "$base_dir" ]]; then
        printf 'clear\n'
    else
        printf 'other:%s\n' "$recorded"
    fi
}
# <<< SHARED
