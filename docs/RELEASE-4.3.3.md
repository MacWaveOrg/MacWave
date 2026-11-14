# MacWave 4.3.3 Release Notes

- Released: 2026-11-14, build `318F1452`
- Branch: `4.3` (the 4.3 line; `4.4` is a separate line)
- Previous release: [4.3.2](RELEASE-4.3.2.md)
- **Security fix**: answering "no" to the `--skip-ssl` warning did not stop the command

## Bottom line first

`--skip-ssl` prints a warning and asks *"Are you sure?"*. Up to 4.3.2, **any** answer other
than `y` / `Y` let the install continue — it only kept certificate verification switched on.
If you answered `no` and the command went on to download and install a package, that is this
bug: the confirmation was not a gate.

| Answer to "Are you sure?" | 4.3.2 and earlier | 4.3.3 |
| --- | --- | --- |
| `y` / `Y` | skips verification and installs | same |
| `n`, bare Enter, `yes`, anything else, EOF | ❌ installs anyway | ✅ stops with exit code 1, nothing downloaded |
| `-s` / `--silent` | no prompt, honours the flag | same |

✅ = the command stopped, which is what the answer asked for.
❌ = the command went ahead without consent.

## Why this is a security update

A confirmation that cannot say "no" is decorative. Concretely, in 4.3.2:

- you decline, and a package is installed anyway;
- because verification stayed on, the install then often **fails with an SSL error** — which
  reads exactly like "`--skip-ssl` doesn't work", so the natural next move is to retry with
  `-F`, i.e. to add *more* force to a command whose confirmation you had just refused;
- `wave upgrade --all` was worse still: it ignored the answer entirely
  (`pkg/upgrader.py` called `confirm_skip_ssl(words)` and dropped the return value), so a
  batch upgrade ran after you said no.

**What was *not* at risk**: declining always kept `verify=True`. `lib/tls.py`'s `revoke()`
resets both `_requested` and `_enabled`, so no request went out over an unverified
connection. Nothing was fetched from an unauthenticated peer. The defect is the bypassed
consent and the misleading failure mode, not a MITM window.

## Root cause

`confirm_skip_ssl()` returned a boolean, and the caller read `False` as "don't skip
verification — but carry on":

```python
config["skip_ssl_verify"] = confirm_skip_ssl(flags)      # False → keep installing
```

The function's own docstring described the prompt as a safety question, and the `-s` branch
was written on the assumption that a decline would abort ("若这里默默拒绝，装失败时会抛一个
SSL 错误"). Only the interactive path was missing that behaviour.

## The fix

1. **Allowlist, not denylist.** Only `y` / `Y` proceeds. `n`, an empty answer, `yes`, EOF and
   anything else fall through to the refusal branch. (`confirm_skip_ssl` now reads
   `if confirm not in ("Y", "y")`.)
2. **The abort happens inside the function** (`steplog.fail`), not at the call sites. That is
   what makes `wave install` and `wave upgrade --all` behave identically — the upgrader never
   read the return value, so no call-site fix could have covered it.
3. **The prompt says what it accepts**: `… Are you sure? [y/N]`, and it is printed in red
   (`RED_BOLD`), matching the existing "Do you want to retry? [y/N]" prompt. It is the only
   place in the tool where the user is asking to lower security.
4. **`-s` is unchanged**: silent mode never prompted, never asks, and still honours the flag
   the user wrote. Changing that would turn a scripted install into a silent failure.

## Evidence

Refusing on 4.3.3:

```console
$ printf 'n\n' | wave install jq --skip-ssl
🌊 You selected --skip-ssl, this will skip SSL certificate verification, which may cause security risks. Are you sure? [y/N]
🌊 Error: not installing with --skip-ssl: the confirmation was declined
🌊 Next      nothing was downloaded or installed
🌊           run it again and answer y at the prompt to skip verification
🌊           or drop --skip-ssl if certificate verification works on this network
$ echo $?
1
```

Same input on 4.3.2 (reported by a user; reproduced before the fix):

```console
$ wave install jq --skip-ssl
🌊 You selected --skip-ssl, this will skip SSL certificate verification, which may cause security risks. Are you sure?
n
🌊 Fetching version info...
🌊 Version info fetched successfully.
🌊 Successfully installed jq@1.8.2          ← installed after answering "no"
```

Self-check you can run yourself — the exit code is the whole difference:

```bash
wave install jq --skip-ssl      # answer n
echo $?                         # 4.3.3: 1 (and nothing was downloaded)
                                # 4.3.2: 0, package installed
```

Positive control — answering `y` still installs, so the fix did not break the feature:

```console
$ printf 'y\n' | wave install jq --skip-ssl
🌊 You selected --skip-ssl, … Are you sure? [y/N]
🌊 Fetching version info...
… successfully installed
```

## Tests

| Script | 4.3.2 → 4.3.3 |
| --- | --- |
| `scripts/message_test.sh` | 61 → 70 |
| `scripts/random_test.py` (`run_skip_ssl_case`) | asserted `exit=0` on `n` — rewritten |

`message_test` now pins: the flag is named, the consequence is stated, `[y/N]` is present,
the prompt is red (`\033[1;31m`, not plain red or yellow), exit code is 1, the refusal is
explained, nothing was installed, and `yes` is **not** accepted (allowlist check).

`random_test`'s case was asserting the old behaviour (`answer=n` → expect exit 0 and a
successful install). It now asserts the allowlist: `y` installs; `n`, empty and `yes` exit 1
with nothing in `bin/`.

## How to upgrade

```bash
wave selfupdate
```

If `wave` is unusable on your machine, run the install command again.

## Mirror

The mirror needs `selfupdate`, `configdata` and `core` re-synced, otherwise mirror users keep
reading the old version pointer.

## Data shipped with this release

| Repository | Content |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.3/update_commands.sh` (generated from the fixed tree) |
| `Selfupdate` | `macwavedata/latest.toml` → 4.3.3 / `318F1452` / branch `4.3` |
| `configdata` | `versiondata/latest_version` → 4.3.3 / `318F1452` / branch `4.3` |
| `Pages` | version → 4.3.3 |
| `MacWave` Release `v4.3.3` | every `.py` / `.sh` at the tag, flat, plus `MacWave-4.3.3.tar` and `.tar.gz` — asset count = file count + 2 |

---

# MacWave 4.3.3 发布说明

- 发布：2026-11-14，构建号 `318F1452`
- 分支：`4.3`（4.3 这条线；`4.4` 是另一条）
- 上一版：[4.3.2](RELEASE-4.3.2.md)
- **安全修复**：`--skip-ssl` 的警告问「确定吗」，答「否」并不能让命令停下来

## 先说结论

`--skip-ssl` 会先警告一句、问一句 *"Are you sure?"*。4.3.2 及以前，**除了 `y` / `Y` 之外的
任何答复**都会让安装继续 —— 只是不跳证书校验而已。你答了 `no`，命令却照样下载并装完，
就是这个 bug：那道确认根本不是闸门。

| 对「确定吗」的答复 | 4.3.2 及以前 | 4.3.3 |
| --- | --- | --- |
| `y` / `Y` | 跳过校验并安装 | 同 |
| `n`、直接回车、`yes`、其它任何内容、EOF | ❌ 照样安装 | ✅ 中止，退出码 1，什么都没下载 |
| `-s` / `--silent` | 不询问，按旗标意愿放行 | 同 |

✅ = 命令停了下来（这正是那句答复要求的）；❌ = 未经同意继续执行。

## 为什么算安全更新

一道说不了「不」的确认只是装饰。4.3.2 上的实际后果是：

- 你拒绝了，包还是被装上；
- 因为校验仍然开着，这次安装往往**以 SSL 错误失败** —— 看起来完全是「`--skip-ssl` 没生效」，
  于是最自然的下一步是加 `-F` 再来一次，也就是给你刚刚拒绝过的那条命令再加一道「强制」；
- `wave upgrade --all` 更糟：它**完全不看**返回值（`pkg/upgrader.py` 里
  `confirm_skip_ssl(words)` 的返回值被丢掉），所以答「否」对批量升级毫无作用。

**没有受到威胁的部分**：拒绝时 `verify` 一直是 `True`。`lib/tls.py` 的 `revoke()` 把
`_requested` 与 `_enabled` 两个状态一起归零，所以没有任何请求走到「不验证书」的连接上，
也就没有从不可信对端取到东西。缺陷是**被跳过的同意**和**误导性的失败表现**，
不是一条 MITM 通道。

## 根本原因

`confirm_skip_ssl()` 返回一个布尔值，而调用方把 `False` 读成「别跳过校验 —— 但继续装」：

```python
config["skip_ssl_verify"] = confirm_skip_ssl(flags)      # False → 照装不误
```

这个函数自己的 docstring 把那句问话当作安全询问，`-s` 那一段也是按「拒绝就中止」的
假设写的（原注释：「若这里默默拒绝，装失败时会抛一个 SSL 错误」）。只有**交互**这条路径
漏了这个行为。

## 修复

1. **白名单，不是黑名单。** 只有 `y` / `Y` 继续。`n`、空答复、`yes`、EOF 以及其它任何内容
   一律落到拒绝分支（现在是 `if confirm not in ("Y", "y")`）。
2. **中止写在函数内部**（`steplog.fail`），而不是各个调用点。这是 `wave install` 与
   `wave upgrade --all` 能一致的原因 —— 升级那条路径从来不读返回值，光改调用点覆盖不到它。
3. **提示说清它接受什么**：`… Are you sure? [y/N]`，并且用红色（`RED_BOLD`）打出来，
   与既有的「Do you want to retry? [y/N]」一致。这是全工具唯一一处「用户主动要求降低
   安全性」的地方。
4. **`-s` 不动**：静默模式本来就不提问，仍然按用户写下的旗标放行。改了它等于让脚本化安装
   变成静默失败。

## 证据

4.3.3 上拒绝：

```console
$ printf 'n\n' | wave install jq --skip-ssl
🌊 You selected --skip-ssl, this will skip SSL certificate verification, which may cause security risks. Are you sure? [y/N]
🌊 Error: not installing with --skip-ssl: the confirmation was declined
🌊 Next      nothing was downloaded or installed
🌊           run it again and answer y at the prompt to skip verification
🌊           or drop --skip-ssl if certificate verification works on this network
$ echo $?
1
```

同样的输入在 4.3.2 上（用户报告，修复前已复现）：

```console
$ wave install jq --skip-ssl
🌊 You selected --skip-ssl, this will skip SSL certificate verification, which may cause security risks. Are you sure?
n
🌊 Fetching version info...
🌊 Version info fetched successfully.
🌊 Successfully installed jq@1.8.2          ← 答了「否」之后装上了
```

你自己能跑的自查 —— 差别就在退出码：

```bash
wave install jq --skip-ssl      # 答 n
echo $?                         # 4.3.3：1（而且什么都没下载）
                                # 4.3.2：0，包已经被装上了
```

正面对照 —— 答 `y` 仍然正常安装，说明没有把功能改坏：

```console
$ printf 'y\n' | wave install jq --skip-ssl
🌊 You selected --skip-ssl, … Are you sure? [y/N]
🌊 Fetching version info...
… successfully installed
```

## 测试

| 脚本 | 4.3.2 → 4.3.3 |
| --- | --- |
| `scripts/message_test.sh` | 61 → 70 |
| `scripts/random_test.py`（`run_skip_ssl_case`） | 原来断言 `n` 时 `exit=0`，已重写 |

`message_test` 现在钉住：点名旗标、说明后果、有 `[y/N]`、提示是红字（`\033[1;31m`，
不是普通红也不是黄）、退出码为 1、说明了拒绝原因、什么都没装、以及 `yes` **不算**答应
（白名单校验）。

`random_test` 那条用例原本把旧行为写进了断言（`answer=n` → 期望 exit 0 且装成功），
现在改为钉白名单语义：`y` 装成功；`n`、空答复、`yes` 都是退出码 1 且 `bin/` 里没有东西。

## 升级方式

```bash
wave selfupdate
```

若 `wave` 已经不可用，重跑一次安装命令即可。

## 镜像

镜像站需要重新同步 `selfupdate`、`configdata` 与 `core`，否则镜像用户读到的仍是旧版本指针。

## 随本次发布更新的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.3/update_commands.sh`（由修复后的树生成） |
| `Selfupdate` | `macwavedata/latest.toml` → 4.3.3 / `318F1452` / 分支 `4.3` |
| `configdata` | `versiondata/latest_version` → 4.3.3 / `318F1452` / 分支 `4.3` |
| `Pages` | 版本号 → 4.3.3 |
| `MacWave` 的 Release `v4.3.3` | 该 tag 下全部 `.py` / `.sh`（扁平） + `MacWave-4.3.3.tar` 与 `.tar.gz`，资产数 = 文件数 + 2 |
