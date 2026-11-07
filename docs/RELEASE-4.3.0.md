# MacWave 4.3.0 Release Notes

- Released: 2026-11-04, build `308A1849`
- Branch: `4.3` (new; cut from `d084c9d`, the last commit on `4.2`. The 4.2.5 tag stays at `926a48a`)
- Previous release: [4.2.5](RELEASE-4.2.5.md)

## Please upgrade: every release up to 4.2.5 ships a defect that lets the whole machine be taken over

This is not "you may want to upgrade", it is **you need to upgrade**. Every version from at
least 4.0.0 through 4.2.5 contains the `chown -R` described in item ①; 4.3.0 is the first
release that does not.

The three items below are ordered by severity, and only ② is a vulnerability in the CVE
sense — ① is the precondition that makes ② reachable.

| Item | CVSS 3.1 | CVSS 4.0 |
| --- | --- | --- |
| ① system directories accepted as an install root | 7.2 — `CVSS:3.1/AV:L/AC:H/PR:L/UI:R/S:C/C:N/I:H/A:H` | 5.9 — `CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:A/VC:N/VI:H/VA:H/SC:N/SI:H/SA:H` |
| ② user-owned tree on the system `PATH` | **7.5** — `CVSS:3.1/AV:L/AC:H/PR:L/UI:R/S:C/C:H/I:H/A:H` | 6.9 — `CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:P/VC:H/VI:H/VA:N/SC:H/SI:H/SA:N` |
| ③ update scripts crash on 4.2.1 / 4.2.2 | not a vulnerability (availability defect, no attacker) | — |

### ① Installing into `/usr/local` chowns all of Homebrew

When `install.sh` receives `--dir-option=3=/usr/local`, the old validation lets it through
(it only rejected `..`, control characters, non-ASCII, relative paths and `/`). The installer
then runs:

```bash
sudo chown -R "$CURRENT_USER": "$BASE_DIR"     # BASE_DIR = /usr/local
```

So **the whole of `/usr/local` ends up owned by the current user** — every Homebrew directory
and `brew`'s own executable live in there. And the rollback path, taken when the user declines
the license, is `rm -rf "$BASE_DIR"`, which **deletes `/usr/local` outright**.

Measured: every one of these paths passed the old validation — `/usr/local`, `/opt`, `/etc`,
`/usr`, `/bin`, `$HOME`.

**As of 4.3.0**: the system directories themselves are always rejected (compared for exact
equality, so subdirectories such as `/opt/macwave` are unaffected); a directory that already
exists, is not empty, and was not created by MacWave is rejected as well.

### ② System-wide installs put user-owned binaries on the system PATH

Another consequence of that same `chown -R`: `/opt/macwave` belongs to "whoever installed it
first", so `/opt/macwave/links/jq` is **writable by that user**. Any process running as that
user can replace it, and it may then be executed by other users, by scripts, or by root — a
textbook local privilege-escalation path.

**As of 4.3.0**: a fresh install hands the tree to `root:<admin group>` with mode 755.

| Who | Permission |
| --- | --- |
| Everyone | read + execute → **can run installed packages** |
| Administrators | `sudo wave install` → **can install and remove** |

The cost is that a system-wide `wave install` now needs `sudo`. That is stated **before
anything happens** (rather than failing halfway through a download with `Permission denied`
and having it blamed on "network or proxy issues").

### ③ The update scripts crash on most Macs (4.2.1 / 4.2.2)

If you installed 4.2.1 or 4.2.2, both `wave selfupdate` and the official install command fail
with `unbound variable`. The cause: Chinese copy written as `$MACWAVE_VERSION！` and
`$repo_path……` — a variable immediately followed by a Chinese punctuation mark. Under a UTF-8
locale, `/bin/bash` 3.2 reads the first byte of that character into the variable name, so
`set -u` reports "variable not set".

4.2.3 fixed it, this release inherits the fix, and `scripts/shell_lint.sh` now scans for this
class of mistake on both pipelines.

## New in this release: `min_os` graduates to a first-class feature

`min_os` moves from its experimental 4.2 state to a supported feature. A version record in the
index can declare the minimum macOS a package requires; installing warns and asks.

The data is backfilled across the whole index: **100% of real packages** (arm64 96/112,
amd64 89/106; the gaps are only the `test_*` negative fixtures and `fileicon`, a bash script).

Behaviour matrix:

| Situation | Behaviour |
| --- | --- |
| The record has no `min_os` | pass silently |
| This Mac ≥ the declared value | pass silently |
| This Mac < the declared value, default | yellow warning + `Continue installing anyway? [y/N]` |
| Answer `y` / `Y` | continue installing |
| Any other answer (including a bare Enter, or non-interactive) | abort, **nothing is downloaded** |
| `-s` (including `-sS`) | no question, abort; plain `-s` prints nothing at all |
| `-F` / `--force` | no question, install — even `-s` cannot suppress it |

**Why ask instead of hard-block**: `minos` is a build-time declaration, not evidence of the
APIs actually used.

| Package | Declared | Reality |
| --- | --- | --- |
| `jq@1.8.2` | 14.0 | runs fine on macOS 12.7.6, measured |
| `pandoc@3.13` | 15.0 | may genuinely use newer APIs |
| `ipsw@3.1.7xx` | **27.2** | Go linked against Xcode 27 beta, which embeds the SDK version in `minos` verbatim |
| `ollama@0.3x` | **26.2** | same as above |

With a hard block, `ipsw` could not be installed on **any** released macOS — yet it runs fine.

## New in this release: hints when a command name is mistyped

```
$ wave instal jq
🌊 Error: Unknown command or argument.
   wave instal jq
        ^^^^^^

🌊 Did you mean: wave install jq
   instal is not a command. The one you want is install.

   For the full list: wave -h
```

Single-letter mistakes (delete / substitute / insert one character, all 4670 enumerated) are
**caught 98.1%** of the time, with 0.3% guessed wrong. When it cannot guess, it leaves a single
`wave -h` line instead of dumping fifty-odd lines of help.

## How to upgrade

```bash
wave selfupdate
```

**If you are on 4.2.1 / 4.2.2** (selfupdate is broken in those two), use the install command
instead:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

**If you installed into `/opt/macwave` or `/usr/local/macwave`**: `wave selfupdate` replaces
the files but does **not** change who owns the install tree — it keeps the owner it already
had (the account that installed it). Only a fresh run of `install.sh` hands the tree over to
`root:<admin group>` with mode 755. Until that happens, item ② is still reachable on that
machine, and `wave install` still works without `sudo`. Reinstall once if you want the
handover now; a later release will make `selfupdate` do it.

## Branch changes

| Item | Change |
| --- | --- |
| New branch | `4.3` (cut after 4.2.5, carries the entire 4.2.x history) |
| `4.2` | stops at `d084c9d` (the fork point); no further commits |
| `configdata` | `branch` → `4.3`, `version` → 4.3.0 |
| CI | `4.3` added to the branch allowlists of `format-test` and CircleCI |
| `dependabot.yml` | `target-branch` → `4.3` |

## Data shipped with this release

| Repository | Content |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.0/update_commands.sh` |
| `configdata` | `latest_version` → 4.3.0 / branch 4.3 |
| `Pages` | version → 4.3.0 |

---

# MacWave 4.3.0 发布说明

- 发布：2026-11-04，构建号 `308A1849`
- 分支：`4.3`（新建，从 `4.2` 的最后一个提交 `d084c9d` 切出；4.2.5 的 tag 仍在 `926a48a`）
- 上一版：[4.2.5](RELEASE-4.2.5.md)

## 请务必升级：4.2.5 及更早的每个版本都存在一个能让整台机器被接管的缺陷

这不是「建议升级」，是**需要升级**。至少从 4.0.0 到 4.2.5，每个版本都带着 ① 里那条
`chown -R`；4.3.0 是第一个没有它的版本。

下面三条按严重程度排列。其中只有 ② 是 CVE 意义上的漏洞 —— ① 是让 ② 得以成立的前置
条件。

| 项 | CVSS 3.1 | CVSS 4.0 |
| --- | --- | --- |
| ① 系统目录可以被当成安装根目录 | 7.2 —— `CVSS:3.1/AV:L/AC:H/PR:L/UI:R/S:C/C:N/I:H/A:H` | 5.9 —— `CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:A/VC:N/VI:H/VA:H/SC:N/SI:H/SA:H` |
| ② 系统 `PATH` 上的二进制归安装者所有 | **7.5** —— `CVSS:3.1/AV:L/AC:H/PR:L/UI:R/S:C/C:H/I:H/A:H` | 6.9 —— `CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:P/VC:H/VI:H/VA:N/SC:H/SI:H/SA:N` |
| ③ 升级脚本在 4.2.1 / 4.2.2 上崩 | 不是漏洞（可用性缺陷，无攻击者） | — |

### ① 装到 `/usr/local` 时，会 chown 整个 Homebrew

`install.sh` 收到 `--dir-option=3=/usr/local` 时，旧版校验会放行（它只挡了 `..`、
控制字符、非 ASCII、相对路径和 `/`）。之后安装脚本执行：

```bash
sudo chown -R "$CURRENT_USER": "$BASE_DIR"     # BASE_DIR = /usr/local
```

于是**整个 `/usr/local` 变成当前用户的** —— Homebrew 的全部目录、`brew` 自己的
可执行文件都在里面。而拒绝用户协议时的回滚是 `rm -rf "$BASE_DIR"`，那一步会
**删掉 `/usr/local` 整个目录**。

实测这些路径旧版全部能通过校验：`/usr/local`、`/opt`、`/etc`、`/usr`、`/bin`、
`$HOME`。

**4.3.0 起**：系统目录本身一律拒绝（按完全相等判，`/opt/macwave` 这类子目录不受
影响）；已存在且非空、又不是 MacWave 安装的目录也拒绝。

### ② 系统级安装把用户拥有的二进制放进了系统 PATH

同一条 `chown -R` 的另一个后果：`/opt/macwave` 归「第一个装它的人」所有，于是
`/opt/macwave/links/jq` 是**用户可写**的。任何以该用户身份运行的进程都能替换它，
而它可能被别的用户、脚本甚至 root 执行 —— 这是教科书式的本地提权路径。

**4.3.0 起**：全新安装会把树交给 `root:<管理员组>`、权限 755（自助升级不改属主，见「升级方式」）。

| 角色 | 权限 |
| --- | --- |
| 所有人 | 读 + 执行 → **能运行已装的包** |
| 管理员 | `sudo wave install` → **能装、能删** |

代价是系统级安装下 `wave install` 需要 `sudo`。这一点现在会**在动手之前就说清楚**
（而不是等下载到一半报 `Permission denied` 并被归因成「网络或代理问题」）。

### ③ 升级脚本在多数 macOS 上直接崩（4.2.1 / 4.2.2）

如果你装过 4.2.1 或 4.2.2，`wave selfupdate` 与官方安装命令都会以
`unbound variable` 失败。原因：中文文案写成 `$MACWAVE_VERSION！`、`$repo_path……`
—— 变量后面紧跟中文标点，`/bin/bash` 3.2 在 UTF-8 locale 下会把那个字符的首字节
读进变量名，`set -u` 于是报「变量不存在」。

4.2.3 已修复，本版继承修复，并新增 `scripts/shell_lint.sh` 在两条流水线上扫这
一类写法。

## 本版新增：`min_os` 转正

`min_os` 从 4.2 的实验状态转为正式特性。索引的版本记录可以声明一个包要求的
macOS 下限，安装时警告并询问。

数据已全库回填：**真实软件包 100% 覆盖**（arm64 96/112、amd64 89/106；缺的只有
`test_*` 负向样本与 `fileicon` 这个 bash 脚本）。

行为矩阵：

| 情况 | 行为 |
| --- | --- |
| 记录里没有 `min_os` | 静默放行 |
| 本机 ≥ 声明 | 静默放行 |
| 本机 < 声明，默认 | 黄字警告 + `Continue installing anyway? [y/N]` |
| 答复 `y` / `Y` | 继续安装 |
| 其它任何答复（含直接回车、非交互） | 中止，**不下载** |
| `-s`（含 `-sS`） | 不询问，直接中止；纯 `-s` 一个字都不输出 |
| `-F` / `--force` | 不问，直接装 —— `-s` 也压不住 |

**为什么是询问而不是硬拦截**：`minos` 是构建时的声明，不等于真实 API 需求。

| 包 | 声明 | 实际 |
| --- | --- | --- |
| `jq@1.8.2` | 14.0 | 在 macOS 12.7.6 上实测照常运行 |
| `pandoc@3.13` | 15.0 | 可能真用到新 API |
| `ipsw@3.1.7xx` | **27.2** | Go 用 Xcode 27 beta 链接，SDK 版本被原样写进 `minos` |
| `ollama@0.3x` | **26.2** | 同上 |

硬拦下来的话，`ipsw` 在**任何**已发布的 macOS 上都装不了 —— 而它实际跑得动。

## 本版新增：命令名打错时的提示

```
$ wave instal jq
🌊 Error: Unknown command or argument.
   wave instal jq
        ^^^^^^

🌊 Did you mean: wave install jq
   instal is not a command. The one you want is install.

   For the full list: wave -h
```

单字母错误（删 / 换 / 插一个字符，穷举 4670 种）**命中 98.1%**，误猜 0.3%。
猜不到时也只留一行 `wave -h`，不再倒五六十行帮助。

## 升级方式

```bash
wave selfupdate
```

**如果你在 4.2.1 / 4.2.2**（那两版的 selfupdate 是坏的），改用安装命令：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

**如果你当初装在 `/opt/macwave` 或 `/usr/local/macwave`**：`wave selfupdate` 只换文件，
**不改安装树的属主** —— 它保持原来的属主（当初装它的那个账号）。只有重新跑一次
`install.sh` 才会把树交给 `root:<管理员组>`、权限 755。在重装之前，那台机器上的 ②
仍然可被利用，`wave install` 也仍然不需要 `sudo`。想立刻拿到新的所有权模型就重装一次；
后续版本会让 `selfupdate` 自己完成这一步。

## 分支变化

| 项 | 变化 |
| --- | --- |
| 新分支 | `4.3`（从 4.2.5 之后切出，含全部 4.2.x 历史） |
| `4.2` | 停在 `d084c9d`（4.3 的切出点），不再接收提交 |
| `configdata` | `branch` → `4.3`，`version` → 4.3.0 |
| CI | `format-test` 与 CircleCI 的分支白名单都加了 `4.3` |
| `dependabot.yml` | `target-branch` → `4.3` |

## 本版随附的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.0/update_commands.sh` |
| `configdata` | `latest_version` → 4.3.0 / branch 4.3 |
| `Pages` | 版本号 → 4.3.0 |
