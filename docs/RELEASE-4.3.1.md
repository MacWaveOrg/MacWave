# MacWave 4.3.1 Release Notes

- Released: 2026-11-08, build `312A1114`
- Branch: `4.3` (same line as 4.3.0; the `v4.3.0` tag stays at `12a291c`)
- Previous release: [4.3.0](RELEASE-4.3.0.md)

## Please upgrade: 4.3.0 fixed new installs only

4.3.0 moved every system-wide install to `root:<admin group>` with mode 755 — but it only
taught `install.sh` to do that. `wave selfupdate` was never given the same step, and upgrading
is what nearly everyone does. On a machine that reached 4.3.0 by upgrading:

- the install tree still belongs to the account that installed it;
- `/opt/macwave/links/<name>` is still **writable by that account**;
- that path is still on the system `PATH`, where other users, scripts and root may run it.

Item ② of the 4.3.0 notes was therefore only half fixed: a fresh install was clean, an upgraded
machine was not. This release closes the upgrade path, and closes the same class of mistake at
the uninstall end.

Severity is unchanged from that item: **CVSS 3.1 7.5**
(`CVSS:3.1/AV:L/AC:H/PR:L/UI:R/S:C/C:H/I:H/A:N`), **CVSS 4.0 6.9**
(`CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:P/VC:H/VI:H/VA:N/SC:H/SI:H/SA:N`).

## What 4.3.1 does

### ① `selfupdate` hands the tree over, exactly like `install.sh`

After the update finishes writing, the tree becomes `root:<admin group>` at mode 755:

| Who | Permission |
| --- | --- |
| Everyone | read + execute → **can run installed packages** |
| Administrators | `sudo wave install` → **can install and remove** |

Order matters, and it is asserted by a test: the handover runs **after** every write to the
tree (downloads, launcher, stale-bytecode cleanup). Move it earlier and the rest of the upgrade
needs `sudo` to write what it just made read-only.

User-level installs (`~/.local/macwave`) are untouched — they belong to their owner by design.

If the handover fails, the upgrade still finishes, but it says so plainly instead of looking
successful:

```
🌊 Warning: could not hand /opt/macwave over to root:admin.
🌊 The tree is still writable by <you>; links/ can be replaced by that account.
🌊 Re-run this command, or reinstall with lib/install.sh.
```

### ② `uninstall` no longer deletes a directory it did not create

`base_dir` comes from `config.json`, and a user-level config is writable by any process running
as that user. That value used to go straight into `sudo rm -rf` whenever it was not under
`$HOME`. Now a directory is removed only when it really is a MacWave install — it must contain
`lib/wave.py` — and these are refused outright:

```
/   /usr   /usr/local   /opt   /etc   /bin   /sbin   /System   /Library
$HOME
```

Anything else is skipped with a message that names the directory and the reason:

```
🌊 Skipping /usr/local: a system directory.
🌊 Skipping /Users/me: your home directory.
🌊 Skipping /opt/other-tool: not a MacWave install (no lib/wave.py).
🌊 Nothing was deleted there. If you are sure, remove it yourself.
```

## Evidence

### The gap, straight from the tags

```
$ git show v4.3.0:lib/selfupdate.sh | grep -c hand_over_system_install
0
$ git show v4.3.0:lib/selfupdate.sh | grep -n 'chown -R'
878:    sudo chown -R "root:$_admin_group" "$CONFIG_DIR" 2>/dev/null \
879:        || sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
```

Only the config directory. `$BASE_DIR` appears in no `chown` line of that file — the upgrade
path never touched ownership.

### The commands now issued

`scripts/dir_guard_test.sh` extracts `hand_over_system_install()` and runs it against a stub
`sudo` that records every call:

```
chown -R root:admin /…/sys-level-macwave
chmod -R u+rwX,go+rX,go-w /…/sys-level-macwave
```

For a user-level install the log stays empty — nothing is touched.

### Uninstall, actually run

Both versions were run in a sandbox (`MACWAVE_TEST`, a stub `sudo`), each with a `config.json`
pointing at a different `base_dir`:

| `base_dir` in `config.json` | 4.3.0 | 4.3.1 |
| --- | --- | --- |
| `/usr/local` holding an unrelated file | ❌ deleted | ✅ kept, `Skipping …: a system directory` |
| `$HOME` (even with `lib/wave.py`) | ❌ deleted | ✅ kept, `Skipping …: your home directory` |
| A directory that is not a MacWave tree | ❌ deleted | ✅ kept, `Skipping …: not a MacWave install` |
| A real MacWave tree | ✅ deleted | ✅ deleted |

Read the table as **✅ = safe for you**, **❌ = dangerous for you** — the right answer differs
per row, so the colouring follows your interest, not "did the command work".

### Regression

`bash scripts/dir_guard_test.sh` — 62 assertions, fully offline, seconds:

- section 9: `selfupdate` calls the handover, uses the same ownership model as `install.sh`,
  and does it *after* the launcher write; the issued commands are checked against the stub
  `sudo`, and a user-level install issues none;
- section 10: the four rows above, run for real against a copy of the uninstaller.

`wave selfupdate` on 4.3.0 also still works — that is how you get here.

## Also in this release

These landed on the `4.3` branch after the `v4.3.0` tag and ship for the first time here.
None of them is a security fix; they are listed so the upgrade is not a surprise.

| Change | What it means |
| --- | --- |
| `install.sh --dry-run` | Prints every step the installer would take — no download, no sudo, no directory, no file written. Works offline: a placeholder version is used when the index cannot be reached |
| `PATH` line is `eval "$(… shellenv)"` | The same shape Homebrew uses. Works for `bash`, `zsh`, `sh`, `dash`, `ksh` and `csh`/`tcsh`; old lines written by 4.2 and earlier are replaced in one command |
| Clearer installer output | Progress lines say what is happening and what comes next; a failure names the step and the command to retry |
| Usage errors share one colour scheme | Unknown flag / wrong command now use the same colours as `wave instal`'s "Did you mean:" block — plain body text, only the thing to type in green |
| `cloc` listed as supported | Same list as the site and `infosource` |

## Upgrading

```bash
wave selfupdate
```

From 4.3.0 this is the intended path: it updates the files and then performs the handover, so
`sudo wave install <package>` is what you use afterwards.

**If you are on 4.2.1 / 4.2.2** (selfupdate is broken in those two), use the install command
instead:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

`4.3.0` itself needs nothing special: its `selfupdate` downloads and writes correctly, it simply
never changed ownership.

## Branch changes

| Item | Change |
| --- | --- |
| Branch | `4.3` continues; `main` carries the same commit |
| `configdata` | `version` → 4.3.1, `build_number` → this build, `branch` stays `4.3` |
| `Selfupdate` | `macwavedata/latest.toml` → 4.3.1; new frozen `macwavedata/4.3.1/update_commands.sh` |
| `Pages` | version → 4.3.1 |

## Data shipped with this release

| Repository | Content |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.1/update_commands.sh` |
| `configdata` | `latest_version` → 4.3.1 / branch 4.3 |
| `Pages` | version → 4.3.1 |

`update_commands.sh` is frozen per version: the delta versus `v4.3.0` is nine files —
`lib/selfupdate.sh`, `lib/uninstall.sh`, the installer and the error-message modules that
landed on the branch after the 4.3.0 tag (see below).

---

# MacWave 4.3.1 发布说明

- 发布：2026-11-08，构建号 `312A1114`
- 分支：`4.3`（与 4.3.0 同一条线；`v4.3.0` 的 tag 仍在 `12a291c`）
- 上一版：[4.3.0](RELEASE-4.3.0.md)

## 请务必升级：4.3.0 只修好了全新安装

4.3.0 把系统级安装改成了 `root:<管理员组>`、权限 755 —— 但它只教会了 `install.sh`。
`wave selfupdate` 从来没有这一步，而升级恰恰是绝大多数人走的路。于是靠升级到 4.3.0
的机器上：

- 安装树仍然归「当初装它的那个账号」所有；
- `/opt/macwave/links/<名>` 仍然**对该账号可写**；
- 那个路径仍然在系统 `PATH` 上，会被别的用户、脚本甚至 root 执行。

也就是说 4.3.0 的第 ② 条只修了一半：全新安装是干净的，升级上来的不是。本版补上升级
路径，并把同一类错误在卸载端的入口一起堵掉。

严重性与 4.3.0 那条一致：**CVSS 3.1 7.5**
（`CVSS:3.1/AV:L/AC:H/PR:L/UI:R/S:C/C:H/I:H/A:N`），**CVSS 4.0 6.9**
（`CVSS:4.0/AV:L/AC:L/AT:P/PR:L/UI:P/VC:H/VI:H/VA:N/SC:H/SI:H/SA:N`）。

## 4.3.1 做了什么

### ① `selfupdate` 交还属主，与 `install.sh` 同一条规则

更新写完之后，树变成 `root:<管理员组>`、权限 755：

| 角色 | 权限 |
| --- | --- |
| 所有人 | 读 + 执行 → **能运行已装的包** |
| 管理员 | `sudo wave install` → **能装、能删** |

顺序不能反，而且有测试盯着：交还发生在**所有写树动作之后**（下载、写 launcher、清陈旧
字节码缓存）。提前做的话，本次升级剩下的写入就得用 `sudo` 去改它刚刚设成只读的东西。

用户级安装（`~/.local/macwave`）不受影响 —— 它本来就该归用户自己。

交还失败时升级仍然完成，但会把话说明白，而不是看起来一切正常：

```
🌊 Warning: could not hand /opt/macwave over to root:admin.
🌊 The tree is still writable by <你>; links/ can be replaced by that account.
🌊 Re-run this command, or reinstall with lib/install.sh.
```

### ② `uninstall` 不再删掉不是自己装的目录

`base_dir` 来自 `config.json`，而用户级配置对任何以该用户身份运行的进程都可写。以前只要
它不在 `$HOME` 下，就被直接丢给 `sudo rm -rf`。现在只有确实是 MacWave 安装的目录（必须
含 `lib/wave.py`）才会被删，下面这些一律拒绝：

```
/   /usr   /usr/local   /opt   /etc   /bin   /sbin   /System   /Library
$HOME
```

其余情况跳过，并说清是哪个目录、哪条理由：

```
🌊 Skipping /usr/local: a system directory.
🌊 Skipping /Users/me: your home directory.
🌊 Skipping /opt/other-tool: not a MacWave install (no lib/wave.py).
🌊 Nothing was deleted there. If you are sure, remove it yourself.
```

## 证据

### 缺口，直接从 tag 上看

```
$ git show v4.3.0:lib/selfupdate.sh | grep -c hand_over_system_install
0
$ git show v4.3.0:lib/selfupdate.sh | grep -n 'chown -R'
878:    sudo chown -R "root:$_admin_group" "$CONFIG_DIR" 2>/dev/null \
879:        || sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
```

只有配置目录。那个文件里没有任何一行 `chown` 涉及 `$BASE_DIR` —— 升级路径从没动过属主。

### 现在下发的命令

`scripts/dir_guard_test.sh` 把 `hand_over_system_install()` 抽出来，对着一个会记录调用的
假 `sudo` 跑：

```
chown -R root:admin /…/sys-level-macwave
chmod -R u+rwX,go+rX,go-w /…/sys-level-macwave
```

用户级安装时日志是空的 —— 一个字节都没动。

### 卸载：真跑过

两个版本都在沙箱里跑（`MACWAVE_TEST` + 假 `sudo`），各自用一份指向不同 `base_dir` 的
`config.json`：

| `config.json` 里的 `base_dir` | 4.3.0 | 4.3.1 |
| --- | --- | --- |
| `/usr/local`（里面有一个无关文件） | ❌ 被删 | ✅ 保留，`Skipping …: a system directory` |
| `$HOME`（即使里面有 `lib/wave.py`） | ❌ 被删 | ✅ 保留，`Skipping …: your home directory` |
| 不是 MacWave 树的普通目录 | ❌ 被删 | ✅ 保留，`Skipping …: not a MacWave install` |
| 真正的 MacWave 树 | ✅ 被删 | ✅ 被删 |

按**你的利益**读这张表：**✅ = 对你安全**，**❌ = 对你危险** —— 每一行「正确」的答案
不一样，所以着色按你的利益来，不是按「命令有没有跑成功」。

### 回归

`bash scripts/dir_guard_test.sh` —— 62 条断言，纯离线，秒级：

- 第 9 组：`selfupdate` 调用交还、与 `install.sh` 用同一套所有权模型、位置在写 launcher
  之后；下发的命令对着假 `sudo` 逐条核对，用户级安装一条都不发；
- 第 10 组：上表四行，用卸载脚本的副本真跑。

4.3.0 上执行 `wave selfupdate` 仍然可用 —— 你就是这么到这里的。

## 本版还包含

这些是在 `v4.3.0` 的 tag 之后落到 `4.3` 分支上的改动，本版第一次发出去。都不是安全修复，
列在这里只是让升级不意外。

| 改动 | 含义 |
| --- | --- |
| `install.sh --dry-run` | 把安装器会做的每一步打出来 —— 不下载、不提权、不建目录、不写文件；取不到索引时用占位版本号继续，断网也能看完 |
| `PATH` 那一行改成 `eval "$(… shellenv)"` | 与 Homebrew 同形。`bash`、`zsh`、`sh`、`dash`、`ksh`、`csh`/`tcsh` 都覆盖；4.2 及更早写进 rc 的旧条目在一条命令里替换掉 |
| 安装器输出更清楚 | 每一步说清在做什么、下一步是什么；失败时点名是哪一步、该敲什么重试 |
| 用法错误统一配色 | 未知旗标 / 命令用错，与 `wave instal` 的「Did you mean:」用同一套配色 —— 正文默认色，只有该敲的部分是绿的 |
| 支持列表加入 `cloc` | 与官网、`infosource` 保持一致 |

## 升级方式

```bash
wave selfupdate
```

从 4.3.0 上来走这条路即可：它先把文件更新完，再做属主交还；之后装包要用
`sudo wave install <包>`。

**如果你在 4.2.1 / 4.2.2**（那两版的 selfupdate 是坏的），改用安装命令：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

`4.3.0` 本身不需要特殊处理：它的 `selfupdate` 下载与落盘都正常，只是从来没改过属主。

## 分支变化

| 项 | 变化 |
| --- | --- |
| 分支 | `4.3` 继续；`main` 上是同一个提交 |
| `configdata` | `version` → 4.3.1，`build_number` → 本次构建号，`branch` 仍为 `4.3` |
| `Selfupdate` | `macwavedata/latest.toml` → 4.3.1；新增冻结的 `macwavedata/4.3.1/update_commands.sh` |
| `Pages` | 版本号 → 4.3.1 |

## 本版随附的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.1/update_commands.sh` |
| `configdata` | `latest_version` → 4.3.1 / branch 4.3 |
| `Pages` | 版本号 → 4.3.1 |

`update_commands.sh` 按版本冻结：相对 `v4.3.0` 的差异是九个文件 —— `lib/selfupdate.sh`、
`lib/uninstall.sh`，以及在 4.3.0 的 tag 之后落到分支上的安装器与报错模块（见下）。
