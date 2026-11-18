# MacWave 4.4.0-beta3

Prerelease · build `323L0533` · branch `4.4` · previous beta [4.4.0-beta2](RELEASE-4.4.0-beta2.md) · stable line `4.3.4`

This one is mostly the installer: who gets asked for a password, what happens before it
asks, and how it behaves inside a script. Underneath, three things that had more than one
implementation now have exactly one.

## Bottom line first

| Area | Before | Now |
| --- | --- | --- |
| Elevation | decided by "is the target outside `$HOME`" | decided by write permission, confirmed by a real write probe |
| SIP | not considered | sealed system volume and SIP range checked before anything is downloaded |
| Scripted install | spinner, ANSI, `--help` fetched the release pointer | `--raw`, `--print-usage`, `--help` returns without network |
| Version comparison | three implementations | one: `lib/versioncompare.py` |

## install.sh

**Elevation**

- Write permission on the target tree *and* the config directory decides — not the
  position relative to `$HOME`. An owned external volume (`/Volumes/SSD/macwave`) no
  longer asks; `~/.local/macwave` left root-owned by an earlier `sudo` now does.
- Permission bits are only the first check. An empty probe file is created in the nearest
  existing directory and immediately removed. `Permission denied` → need `sudo`;
  anything else (ENOSPC, read-only mount) → hard error, because dressing an environment
  problem up as a password prompt wastes the user's time.
- `--skip-probe` skips the probe and keeps the permission-bit check. `--dry-run` never
  writes, so it uses bits only.

**SIP / sealed system volume**

- Target inside SIP's range (`/usr` except `/usr/local`, `/bin`, `/sbin`, `/System`,
  `/Library/Apple`): a sealed system volume is refused before download — that is a kernel
  refusal, `sudo` included. Unsealed: `disabled` / `enabled (Custom Configuration)` warns
  and continues (OCLP and friends); the reasoning is in the comment above `mw_sip_status`.
- Reading the state is not itself a reason to refuse: unknown (non-macOS, old systems)
  proceeds, otherwise every container and every 10.x box would be locked out.

**Output and flags**

- `--raw`: no ASCII art, no colour, no spinner, no cursor movement; downloads print one
  `####` line per 10% (unknown length → per MiB). Same semantics as `wave install --raw`.
- `--print-usage` prints usage and continues. `--help` prints usage and stops, and is
  rejected alongside install arguments — only `--dry-run`, `--raw`, `--zh` may accompany
  it. Neither one touches the network any more.
- Arguments are parsed once, before the version request: parse → presentation → test root
  → fetch version. The version lookup used to sit inside argument parsing, which forced
  three separate scans of `$@`; `--help` downloading the pointer was one symptom. An
  unknown option still gets a clean report under `--raw`, because the presentation layer
  re-reads the raw argv after parsing stops.

**Agreement**

- Refusing the agreement no longer deletes an existing install: rollback removes
  `BASE_DIR` / `CONFIG_DIR` only when `TREE_PREEXISTED=0`, recorded before the first
  `mkdir`.
- Answers are normalised: empty / `y` / `yes` accept, `n` / `no` refuse, anything else
  re-asks, three unrecognised answers count as refusal. Previously only empty and `y`
  accepted, so `yes` deleted a fresh install.
- The agreement is actually recorded now (`AGREEMENT.json`); the message used to claim
  otherwise. The identifier is read out of the installed `lib/selfupdate.py`, never copied
  into bash. `--ci` records it too.

**Strict mode** — `set -eE -u -o pipefail` now comes *before* the test-root setup, so a
failure while relocating `HOME` is caught instead of silently continuing without
isolation.

## wave CLI

- `cli/commands.py` holds one table that feeds four consumers: dispatch, the Commands
  section of `wave -h`, `wave <cmd> --help`, and the man/info generators. The `if/elif`
  chain is gone (importlib + handler name), so "listed in help, missing from dispatch"
  cannot happen quietly again.
- `cli/common.py` parses every common flag once (`-v/-C/--skip-ssl/--limit-rate/--proxy`,
  three timeouts, `--install-python-from-source`). The same bad `--proxy` or `--max-time`
  now produces the same message and exit code on every command; `wave selfupdate --proxy`
  used to ignore the flag silently while `wave install` rejected it.
- `--unlink` is now `--no-link` (old spelling still accepted). Alias knowledge lives in
  `cli/flags.py` only.
- `wave install --raw` / `wave upgrade --raw`: one `####` line per 10%, resumable
  downloads report the existing byte count.
- `wave selfupdate --dry-run`: prints current → target version, branch, whether the
  agreement will be asked, the timeouts, and which script would run. Stops before the
  agreement question, writes nothing.
- A beta refuses `wave selfupdate` — both entry points (`lib/selfupdate.py` before any
  network, `lib/selfupdate.sh` before elevation), one authority (`versioncompare.is_prerelease`),
  and the message says where to reinstall from.
- Agreement confirmation before an upgrade (4.4 onwards): asked once, keyed on
  "installed version ≤ `AGREEMENT_INTRODUCED_IN`", stored in `AGREEMENT.json` — kept out
  of `VERSION.json` because `update_commands.sh` rewrites that file and would clobber it.
  A cross-major-version upgrade is stopped by the reinstall guard first, so the question
  is not asked when the answer cannot help.
- `uninstall.sh`: exit codes 0 done / 1 usage or no terminal / 2 permission / 3 partial;
  one unremovable path no longer aborts the rest; bad JSON or missing `python3` no longer
  exits silently with nothing deleted; `"$HOME"/*` instead of `$HOME*`; a failed self-delete
  no longer masks the exit code; the `sed` fallback also removes the `# MacWave` marker line.

## Versions

- `lib/versioncompare.py` is the only implementation for MacWave's own version, package
  versions and dependency versions: PEP 440 ordering (`4.4.0-beta1 < 4.4.0`), community
  suffixes (`procursus` / `macwaveteam` / `Xteam`) normalised to `X.Y.Z.N`, two-part and
  three-part equivalent, unnumbered prereleases padded (`rc` → `rc0`), unparsable strings
  degraded to numeric segments instead of raising. 40 real version strings were compared
  pairwise against the old implementations (780 pairs, identical order).
- `parse_dep_ref` / `parse_dep_refs` moved to `surfboard/querier.py`, where the querying
  already lives.
- The upgrade migration deletes `pkg/pkgversionparser.py`, `surfboard/depsversionparser.py`
  and `lib/versioncmp.py` from existing trees.

## Network and TLS

- `MACWAVE_CACERT`: extra root CA for every request.
- `net/tls.py` classifies certificate failures and gives each class its own next step:
  expired (report `notAfter`), self-signed / private CA (ask for the root, or switch
  mirror), incomplete chain (mirror is missing the intermediate), hostname mismatch (list
  what the certificate is for and what you asked for — do not bypass), and
  connect/DNS failure ("this is the network, not TLS"). One unverified handshake per host
  reads `notAfter` / SAN; only when the failure is already known to be certificate-related.

## Config

- `config/envvar.py` is the single source for the `MACWAVE_*` domain names, the pip index
  and the test root; `net/domains.py` keeps validation and URL building only. The two shell
  scripts inline the same values and `scripts/check_domain_defaults.py` compares them
  table-driven (a name that is not in the table is itself an error).
- Variables nobody read were deleted: `MACWAVE_TEST_ROOT`, `MACWAVE_CONFIG_DIR`,
  `MACWAVE_TARGET_VERSION`, `MACWAVE_DRY_RUN`. The manual lost `MACWAVE_MIRROR`, which
  never existed, and gained `MACWAVE_CACERT`.

## Portability and CI

- `mktemp "${TMPDIR:-/tmp}/prefix.XXXXXX"` everywhere. `mktemp -t prefix` is BSD-only;
  GNU `mktemp` requires three `X`s, and its failure made the write probe report "not a
  permission problem", which aborted every install on Linux.
- `/bin/bash` in all 90 call sites (scripts, `subprocess`, workflows, docs). The beta guard
  used `${1,,}`, which is bash 4; on macOS's 3.2 it exited before printing anything.
- `shell_lint.sh` grew three sections: bash-4 constructs, bare `bash`, `mktemp -t`.
- The release asset guard retries instead of failing: `release: published` fires before the
  first asset is uploaded, which reported a 14-of-82 upload as "missing assets".
- `[skip ci]` may not be the last commit of a push that also carries code.

## Fixed along the way

- `lib/versioncmp.py` had terminal paste garbage appended (an `of=/dev/rdisk8 bs=4m` line);
  any `import versioncmp` was a `SyntaxError`, i.e. `wave selfupdate` and the pointer sync
  workflow were dead on `main`.
- `link_test.sh` had an inline Python block whose quoting was eaten by double quotes, so the
  assertion compared nothing.
- `configpath_test.sh` did not put `config/` on `sys.path`.
- The agreement step could hand `VERSION.json` to root inside CI.

## Tests

| Script | Status |
| --- | --- |
| `versioncompare_test.sh` | new, 69 assertions: ordering, suffixes, equivalence, parser relocation, and "only one implementation" |
| `raw_test.sh` | new, 34: `wave install --raw`, `install.sh --raw`, `mw_download` tick marks |
| `install_privilege_test.sh` | new, 21: elevation matrix, SIP/SSV matrix (skip on non-macOS), write probe, `--skip-probe` |
| `install_flags_test.sh` | new, 12: `--help` / `--print-usage` combinations, and that `--help` never reaches the network |
| `commands_test.sh` | new, 3: metadata ↔ handler, flags in help, README consistency |
| `tls_test.sh` | new, 16: six failure classes, both the Python and the `curl` wording |
| `dir_guard_test.sh`, `selfupdate_test.sh` | extended: uninstall exit codes, beta refusal, agreement decision table, `--dry-run` |

All of them run in both pipelines.

## Install

```bash
MACWAVE_VERSION=4.4.0-beta3 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta3/install.sh)"
```

`install.sh` reads the version from the release pointer, not from the URL it came from —
without the two variables you get the current stable build. The URL only decides which copy
of `install.sh` runs.

## Back to stable

`wave selfupdate` is refused on a beta, so this is a reinstall:

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

## Data shipped with this release

| Repository | Content |
| --- | --- |
| `Selfupdate` | `macwavedata/4.4.0-beta3/update_commands.sh` (generated from the tagged tree; new modules first) |
| `Selfupdate` | `macwavedata/latest.toml` — **unchanged**: a beta never goes there |
| `configdata` | `versiondata/latest_version` — **unchanged** (`4.3.4` / branch `4.3`) |
| `Pages` | **unchanged** |
| `MacWave` Release `v4.4.0-beta3` | every `.py` / `.sh` at the tag, flat (89 files), plus `MacWave-4.4.0-beta3.tar`, `.tar.gz`, `SHA256SUMS`, `SHA256SUMS.asc` — asset count = 89 + 4 = 93 |

---

# MacWave 4.4.0-beta3

预发布 · 构建号 `323L0533` · 分支 `4.4` · 上一个 beta [4.4.0-beta2](RELEASE-4.4.0-beta2.md) · 稳定线 `4.3.4`

这一版主要是安装器：谁会看到密码提示、提示之前先做什么、以及在脚本里怎么表现。
底下还有三件「本来有两三份实现、现在只剩一份」的事。

## 先说结论

| 方面 | 以前 | 现在 |
| --- | --- | --- |
| 提权 | 看「目标是否在 `$HOME` 之外」 | 看写权限，并用一枚真文件探针确认 |
| SIP | 不看 | 系统卷是否密封、目标是否在 SIP 范围内，都在下载之前判 |
| 脚本化安装 | 转圈、ANSI、`--help` 会去取发布指针 | `--raw`、`--print-usage`、`--help` 不联网 |
| 版本比较 | 三份实现 | 一份：`lib/versioncompare.py` |

## install.sh

**提权**

- 目标是目标树与配置目录的**写权限**，与「在不在 `$HOME` 之外」无关。自己拥有的外置卷
  （`/Volumes/SSD/macwave`）不再问密码；被上一次 `sudo` 装成 root 所有的
  `~/.local/macwave` 现在会正确地要密码。
- 权限位只是第一道。在最近的已存在目录里建一个空文件探针、立刻删掉：
  `Permission denied` → 需要 `sudo`；其它原因（磁盘满、只读挂载）→ 直接报错，
  不把环境问题伪装成密码提示。
- `--skip-probe` 只跳过探针，权限位判断保留；`--dry-run` 从不写文件，因此只看权限位。

**SIP / 系统卷密封**

- 目标落在 SIP 范围（`/usr` 除 `/usr/local`、`/bin`、`/sbin`、`/System`、`/Library/Apple`）：
  系统卷密封时在下载之前拒绝 —— 那是内核层拒绝，`sudo` 也没用。未密封时，
  `disabled` / `enabled (Custom Configuration)` 警告后继续（OCLP 这类），
  理由写在 `mw_sip_status` 上面的注释里。
- 读不到状态（非 macOS、老系统）不算拒绝理由，否则所有容器和 10.x 机器都被挡在门外。

**输出与旗标**

- `--raw`：没有艺术字、颜色、转圈与光标控制；下载每 10% 一行 `####`（长度未知时按 MiB）。
  语义与 `wave install --raw` 一致。
- `--print-usage` 打用法后继续；`--help` 打用法后停下，且与安装参数连用会被拒绝 ——
  只允许 `--dry-run`、`--raw`、`--zh` 同行。两者都不再联网。
- 参数只解析一遍，且排在取版本号之前：解析 → 呈现 → 测试根 → 取版本。取版本号原本夹在
  参数解析中间，逼得脚本扫三遍 `$@`（`--help` 去取指针就是症状之一）。解析在第一个未知
  选项处停下后，呈现层会从原始 argv 再认一次 `--raw`，所以「未知选项 + `--raw`」的报错
  依然是干净的。

**协议**

- 拒绝协议不再删除已有安装：只有 `TREE_PREEXISTED=0`（这棵树是本次建的，判定记在第一条
  `mkdir` 之前）时才回滚 `BASE_DIR` / `CONFIG_DIR`。
- 应答归一化：空 / `y` / `yes` 同意，`n` / `no` 拒绝，其它重问，连续三次认不出按拒绝。
  以前只有空与 `y` 算同意，于是 `yes` 会删掉刚装好的东西。
- 同意现在真的会写进 `AGREEMENT.json`（以前提示语是假的）。标识从装好的
  `lib/selfupdate.py` 里读，不在 bash 里另抄日期；`--ci` 的自动同意也记录。

**严格模式** —— `set -eE -u -o pipefail` 挪到测试根处理**之前**，搬 `HOME` 那几步出错
会被抓住，而不是静默继续跑在未隔离的环境里。

## wave 命令

- `cli/commands.py` 一张表喂四处：分发、`wave -h` 的 Commands 一节、`wave <cmd> --help`、
  man/info 生成器。`if/elif` 链消失（换成 importlib + handler 名），
  「帮助里有、分发里没有」不可能再静默发生。
- `cli/common.py` 统一解析全部公共旗标（`-v/-C/--skip-ssl/--limit-rate/--proxy`、三档超时、
  `--install-python-from-source`）。同一个非法 `--proxy` / `--max-time` 在任何命令下都是
  同一句错、同一个退出码；以前 `wave selfupdate --proxy` 静默忽略、`wave install` 报错。
- `--unlink` 改名 `--no-link`（旧写法仍接受）。别名的知识只在 `cli/flags.py` 一处。
- `wave install --raw` / `wave upgrade --raw`：每 10% 一行 `####`，续传时报告已有字节数。
- `wave selfupdate --dry-run`：打印当前 → 目标版本、分支、会不会问协议、超时、要跑哪份脚本；
  停在协议询问之前，一个字节都不写。
- beta 上 `wave selfupdate` 拒绝执行，两个入口各一处（`lib/selfupdate.py` 在联网前、
  `lib/selfupdate.sh` 在提权前），判定同源于 `versioncompare.is_prerelease`，
  消息里给出重装命令。
- 4.4 起升级前确认用户协议：问一次，判据是「已装版本 ≤ `AGREEMENT_INTRODUCED_IN`」，
  记在 `AGREEMENT.json` —— 刻意不塞进 `VERSION.json`，那个文件会被 `update_commands.sh`
  覆盖。跨大版本时「请去官网重装」那条守卫先说话，问协议不会抢在它前面。
- `uninstall.sh`：退出码 0 完成 / 1 用法或无终端 / 2 权限不足 / 3 部分失败；单个路径删不掉
  不再中断后面的清理；坏 JSON 或缺 `python3` 不再静默退出、什么都不删；家目录判断改用
  `"$HOME"/*`；自删失败不再盖掉退出码；`sed` 兜底也会删掉 `# MacWave` 标记行。

## 版本

- `lib/versioncompare.py` 是自身版本、包版本、依赖版本的唯一实现：PEP 440 排序
  （`4.4.0-beta1 < 4.4.0`）、社区后缀（`procursus` / `macwaveteam` / `Xteam`）归一化成
  `X.Y.Z.N`、两段与三段等价、没有编号的预发布补 0（`rc` → `rc0`）、读不出来的串退化成
  数字段而不抛异常。与旧实现拿 40 个真实版本串两两比对过（780 组，序完全一致）。
- `parse_dep_ref` / `parse_dep_refs` 搬进 `surfboard/querier.py`。
- 升级迁移会从已有安装树里删掉 `pkg/pkgversionparser.py`、
  `surfboard/depsversionparser.py`、`lib/versioncmp.py`。

## 网络与 TLS

- `MACWAVE_CACERT`：为所有请求加一份额外根证书。
- `net/tls.py` 把证书失败分诊，每类给各自下一步：过期（报 `notAfter`）、自签或私有 CA
  （要根证书，或换镜像）、链不完整（镜像少发中间证书）、主机名不匹配（列出证书签给谁、
  你在访问谁，并明说不要绕过）、连不上或解析失败（第一句就说这是网络问题）。
  只有确定是证书问题时，才对同一主机做一次不校验握手读 `notAfter` / SAN。

## 配置

- `config/envvar.py` 是 `MACWAVE_*` 域名、pip 索引与测试根的唯一出处；`net/domains.py`
  只剩校验与拼 URL。两份 shell 脚本内联同样的值，`scripts/check_domain_defaults.py`
  按表比对（表上没有的名字本身就是错误）。
- 删掉没人读的变量：`MACWAVE_TEST_ROOT`、`MACWAVE_CONFIG_DIR`、`MACWAVE_TARGET_VERSION`、
  `MACWAVE_DRY_RUN`。手册删掉从未存在的 `MACWAVE_MIRROR`，补上 `MACWAVE_CACERT`。

## 可移植性与 CI

- 临时文件一律 `mktemp "${TMPDIR:-/tmp}/前缀.XXXXXX"`。`mktemp -t 前缀` 是 BSD 写法，
  GNU 版本要求三个 `X`，它一失败写探针就报「不是权限问题」，于是 Linux 上每次安装都中止。
- 90 处调用一律写 `/bin/bash`。beta 拦截用过 `${1,,}`（bash 4 语法），在 macOS 自带的 3.2
  上一句提示都没打就退出。
- `shell_lint.sh` 新增三节：bash 4 语法、裸 `bash`、`mktemp -t`。
- 发布资产守卫改成重试：`release: published` 在第一个资产上传前就触发，曾把 82 个资产传了
  14 个时的状态判成「缺资产」。
- `[skip ci]` 不许是同一次推送里同时带代码时的最后一条。

## 顺手修掉的

- `lib/versioncmp.py` 末尾被粘进了终端内容（一行 `of=/dev/rdisk8 bs=4m`），任何
  `import versioncmp` 都是 `SyntaxError` —— 也就是 `main` 上 `wave selfupdate` 与指针同步
  工作流都是死的。
- `link_test.sh` 里那段内联 Python 的引号被双引号吃掉，断言一直在比较空字符串。
- `configpath_test.sh` 没有把 `config/` 放进 `sys.path`。
- 协议那一步在 CI 里可能把 `VERSION.json` 交给 root。

## 测试

| 脚本 | 状态 |
| --- | --- |
| `versioncompare_test.sh` | 新增，69 条：序、后缀、等价、解析器搬家，以及「只剩一份」 |
| `raw_test.sh` | 新增，34 条：`wave install --raw`、`install.sh --raw`、`mw_download` 刻度 |
| `install_privilege_test.sh` | 新增，21 条：提权矩阵、SIP/SSV 矩阵（非 macOS 跳过）、写探针、`--skip-probe` |
| `install_flags_test.sh` | 新增，12 条：`--help` / `--print-usage` 组合，以及 `--help` 不联网 |
| `commands_test.sh` | 新增，3 条：元数据 ↔ handler、帮助里的旗标、README 一致性 |
| `tls_test.sh` | 新增，16 条：六类失败，Python 与 `curl` 两处措辞 |
| `dir_guard_test.sh`、`selfupdate_test.sh` | 扩充：卸载退出码、beta 拦截、协议判定表、`--dry-run` |

以上两条流水线都跑。

## 安装

```bash
MACWAVE_VERSION=4.4.0-beta3 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta3/install.sh)"
```

`install.sh` 从发布指针读版本号，不从它被下载的那个 URL 读 —— 不带这两个变量装到的是当前
正式版。URL 只决定你跑的是哪一份 `install.sh`。

## 回到稳定版

beta 上 `wave selfupdate` 会被拒绝，所以这是重装：

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

## 这一版附带的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.4.0-beta3/update_commands.sh`（由 tag 的树生成，新模块排在前面） |
| `Selfupdate` | `macwavedata/latest.toml` —— **不动**：beta 永远不写进去 |
| `configdata` | `versiondata/latest_version` —— **不动**（`4.3.4` / 分支 `4.3`） |
| `Pages` | **不动** |
| `MacWave` Release `v4.4.0-beta3` | tag 下全部 `.py` / `.sh` 扁平（89 个），加 `MacWave-4.4.0-beta3.tar`、`.tar.gz`、`SHA256SUMS`、`SHA256SUMS.asc` —— 资产数 = 89 + 4 = 93 |
