# MacWave 4.2.4 Release Notes

- Released: 2026-11-04, build `308A1614`
- Branch: `4.2`
- Previous release: [4.2.3](RELEASE-4.2.3.md) (same day, critical fix)

## Summary

**Exactly one decorative element of `install.sh` changed**: the WAVE ASCII art is back.
Runtime code, index data and package installation logic are byte-for-byte unchanged.

## What happened

| Time | Commit | Action |
| --- | --- | --- |
| 14:13 | `6077937` | adds `SKY_BLUE` and the `██╗ ██╗` WAVE banner |
| 14:18 | `78e6e8c` | adds `set -u`; the banner disappears |
| 14:19 | `89ec087` | adds `set -o pipefail` |

The parent of `78e6e8c` is the commit **before** `6077937` (`cdc0c0e`) — it was re-edited
from an older version instead of being stacked on top of the banner, so the banner was
overwritten, not deliberately removed.

A `git rebase --onto` in between then dropped `6077937` from the branch, so in the history it
looked as if the banner had never existed. It was in the object database the whole time, and is
restored verbatim in this release.

## What it looks like now

```
██╗    ██╗ █████╗ ██╗   ██╗███████╗
██║    ██║██╔══██╗██║   ██║██╔════╝
██║ █╗ ██║███████║██║   ██║█████╗
██║███╗██║██╔══██║╚██╗ ██╔╝██╔══╝
╚███╔███╔╝██║  ██║ ╚████╔╝ ███████╗
 ╚══╝╚══╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝

🌊 欢迎使用 MacWave 4.2.4！
```

The banner is language-independent and prints under both `--zh` and the default English; the
welcome line still goes through `mw_say()`, so each language speaks for itself.

## ⚠️ Important: `wave selfupdate` will not show you this banner

`lib/install.sh` is in the `EXCLUDED` list of `scripts/build_update_commands.py` — it does not
take part in self-update (every install fetches and executes it fresh, so installing it into
the install tree would be pointless). Therefore:

| Location | Has the banner? |
| --- | --- |
| Repository `lib/install.sh` | ✅ |
| `raw.githubusercontent` / mirror `core/4.2/` | ✅ |
| Install tree `~/.local/macwave/lib/install.sh` | ❌ **always the copy from the first install** |
| Files fetched by `wave selfupdate` | ❌ `install.sh` is not among them |

In other words: **to see the banner you must run the install command again**; `wave selfupdate`
to 4.2.4 updates the other files, and the banner will not appear.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" -- --zh
```

## Should you upgrade

**Not upgrading is perfectly fine.** 4.2.3 already fixed the fatal problem (`unbound variable`
under a UTF-8 locale) and is functionally identical to 4.2.4; the only difference is one wave
missing at install time.

Only machines that want to see the banner need to upgrade.

## How to upgrade

```bash
wave selfupdate
```

## Data shipped with this release

| Repository | Content |
| --- | --- |
| `Selfupdate` | `macwavedata/4.2.4/update_commands.sh` |
| `configdata` | `latest_version` → 4.2.4 |
| `Pages` | version → 4.2.4 |

---

# MacWave 4.2.4 发布说明

- 发布：2026-11-04，构建号 `308A1614`
- 分支：`4.2`
- 上一版：[4.2.3](RELEASE-4.2.3.md)（同日，紧急修复）

## 概述

**只改了 `install.sh` 的一个装饰元素**：把 WAVE 的 ASCII 艺术字补回来。
运行时代码、索引数据、包安装逻辑一个字节都没动。

## 发生了什么

| 时间 | 提交 | 动作 |
| --- | --- | --- |
| 14:13 | `6077937` | 加了 `SKY_BLUE` 与 `██╗ ██╗` 的 WAVE 横幅 |
| 14:18 | `78e6e8c` | 加 `set -u`；横幅不见了 |
| 14:19 | `89ec087` | 加 `set -o pipefail` |

`78e6e8c` 的父提交是 `6077937` **之前**的那个（`cdc0c0e`），也就是它从旧版重新
编辑而不是叠在横幅之上 —— 所以横幅是被覆盖掉的，不是有意删除。

中间还有一次 `git rebase --onto`，把 `6077937` 从分支上摘掉了，于是历史里看起来
「从未有过这个横幅」。它其实一直在对象库里，这次照原样取回。

## 现在的样子

```
██╗    ██╗ █████╗ ██╗   ██╗███████╗
██║    ██║██╔══██╗██║   ██║██╔════╝
██║ █╗ ██║███████║██║   ██║█████╗
██║███╗██║██╔══██║╚██╗ ██╔╝██╔══╝
╚███╔███╔╝██║  ██║ ╚████╔╝ ███████╗
 ╚══╝╚══╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝

🌊 欢迎使用 MacWave 4.2.4！
```

横幅与语言无关，`--zh` 和默认英文都打；欢迎语那一行继续走 `mw_say()`，所以两种语言
各说各的。

## ⚠️ 关键：`wave selfupdate` 看不到这个横幅

`lib/install.sh` 在 `scripts/build_update_commands.py` 的 `EXCLUDED` 里 ——
它不参与自更新（每次安装都是从远端现取执行，装进安装树没有意义）。所以：

| 位置 | 有横幅吗 |
| --- | --- |
| 仓库 `lib/install.sh` | ✅ |
| 线上 `raw.githubusercontent` / 镜像 `core/4.2/` | ✅ |
| 安装树 `~/.local/macwave/lib/install.sh` | ❌ **永远是首次安装时那份** |
| `wave selfupdate` 下载的文件 | ❌ 不含 `install.sh` |

也就是说：**想看横幅，必须重新运行一次安装命令**；`wave selfupdate` 到 4.2.4
只会更新其它文件，横幅不会出现。

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" -- --zh
```

## 要不要升级

**不升也完全可以。** 4.2.3 已经修完了那个致命问题（UTF-8 locale 下
`unbound variable`），功能上与 4.2.4 完全一致，差别只是安装时少一朵浪。

只有想看到横幅的机器需要升。

## 升级方式

```bash
wave selfupdate
```

## 本版随附的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.2.4/update_commands.sh` |
| `configdata` | `latest_version` → 4.2.4 |
| `Pages` | 版本号 → 4.2.4 |
