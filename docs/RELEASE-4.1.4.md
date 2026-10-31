# MacWave 4.1.4 发布说明

> 本文说明 4.1.4 的变更范围与升级方式。
> 这是一个**功能版本**：新增 `-s/-S`、`upgrade --all`，并改进错误提示。
> 数据格式无变化，升级无迁移步骤。
>
> 发布分支：`4.1`

---

## 概述

这一版全部围绕「让脚本能用、让错误说清」。三条线：

| 你想要的 | 现在可以这样写 | 以前 |
| --- | --- | --- |
| 静默安装，只看退出码 | `wave install jq -s` | 进度、链接、逐条 `🌊` 全打印 |
| 静默但保留失败原因 | `wave install jq -sS` | 不存在这个组合 |
| 把所有包都升到最新 | `wave upgrade --all` | 只能一个个来 |
| 无人值守跑安装脚本 | `bash install.sh --ci` | `--silent`（现已改名） |

---

## 一、`-s, --silent` 与 `-S, --show-error`

两者语义**与 curl 完全一致**，因为它们本来就是同一组用法：

| 写法 | 成功时 | 失败时 | 退出码 |
| --- | --- | --- | --- |
| （不加） | 正常输出 | 完整诊断 | 0 / 非 0 |
| `-s` | 0 字节 | **0 字节** | 0 / 非 0 |
| `-sS` | 0 字节 | 完整诊断 | 0 / 非 0 |
| `-S` | 正常输出 | 完整诊断 | 0 / 非 0 |

```bash
# 只要成败，不要任何输出
if wave install jq -s; then echo ok; fi

# 平时安静，出问题时把原因留给我
wave install jq -sS || true
```

合并写法与 `-X`、`-C` 一致：`-sS`、`-Ss`、`-sXv`、`-CsX` 都认。

**为什么单给 `-s` 时连错误也不打印**：脚本里最常见的用法是
`if wave install jq -s; then …`，此时错误文本没有任何读者，而 `curl -s`
一直就是这个行为。需要错误时加一个字母即可。

### 实现方式

`-s` 通过把 **fd 1 与 fd 2 指向 `/dev/null`** 实现：

```python
os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
os.dup2(os.open(os.devnull, os.O_WRONLY), 2)
```

而不是给全仓七十多处 `print` 逐句加判断。后者有两个躲不开的问题：迟早漏一处；
且子进程（`curl`、`pkgunzip.sh`、进度条）根本不认 Python 的 `sys.stdout`。

`-s` 与 `-v` 同时给时，`-s` 优先 —— 静默的语义就是「不要再说了」。

`-s` 只对**会改动系统**的命令生效：`install`、`upgrade`、`uninstall`、
`link`、`unlink`、`selfupdate`。给 `list`、`latest`、`info`、`search`、`mirror`
传 `-s` 会被明确拒绝（否则你会得到一条什么都没输出的命令，却没有退出码可以说明原因）。

---

## 二、`wave upgrade --all`（`-a`）

```bash
wave upgrade --all          # 全部升到最新，旧版本保留
wave upgrade --all -X       # 全部升到最新，并清掉各自的旧版本
wave upgrade -a -s          # 静默批处理
```

- 与 `link` / `unlink` / `linkquery` / `latest` 的 `-a` 同名同义，不必记两套
- 默认**保留旧版本**（与单包升级一致）；给了 `-X` 才删
- **批量模式下 `-X` 不再逐个包弹「要删掉全部旧版本吗」** —— 这句话已经对所有包说过了
- 单个包失败（索引里没有、下载或校验失败）**不会中断其余的包**：

```
🌊 Checking the latest version of curl...
🌊 Upgrading curl: 1.0 -> 1.7.1
🌊 Checking the latest version of ghost...
🌊 Error: cannot read the version list for ghost
🌊 Checking the latest version of jq...
🌊 jq is already at the latest version (1.7.1).
🌊 1 upgraded, 1 already at the latest, 1 failed.
🌊 Error: could not upgrade ghost.
```

收尾汇总，并有包失败时以非零码退出 —— 脚本据此就能判断要不要重跑。

`--all` 与包名互斥，同时给会直接报错，而不是猜你的意思。

---

## 三、安装脚本的 `--silent` 改名为 `--ci`

`install.sh` 原来用 `-S/--silent`。而 `wave -S` 现在是 `--show-error`，
同一个产品里 `-S` 有两种含义，迟早出事。

它表达的意思本来就是「无人值守、给 CI 用」，所以直接改名：

```bash
bash install.sh --ci --dir-option=1
bash install.sh --CI --dir-option=2      # 大小写等价
```

旧写法**没有保留为别名** —— 留着等于把那个坑留在原地，现在会明确报
`unknown option '-S'`。

---

## 四、旗标用错时不再说「unknown」

同一个旗标被拒绝，其实有两种原因，说法必须分开：

| 你写的 | 以前 | 现在 |
| --- | --- | --- |
| `wave install jq -X` | `illegal option -X` | `-X only applies to wave upgrade` |
| `wave install jq -q -sS` | `wave: unknown flag: -q` | 不变（确实是拼错） |

`-X` 拼写没错，错的是命令。一律说成 unknown 会让人去反复改大小写，真正的原因
（选错了命令）反而看不到。静默模式下同理：`wave: -X only applies to wave upgrade`。

### 顺带修掉的三处

1. `wave install jq --json` 曾提示「`--json` 也适用于 `wave latest`」，
   而 `latest` 收到 `--json` 会直接拒绝 —— 把人指到一条同样会失败的命令上。
   `--json/--yaml/--toml/--raw` 只属于 `info`。
2. `wave list -s` 曾报 `unknown flag: -s`，现在说清它适用于哪些命令。
3. `wave update jq` 已经建议 `wave upgrade` 之后，不再打印整篇 56 行帮助，
   只留 6 行：错误、建议、`wave --help` 指路。

---

## 五、测试

新增 `scripts/flags_test.sh`，已进 CI。它做两件容易失效的事：

- 把 `lib/flags.py`（诊断用的旗标全集）与各命令真实的白名单逐项比对，
  两边走散就红 —— 那份清单只在「命令名写错」时才会被读到，平时跑不到，漏一项没人发现
- 断言 `-s` 真的一个字节都不输出、且失败时退出码非零

`scripts/upgrade_test.sh` 补了批量升级矩阵，包括「一个包失败、其余照常升级」。

> 修 `flags_test.sh` 自身时发现一个尴尬的问题：那个 Python 比对块打印了
> `FAIL ...` 却始终返回 0，`shell` 拿到 `rc=0`，「清单一致」这条断言
> **从来没可能变红**。现在补了 `sys.exit(1 if problems else 0)`，
> 并用「故意注入一条错配」反证它确实会红。

---

## 升级方式

```bash
wave selfupdate
```

4.x 内部升级，无迁移步骤，不改数据格式，不需要 sudo。

**3.x 用户不走这条路。** 跨大版本守卫内置于 3.x 脚本，你会看到：

```
🌊 MacWave 4 is a new major version, so it cannot be installed with selfupdate.
🌊 Your version: 3.2.x. Please install 4.1.4 from the website:
   https://macwave.org
🌊 Your current installation has not been changed.
```

请按提示从官网安装。4.0 的迁移说明见 [RELEASE-4.0.0.md](./RELEASE-4.0.0.md)。

---

## 已知限制

- `-s` 只压终端输出，不改变任何行为；需要「失败时重试」之类的能力请自己在外层做。
- 批量升级是**串行**的：几十个包时会依次检查版本，没有并发。`wave latest --all`
  可以先用来看哪些包需要升级。
- 批量模式不提供「跳过某个包」的语法；只想升一个就用单包形式。
- `install.sh` 的旧写法 `-S/--silent` 已移除，依赖它的脚本需要改成 `--ci`。

---

## 本版随附的数据

无数据格式变更。

```
macwavedata/latest.toml                  哪个版本是最新的
macwavedata/4.1.4/update_commands.sh     这一版具体怎么装
```

`update_commands.sh` 按版本冻结，发布后不再修改。
