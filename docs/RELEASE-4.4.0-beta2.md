# MacWave 4.4.0-beta2

Prerelease. `releases/latest` still points at 4.3.4 — installing this build is a
deliberate choice, and `wave selfupdate` will move you **back** to the stable line
when a newer 4.3.x ships.

## What changed since beta1

Two fixes, both about commands that reported success while doing nothing:

| Change | Why |
| --- | --- |
| `--skip-ssl` refusal now aborts | Answering `n`, Enter, `yes` or EOF used to keep installing (only without skipping verification) — the confirmation could not say no |
| Incomplete install trees self-heal | The generated script now carries the full file list and checks it, so a wounded tree is reinstalled instead of being told "Already at" |

## Install

```bash
MACWAVE_VERSION=4.4.0-beta2 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta2/install.sh)"
```

**The two environment variables are the whole point.** `install.sh` reads the version
from the release pointer (`latest.toml`), not from the URL it was downloaded from — so
without them you get the current stable build, not this beta. The URL only decides which
copy of `install.sh` you run.

This also means `wave selfupdate` cannot be used on a beta: it follows the same pointer,
and a beta lives on a different branch. It refuses, in red, and tells you where to
reinstall from. `VERSION.json` records `"version": "4.4.0-beta2"`, which is how it knows.

## Back to stable

`wave selfupdate` is refused on a beta, so leaving the beta is also a reinstall of the
stable build:

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

---

# MacWave 4.4.0-beta2

预发布版。`releases/latest` 仍指向 4.3.4 —— 装这个版本是一个明确的选择；等 4.3.x
出了更新的正式版，`wave selfupdate` 会把你带回稳定线。

## 相对 beta1 改了什么

两个修复，性质相同：命令报告成功，实际什么都没做。

| 改动 | 原因 |
| --- | --- |
| `--skip-ssl` 拒绝后中止 | 答 `n`、直接回车、`yes` 或 EOF 以前会继续安装（只是不跳过校验）—— 那道确认说不了「不」 |
| 安装树不完整时自愈 | 生成的脚本现在带全量清单并自检，坏树会被重装，而不是被告知「Already at」 |

## 安装

```bash
MACWAVE_VERSION=4.4.0-beta2 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta2/install.sh)"
```

**这两个环境变量是关键。** `install.sh` 从发布指针（`latest.toml`）读版本号，不是从
它被下载的那个 URL 读 —— 不带上它们，装到的是当前正式版，不是这个 beta。URL 只决定
你跑的是哪一份 `install.sh`。

这也是为什么 beta 上不能用 `wave selfupdate`：它读的是同一个指针，而 beta 在另一条
分支上。它会用红字拒绝，并告诉你该去哪里重装。`VERSION.json` 里写着
`"version": "4.4.0-beta2"`，它就是这么知道的。

## 回到稳定版

beta 上 `wave selfupdate` 会被拒绝，所以回稳定线也是重装一次正式版：

```bash
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```
