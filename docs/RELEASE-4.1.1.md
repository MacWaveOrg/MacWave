# MacWave 4.1.1 发布说明

> 本文说明 4.1.1 的变更范围、使用方式与已知限制。
> 三个新命令选项，不涉及数据格式，升级无迁移步骤。
>
> 镜像站的搭建与变量含义参见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)，
> 数据层的文件布局参见 [DATA-LAYER.md](./DATA-LAYER.md)。
>
> 发布分支：`4.1`

---

## 概述

4.1.1 补上三处「看」的能力，都源于同一个问题：**信息在，但没有出口**。

| 想知道什么 | 4.1.0 之前只能 | 4.1.1 之后 |
| --- | --- | --- |
| 有哪些包该升级了 | 起一次 `upgrade`，看它删改什么 | `wave latest --all` |
| 某个包的字段值 | 抓 `wave info` 的文字输出 | `wave info --json` |
| 索引里这条记录原样长什么样 | 翻 GitHub 上的文件 | `wave info --raw` |
| 命令敲错时该敲什么 | 读整篇帮助 | 直接给出正确写法 |

另外把镜像站的运维脚本也纳入本分支，使服务器能自己跟进上游新版本。

---

## 用户可见的变更

### `wave latest`

判断「有什么过期了」原先必须启动升级。现在可以只问不做：

```
$ wave latest jq
🌊 jq  1.7.1 → 1.8.0
```

```
$ wave latest --all
🌊 jq        1.7.1 → 1.8.0
🌊 ffmpeg    9.0   (已是最新)
```

比较基准是**已安装的最高版本**，不是那个不带版本号的链接。链接才是实际执行的，
所以当它指向更旧的版本时，右侧会附一行提示 —— 值得知道，但正常情况不打扰。

两种失败从此不再长得一样：名字拼错会从索引自己的名字表里给出建议；
名字确实不存在则直接说没找到，并提示可能是索引没更新。

### `wave info --json` / `--yaml` / `--toml` / `--raw`

原先只能打印带标签的文字行，想要某个字段就得从文本里抠。
现在三种格式输出同一组字段：`name`、`author`、`description`、`homepage`、
`license`、`installed`、`available`、`latest`。

三者互斥，同时要两种是错误而不是悄悄选一个。

`--raw` 刻意不是「同一份数据的另一种排版」，而是把索引里的 `@common` 记录
**原样**打印，连 `sha256` 和 `url` 一起。它回答的是「这个作者名是从哪儿来的」——
只重排客户端恰好解析的那几个字段，反而会把没解析的藏起来。
包里没有这条记录时是错误，不是空输出。

### 敲错时直接说该敲什么

两处死胡同：

**命令名拼错。** `wave update jq` 会失败，因为只有 `upgrade`。原先的回覆是一句
「Unknown command or argument」加上整篇帮助。而 `/usr/bin` 下其它包管理器
都把它拼作 `update`，这正是大家会犯的错。现在它会认出这一小组值得猜的名字
（`update`、`remove`、`ls` 等），并把**建议里的其余命令行原样保留**，
于是可以直接粘回去重跑。

**包名拼错**原先总是给同样的三行提示（确认包存在、确认镜像地址、重建索引）。
现在会先从索引里找相近的名字。

---

## 镜像运维（对使用者透明）

本分支同时纳入镜像站的自动化脚本，普通用户无需任何操作：

- `scripts/mirror-check/` 定期检查镜像站与上游是否一致，结果记入日志
- `scripts/known-bad-records.txt` 记录**故意坏掉**的测试记录（`test_001`、
  `test_no_sha256`、`test_wrong_sha256`、`ldid`），CI 与镜像脚本共读这一份，
  免得两边各记一份、日后漂移
- 修掉了镜像脚本不认识这份清单的问题：原先每轮都会把那五个「故意坏」的记录
  报成失败，真正的故障就埋在里面了

---

## 升级方式

```bash
wave selfupdate
```

4.x 内部升级，无迁移步骤，不改任何数据格式。

**3.x 用户不走这条路。** 跨大版本守卫内置于 3.x 脚本，你会看到：

```
🌊 MacWave 4 is a new major version, so it cannot be installed with selfupdate.
🌊 Your version: 3.2.x. Please install 4.1.1 from the website:
   https://macwave.org
🌊 Your current installation has not been changed.
```

请按提示从官网安装。4.0 的迁移说明见 [RELEASE-4.0.0.md](./RELEASE-4.0.0.md)。

---

## 已知限制

- `wave latest` 只比较版本号，不判断依赖关系是否需要连带升级
- `--raw` 输出的是记录原样，字段名与顺序随索引变化，不适合当稳定接口
- 镜像健康检查依赖 GitHub API，未认证时每小时限 60 次；脚本已复用
  `GH_TOKEN`，未设置时会跳过检查而不是报失败

---

## 本版随附的数据

无数据格式变更。索引与包体沿用 4.1.0 的布局：

```
macwavedata/latest.toml                  哪个版本是最新的
macwavedata/4.1.1/update_commands.sh     这一版具体怎么装
```

`update_commands.sh` 按版本冻结，发布后不再修改。
