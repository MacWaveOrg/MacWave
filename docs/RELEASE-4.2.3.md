# MacWave 4.2.3 Release Notes

- Released: 2026-11-04, build `308A1547`
- Branch: `4.2`
- **Security / critical fix**: installing and upgrading 4.2.1 and 4.2.2 fail outright on most Macs

## Bottom line first

**Upgrade from 4.2.1 / 4.2.2 to 4.2.3.** On machines where `LC_CTYPE` is UTF-8 (the macOS
default), both of those versions abort with an error in two places:

| Path | 4.2.1 / 4.2.2 | 4.2.3 |
| --- | --- | --- |
| Official install command `… \| /bin/bash -c "…/install.sh"` | ❌ `MACWAVE_VERSION?: unbound variable` | ✅ |
| `wave selfupdate` (upgrading to those two) | ❌ `repo_path?: unbound variable` | ✅ |

## Root cause

The `--zh` commit added Chinese copy to the installer and the update script, and a few places
were written with "a variable immediately followed by Chinese punctuation":

```bash
say "… Welcome to MacWave $MACWAVE_VERSION!" "… 欢迎使用 MacWave $MACWAVE_VERSION！"
#                                                  ↑ here: variable followed by a full-width '!'
say "… Downloading $repo_path..." "… 正在下载 $repo_path……"
#                                               ↑ here: followed by an ellipsis
```

Under a UTF-8 locale, `/bin/bash` 3.2 (the one macOS ships) reads the first byte of the
multi-byte character that follows the variable into the variable name, so `set -u` reports
"variable not set":

```
install.sh: line 456: MACWAVE_VERSION?: unbound variable
update_commands.sh: line 125: repo_path?: unbound variable
```

The three locale behaviours differ, which is why it never surfaced during development:

| locale | `/bin/bash` 3.2 | bash 5.x |
| --- | --- | --- |
| `C` / `POSIX` | ✅ fine | ✅ fine |
| `en_US.UTF-8` | ❌ unbound variable | ✅ fine |
| unset (follows the system) | depends on the system default | ✅ fine |

The development machine's `LC_CTYPE` is `C`, so everything was green locally; macOS users and
CI are UTF-8, so it blew up every time. **The same trap had already bitten once during 4.2
development** (`$BACKFILL（` in `minos_test`) — that time only one occurrence was fixed and
nothing else was audited.

## The fix

1. **Braces everywhere.** 10 occurrences found: 6 in `lib/install.sh`, 2 in
   `scripts/update_commands.template.sh`, 1 in `scripts/linksafety_test.sh` (pre-existing),
   1 in `scripts/configpath_test.sh` (a comment). All fixed as `${VAR}……`.
2. **New `scripts/shell_lint.sh`, run on both pipelines:**
   - scans every `.sh` for "`$VAR` immediately followed by a multi-byte character" and fails on
     a hit
   - runs `bash -n` over every `.sh`
3. **New section in `AGENTS.md`:** verifying shell output that contains Chinese requires an
   explicit `LC_ALL=en_US.UTF-8`, otherwise the local `C` locale means this class of error
   never appears.

The guard was verified: reinstating the bug makes the lint report it at the exact line.

## Other changes that came along

### Point at the offending word with `^`

When a command name or flag is mistyped, the command line is echoed back verbatim, only the
offending span is highlighted in red, and the next line points at it with `^`:

```
🌊 Error: illegal option --connect-time for `wave install`
🌊           you ran: wave install yq -v -C --limit-rate=10M --max-time=5min --connect-time=1min
🌊                                                                           ^^^^^^^^^^^^^^
🌊 Next      Did you mean --connect-timeout?
```

When no correct spelling can be guessed (the command name is wildly off) it still points —
previously that block sat inside `if suggestion`, so with no guess the user got nothing and had
to stare at the command line themselves:

```
🌊 Error: Unknown command or argument.
   wave frobnicate xyz
        ^^^^^^^^^^
```

### Candidates for mistyped flags

```
🌊 Next      Did you mean --connect-timeout?
```

`difflib` matches only within **the current command's own allowlist** and never guesses across
commands; when nothing is close it makes nothing up.

## Tests

| Script | Assertions |
| --- | --- |
| `scripts/shell_lint.sh` (new) | 2 |
| `scripts/message_test.sh` | 24 → 28 |

`message_test` assertions now go through `strip_ansi()`, so they no longer depend on terminal
escape sequences — which word gets highlighted is a presentation detail and should not make the
assertions brittle.

## How to upgrade

```bash
wave selfupdate
```

On a machine already running 4.2.1 / 4.2.2 **where `wave` still works**: `wave` itself is fine;
what is broken is the installer and the self-update script, so `wave selfupdate` will download
the 4.2.3 scripts (the fixed ones) and succeed.

If `wave selfupdate` fails too, just run the install command once more.

## Mirror

The mirror site needs `selfupdate`, `configdata` and `core` re-synced, otherwise mirror users
keep reading the old version pointer.

## Data shipped with this release

| Repository | Content |
| --- | --- |
| `Selfupdate` | `macwavedata/4.2.3/update_commands.sh` (generated from the fixed template, 29 files) |
| `configdata` | `latest_version` → 4.2.3 |
| `Pages` | version → 4.2.3 |

---

# MacWave 4.2.3 发布说明

- 发布：2026-11-04，构建号 `308A1547`
- 分支：`4.2`
- **安全/紧急修复**：4.2.1 与 4.2.2 的安装与升级在多数 macOS 上直接失败

## 先说结论

**请从 4.2.1 / 4.2.2 升级到 4.2.3。** 这两版在 `LC_CTYPE` 为 UTF-8 的机器上
（macOS 的默认值）会在两处直接报错退出：

| 路径 | 4.2.1 / 4.2.2 | 4.2.3 |
| --- | --- | --- |
| 官方安装命令 `… \| /bin/bash -c "…/install.sh"` | ❌ `MACWAVE_VERSION?: unbound variable` | ✅ |
| `wave selfupdate`（升到这两个版本） | ❌ `repo_path?: unbound variable` | ✅ |

## 事故原因

`--zh` 那次提交给安装程序与更新脚本加了中文文案，其中几处写成「变量后面直接跟
中文标点」：

```bash
say "… Welcome to MacWave $MACWAVE_VERSION!" "… 欢迎使用 MacWave $MACWAVE_VERSION！"
#                                                  这里 ↑ 变量后紧跟全角叹号
say "… Downloading $repo_path..." "… 正在下载 $repo_path……"
#                                               这里 ↑ 后面紧跟省略号
```

`/bin/bash` 3.2（macOS 自带）在 UTF-8 locale 下会把紧跟变量的那个多字节字符的
首字节读进变量名，于是 `set -u` 报「变量不存在」：

```
install.sh: line 456: MACWAVE_VERSION?: unbound variable
update_commands.sh: line 125: repo_path?: unbound variable
```

三种 locale 行为不同，这决定了它为什么没在开发时暴露：

| locale | `/bin/bash` 3.2 | bash 5.x |
| --- | --- | --- |
| `C` / `POSIX` | ✅ 正常 | ✅ 正常 |
| `en_US.UTF-8` | ❌ 报 unbound variable | ✅ 正常 |
| 未设置（跟随系统） | 看系统默认 | ✅ 正常 |

开发机的 `LC_CTYPE` 是 `C`，所以本地怎么跑都绿；macOS 用户与 CI 是 UTF-8，
于是必炸。**同一个坑在 4.2 开发期已经咬过一次**（`minos_test` 里的 `$BACKFILL（`），
那次只修了一处，没有查全部。

## 修复

1. **全仓加花括号。** 扫出 10 处：`lib/install.sh` 6 处、
   `scripts/update_commands.template.sh` 2 处、`scripts/linksafety_test.sh` 1 处
   （历史遗留）、`scripts/configpath_test.sh` 1 处（注释）。修法统一是
   `${VAR}……`。
2. **新增 `scripts/shell_lint.sh`，两条流水线都跑：**
   - 扫全部 `.sh` 里「`$VAR` 紧跟多字节字符」的写法，命中即红
   - 所有 `.sh` 过一遍 `bash -n`
3. **`AGENTS.md` 补一节：**验证带中文的 shell 输出时必须显式切
   `LC_ALL=en_US.UTF-8`，否则本机的 `C` locale 会让这类错误永远不出现。

防线本身验过：把 bug 还原回去，lint 立刻在对应行号报出来。

## 同批带出的其它改动

### 报错时用 `^` 指出错在哪个词

命令名或旗标打错时，先原样回显一遍命令行，只把出错的那一段标红，下一行用 `^`
指住它：

```
🌊 Error: illegal option --connect-time for `wave install`
🌊           you ran: wave install yq -v -C --limit-rate=10M --max-time=5min --connect-time=1min
🌊                                                                           ^^^^^^^^^^^^^^
🌊 Next      Did you mean --connect-timeout?
```

猜不出正确的写法时（命令名拼得太离谱）也会指 —— 以前那段整个包在
`if suggestion` 里，猜不到就一个字都不给，用户只能自己盯着命令行找：

```
🌊 Error: Unknown command or argument.
   wave frobnicate xyz
        ^^^^^^^^^^
```

### 旗标拼错给候选

```
🌊 Next      Did you mean --connect-timeout?
```

`difflib` 只在**当前命令的白名单**里匹配，不跨命令猜；没有接近的候选时不编造。

## 测试

| 脚本 | 断言数 |
| --- | --- |
| `scripts/shell_lint.sh`（新增） | 2 |
| `scripts/message_test.sh` | 24 → 28 |

`message_test` 的断言改用 `strip_ansi()`，不再依赖终端转义序列 —— 文案里高亮
哪个词属于呈现细节，不该让断言跟着碎。

## 升级方式

```bash
wave selfupdate
```

已经在 4.2.1 / 4.2.2 且**能正常跑 `wave`** 的机器：`wave` 本身没坏，坏的是
安装与自更新脚本，所以 `wave selfupdate` 会下载到 4.2.3 的脚本（修复版）并成功。

如果 `wave selfupdate` 也失败了，重新跑一次安装命令即可。

## 镜像

镜像站需要重新同步 `selfupdate`、`configdata`、`core` 三份数据，否则镜像用户
仍会读到旧版本指针。

## 本版随附的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.2.3/update_commands.sh`（由修复后的模板生成，29 个文件） |
| `configdata` | `latest_version` → 4.2.3 |
| `Pages` | 版本号 → 4.2.3 |
