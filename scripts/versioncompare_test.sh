#!/bin/bash

# versioncompare_test.sh
# 版本比较只有一份实现：lib/versioncompare.py。这个脚本钉住它的语义，以及「确实只有一份」。
#
# 为什么需要它：版本号不是数字串，错法又只在特定串上显形 ——
#   * 预发布必须排在正式版**之下**（4.4.0-beta1 < 4.4.0）。按数字段比会得到相反
#     的结论，装过 beta 的人于是永远等不到正式版，平时怎么测都看不出来。
#   * 两段与三段等价（2.3 == 2.3.0），否则同一个包会因为写法不同被当成两个版本。
#   * 没编号的预发布要补 0（1.0.0-rc → rc0），否则直接是 InvalidVersion。
#   * 社区后缀（procursus / macwaveteam / Xteam）先归一化成 X.Y.Z.N 再比，
#     否则它们会退化成「读不出数字 = 0」，排序把最高版本判成最旧。
#   * 读不出来的串不许抛异常：上层要给的是「版本无效」这种能看懂的提示。
#
# 另外钉住合并本身：pkg/pkgversionparser.py 与 surfboard/depsversionparser.py 已经
# 并进来，仓库里不该再有它们；两者的公开名字仍要能从 versioncompare 取到，依赖引用
# 解析搬到 querier.py 后行为不变。
#
# 全程离线，不碰安装目录。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
HARD_FAIL=0

# -------------------- 1. 版本比较本身 --------------------
OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import sys

repo = sys.argv[1]
components = [line.split("#", 1)[0].strip()
              for line in open(f"{repo}/scripts/components.txt", encoding="utf-8")]
sys.path[:0] = [f"{repo}/{name}" for name in components if name]

import versioncompare as vc

passed = 0
failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"PASS: {label}")
    else:
        failed += 1
        print(f"FAIL: {label} -> got {got!r}, want {want!r}")


# ----- 基本序：数字段按数值比，不是按字典序 -----
check("2.10 > 2.9", vc.compare("2.10", "2.9"), 1)
check("2.10.0 > 2.9.0", vc.compare("2.10.0", "2.9.0"), 1)
check("相等的两个串", vc.compare("1.2.3", "1.2.3"), 0)
check("两段与三段等价", vc.compare("2.3", "2.3.0"), 0)
check("sort_key 两段与三段相等", vc.sort_key("2.3") == vc.sort_key("2.3.0"), True)

# ----- 预发布：一律低于同号正式版 -----
for text in ("4.4.0-beta1", "4.4.0b1", "4.4.0rc1", "4.4.0a1", "4.4.0.dev1"):
    check(f"{text} < 4.4.0", vc.sort_key(text) < vc.sort_key("4.4.0"), True)
check("dev1 < a1", vc.sort_key("4.4.0.dev1") < vc.sort_key("4.4.0a1"), True)
check("a1 < b1", vc.sort_key("4.4.0a1") < vc.sort_key("4.4.0b1"), True)
check("b1 < rc1", vc.sort_key("4.4.0b1") < vc.sort_key("4.4.0rc1"), True)
check("4.4.0 < 4.4.1", vc.sort_key("4.4.0") < vc.sort_key("4.4.1"), True)

# ----- 没编号的预发布补 0 -----
check("1.0.0-rc 可解析且低于 1.0.0", vc.sort_key("1.0.0-rc") < vc.sort_key("1.0.0"), True)
check("1.0.0-beta 低于 1.0.0", vc.sort_key("1.0.0-beta") < vc.sort_key("1.0.0"), True)
check("1.0.0-alpha 低于 1.0.0-beta", vc.sort_key("1.0.0-alpha") < vc.sort_key("1.0.0-beta"), True)
check("1.0.0-rc1 低于 1.0.0", vc.sort_key("1.0.0-rc1") < vc.sort_key("1.0.0"), True)

# ----- 社区后缀：归一化成 X.Y.Z.N -----
check("2.1.5-procursus7 > 2.1.5-procursus2",
      vc.sort_key("2.1.5-procursus7") > vc.sort_key("2.1.5-procursus2"), True)
check("procursus 后缀不退化（2.1.5-procursus7 > 2.1.4）",
      vc.sort_key("2.1.5-procursus7") > vc.sort_key("2.1.4"), True)
check("1.0-Xteam2 == 1.0.0.2", vc.sort_key("1.0-Xteam2") == vc.sort_key("1.0.0.2"), True)
check("1.0-macwaveteam1 == 1.0.0.1", vc.sort_key("1.0-macwaveteam1") == vc.sort_key("1.0.0.1"), True)
check("后缀大小写不敏感（XTEAM == Xteam）",
      vc.sort_key("1.0-XTEAM3") == vc.sort_key("1.0-Xteam3"), True)
check("下划线分隔也认（1.0_procursus2 == 1.0-procursus2）",
      vc.sort_key("1.0_procursus2") == vc.sort_key("1.0-procursus2"), True)
check("is_special_version 认出后缀", vc.is_special_version("1.0-Xteam1"), True)
check("普通版本不是 special", vc.is_special_version("1.2.3"), False)

# ----- 读不出来的串不抛异常 -----
check("1.8.2_1 退化成 1.8.2", vc.compare("1.8.2_1", "1.8.2"), 0)
check("纯字母当作 0", vc.version("abc") == vc.version("0"), True)
check("空串当作 0", vc.version("") == vc.version("0"), True)
check("前后空白被忽略", vc.compare(" 1.2 ", "1.2.0"), 0)

# ----- is_prerelease / is_newer -----
for text, want in [("4.4.0-beta2", True), ("4.4.0rc1", True), ("4.4.0.dev1", True),
                   ("4.4.0", False), ("1.2.3", False)]:
    check(f"is_prerelease({text})", vc.is_prerelease(text), want)
check("is_newer：没装过一律算新", vc.is_newer("1.0", None), True)
check("is_newer：空串也算没装", vc.is_newer("1.0", ""), True)
check("is_newer：更新的版本", vc.is_newer("1.1", "1.0"), True)
check("is_newer：更旧的版本", vc.is_newer("1.0", "1.1"), False)
check("is_newer：预发布低于正式版", vc.is_newer("4.4.0-beta1", "4.4.0"), False)

# ----- sort_versions / get_max_version -----
versions = ["1.0.0-rc", "1.0.0", "2.1.5-procursus7", "1.0-Xteam1",
            "1.0.0-alpha", "1.0.0-beta", "1.0.0-rc1"]
check("sort_versions 默认从高到低",
      vc.sort_versions(versions),
      ["2.1.5-procursus7", "1.0-Xteam1", "1.0.0", "1.0.0-rc1", "1.0.0-rc",
       "1.0.0-beta", "1.0.0-alpha"])
check("sort_versions 可反向", vc.sort_versions(["1.0", "2.0"], reverse=False), ["1.0", "2.0"])
check("get_max_version", vc.get_max_version(versions), "2.1.5-procursus7")
check("get_max_version 空输入", vc.get_max_version([]), None)
check("两段与三段在排序里同序",
      vc.get_max_version(["2.3.0", "2.3"]) in ("2.3.0", "2.3"), True)

# ----- 合并后公开名字仍然齐 -----
for name in ("version", "sort_key", "compare", "is_prerelease", "is_newer",
             "sort_versions", "get_max_version", "safe_parse_pkg_version",
             "is_special_version", "handle_pre_release", "extract_special_info",
             "safe_parse_special_version"):
    check(f"versioncompare.{name} 存在", callable(getattr(vc, name, None)), True)

print(f"# summary {passed} {failed}")
PYEOF
)

[[ $? -eq 0 ]] || { HARD_FAIL=$((HARD_FAIL + 1)); echo -e "${RED_BOLD}🌊 FAIL: 版本比较段 python 异常退出${RESET}"; }

echo "$OUTPUT" | grep -v '^PASS: \|^FAIL: \|^NOTE: \|^#\|^$'
PASSED=$((PASSED + $(echo "$OUTPUT" | grep -c '^PASS: ')))
FAILED=$((FAILED + $(echo "$OUTPUT" | grep -c '^FAIL: ')))
echo "$OUTPUT" | grep '^FAIL: '
echo "$OUTPUT" | grep '^NOTE: '

# -------------------- 2. 只剩一份实现 --------------------
for stale in pkg/pkgversionparser.py surfboard/depsversionparser.py lib/versioncmp.py; do
    if [[ -e "$REPO_DIR/$stale" ]]; then
        FAILED=$((FAILED + 1))
        echo "FAIL: $stale 仍在仓库里（版本逻辑应当只有 lib/versioncompare.py 一份）"
    else
        PASSED=$((PASSED + 1))
        echo "PASS: $stale 已移除"
    fi
done

# 出货代码里不许再 import 这几个模块名（注释里提到历史不算：只查 import 语句）
COMPONENT_DIRS=()
while read -r dir; do
    [[ -n "$dir" ]] && COMPONENT_DIRS+=("$REPO_DIR/$dir")
done < <(sed -e 's/#.*//' "$REPO_DIR/scripts/components.txt" | tr -d ' ' | grep -v '^$')
COMPONENT_DIRS+=("$REPO_DIR/scripts")

STALE_HITS=$(grep -rn "^[[:space:]]*\(import\|from\) \(pkgversionparser\|depsversionparser\|versioncmp\)" \
    "${COMPONENT_DIRS[@]}" 2>/dev/null)
if [[ -n "$STALE_HITS" ]]; then
    FAILED=$((FAILED + 1))
    echo "FAIL: 仍有代码导入已删除的模块："
    echo "$STALE_HITS"
else
    PASSED=$((PASSED + 1))
    echo "PASS: 没有代码导入已删除的版本模块"
fi

# -------------------- 3. 依赖引用解析（从 depsversionparser 搬到 querier） --------------------
# `import querier` 在模块级就会调 load_base_dir()：找不到配置文件直接 sys.exit(1)。
# CircleCI 刻意保持零配置，所以那里必须造一份；本机已有配置时不要覆盖（一律伪造
# 会让 python 找不到用户级 site-packages）。
CONFIG_PROBE=(/opt/macwave_config/config.json "$HOME/.config/macwave_config/config.json")
NEED_FAKE_HOME=1
for candidate in "${CONFIG_PROBE[@]}"; do
    [[ -f "$candidate" ]] && NEED_FAKE_HOME=0
done
if [[ "$NEED_FAKE_HOME" -eq 1 ]]; then
    export HOME="$WORK/home"
    mkdir -p "$HOME/.config/macwave_config" "$WORK/base/bin"
    printf '{"base_dir": "%s"}\n' "$WORK/base" > "$HOME/.config/macwave_config/config.json"
fi

OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import sys

repo = sys.argv[1]
components = [line.split("#", 1)[0].strip()
              for line in open(f"{repo}/scripts/components.txt", encoding="utf-8")]
sys.path[:0] = [f"{repo}/{name}" for name in components if name]

from querier import parse_dep_ref, parse_dep_refs

passed = 0
failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"PASS: {label}")
    else:
        failed += 1
        print(f"FAIL: {label} -> got {got!r}, want {want!r}")


check("名字@版本号", parse_dep_ref("openssl@3.0.15"), ("openssl", "3.0.15"))
check("去掉引号与空白", parse_dep_ref('  "openssl@3.0.15" '), ("openssl", "3.0.15"))
check("名字里的 . 与 - 合法", parse_dep_ref("libfoo-dev@1.2.3.4"), ("libfoo-dev", "1.2.3.4"))
check("批量解析跳过空行",
      parse_dep_refs(["a@1", "", "   ", "b@2"]), [("a", "1"), ("b", "2")])
check("批量解析保持原顺序", parse_dep_refs(["z@1", "a@2"]), [("z", "1"), ("a", "2")])

print(f"# summary {passed} {failed}")
PYEOF
)

[[ $? -eq 0 ]] || { HARD_FAIL=$((HARD_FAIL + 1)); echo -e "${RED_BOLD}🌊 FAIL: 依赖引用段 python 异常退出${RESET}"; }

PASSED=$((PASSED + $(echo "$OUTPUT" | grep -c '^PASS: ')))
FAILED=$((FAILED + $(echo "$OUTPUT" | grep -c '^FAIL: ')))
echo "$OUTPUT" | grep '^FAIL: '

# 不合法的引用必须退出 1，并说清期望的格式
for bad in "noseparator" "@1.0" "openssl@"; do
    OUT=$("$PYTHON" - "$REPO_DIR" "$bad" <<'PYEOF' 2>&1
import sys

repo, bad = sys.argv[1], sys.argv[2]
components = [line.split("#", 1)[0].strip()
              for line in open(f"{repo}/scripts/components.txt", encoding="utf-8")]
sys.path[:0] = [f"{repo}/{name}" for name in components if name]

from querier import parse_dep_ref
parse_dep_ref(bad)
print("NOT-REJECTED")
PYEOF
)
    RC=$?
    if [[ $RC -eq 1 && "$OUT" == *"Expected format"* && "$OUT" != *"NOT-REJECTED"* ]]; then
        PASSED=$((PASSED + 1))
        echo "PASS: 拒绝非法依赖引用 '$bad'（exit 1 且给出期望格式）"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: 非法依赖引用 '$bad' 的拒绝行为不对（exit ${RC}）-> $OUT"
    fi
done

FAILED=$((FAILED + HARD_FAIL))

# 渠道与构建号：RC 与正式版各读自己的探针，同一个版本靠构建号区分先后
OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF' 2>&1
import sys

repo = sys.argv[1]
components = [line.split("#", 1)[0].strip()
              for line in open(f"{repo}/scripts/components.txt", encoding="utf-8")]
sys.path[:0] = [f"{repo}/{name}" for name in components if name]

from versioncompare import channel_for, build_key, is_newer_build, newer_release

passed = 0
failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"PASS: {label}")
    else:
        failed += 1
        print(f"FAIL: {label} -> got {got!r}, want {want!r}")


check("rc 后缀是 RC 渠道", channel_for("4.4.1-rc"), "rc")
check("beta 仍是「不许 selfupdate」那条路（没有自己的探针）",
      channel_for("4.4.0-beta2"), "beta")
check("dev 同上", channel_for("4.4.0.dev1"), "beta")
check("带编号的 rc 也是 RC 渠道", channel_for("4.4.1-rc1"), "rc")
check("正式版是正式渠道", channel_for("4.4.1"), "stable")
check("没装按正式渠道", channel_for(""), "stable")
check("构建号解析（RC 的 R）", build_key("323R1250"), (323, 1250))
check("构建号解析（正式版的周几）", build_key("323D1250"), (323, 1250))
check("构建号坏值返回 None", build_key("323X"), None)
check("晚一分钟是新的", is_newer_build("323R1251", "323R1250"), True)
check("同一个不是新的", is_newer_build("323R1250", "323R1250"), False)
check("跨天按天数算", is_newer_build("324R0001", "323R2359"), True)
check("本机没有构建号时接受探针", is_newer_build("323R1250", ""), True)
check("探针构建号坏了不接受", is_newer_build("", "323R1250"), False)
check("版本更新时忽略构建号", newer_release("4.4.1", "320D0900", "4.4.0", "323R1250"), True)
check("版本相同才比构建号", newer_release("4.4.1-rc", "323R1300", "4.4.1-rc", "323R1250"), True)
check("版本相同构建号也相同 = 没有新版",
      newer_release("4.4.1-rc", "323R1250", "4.4.1-rc", "323R1250"), False)
check("RC 之上是正式版", newer_release("4.4.1", "323D1250", "4.4.1-rc", "323R1250"), True)
check("正式版不会退回 RC", newer_release("4.4.1-rc", "323R1250", "4.4.1", "323D1250"), False)

print(f"# summary {passed} {failed}")
PYEOF
)

[[ $? -eq 0 ]] || { HARD_FAIL=$((HARD_FAIL + 1)); echo -e "${RED_BOLD}🌊 FAIL: 渠道/构建号段 python 异常退出${RESET}"; }
PASSED=$((PASSED + $(echo "$OUTPUT" | grep -c '^PASS: ')))
FAILED=$((FAILED + $(echo "$OUTPUT" | grep -c '^FAIL: ')))
echo "$OUTPUT" | grep '^FAIL: '

FAILED=$((FAILED + HARD_FAIL))

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All version comparison tests passed${RESET}"
