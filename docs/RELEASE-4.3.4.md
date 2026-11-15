# MacWave 4.3.4 Release Notes

- Released: 2026-11-15, build `319G1644`
- Branch: `4.3`
- Previous release: [4.3.3](RELEASE-4.3.3.md)
- **Fix**: a damaged installation could not be repaired by any command

## Bottom line first

If your install tree is missing one file — a half-finished update, a Ctrl-C, a
skipped-version upgrade, or two lines of MacWave mixed together — then up to 4.3.3
**nothing could fix it**:

- `wave` could not start, so `wave selfupdate` was not available;
- `install.sh` "succeeded" but downloaded **one** file, because it decided
  "upgrade" vs "fresh install" by a single existence test.

You ended up in a loop where every attempt reported success and nothing changed.

| Situation | 4.3.3 and earlier | 4.3.4 |
| --- | --- | --- |
| Tree complete, same version | "Already at", no download | same |
| Tree missing a file, same version | ✅ **"Already at" — never repaired** | reinstalls everything |
| Tree exists but incomplete | ✅ **delta only — the missing file stays missing** | full install |
| Upgrade that skips versions | ✅ **delta of the last two versions only — silently incomplete** | full top-up |
| `wave` cannot import its own modules | bare traceback, no hint | one line + the exact reinstall command |

✅ = the defect (the user had no way out), ❌ n/a.

## What actually happened

Reported on 2026-11-15. File timestamps on the machine reconstructed it exactly:

| When | What |
| --- | --- |
| 11-13 19:55 | 4.4 installed successfully. Its migration deleted `lib/configerror.py` and friends — correct for 4.4, whose `wave.py` puts `config/` on `sys.path`. |
| 11-14 16:06 | `wave selfupdate` ran again, targeting **4.3.2** (the mirror's `latest.toml` had not been re-synced). 4.3.2's delta was computed as "4.3.1 → 4.3.2" and contains 6 files, so it wrote 4.3's `lib/wave.py`, `lib/silent.py`, `lib/suggest.py` … **on top of a 4.4 tree**. |

The result is a tree whose bootstrapping `wave.py` is from the 4.3 line — and that file
needs `lib/configerror.py`, which 4.4's migration had just deleted. Two lines of MacWave
in one tree.

`update_commands.sh` deltas are computed against the *immediately preceding* release.
They are only valid if the installed tree really is that release. Nothing checked.

## The fix

1. **The generator now emits the full path list** (`FULL_FILES`) next to the existing
   `install_fresh` manifest — one source, two uses, so they cannot drift apart.
2. **`tree_complete()` in the generated script** stats every path in that list.
3. **The decision uses it**, in three places:
   - `CURRENT_VERSION == VERSION` only short-circuits output when the tree is complete.
     `VERSION.json` proves "a run finished", not "the files are still there".
   - before choosing delta: incomplete tree → full install (the delta's premise,
     "every file I do not list is still correct", does not hold).
   - after delta: still incomplete → top up with a full install. This covers
     skipped-version upgrades.
4. **`MACWAVE_FULL_INSTALL=1`** forces a full install regardless.
5. **`wave.py` fails legibly** if a module is missing: one line plus the reinstall
   command, instead of a traceback nobody can act on.
6. `lib/install.sh`'s comment no longer claims that an empty `MACWAVE_CURRENT_VERSION`
   means "install everything" — it never did.

## Evidence

The tree that produced the bug, before and after:

```console
$ wave selfupdate
Traceback (most recent call last):
  File ".../lib/wave.py", line 9, in <module>
    from configerror import check_environment, check_dependencies
ModuleNotFoundError: No module named 'configerror'

$ /bin/bash -c "$(curl -fsSL .../install.sh)"   # up to 4.3.3
🌊 Updating MacWave unknown -> 4.3.3
🌊 Downloading pkg/pkginstaller.py...           # one file; nothing was repaired
```

On 4.3.4 the same tree self-heals:

```console
🌊 The installed tree is incomplete; reinstalling all of MacWave 4.3.4
🌊 安装树不完整，正在重新安装 MacWave 4.3.4 的全部文件
… (all files) …
🌊 Successfully updated
```

Self-check: delete any installed file, then update. 4.3.3 says "Already at"/does nothing;
4.3.4 restores it.

```bash
rm ~/.local/macwave/lib/steplog.py
wave selfupdate     # 4.3.4: reinstalls; the missing file comes back
```

## Tests

| Script | 4.3.3 → 4.3.4 |
| --- | --- |
| `scripts/update_commands_test.sh` | 42 → 50 |

The new section 12 pins four behaviours: a complete tree at the same version is left
alone; the same version with a missing file is repaired (and does not print "Already at");
an incomplete tree takes the full path; `MACWAVE_FULL_INSTALL=1` overwrites even a
complete tree. One of those four immediately caught a bug in this very change — the
`Already at` shortcut ran before the force flag was consulted.

## How to upgrade

```bash
wave selfupdate
```

If `wave` cannot start at all, reinstall — that now works too:

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

## Mirror

The mirror needs `selfupdate`, `configdata` and `core` re-synced. Until it is, mirror
users keep reading the old `latest.toml` — and **that is exactly how the reported
incident started** (a stale pointer sent a 4.4 tree down the 4.3.2 delta path).

## Data shipped with this release

| Repository | Content |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.4/update_commands.sh` |
| `Selfupdate` | `macwavedata/latest.toml` → 4.3.4 / branch `4.3` |
| `configdata` | `versiondata/latest_version` → 4.3.4 / branch `4.3` |
| `Pages` | version → 4.3.4 |
| `MacWave` Release `v4.3.4` | every `.py` / `.sh` at the tag, flat, plus `MacWave-4.3.4.tar` and `.tar.gz` |

---

# MacWave 4.3.4 发布说明

- 发布：2026-11-15，构建号 `319G1644`
- 分支：`4.3`
- 上一版：[4.3.3](RELEASE-4.3.3.md)
- **修复**：安装树一旦损坏，任何命令都修不好

## 先说结论

安装树少了一个文件 —— 升级中途断网、Ctrl-C、跳版本升级、两条线的文件混在一起 ——
在 4.3.3 及以前**没有任何命令能修**：

- `wave` 起不来，所以 `wave selfupdate` 这条路没了；
- `install.sh` 报告成功，实际只下**一个**文件 —— 它用一次「存在性判断」决定
  走增量还是全量。

于是你陷入一个循环：每次尝试都成功，什么都没变。

| 情况 | 4.3.3 及以前 | 4.3.4 |
| --- | --- | --- |
| 树完整、版本相同 | "Already at"，不下载 | 同 |
| 树缺文件、版本相同 | ✅ **"Already at" —— 永远不修** | 重装全部 |
| 树存在但不完整 | ✅ **只走增量 —— 缺的文件继续缺** | 全量 |
| 跳版本升级 | ✅ **只含最近两版的差异 —— 静默不完整** | 全量补齐 |
| `wave` import 不到自己的模块 | 一句 traceback，没有下一步 | 一行说明 + 能照做的命令 |

## 实际发生了什么

2026-11-15 报上来的。文件时间戳把过程完整还原：

| 时间 | 发生了什么 |
| --- | --- |
| 11-13 19:55 | 4.4 装成功。它的迁移删掉了 `lib/configerror.py` 等 —— 对 4.4 是对的，4.4 的 `wave.py` 会把 `config/` 加进 `sys.path` |
| 11-14 16:06 | 又跑了一次 `wave selfupdate`，目标是 **4.3.2**（镜像的 `latest.toml` 还没同步）。4.3.2 的增量是按「4.3.1 → 4.3.2」算的，共 6 个文件，于是它把 4.3 线的 `lib/wave.py`、`lib/silent.py`、`lib/suggest.py`… **盖在了一棵 4.4 树上** |

结果是：这棵树的启动器 `wave.py` 来自 4.3 线，而它需要 `lib/configerror.py` ——
那个文件刚被 4.4 的迁移删掉。一棵树里混着两条线。

`update_commands.sh` 的增量是相对**相邻上一版**算的，只有在「安装树确实是那一版」
时才成立。而没有任何地方检查过这件事。

## 修复

1. **生成器把全量清单也输出一份**（`FULL_FILES`），与 `install_fresh` 的清单同源，
   两处不可能漂移。
2. **生成的脚本里加 `tree_complete()`**，逐个 stat 那份清单。
3. **三处判断都用它**：
   - `CURRENT_VERSION == VERSION` 只有在树完整时才直接返回 —— `VERSION.json` 证明
     「上次跑完了」，不证明「文件还在」。
   - 选增量之前：树不完整 → 全量（增量的前提「我没列出的文件都是对的」不成立）。
   - 增量之后：仍不完整 → 全量补齐（跳版本升级就是这一类）。
4. **`MACWAVE_FULL_INSTALL=1`** 强制全量。
5. **`wave.py` 缺模块时给一句能照做的命令**，而不是没人能处理的 traceback。
6. `lib/install.sh` 的注释不再声称「`MACWAVE_CURRENT_VERSION` 留空 = 全量安装」——
   它从来就不是。

## 证据

出问题的那棵树，修复前后：

```console
$ wave selfupdate
Traceback (most recent call last):
  File ".../lib/wave.py", line 9, in <module>
    from configerror import check_environment, check_dependencies
ModuleNotFoundError: No module named 'configerror'

$ /bin/bash -c "$(curl -fsSL .../install.sh)"   # 4.3.3 及以前
🌊 Updating MacWave unknown -> 4.3.3
🌊 Downloading pkg/pkginstaller.py...           # 只有一个文件；什么都没修
```

4.3.4 上同一棵树会自愈：

```console
🌊 The installed tree is incomplete; reinstalling all of MacWave 4.3.4
🌊 安装树不完整，正在重新安装 MacWave 4.3.4 的全部文件
…（全部文件）…
```

自查：随便删一个已安装的文件，再更新一次。4.3.3 会说「Already at」或什么都不做；
4.3.4 会把它补回来。

```bash
rm ~/.local/macwave/lib/steplog.py
wave selfupdate     # 4.3.4：重装，缺的文件回来了
```

## 测试

| 脚本 | 4.3.3 → 4.3.4 |
| --- | --- |
| `scripts/update_commands_test.sh` | 42 → 50 |

新增的第 12 段钉住四件事：树完整且版本相同就什么都不做；版本相同但缺文件必须修
（且不能打印 "Already at"）；树不完整走全量；`MACWAVE_FULL_INSTALL=1` 连完整的树也覆盖。
其中一条当场抓出了**这次改动自己**的一个 bug —— 强制旗标被 `Already at` 短路了。

## 升级方式

```bash
wave selfupdate
```

若 `wave` 已经完全起不来，重跑安装命令 —— 现在这条路也是通的：

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

## 镜像

镜像站需要重新同步 `selfupdate`、`configdata` 与 `core`。在同步完成之前，镜像用户读到的
仍是旧指针 —— **而这次事故正是这样开始的**（旧指针把一棵 4.4 的树送上了 4.3.2 的增量路径）。

## 随本次发布更新的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.4/update_commands.sh` |
| `Selfupdate` | `macwavedata/latest.toml` → 4.3.4 / 分支 `4.3` |
| `configdata` | `versiondata/latest_version` → 4.3.4 / 分支 `4.3` |
| `Pages` | 版本号 → 4.3.4 |
| `MacWave` 的 Release `v4.3.4` | 该 tag 下全部 `.py` / `.sh`（扁平）+ `MacWave-4.3.4.tar` 与 `.tar.gz` |
