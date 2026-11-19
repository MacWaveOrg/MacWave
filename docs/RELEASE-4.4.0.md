# MacWave 4.4.0

Released: 2026-11-19 · build `323D1346` · branch `4.4` ·
previous stable 4.3.4 ·
detail per stage: [beta1](RELEASE-4.4.0-beta1.md) · [beta2](RELEASE-4.4.0-beta2.md) ·
[beta3](RELEASE-4.4.0-beta3.md) · [rc](RELEASE-4.4.0-rc.md)

> This file supersedes the 2026-11-09 draft that carried build `313B1740`; that plan became
> 4.4.0-beta1 and the line has moved on since.

4.4 is a "make the failure happen earlier" release. Almost everything in it moves a problem
from *after* the user has committed — installed, configured, half-running — to *before*
anything is downloaded, and says what to do instead. Two structural changes ride along: the
installer now knows what machine it is on, and the download path can be checked against a
key.

## Bottom line first

| Area | Before 4.4 | Now |
| --- | --- | --- |
| Wrong machine (iOS, Android, ChromeOS, old macOS) | installed, then every command failed | refused before download, with the reason and an alternative |
| Elevation | "is the target outside `$HOME`" | write permission, confirmed by a real write probe |
| Sealed system volume / SIP | not considered | checked before download; unsealed systems continue with a warning |
| Scripted install | spinner, ANSI, `--help` fetched the network | `--raw`, `--print-usage`, `--help` offline |
| Version comparison | three implementations | one (`lib/versioncompare.py`), channels and build numbers included |
| Download integrity | transport only | checksums pinned to a signed manifest (**experimental, warn-only**) |

## 1. Which machine are we on

`lib/install.sh` decides this first, before the version request, before `sudo`, before
anything is written.

- **macOS older than 10.15** — refused by version. The bundled interpreter and the command
  set do not exist there.
- **iOS** — refused. iOS also reports `Darwin`, so the kernel alone cannot tell them apart;
  the decision uses `hw.model`, `hw.machine` and `version.plist`, i.e. information the
  kernel supplies. Jailbreak traces (`/var/jb`, `/private/var/mobile`) are only a fallback:
  new-style rootless jailbreaks hide deliberately, old-style rooted ones never create
  `/var/jb`, so trusting them gets both directions wrong. Creating `/var/jb` on a Mac does
  not fool it.
- **Android and ChromeOS** — refused. Both can run `bash` and look installable; Android has
  no glibc, ChromeOS is a container. Better to say so once than to fail at the first
  command.
- Each refusal prints what was detected and where to go instead.

**Elevation and the system volume**

- Permission *bits* are only the first check: an empty probe file is created in the nearest
  existing directory and immediately removed. `Permission denied` means `sudo`; anything
  else (ENOSPC, read-only mount) is a hard error, because dressing an environment problem up
  as a password prompt wastes the user's time.
- Targets inside SIP's range are checked for a sealed system volume first — that refusal is
  the kernel's and `sudo` does not help. Unsealed systems (OCLP and friends) warn and
  continue. Unknown state proceeds: otherwise every container and every 10.x box is locked
  out.
- `--skip-probe` keeps the old bits-only check; `--dry-run` never writes, so it uses bits.

## 2. The installer, as something a script can drive

- `--raw`: no ASCII art, no colour, no spinner, no cursor movement; downloads print one
  `####` line per 10% (unknown length → per MiB). Same semantics as `wave install --raw`.
- `--print-usage` prints usage and continues; `--help` prints usage and stops — and neither
  touches the network any more. Arguments are parsed exactly once, before the version
  request.
- **Agreement** is asked once, normalised (`y`/`yes`/empty → yes, `n`/`no` → no, anything
  else asks again, three times, then counts as no), and *recorded* — 4.3 promised to write
  `AGREEMENT.json` and did not. Upgrades across a major version no longer ask: the
  "reinstall from the release page" guard speaks first.
- **Rollback never deletes an existing installation.** The tree is only removed if this run
  created it (`TREE_PREEXISTED`); otherwise the message is "your existing installation is
  untouched, re-run the installer to continue".
- An incomplete tree is repaired rather than trusted: `VERSION.json` plus `lib/wave.py`
  existing was not proof that the last update finished.
- Installer exit codes have meaning now (`0` done, `1` refused/failed, `2` usage, `3`
  needs privileges, `4` platform), so CI and wrappers can branch on them.

**One more thing, deliberately vague:** the installer opens and closes with a little
terminal decoration, and there are one or two other small things in there for people who
read the script end to end. They are not listed here on purpose.

## 3. One CLI, one parser, one command table

- Common flags (`--verbose`, `--resume`, `--skip-ssl`, `--proxy`, `--max-time`,
  `--limit-rate`, …) go through a single `cli/common.parse()`. A malformed `--proxy` or
  `--max-time` now fails with the same wording and the same exit code in
  `install`/`selfupdate`/`latest`/`info`/`mirror` — they used to differ per command.
- Subcommands and their help live in `cli/commands.py`; `wave -h`, `-h --zh` and the 15
  per-command help pages are generated from it, and `scripts/commands_test.sh` keeps the
  metadata honest.
- `--unlink` is now `--no-link` (the old name still works and is labelled as the old name).
- `wave selfupdate --dry-run`: prints the plan — current → target, branch, whether the
  agreement will be asked, the three timeouts — before the agreement question, then exits.
  Nothing is downloaded, nothing is written.
- `wave shellenv` and `wave manual` are documented in both READMEs and on the website.

## 4. Network failures that say what to do

- TLS failures are classified into five kinds — expired (`notAfter` printed), self-signed or
  private CA, incomplete chain, hostname mismatch, plain network — each with its own next
  step. Hostname mismatch says *do not* bypass, and why.
- `MACWAVE_CACERT` points at an extra root certificate (PEM); it is validated up front
  rather than silently ignored, and applies to `requests`, `urllib` and `curl` alike.
  Precedence: `--skip-ssl` > `MACWAVE_CACERT` > system store.
- Every `MACWAVE_*` variable that is actually read is listed in `config/envvar.py`, and
  `scripts/check_domain_defaults.py` fails if a documented name, a package-index name, or an
  unregistered name appears. Six variables that were written and never read were removed.

## 5. Versions, channels, builds

- `lib/versioncompare.py` is the only version comparison in the project (three used to
  exist, and a beta counted as *newer* than its release).
- Channel follows what is installed: `X.Y.Z-rc` reads `rcdata/latest.toml`, everything else
  reads `macwavedata/latest.toml`. Betas are still refused — they have no pointer of their
  own, and following the stable one mixes two lines in one tree.
- Build numbers are part of the decision now, not just decoration: same version, newer build
  means a newer build. Format is `<days since 2026-01-01><letter><HHMM>`, the letter
  encoding channel and weekday: `A`-`G` stable (Mon-Sun), `H` special dates, `I`-`O` beta
  (`P` special), `R` always for RC.
- When the RC line closes, the client crosses to stable as a **full** install.

## 6. Experimental signing

4.4 is the first line that ships a key: an OpenPGP key in `Keys/` with its fingerprint
pinned in `net/signature.py`, plus an RSA key for machines, because LibreSSL on macOS
cannot verify OpenPGP. `latest.toml` gets a detached signature, the update script is pinned
by a hash inside that signed data, and every downloaded file carries its own hash.

**A failed check warns and continues.** Enforcement (`MACWAVE_STRICT_HASHES=1`) is the
intended default later, once a signed line has been in the field: old clients run their own
old scripts, so turning it on now would lock them out. The full table, the switches and the
key layout are in [the RC notes](RELEASE-4.4.0-rc.md) and
[Keys/README.md](../Keys/README.md).

## 7. Smaller things worth knowing

- `wave uninstall` exit codes have meanings, and a failure part-way no longer aborts the
  rest of the removal; the `sed` fallback removes the `# MacWave` marker line too.
- Dependencies without a checksum are refused instead of installed (index data defect, not
  a user problem).
- Documentation: `AGENTS.md` gained the CI-ONLY boundary rules, `docs/CODE-MAP.md` moved
  `config/` to where it actually lives, and the manual documents `MACWAVE_CACERT`.

## Upgrading

| From | How |
| --- | --- |
| 4.3.x | installer, or `wave selfupdate` once this release is the stable pointer |
| 4.4.0-beta1/2/3 | `wave selfupdate` refuses on purpose — reinstall from the release page |
| 4.4.0-rc | `wave selfupdate` crosses to this release as a full install |

## Verifying the download

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # everything OK
```

Signing key fingerprint: `7220E218395DE865AACC339167F14E52D0E229FB`
(`MacWave Release <macwaveorg@outlook.com>`).

---

# MacWave 4.4.0

发布：2026-11-19 · 构建号 `323D1346` · 分支 `4.4` ·
上一个稳定版 4.3.4 ·
各阶段细节：[beta1](RELEASE-4.4.0-beta1.md) · [beta2](RELEASE-4.4.0-beta2.md) ·
[beta3](RELEASE-4.4.0-beta3.md) · [rc](RELEASE-4.4.0-rc.md)

> 本文件取代 2026-11-09 那份构建号 `313B1740` 的草稿 —— 那个计划后来成了 4.4.0-beta1，
> 这条线之后又走了很远。

4.4 是一个「让失败提前发生」的版本。几乎每一项改动都把问题从*用户已经付出代价之后*
（装好了、配置写了、半跑着）挪到*下载任何东西之前*，并说清下一步该做什么。
另有两个结构性变化：安装器现在认得出自己在什么机器上，下载路径可以对着公钥核对。

## 先说结论

| 方面 | 4.4 之前 | 现在 |
| --- | --- | --- |
| 装错机器（iOS、Android、ChromeOS、旧 macOS） | 装上了，之后每条命令都失败 | 下载前拒绝，给出原因与替代做法 |
| 提权 | 「目标是否在家目录之外」 | 写权限，并用一次真实写入探针确认 |
| 系统卷密封 / SIP | 不考虑 | 下载前检查；未密封的系统警告后继续 |
| 脚本化安装 | 转圈动画、ANSI、`--help` 会联网 | `--raw`、`--print-usage`、`--help` 不联网 |
| 版本比较 | 三份实现 | 一份（`lib/versioncompare.py`），含渠道与构建号 |
| 下载完整性 | 只靠传输层 | 校验值钉在签了名的清单上（**实验性，只警告**） |

## 1. 先问「这是什么机器」

`lib/install.sh` 先判这个，早于取版本号、早于 `sudo`、早于写任何文件。

- **低于 macOS 10.15** —— 按版本拒绝。那套捆绑解释器与命令集在那上面不存在。
- **iOS** —— 拒绝。iOS 也报 `Darwin`，光看内核分不出来；判定用 `hw.model`、`hw.machine`
  与 `version.plist`，也就是内核给出的信息。越狱痕迹（`/var/jb`、`/private/var/mobile`）
  只作兜底：新式无根越狱会刻意隐藏，老式有根越狱根本不建 `/var/jb`，两边都会错。
  而在 Mac 上手动 `mkdir /var/jb` 骗不过它。
- **Android 与 ChromeOS** —— 拒绝。两者都能跑 `bash`、看起来「有终端就能装」；
  Android 没有 glibc，ChromeOS 只是个容器。说清一次，比在第一条命令上失败好。
- 每次拒绝都说明检测到什么、应该去哪里。

**提权与系统卷**

- 权限位只是第一道检查：在最靠近的可写目录里建一个空探针文件再立刻删掉。
  `Permission denied` 意味着要 `sudo`；其它原因（ENOSPC、只读挂载）是硬错误 ——
  把环境问题包装成密码提示，是在浪费用户的时间。
- 目标落在 SIP 范围内时，先检查系统卷是否密封 —— 那是内核的拒绝，`sudo` 也没用。
  未密封（OCLP 那类）警告后继续。状态未知则放行：否则每个容器、每台 10.x 都会被锁在门外。
- `--skip-probe` 保留旧的「只看权限位」；`--dry-run` 不写文件，因此也用权限位。

## 2. 安装器，作为「可以被脚本驱动的东西」

- `--raw`：没有艺术字、颜色、转圈动画与光标控制；下载每 10% 打一行 `####`
  （长度未知时按 MiB）。语义与 `wave install --raw` 相同。
- `--print-usage` 打用法后继续；`--help` 打用法就停 —— 两者都不再联网。
  参数只解析一次，且早于取版本号。
- **协议**只问一次，答复归一化（`y`/`yes`/空 → 同意，`n`/`no` → 拒绝，其它重问，
  最多三次，三次后按拒绝处理），并且**真的写下来** —— 4.3 承诺写 `AGREEMENT.json` 却没有写。
  跨大版本的升级不再问协议：「请去发布页重装」那条守卫先说话。
- **回滚绝不删除已有安装。** 只有这次安装自己建的树才删（`TREE_PREEXISTED`）；
  否则提示「已有安装保持原样，重新运行安装器可继续」。
- 安装树不完整时**修**而不是信：`VERSION.json` 与 `lib/wave.py` 都在，不等于上次更新跑完了。
- 安装器的退出码有语义了（`0` 完成、`1` 拒绝/失败、`2` 用法、`3` 需要提权、`4` 平台），
  CI 与包装脚本可以据此分支。

**还有一件故意说不细的事：** 安装器开头和结尾有一点终端装饰，脚本里还藏着一两处给
「从头读到尾的人」的小东西。这里就不列了 —— 列出来就不是彩蛋了。

## 3. 一个 CLI，一个解析器，一张命令表

- 公共旗标（`--verbose`、`--resume`、`--skip-ssl`、`--proxy`、`--max-time`、`--limit-rate` …）
  统一走 `cli/common.parse()`。写错的 `--proxy` 或 `--max-time` 现在在
  `install`/`selfupdate`/`latest`/`info`/`mirror` 给出同样的措辞与退出码 —— 以前每个命令各说各的。
- 子命令与帮助集中在 `cli/commands.py`；`wave -h`、`-h --zh` 与 15 个分命令帮助都由它生成，
  `scripts/commands_test.sh` 保证元数据不漂。
- `--unlink` 改名为 `--no-link`（旧名仍可用，帮助里标明是旧名）。
- `wave selfupdate --dry-run`：在问协议之前打印计划 —— 当前 → 目标、分支、构建号、渠道、
  协议会不会问、三档超时 —— 然后退出。不下载、不写入。
- `wave shellenv` 与 `wave manual` 进了两份 README 与官网。

## 4. 会告诉你下一步的网络失败

- TLS 失败分五类 —— 过期（打印 `notAfter`）、自签或私有 CA、链不完整、主机名不匹配、
  纯网络问题 —— 每类各有下一步。主机名不匹配会明确说「不要绕过」，并说明原因。
- `MACWAVE_CACERT` 指向额外的根证书（PEM）；它会先做可用性校验而不是被静默忽略，
  且对 `requests`、`urllib`、`curl` 三条传输都生效。优先级：`--skip-ssl` > `MACWAVE_CACERT` > 系统证书库。
- 所有真正会被读取的 `MACWAVE_*` 变量都登记在 `config/envvar.py`，`scripts/check_domain_defaults.py`
  会在「文档里写了、包索引里写了、或没登记」时失败。六个「写了没人读」的变量被删掉。

## 5. 版本、渠道、构建号

- `lib/versioncompare.py` 是全项目唯一的版本比较（以前有三份，而且 beta 被算得比正式版*更新*）。
- 渠道跟着「装的是什么」走：`X.Y.Z-rc` 读 `rcdata/latest.toml`，其余读 `macwavedata/latest.toml`。
  beta 仍然拒绝 —— 它们没有自己的指针，跟着正式版走就会混分支。
- 构建号现在参与判断，不再只是装饰：版本相同、构建号更新就是有新版。格式是
  `<距 2026-01-01 的天数><字母><HHMM>`，字母编码渠道与周几：`A`-`G` 正式版（周一-周日）、
  `H` 特殊日期、`I`-`O` beta（`P` 特殊）、`R` 固定用于 RC。
- RC 渠道收尾时，客户端以**全量**方式切到正式版。

## 6. 实验性签名

4.4 是第一条带公钥的发布线：`Keys/` 里一把 OpenPGP 钥，指纹钉在 `net/signature.py`；
另有一把 RSA 钥给机器用，因为 macOS 的 LibreSSL 验不了 OpenPGP。`latest.toml` 有分离签名，
更新脚本被签名数据里的哈希钉住，每个下载文件各自带哈希。

**校验失败只警告，继续安装。** 强制（`MACWAVE_STRICT_HASHES=1`）是以后的目标默认值，
要等带签名的发布线在场上跑过一段：老客户端跑的是自己那份老脚本，现在打开等于把它们锁在门外。
完整表格、开关与密钥布局见 [RC 说明](RELEASE-4.4.0-rc.md) 与
[Keys/README.md](../Keys/README.md)。

## 7. 其它值得知道的

- `wave uninstall` 的退出码有语义，中途失败不再中断后面的删除；`sed` 兜底也会删掉 `# MacWave` 标记行。
- 没有校验值的依赖会被拒绝安装，而不是装上（这是索引数据缺陷，不是用户的问题）。
- 文档：`AGENTS.md` 补上 CI-ONLY 边界规则，`docs/CODE-MAP.md` 把 `config/` 挪回它实际所在的位置，
  手册补上 `MACWAVE_CACERT`。

## 升级

| 从 | 怎么升 |
| --- | --- |
| 4.3.x | 跑安装器；等本版成为稳定指针后也可以 `wave selfupdate` |
| 4.4.0-beta1/2/3 | `wave selfupdate` 会拒绝（有意）—— 从发布页重装 |
| 4.4.0-rc | `wave selfupdate` 以全量方式切到本版 |

## 核对你下载的东西

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # 全部 OK
```

签名指纹：`7220E218395DE865AACC339167F14E52D0E229FB`
（`MacWave Release <macwaveorg@outlook.com>`）。
