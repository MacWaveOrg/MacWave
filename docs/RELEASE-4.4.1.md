# MacWave 4.4.1

Released: 2026-11-19 · build `323D1524` · branch `4.4` ·
previous release [4.4.0](RELEASE-4.4.0.md)

A one-bug release. 4.4.0 could record a version it had not actually installed, and once it
did, nothing would ever repair the tree. Two smaller things in the same area: a download
failure now says when the whole branch is missing from the mirror, and `README.md` files are
no longer part of the install list.

## The bug

The installer wrote `VERSION.json` **before** downloading the program files. `VERSION.json`
is the only thing the client uses to decide "is this installed, and is it up to date", so a
failure in between left the worst possible state:

```
VERSION.json says 4.4.0
the tree is still 4.3.x
wave selfupdate compares 4.4.0 with 4.4.0 and reports "already up to date"
```

That is exactly what happened on release day: the mirror had not synced `core/4.4` yet, the
first download returned 404, and the machine was stuck looking current while running old
code. Retrying the installer worked; `wave selfupdate` could not.

`VERSION.json` is now written after `update_commands.sh` succeeds, together with the
`root:admin` hand-over of the config directory (that hand-over used to happen earlier, which
is why the file had to be written early — both moved together).

## Also in this release

- **Two outputs that forgot their language.** The manifest template printed "the installed
  tree is incomplete" twice — once in English, once in Chinese — so English users saw a
  Chinese line and Chinese users saw an English one. And the dependency note during package
  installation carried a hard-coded Chinese suffix (`(被 zstd 引用)`); it now reads
  `(referenced by zstd)`.

- **A download failure now names the likely cause.** Every failed file prints a line saying
  that, if *every* file fails the same way, the mirror has not synced that branch yet. A
  single missing file and an entire missing branch used to look identical in the log.
- **`README.md` is no longer downloaded.** It is documentation for people reading the
  repository; nothing in the installed tree reads it, but a 404 on it aborted the whole
  install. The install list drops from 73 files to 72 (`Keys/` keeps its public keys).

## Upgrading

| From | How |
| --- | --- |
| 4.4.0 | `wave selfupdate`, or rerun the installer |
| 4.3.x | the installer, or `wave selfupdate` |
| 4.4.0-beta1/2/3 | reinstall from the release page (betas are refused) |
| 4.4.0-rc | `wave selfupdate` crosses to the stable line as a full install |

If you are one of the machines left in the "4.4.0 recorded, 4.3.x installed" state:
4.4.1 is the way out, because the version numbers finally differ. Nothing needs to be
deleted by hand.

## Verifying the download

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # everything OK
```

Signing key fingerprint: `7220E218395DE865AACC339167F14E52D0E229FB`
(`MacWave Release <macwaveorg@outlook.com>`).

---

# MacWave 4.4.1

发布：2026-11-19 · 构建号 `323D1524` · 分支 `4.4` ·
上一版 [4.4.0](RELEASE-4.4.0.md)

一个 bug 的补丁版。4.4.0 有可能把「没装上的版本」记下来，而一旦记下，任何东西都不会
再去修那棵树。同一个地方还有两处小改动：下载失败时会说清「可能是整个分支没同步」，
以及 `README.md` 不再进入安装清单。

## 这个 bug

安装器**先写** `VERSION.json`、**后下**程序文件。而 `VERSION.json` 是客户端判断
「装了没、是不是最新」的唯一依据，所以中途失败会留下最糟的状态：

```
VERSION.json 写着 4.4.0
树还是 4.3.x
wave selfupdate 拿 4.4.0 和 4.4.0 比较，回答「已是最新」
```

发版当天就是这样：镜像还没同步 `core/4.4`，第一个下载就 404，机器看着是最新的、
跑的却是旧代码。重跑安装器能救；`wave selfupdate` 救不了。

现在 `VERSION.json` 在 `update_commands.sh` 成功之后才写，配置目录交还 `root:admin`
也跟着挪到那之后（交还原本更早，这正是当初必须提前写文件的原因 —— 两者一起挪）。

## 同一版里的另外两处

- **两处漏了语言的输出。** 清单模板把「安装树不完整」打了两遍 —— 一遍英文一遍中文，
  于是英文用户会看到中文那行、中文用户会看到英文那行。另外装包时那句依赖说明里写死了
  中文后缀（`(被 zstd 引用)`），现在读作 `(referenced by zstd)`。

- **下载失败现在会指出可能的原因。** 每个失败的文件后面都会打一句：如果每个文件都
  这样，说明镜像还没同步这个分支。以前「单个文件缺失」和「整棵分支缺失」在日志里
  长得一模一样。
- **`README.md` 不再下载。** 它是写给仓库读者看的说明，安装树里没人读，但它一 404
  就会中止整个安装。清单从 73 个文件降到 72 个（`Keys/` 里只留公钥）。

## 升级

| 从 | 怎么升 |
| --- | --- |
| 4.4.0 | `wave selfupdate`，或重跑安装器 |
| 4.3.x | 跑安装器，或 `wave selfupdate` |
| 4.4.0-beta1/2/3 | 从发布页重装（beta 会被拒绝） |
| 4.4.0-rc | `wave selfupdate` 以全量方式切到稳定线 |

如果你正是那台「记着 4.4.0、装着 4.3.x」的机器：4.4.1 就是出路，因为版本号终于不同了。
不需要手工删任何东西。

## 核对你下载的东西

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # 全部 OK
```

签名指纹：`7220E218395DE865AACC339167F14E52D0E229FB`
（`MacWave Release <macwaveorg@outlook.com>`）。
