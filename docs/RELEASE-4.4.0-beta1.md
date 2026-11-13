# MacWave 4.4.0-beta1 — pre-release

- Released: 2026-11-13, from the `4.4` line
- **This is a beta.** It is published as a pre-release on purpose: the install command
  that points at *the latest stable release* will keep giving you 4.3.2, and
  `wave selfupdate` will not move you onto this build.
- Previous stable release: [4.3.2](RELEASE-4.3.2.md)

## Install this beta

```bash
MACWAVE_VERSION=4.4.0-beta1 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta1/install.sh)"
```

The two environment variables are what make this a beta install. Without them the
installer reads the version from the release pointer and gives you the current stable
release — which is exactly what the command on the website does, and what every normal
user gets.

To go back to stable afterwards, run the normal install command:

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

### Two consequences worth knowing before you run it

| What | Why |
| --- | --- |
| `wave selfupdate` will not offer 4.4.0-beta1 | The updater compares against the stable release pointer, which stays at 4.3.2. A beta must never be reachable that way — otherwise everyone gets dragged onto it. |
| Once the final 4.4.0 ships, `wave selfupdate` still will not move you off the beta | Versions are compared by their numeric parts, so `4.4.0-beta1` sorts **above** `4.4.0`. Reinstall with the install command above to leave the beta. |

## What is in it

Everything from 4.3.2, plus:

1. **`--install-from-source` is withdrawn.** The flag is now rejected with a normal
   `illegal option` error. Its implementation is still in the tree; only the CLI entry
   point is gone.
2. **Directory layout changed** — `config*` files moved to `config/`, and `help` /
   `flags` / `suggest` / `silent` moved to `cli/`. Both the repository and the install
   tree use this layout. Upgrading deletes the old flat copies under `lib/` so there is
   exactly one copy of each module on `sys.path`.
3. **man pages and Info manuals, in English and Chinese** — `man wave`, `man wave-zh`,
   `info wave`, `info wave-zh`, and `wave manual [--zh] [--color]` for machines without
   texinfo. All of it is generated from one source, so the terminal help, the man pages
   and the Info files cannot drift apart.
4. **`wave -h --zh` and `wave <command> -h --zh`** — the terminal help has a Chinese
   edition too.
5. **Internals split up** — the argv tokenizer, the "did you mean" heuristics and the
   `-s` / `-S` handling each live in one place now instead of four.

### Translators: please read

The Chinese text under `cli/help_zh.py` was machine-drafted and then reviewed in several
passes. It is the single source for every Chinese string in this release. If you edit the
generated `man/*-zh.1` or `info/wave-zh.info` files directly, the next
`python3 scripts/build_docs.py` overwrites your work and `scripts/docs_test.sh` fails —
edit `cli/help_zh.py` instead.

## Upgrading and downgrading

```bash
# stay on stable
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"

# install this beta
MACWAVE_VERSION=4.4.0-beta1 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta1/install.sh)"
```

## Regression

| Suite | Result |
| --- | --- |
| `bash scripts/structure_test.sh` | 7 checks (install tree, `sys.path`, assets not importable) |
| `bash scripts/docs_test.sh` | 10 checks (docs fresh, zh/en parity, typography, command table ↔ dispatch) |
| `bash scripts/message_test.sh` | 61 |
| `bash scripts/dir_guard_test.sh` | 72 |
| `bash scripts/linksafety_test.sh` | 28 |
| `bash scripts/shellenv_test.sh` | 10 |
| `bash scripts/domains_test.sh` | all (defaults now follow `HEAD`) |
| `flags` / `latest` / `info_format` / `configpath` / `net_policy` / `depsync` / `minos` / `update_commands` / `markdown` / `shell_lint` | all green |

---

# MacWave 4.4.0-beta1 发布说明（测试版）

- 发布：2026-11-13，来自 `4.4` 这条线
- **这是 beta。** 它被有意标成预发布：指向「最新正式版」的安装命令仍然给你 4.3.2，
  `wave selfupdate` 也不会把你搬到这个构建上。
- 上一正式版：[4.3.2](RELEASE-4.3.2.md)

## 安装这个 beta

```bash
MACWAVE_VERSION=4.4.0-beta1 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta1/install.sh)"
```

那两个环境变量就是它成为「装 beta」的原因。不给它们时，安装器会从发布指针读版本号，
给你当前的正式版 —— 官网那条命令正是这么用的，也是所有普通用户拿到的。

装完想回正式版，跑一次普通安装命令即可：

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

### 跑之前该知道的两件事

| 现象 | 原因 |
| --- | --- |
| `wave selfupdate` 不会提供 4.4.0-beta1 | 更新器比较的是正式版指针，它停在 4.3.2。beta 绝不能从这条路可达 —— 否则所有人都会被拖上去。 |
| 将来 4.4.0 正式版发布后，`wave selfupdate` 也不会把你从 beta 挪走 | 版本按数字段比较，`4.4.0-beta1` 排在 `4.4.0` **之上**。要离开 beta，用上面那条安装命令重装。 |

## 这一版有什么

4.3.2 的全部内容，另加：

1. **`--install-from-source` 暂时下线。** 现在给它是标准的 `illegal option` 报错。
   实现仍在树里，少的只是 CLI 入口。
2. **目录结构变了** —— `config*` 系列移到 `config/`，`help` / `flags` / `suggest` /
   `silent` 移到 `cli/`。仓库与安装树都是这个布局。升级会删掉 `lib/` 下的平铺副本，
   保证每个模块在 `sys.path` 上只有一份。
3. **man 页与 Info 手册，中英双语** —— `man wave`、`man wave-zh`、`info wave`、
   `info wave-zh`，以及给没装 texinfo 的机器准备的 `wave manual [--zh] [--color]`。
   全部由同一份源生成，所以终端帮助、man 页与 Info 文件不可能走散。
4. **`wave -h --zh` 与 `wave <命令> -h --zh`** —— 终端帮助也有中文版了。
5. **内部拆解** —— argv 拆解、「你是不是想敲」的启发式、`-s` / `-S` 的处理，
   各自只有一处实现，不再各写四遍。

### 参与翻译的人请读这一段

`cli/help_zh.py` 里的中文是先机器起草、再经过几轮审校的。它是这一版所有中文文案的
**唯一来源**。直接改生成物（`man/*-zh.1`、`info/wave-zh.info`）会被下一次
`python3 scripts/build_docs.py` 覆盖，而且 `scripts/docs_test.sh` 会红 —— 改
`cli/help_zh.py`。

## 升级与降级

```bash
# 留在正式版
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"

# 安装这个 beta
MACWAVE_VERSION=4.4.0-beta1 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta1/install.sh)"
```

## 回归

| 脚本 | 结果 |
| --- | --- |
| `bash scripts/structure_test.sh` | 7 项（安装树、`sys.path`、资源目录不进模块搜索路径） |
| `bash scripts/docs_test.sh` | 10 项（生成物不落后、中英对齐、排版、命令表与分发一致） |
| `bash scripts/message_test.sh` | 61 |
| `bash scripts/dir_guard_test.sh` | 72 |
| `bash scripts/linksafety_test.sh` | 28 |
| `bash scripts/shellenv_test.sh` | 10 |
| `bash scripts/domains_test.sh` | 全部（默认值现在跟随 `HEAD`） |
| `flags` / `latest` / `info_format` / `configpath` / `net_policy` / `depsync` / `minos` / `update_commands` / `markdown` / `shell_lint` | 全绿 |
