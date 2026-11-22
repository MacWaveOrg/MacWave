# MacWave 4.5.0

Released: 2026-11-22 · build `326G1231` · branch `4.5` ·
previous release [4.4.1](RELEASE-4.4.1.md)

4.5 is about **what a single executable cannot carry**. `wave install git` works now: a
version record may declare `install: "tree"`, the installer keeps the whole directory, and
the unversioned link still points at one command. Two pieces come with it — a client floor,
so an old client refuses such a record instead of installing half of it, and a download that
survives a broken connection instead of dying on the first reset. Also here: `wave basedir`,
30 new packages, and one uninstall fix.

## A package can now be a tree

Some tools are not one file. `git` needs `libexec/git-core/git-remote-https` and
`share/git-core/templates`; neovim and helix need `runtime/`. A version record may now say:

```
install: "tree"
```

The installer then keeps the whole extracted directory under `bin/<name>@<version>/`, writes
a `.is_a_tree` marker, and links only `bin/<bin_name>` — so `wave list`, `wave link` and
`wave uninstall` keep working on a single command name. A record without the field still
means the normal single-executable package, so nothing that worked before changes.

First package on this path: `git@2.56.1`. Its tree is 25 MB / 251 files, and `git` resolves
its own prefix at runtime (upstream patch), which is what makes a relocated tree work:

```
$ …/links/git --exec-path
/…/bin/git@2.56.1/libexec/git-core
$ …/links/git ls-remote https://github.com/git/git HEAD
f7de81456940dd6f3274e461149bba12965de609	HEAD
```

## Old clients refuse what they cannot install

`install: "tree"` is new in 4.5. An older client does not error on it — it does not know the
field, so it installs single-executable style and keeps one file. Measured with 4.4.1 against
the same record:

```
🌊 Successfully installed git@2.56.1
🌊 Binary installed to: …/bin/git@2.56.1/git      ← one file, 3.7 MB
$ …/links/git --exec-path
/Users/<builder>/build/git/stage-arm64/libexec/git-core   ← does not exist here
```

`--version`, `init` and local `clone` still work (git is a multi-call binary), but external
helpers fall back to whatever git the system provides.

So a version record may also declare:

```
min_client_version: "4.5.0"
```

4.5 reads it **before downloading** and stops with the next step spelled out
(`wave selfupdate`). `-F/--force` still gets through, with a warning — a forced install of a
tree record on an old client is known to be broken, not doubtful. A missing field means no
check, so index records that need it must say so; `docs/ADD-PACKAGE-CHECKLIST.md` requires it
for every tree package.

## `wave basedir`

The install root was only visible by opening `config.json`, yet it is the answer to "where is
the package, where is the link, what will uninstall delete".

```
$ wave basedir
🌊 ~/.local/macwave
$ wave basedir --raw
/Users/you/.local/macwave
```

Paths under your home directory are shown with `~`; `--raw` prints the absolute path exactly
as stored, because `~` only expands at the start of an unquoted word — `cd "$(wave basedir
--raw)"` would otherwise look for a directory literally named `~`. `-s/--silent` is refused:
the point of this command is the output.

## Downloads survive a broken connection

A transfer that dropped mid-body used to end the install. In a terminal it asked "retry?";
in `-s`, in CI, or with stdin redirected, nobody could answer, so the install was aborted.
The 2026-11-21 CI run is the example: 14.6 MB of `yq`, connection reset at the halfway point,
install failed.

Now:

| Where | Behaviour |
| --- | --- |
| stdin is a terminal | unchanged — it still asks `Do you want to retry? [y/N]` |
| non-interactive (`-s`, CI, `< /dev/null`) | retries twice (2s, then 4s), resuming with `Range` |
| still failing after 2 retries | stops with `Failed to download package after 2 retries` |

`ChunkedEncodingError` is in the retry set now: a truncated body surfaces as
`IncompleteRead`, which is not a `ConnectionError` subclass, so it used to fall through to
"give up immediately". Measured against a server that drops the first two responses:

```
🌊 Download failed: … IncompleteRead(524495 bytes read, 524496 more expected)
🌊 Retrying in 2s (1/2)
🌊 Download failed: … IncompleteRead(262351 bytes read, 262352 more expected)
🌊 Retrying in 4s (2/2)
🌊 Successfully installed test_retry@1.0
```

The second attempt only expected 262,352 bytes — the resume worked.

## 30 new packages

The supported list grows from 34 to 64. Two of them are **self-built**, because upstream
publishes no macOS binary at all; their build recipes and raw artifacts live in
[`MacWaveOrg/Ports`](https://github.com/MacWaveOrg/Ports):

| Package | Version | Why self-built |
| --- | --- | --- |
| `aria2c` | 1.37.0 | 1.36.0 dropped macOS builds; 1.35.0's `osx-darwin` is a 2022 x86_64 |
| `git` | 2.56.1 | `install: "tree"` — the first package that needed it |

The rest: `age`, `columbula`, `difft`, `doggo`, `duckdb`, `gh`, `gitleaks`, `glow`, `gping`,
`grpcurl`, `jless`, `just`, `k9s`, `kubectx`, `mise`, `mkcert`, `rclone`, `restic`, `robinsing`,
`shellcheck`, `shfmt`, `stern`, `tofu`, `typst`, `vhs`, `websocat`, `xh`, `yazi`, `zellij`.

`aria2c` links only system libraries (`libz`, `Security`, `CoreFoundation`, `libc++`,
`libSystem`) because it is built with `--with-appletls`; it therefore declares no `deps:` at
all.

## Fixes

- `wave uninstall` used to remove any rc line that mentioned the package, including lines
  that pointed at a different installation. It now only drops lines pointing at this machine's
  install root.

## Verify the download

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # everything OK
```

Signing key fingerprint: `7220E218395DE865AACC339167F14E52D0E229FB`
(`MacWave Release <macwaveorg@outlook.com>`).

---

# MacWave 4.5.0

发布：2026-11-22 · 构建号 `326G1231` · 分支 `4.5` ·
上一版 [4.4.1](RELEASE-4.4.1.md)

4.5 讲的是**一个可执行文件装不下的东西**。`wave install git` 现在能装了：版本记录可以声明
`install: "tree"`，安装器保留整棵目录，而不带版本号的链接仍然只指向一个命令。配套两件事 ——
客户端版本门槛（旧客户端读到这种记录会拒绝，而不是装一半）与下载中断自动重试（不再被第一次
连接重置判死）。同一版里还有 `wave basedir`、30 个新包，以及一处卸载修复。

## 一个包可以是一棵树

有些工具不是一个文件。`git` 需要 `libexec/git-core/git-remote-https` 与
`share/git-core/templates`；neovim、helix 需要 `runtime/`。版本记录现在可以写：

```
install: "tree"
```

安装器会把整棵解压目录保留在 `bin/<名称>@<版本>/` 下，写一个 `.is_a_tree` 标记，并且只把
`bin/<bin_name>` 链出去 —— 于是 `wave list`、`wave link`、`wave uninstall` 面对的仍然是一个
命令名。没有这个字段的记录仍是普通单文件包，所以此前能装的东西一个都没变。

这条路线上第一个包是 `git@2.56.1`。树本身 25 MB / 251 个文件，而 `git` 在运行时自己解析
前缀（上游 patch），这才是「搬到别处还能用」的关键：

```
$ …/links/git --exec-path
/…/bin/git@2.56.1/libexec/git-core
$ …/links/git ls-remote https://github.com/git/git HEAD
f7de81456940dd6f3274e461149bba12965de609	HEAD
```

## 旧客户端会拒绝它装不了的东西

`install: "tree"` 是 4.5 才有的。旧客户端**不会**报错 —— 它不认识这个字段，于是按单文件装，
只留一个文件。用 4.4.1 对着同一条记录实测：

```
🌊 Successfully installed git@2.56.1
🌊 Binary installed to: …/bin/git@2.56.1/git      ← 只有一个文件，3.7 MB
$ …/links/git --exec-path
/Users/<构建机>/build/git/stage-arm64/libexec/git-core   ← 本机不存在
```

`--version`、`init`、本地 `clone` 还能跑（git 是多调用二进制），但外部 helper 会退回到系统
自带的那份 git。

所以版本记录还可以写：

```
min_client_version: "4.5.0"
```

4.5 在**下载之前**读它并中止，同时把下一步写清楚（`wave selfupdate`）。`-F/--force` 仍能越过，
但会打黄字警告 —— 旧客户端强装 tree 记录是「确定坏」，不是「可能不兼容」。字段缺失时不检查，
所以需要它的记录必须自己写；`docs/ADD-PACKAGE-CHECKLIST.md` 要求每个 tree 包都写。

## `wave basedir`

安装根目录以前只能靠打开 `config.json` 才看得到，而它正是「包装在哪、链接在哪、卸载会删
什么」的答案。

```
$ wave basedir
🌊 ~/.local/macwave
$ wave basedir --raw
/Users/you/.local/macwave
```

家目录下的路径显示成 `~`；`--raw` 输出按存储原样的绝对路径 —— 因为 `~` 只在未加引号的词首
才展开，否则 `cd "$(wave basedir --raw)"` 会去找一个名字就叫 `~` 的目录。`-s/--silent` 被拒绝：
这条命令存在的意义就是输出。

## 下载能扛住一次断连

响应体读到一半断开，以前会让整次安装结束。在终端里它会问「要不要重试」；而在 `-s`、CI、
stdin 被重定向的场景，没有人能回答，于是安装直接失败。2026-11-21 那次 CI 就是例子：
`yq` 的 14.6 MB 下到一半连接被重置，安装以失败告终。

现在：

| 场景 | 行为 |
| --- | --- |
| stdin 是终端 | 不变 —— 仍然问 `Do you want to retry? [y/N]` |
| 非交互（`-s`、CI、`< /dev/null`） | 自动重试两次（2 秒、4 秒），用 `Range` 续传 |
| 两次重试后仍失败 | 以 `Failed to download package after 2 retries` 明确结束 |

`ChunkedEncodingError` 现在也在重试集合里：截断的响应体抛的是 `IncompleteRead`，它不是
`ConnectionError` 的子类，所以以前会落到「直接放弃」那条分支。对一个「前两次响应故意断开」
的服务器实测：

```
🌊 Download failed: … IncompleteRead(524495 bytes read, 524496 more expected)
🌊 Retrying in 2s (1/2)
🌊 Download failed: … IncompleteRead(262351 bytes read, 262352 more expected)
🌊 Retrying in 4s (2/2)
🌊 Successfully installed test_retry@1.0
```

第二次只期望 262,352 字节 —— 续传确实生效了。

## 30 个新包

支持清单从 34 个增长到 64 个。其中两个是**自建包**，因为上游根本不发 macOS 产物；构建配方与
原始产物放在 [`MacWaveOrg/Ports`](https://github.com/MacWaveOrg/Ports)：

| 包 | 版本 | 为什么自建 |
| --- | --- | --- |
| `aria2c` | 1.37.0 | 1.36.0 起不再发 macOS 产物；1.35.0 的 `osx-darwin` 是 2022 年的 x86_64 |
| `git` | 2.56.1 | 需要 `install: "tree"` —— 第一个走这条路线的包 |

其余：`age`、`columbula`、`difft`、`doggo`、`duckdb`、`gh`、`gitleaks`、`glow`、`gping`、
`grpcurl`、`jless`、`just`、`k9s`、`kubectx`、`mise`、`mkcert`、`rclone`、`restic`、`robinsing`、
`shellcheck`、`shfmt`、`stern`、`tofu`、`typst`、`vhs`、`websocat`、`xh`、`yazi`、`zellij`。

`aria2c` 只链系统库（`libz`、`Security`、`CoreFoundation`、`libc++`、`libSystem`），因为它用
`--with-appletls` 构建，所以整条记录里没有 `deps:`。

## 修复

- `wave uninstall` 以前会删掉任何提到该包的 rc 行，包括指向**别的安装**的行。现在只删指向
  本机安装根目录的那些。

## 校验下载

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # everything OK
```

签名密钥指纹：`7220E218395DE865AACC339167F14E52D0E229FB`
（`MacWave Release <macwaveorg@outlook.com>`）。
