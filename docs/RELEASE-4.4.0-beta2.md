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
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta2/install.sh)"
```

Note `releases/download/v4.4.0-beta2` — **not** `releases/latest`, which stays on the
stable line.

## Back to stable

```bash
wave selfupdate
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
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta2/install.sh)"
```

注意是 `releases/download/v4.4.0-beta2`，**不是** `releases/latest` —— 后者留在稳定线。

## 回到稳定版

```bash
wave selfupdate
```
