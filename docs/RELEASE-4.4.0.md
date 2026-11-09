# MacWave 4.4.0 Release Notes

- Released: 2026-11-09, build `313B1740`
- Branch: `4.4` (cut from the `4.3` line; `v4.3.2` stays at `e74921c`)
- Previous release: [4.3.2](RELEASE-4.3.2.md)

## What is in it

Three things, and only one of them is new work:

1. **The fixes first shipped in 4.3.2**, unchanged — see [RELEASE-4.3.2](RELEASE-4.3.2.md)
   for the evidence. That is why the title carries a security prefix: on 4.3.0 / 4.3.1 this
   release is the shortest way out. **No new vulnerability is involved in 4.4.0 itself.**
2. **The internals were split up.** Nothing users type changed; the code that decides how
   it behaves is no longer all in one file — neither the entry point (§1, §2) nor the
   argument handling (§3).

### 1. `wave.py` only reads a command and hands it over

`lib/wave.py` had grown into three jobs at once: parse arguments, hold the command table,
and carry two heuristics tables. The last one does not belong in an entry point, so it moved:

| Module | Owns | Called by |
| --- | --- | --- |
| `lib/silent.py` | `-s` / `-S`: which commands may be silenced, how the flags are stripped (`-sX`, `-CsX`), and applying the result | `wave.py` only |
| `lib/suggest.py` | "did you mean": command names (typo table + spelling) and package names (edit distance + similarity) | `wave.py`, `pkg/pkginstaller.py`, `lib/latest.py` |
| `lib/quiet.py` | unchanged — the runtime output gate (`say` / `ask` / `silence_everything`) | `pkg/`, `surfboard/` |

```
lib/wave.py   355 → 213 lines
lib/silent.py      108 lines   (new)
lib/suggest.py     151 lines   (new)
```

The split is also a correctness boundary: "which commands accept `-s`" used to live inside
the dispatcher, so touching the silent rules meant editing the file that every command goes
through. It now sits in one module that only the entry point imports.

### 2. One package-name matcher instead of two

`wave install` and `wave latest` both answer "did you mean this package?", and they did it
with two different implementations — a hand-written Levenshtein + similarity score in
`pkg/pkginstaller.py`, and `difflib.get_close_matches(cutoff=0.6)` in `lib/latest.py`.
Same question, two answers, and only one of them was ever tuned.

There is now one: `suggest.closest_name()`.

Measured over **12,432** single-character typos of the 47 `arm64` package names (every name
× every position × `a-z0-9-_`), asking each implementation for its one suggestion:

| Path | Before | After |
| --- | --- | --- |
| `wave install <typo>` | 97.6% (hand-written matcher) | 97.6% — same function, moved |
| `wave latest <typo>` | 94.7% (`difflib`, cutoff 0.6) | 97.6% — now the same matcher |

Of the 667 answers that changed, **363** now land on the name the user meant when `latest`
used to suggest a different one; **108** go the other way, and every one of those is a tie
between two names that are both one edit away — `wave latest atop` answers `btop` where it
used to answer `htop`. Either answer is defensible; there is no case where the new matcher
loses to a distance the old one got right.

The install path is unchanged by construction (the function was moved, not rewritten), apart
from one deliberate difference: a query identical to a name in the list is no longer
suggested back. That case cannot occur on this path — if the name exists, there is no 404 to
explain.

### 3. One tokenizer instead of four

Deciding what is a flag and what is a package name was implemented four times — once in
each command's own argument loop:

| Place | What it had to handle |
| --- | --- |
| `pkginstaller.parse_flags` | `--name=value`, `-abc`, and a bare `-` that ends the flag list |
| `silent.strip` | pulling `s` / `S` out of a cluster (`-sX`, `-CsX`) |
| `upgrader.split_input` | pulling `X` / `a` out of a cluster (`-Xv`) |
| `latest.split_arguments` | long form with `=`, and letter-by-letter clusters |
| `pkginfohelper` | `word.partition("=")[0]` |

Each one only knew the letters it cared about, so a rule learned in one place had to be
relearned in the next: `-sX` had to work in `silent` *and* be recognised as a valid cluster
by `install`, and those were two separate pieces of code that could disagree.

`lib/flags.py` now owns the rules (`flag_name` / `split` / `tokens` / `short_cluster` /
`remove_short`). They are pure functions — no printing, no `sys.exit`, no config — which is
what lets `pkg/` and `lib/` both use them. The flag catalogue that was already in that file
stays exactly as it was: **diagnostics only**, never validation.

One fact also stopped being stored twice. "Which commands may be silenced" was written out by
hand in `silent.apply()` and contradicted by the flag catalogue, which filed `-s` under "every
command accepts it". It is now a per-command group in the catalogue, so
`flags.describe("-s")` produces that sentence — byte for byte the same string the code used to
build by hand, and the silent commands are no longer claimed to be all of them. Adding a
read-only command no longer leaves a hole nothing tests.

Nothing about behaviour was rewritten, so the change was checked by equivalence rather than
by re-reading: the old and new implementations were run side by side over **26,930**
argument combinations (`-sX`, `-CsX`, `-Xa`, `--max-time=1min`, a bare `-`, unknown flags,
mixed with package names) and every pair of outputs was identical. The four single cases
that differ at all are the ones where the *old* code differed from itself.

### 4. What did not change

Checked by hand after the split, not inferred from a green build:

```
$ wave list -s
wave: -s only applies to wave install, wave link, wave selfupdate, wave uninstall, wave unlink, wave upgrade
$ wave upgrade jq -sX          # -sX still merges into -s; nothing printed
$ wave -s update jq
wave: unknown command: update  # silent keeps errors, drops 🌊
```

`wave instal jq` still prints the caret line under the misspelt word and still suggests
`install`; `-sS` still prints the error without the leading 🌊.

## Upgrading

```bash
wave selfupdate
```

A minor release re-downloads **all 32** program files rather than a delta (the same
convention as 4.2.0 and 4.3.0), so a client on any 4.x — 4.3.0, 4.3.1 or 4.3.2 — lands on a
complete tree in one step. The two new modules are listed first in that download, so an
interrupted update cannot leave a tree whose `wave.py` imports a file that is not there yet.

## Regression

| Suite | Assertions |
| --- | --- |
| `bash scripts/message_test.sh` | 61 |
| `bash scripts/suggest_test.sh` | 3 (now imports `lib/suggest.py` directly) |
| `bash scripts/flags_test.sh` | 12, §8 pins the tokenizer's return shapes |
| `bash scripts/dir_guard_test.sh` | 72 |
| `flags` / `latest` / `info_format` / `configpath` / `structure` / `net_policy` / `markdown` / `shell_lint` | all green |

`wave.py` is the one file every command goes through, so beyond the suites above the entry
point was smoke-tested by hand for each dispatch branch: unknown command, misspelt command,
`--help` per command, `-s` / `-S` placement before and after the command, and a read-only
command given `-s`. The same for the four parsers in §3: a bad long flag, `-X` used on
`install`, `-av` on `latest`, `--json` with `--raw` on `info`, and `mirror` keeping its own
mutually exclusive formats.

---

# MacWave 4.4.0 发布说明

- 发布：2026-11-09，构建号 `313B1740`
- 分支：`4.4`（从 `4.3` 这条线切出；`v4.3.2` 的 tag 仍在 `e74921c`）
- 上一版：[4.3.2](RELEASE-4.3.2.md)

## 这一版有什么

三件事，只有一件是新做的：

1. **4.3.2 首发的那些修复**，原样带过来 —— 证据见
   [RELEASE-4.3.2](RELEASE-4.3.2.md)。标题带安全前缀就是这个原因：对还在 4.3.0 / 4.3.1
   上的人来说，这一版是最短的出路。**4.4.0 本身不涉及新的漏洞。**
2. **内部结构拆开了。** 用户敲的东西一个都没变，但「决定行为的那部分代码」不再全挤在
   一个文件里 —— 入口（第 1、2 节）与参数处理（第 3 节）都是。

### 1. `wave.py` 只负责「读一个命令、交出去」

`lib/wave.py` 已经长成三件事叠在一起：解析参数、持有命令表、还背着两张启发式表。
最后一件不属于入口，所以搬走了：

| 模块 | 管什么 | 谁调用 |
| --- | --- | --- |
| `lib/silent.py` | `-s` / `-S`：哪些命令能静默、怎么剥旗标（`-sX`、`-CsX`）、剥完怎么落地 | 只有 `wave.py` |
| `lib/suggest.py` | 「你是不是想敲……」：命令名（误用表 + 拼写）、包名（编辑距离 + 相似度） | `wave.py`、`pkg/pkginstaller.py`、`lib/latest.py` |
| `lib/quiet.py` | 没动 —— 运行期的输出闸门（`say` / `ask` / `silence_everything`） | `pkg/`、`surfboard/` |

```
lib/wave.py   355 → 213 行
lib/silent.py      108 行   （新增）
lib/suggest.py     151 行   （新增）
```

拆开也是一条边界：以前「哪些命令接受 `-s`」写在分发器里，改静默规则就得动那个所有命令
都要经过的文件；现在它待在一个只被入口导入的模块里。

### 2. 包名纠错只剩一份实现

`wave install` 与 `wave latest` 回答的是同一个问题「你是不是想装这个包」，却用了两套
实现 —— `pkg/pkginstaller.py` 里手写的 Levenshtein + 相似度，和 `lib/latest.py` 里的
`difflib.get_close_matches(cutoff=0.6)`。同样的问题、两个答案，而且只有一边被调过参。

现在是同一个：`suggest.closest_name()`。

测法是拿 47 个 `arm64` 包名的 **12,432** 组单字母错拼（每个名字 × 每个位置 ×
`a-z0-9-_`），逐个问两套实现「你给哪个名字」：

| 路径 | 改之前 | 改之后 |
| --- | --- | --- |
| `wave install <错拼>` | 97.6%（手写匹配） | 97.6% —— 同一个函数，只是搬了位置 |
| `wave latest <错拼>` | 94.7%（`difflib`，cutoff 0.6） | 97.6% —— 换成同一个匹配 |

667 处答案变了，其中 **363** 处是「本来给的是另一个包，现在给对了」；**108** 处反过来，
而且这 108 处全是「两个名字都只差一个编辑」的平手 —— `wave latest atop` 以前答 `htop`，
现在答 `btop`。两个都说得通，没有一处是新匹配输给了旧匹配本来答对的距离。

install 那条路径按构造是不变的（函数是搬过去的，不是重写）。只有一处有意为之的差别：
查询与清单里某个名字完全相同时，不再把这个名字建议回来 —— 这条路径上不可能出现这种
情况（名字存在就不会 404 到这里）。

### 3. 参数拆解只剩一份实现

「哪个是旗标、哪个是包名」这件事以前实现了四遍，每个命令在自己的参数循环里各写一遍：

| 位置 | 它得处理什么 |
| --- | --- |
| `pkginstaller.parse_flags` | `--name=value`、`-abc`、以及终止旗标列表的单独 `-` |
| `silent.strip` | 从簇里抠出 `s` / `S`（`-sX`、`-CsX`） |
| `upgrader.split_input` | 从簇里抠出 `X` / `a`（`-Xv`） |
| `latest.split_arguments` | 带 `=` 的长写法、逐字母拆的短簇 |
| `pkginfohelper` | 一句 `word.partition("=")[0]` |

每份实现只认得自己关心的那几个字母，于是「在 A 处学到的规则得在 B 处再学一遍」：
`-sX` 既要能在 `silent` 里被剥掉、又要能被 `install` 认成合法簇，而这是两段可以互不
一致的代码。

现在这套规则归 `lib/flags.py`（`flag_name` / `split` / `tokens` / `short_cluster` /
`remove_short`）。它们是纯函数 —— 不打印、不 `sys.exit`、不读配置 —— 所以 `pkg/` 与
`lib/` 都能直接用。这个文件里原本就有的那张旗标清单**一个字没动**：它只用于诊断，
从不参与校验。

顺带让一个事实不再存两份。「哪些命令能静默」原本在 `silent.apply()` 里手拼成一句话，
而旗标清单却把 `-s` 记在「任何命令都接受」那一组里 —— 两处互相矛盾。现在它按命令列进
清单，`flags.describe("-s")` 就能生成那句话：与手拼的字符串逐字节相同，同时不再宣称
所有命令都认 `-s`。以后加一条只读命令，不会留下一个没人测得到的窟窿。

行为没有被重写，所以验证方式是「对照」而不是「重读一遍」：把新旧实现并排跑
**26,930** 组参数组合（`-sX`、`-CsX`、`-Xa`、`--max-time=1min`、单独的 `-`、未知旗标、
与包名混着来），逐组比对输出，全部一致。唯一有差异的四组，是**旧代码自己跟自己**
对不上的那几处。

### 4. 什么没变

下面这些是拆完之后手敲出来的，不是「CI 绿了所以大概没变」：

```
$ wave list -s
wave: -s only applies to wave install, wave link, wave selfupdate, wave uninstall, wave unlink, wave upgrade
$ wave upgrade jq -sX          # -sX 仍合并成 -s，零输出
$ wave -s update jq
wave: unknown command: update  # 静默保留错误，只剥掉 🌊
```

`wave instal jq` 仍然在拼错的那个词下面打 `^^^` 并提示 `install`；`-sS` 仍然打错误但不带
开头的 🌊。

## 升级方式

```bash
wave selfupdate
```

次版本号发布下载的是**全部 32 个**程序文件而不是差量（4.2.0、4.3.0 都是这个约定），所以
任何 4.x 客户端 —— 4.3.0、4.3.1、4.3.2 —— 一次就能落到完整的树上。两个新模块排在这份
下载清单的最前面，中途失败也不会留下「`wave.py` import 一个还没下到的模块」的状态。

## 回归

| 脚本 | 断言数 |
| --- | --- |
| `bash scripts/message_test.sh` | 61 |
| `bash scripts/suggest_test.sh` | 3（改成直接导入 `lib/suggest.py`） |
| `bash scripts/flags_test.sh` | 12，第 8 节钉住拆解函数的返回形状 |
| `bash scripts/dir_guard_test.sh` | 72 |
| `flags` / `latest` / `info_format` / `configpath` / `structure` / `net_policy` / `markdown` / `shell_lint` | 全绿 |

`wave.py` 是所有命令都要过的那个文件，所以除上面的脚本外，每条分发分支都手工冒烟过：
未知命令、拼错命令、各命令的 `--help`、`-s`/`-S` 放在命令前后两种位置、以及给只读命令
加 `-s`。第 3 节那四个解析器同理：长旗标写错、`install` 用 `-X`、`latest` 的 `-av`、
`info` 同时给 `--json` 与 `--raw`、以及 `mirror` 自己那几组互斥格式。
