# MacWave 4.2.5 发布说明

- 发布：2026-11-04，构建号 `308A1654`
- 分支：`4.2`
- 上一版：[4.2.4](RELEASE-4.2.4.md)（同日，只补 ASCII art）

## 概述

只改一件事：**命令名打错时的提示**。装包、索引、网络行为一个字节没动。

以前 `wave instal jq`（少一个 `l`）什么建议都不给，还倒一整篇帮助；现在能猜出来
就给出改法，猜不出来也只留一条指向 `wave -h` 的提示 —— 任何情况下都不再把
五六十行帮助塞进终端。

## 一、手滑会给出完整改法

```
$ wave instal jq
🌊 Error: Unknown command or argument.
   wave instal jq
        ^^^^^^

🌊 Did you mean: wave install jq
   instal is not a command. The one you want is install.

   For the full list: wave -h
```

改法保留你其余的参数与旗标：`wave instal jq --limit-rate 1M` 会提示
`wave install jq --limit-rate 1M`，照着复制就能跑。

### 为什么以前猜不到

`suggest()` 只查一张**语义误用表** —— 那是「其他包管理器的叫法」：

| 你打的 | 提示 |
| --- | --- |
| `update` | `upgrade`（apt / yum / dnf 都是 update） |
| `remove` / `delete` / `rm` | `uninstall` |
| `ls` | `list` |
| `find` | `search` |

手滑（`instal` 少一个 l）完全不在覆盖范围，所以既没建议、也没有别的出路。

现在多了一层拼写兜底。顺序是**先查语义表再跑拼写** —— 不能反：`update` 与
`selfupdate` 的相似度是 0.75，先跑拼写会把它猜成 `selfupdate`，而用户想的是
`upgrade`。

### 命中率是量出来的

枚举所有命令的全部单字母错误（删一个 / 换一个 / 插一个，**4670 种**）：

| 策略 | 猜对 | 猜错 | 不猜 |
| --- | --- | --- | --- |
| 首字母必须相同 | 85.6% | 0.2% | 14.2% |
| 首字母不同时要求 ≥0.9 | 91.7% | 0.3% | 8.1% |
| **首字母不同时要求 ≥0.83（采用）** | **98.1%** | **0.3%** | **1.6%** |
| 无约束 | 99.6% | 0.4% | 0.0% |

第一版写的是「首字母必须相同」，覆盖率只有 85.6% —— `ainfo`（前面多敲一个字母）
这一类全被挡掉了。放宽到 0.83 之后几乎全中，同时仍然挡住 `inst` → `list`：
`inst` 是 `install` 的缩写、相似度 0.75，而真正的单字母笔误都在 0.83 以上。

实测：

| 你打的 | 提示 |
| --- | --- |
| `upgrad jq` | `Did you mean: wave upgrade jq` |
| `instal jq` | `Did you mean: wave install jq` |
| `uninstal jq` | `Did you mean: wave uninstall jq` |
| `lst` | `Did you mean: wave list` |
| `latst` | `Did you mean: wave latest` |
| `inof jq` | `Did you mean: wave info jq` |
| `lnk jq` | `Did you mean: wave link jq` |
| `inst` / `li` / `xyzzy` | 不猜，只提示 `wave -h` |

剩下的 0.3% 猜错是**天然歧义**，任何算法都难分：

| 输入 | 程序猜 | 你可能想打 |
| --- | --- | --- |
| `uinstall` | `uninstall` | `install`（多按了个 u） |
| `lint` | `list` | `link` |
| `last` / `lest` | `latest` | `list` |

文本上确实更像所猜的那个，而且答案一眼能看出不对，成本很低。

## 二、不再倒整篇帮助

猜不到时原来会 `print_custom_help()` —— **五六十行**，在终端里滚过一整屏，
把上面那两行有效信息推到看不见的地方。而真想知道全部命令的人，自己会敲
`wave -h`。

现在四种结局都是 4–8 行：

| 输入 | 行数 |
| --- | --- |
| `wave instal jq` | 8 |
| `wave xyzzy` | 6 |
| `wave install jq --unkown-flag` | 4 |
| `wave`（无参数） | 6 |

```
$ wave xyzzy
🌊 Error: Unknown command or argument.
   wave xyzzy
        ^^^^^

   For the full list: wave -h
```

## 测试

`scripts/message_test.sh` 从 24 条增到 **46 条**，新增覆盖：

- 拼写纠错生效（`instal` / `upgrad` / `lst`）
- 语义表优先于拼写（`update` 不被抢去 `selfupdate`）
- 半截词不乱猜（`inst` / `li` / `xyzzy`）
- 任何情况都不打整篇帮助，且猜得到时输出不超过 10 行

## 兼容性

纯提示层改动，无行为变化：

- 命令、旗标、退出码都没变（打错仍然是 `exit 1`）
- 静默模式（`-s`）仍然是单行 `wave: unknown command: X`
- 脚本若在解析帮助文本，注意 `wave --help` 的提示文案变成了 `wave -h`
  （两者等价，`-h` 是短写法）

## 升级方式

```bash
wave selfupdate
```

## 本版随附的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.2.5/update_commands.sh` |
| `configdata` | `latest_version` → 4.2.5 |
| `Pages` | 版本号 → 4.2.5 |
