# MacWave 4.4.0-rc

Prerelease (release candidate) · build `323R1307` · branch `4.4` ·
previous beta [4.4.0-beta3](RELEASE-4.4.0-beta3.md) · stable line `4.3.4`

This is the last checkpoint before 4.4.0. Nothing in it changes what MacWave does for
people who are not testing it — the three groups of changes below are the last of the
line: the installer now refuses to run on the wrong machine, downloads can be checked
against a key, and the RC line has its own version pointer so it can be published
without touching the stable one.

## Bottom line first

| Area | Before | Now |
| --- | --- | --- |
| Wrong machine | install "succeeded", every command failed afterwards | refused up front, with the reason and where to go next |
| Downloads | trusted the transport | checksums pinned to a signed manifest — **experimental, warn-only** |
| RC publishing | would have overwritten the stable pointer | own pointer in `rcdata/`, stable pointer untouched |

## 1. Experimental signing (expected to be the noisiest thing here)

4.4 is the first line that ships a key, and it is deliberately timid: **a failed check
warns and continues.** Old clients run their own old scripts — making verification
mandatory would lock them out, so the switch to enforcement waits until a signed line has
been in the field.

What is checked, and against what:

| Check | Pinned by | On mismatch |
| --- | --- | --- |
| `latest.toml` (version, branch, manifest hash) | RSA-3072 detached signature `latest.toml.sig` | warning |
| `update_commands.sh` (the script about to be executed by bash) | `update_commands_sha256` in that signed data | warning |
| Every downloaded file | `want <path> <x> <sha256>` — sha256 in the manifest | warning |

- `MACWAVE_WANT_HASHES=1` turns per-file checking on; the client sets it itself once it
  has a manifest hash. Unset = 4.4-before behaviour.
- `MACWAVE_STRICT_HASHES=1` turns warnings into failures. **That is the intended default
  later**, not now.
- Public keys live in `Keys/` and ship with the installation; the fingerprint whitelist
  lives in `net/signature.py` so key exchange shows up in a diff. Two keys, two jobs:
  OpenPGP for people (`gpg --verify SHA256SUMS.asc`), RSA for machines (LibreSSL on macOS
  cannot verify OpenPGP).

## 2. The RC line has its own pointer

```
rcdata/latest.toml                  RC only
macwavedata/latest.toml             stable only
```

- Channel is derived from what is installed: `X.Y.Z-rc` follows the RC pointer, everything
  else follows the stable one. No new state, no new flag.
- Successive builds of the same `X.Y.Z-rc` are told apart by the **build number**
  (`323R1303`), which is stored in `VERSION.json`. Comparing versions alone would report
  "already up to date" forever.
- When the RC line closes and stable is newer, the client crosses over as a **full**
  install (every file replaced). Copying stable increments onto an RC tree is how two
  branches end up in one tree — the 2026-11-15 breakage.
- Betas are still refused: they have no pointer of their own, so following the stable one
  would mix lines.

## 3. Refusing the wrong machine

- Non-macOS is refused before anything is downloaded: iOS (recognised from `hw.model`,
  `hw.machine`, `version.plist` — not from jailbreak traces, which both new and old
  jailbreaks get wrong in opposite directions), Android, ChromeOS.
- macOS older than 10.15 is refused by version, before download.
- Each refusal names what was detected and where the user should go instead, so nobody
  retries twice.

## Upgrading

Nothing to do for 4.3.x users: run the installer (or wait for `wave selfupdate` once
4.4.0 is out).

- **From a beta (4.4.0-beta1/2/3):** `wave selfupdate` refuses on purpose. Reinstall from
  the release page.
- **From this RC:** `wave selfupdate` follows the RC line; once 4.4.0 is out it crosses to
  stable as a full install.

## Verifying the download

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # everything OK
```

Signing key fingerprint: `7220E218395DE865AACC339167F14E52D0E229FB`
(`MacWave Release <macwaveorg@outlook.com>`). Machine-verification key:
`Keys/macwave-rsa.pub.pem`. See [Keys/README.md](../Keys/README.md).

---

# MacWave 4.4.0-rc

预发布（发布候选）· 构建号 `323R1307` · 分支 `4.4` ·
上一个 beta [4.4.0-beta3](RELEASE-4.4.0-beta3.md) · 稳定线 `4.3.4`

这是 4.4.0 之前的最后一个检查点。对不参与测试的人，它没有改变 MacWave 的任何行为 ——
下面三块是这条线最后的收尾：安装器认得出「这不是该装的机器」，下载内容可以对着公钥核对，
以及 RC 有了自己的版本指针，发 RC 不必碰正式版的指针。

## 先说结论

| 方面 | 之前 | 现在 |
| --- | --- | --- |
| 装错机器 | 「装成功了」，之后每条命令都失败 | 提前拒绝，说清原因与下一步 |
| 下载 | 信任传输层 | 校验值钉在签了名的清单上 —— **实验性，只警告** |
| 发 RC | 会覆盖正式版的指针 | 自己的指针在 `rcdata/`，正式版指针不动 |

## 1. 实验性签名（这一版最显眼的部分）

4.4 是第一条带公钥的发布线，而且刻意保守：**校验失败只警告，继续安装。**
老客户端跑的是自己那份老脚本 —— 让验签变成强制，等于让它们装不上。所以「强制」
要等一条带签名的发布线跑过一段时间之后。

校验什么、钉在哪：

| 检查 | 由什么钉住 | 不符时 |
| --- | --- | --- |
| `latest.toml`（版本、分支、清单哈希） | RSA-3072 分离签名 `latest.toml.sig` | 警告 |
| `update_commands.sh`（即将被 bash 执行的脚本） | 那份签名数据里的 `update_commands_sha256` | 警告 |
| 每个下载的文件 | `want <路径> <x> <sha256>` —— 哈希写在清单里 | 警告 |

- `MACWAVE_WANT_HASHES=1` 打开逐文件校验；客户端拿到清单哈希后自己置上。不设就是 4.4 之前的行为。
- `MACWAVE_STRICT_HASHES=1` 把警告变成失败。**这是以后的默认**，现在不设。
- 公钥在 `Keys/` 里随安装树下发；指纹白名单写在 `net/signature.py`，换钥会出现在 diff 里。
  两把钥两个用途：OpenPGP 给人验（`gpg --verify SHA256SUMS.asc`），RSA 给机器验
  （macOS 的 LibreSSL 验不了 OpenPGP）。

## 2. RC 有自己的一套指针

```
rcdata/latest.toml                 只属于 RC
macwavedata/latest.toml            只属于正式版
```

- 渠道由「装的是什么」推出来：`X.Y.Z-rc` 跟 RC 指针，其余跟正式版指针。不需要新状态、不需要新开关。
- 同一个 `X.Y.Z-rc` 的多次构建靠**构建号**（`323R1307`）区分，它记录在 `VERSION.json` 里。
  只比版本号会永远得出「已是最新」。
- RC 渠道收尾、正式版更新时，客户端以**全量**方式切过去（每个文件整体替换）。
  把正式版的增量铺在 RC 树上，就是两条分支混在一棵树里 —— 2026-11-15 那次故障。
- beta 仍然拒绝：它们没有自己的指针，跟着正式版走就会混分支。

## 3. 拒绝装错机器

- 非 macOS 在下载任何东西之前就拒绝：iOS（用 `hw.model`、`hw.machine`、`version.plist` 判定，
  不看越狱痕迹 —— 新式无根越狱会刻意隐藏、老式有根越狱根本不建 `/var/jb`，两边都错）、
  Android、ChromeOS。
- 低于 macOS 10.15 直接拒绝，也在下载之前。
- 每次拒绝都说明检测到什么、应该去哪，避免用户重试第二次。

## 升级

4.3.x 用户什么都不用做：跑安装器（等 4.4.0 成为稳定指针后也可以 `wave selfupdate`）。

- **从 beta（4.4.0-beta1/2/3）**：`wave selfupdate` 会拒绝，这是有意的。请从 Release 页面重装。
- **从本 RC**：`wave selfupdate` 跟 RC 线；4.4.0 发布后会以全量方式切到正式版。

## 核对你下载的东西

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # 全部 OK
```

签名指纹：`7220E218395DE865AACC339167F14E52D0E229FB`
（`MacWave Release <macwaveorg@outlook.com>`）。机器验签公钥：`Keys/macwave-rsa.pub.pem`。
详见 [Keys/README.md](../Keys/README.md)。
