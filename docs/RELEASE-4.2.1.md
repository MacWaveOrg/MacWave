# MacWave 4.2.1 发布说明

- 发布：2026-11-04，构建号 `308A1418`
- 分支：`4.2`
- 上一版：[4.2.0](RELEASE-4.2.0.md)（2026-11-03，安全版本）

## 概述

这一版没有新增命令。三件事：

1. **`min_os`（实验性，4.3 转正）** —— 索引可以声明一个包的 macOS 下限，安装时
   警告并询问。数据已全库回填。
2. **`--zh`** —— 安装程序可以输出中文，覆盖到安装流程的每一步，包括底下的更新脚本。
3. **两处「说得更清楚」** —— 旗标拼错时给候选，裸二进制包也提示安全检查。

外加一处结论修正：**对外承诺的 macOS 下限从 Sonoma 14 改回 Monterey 12**。

---

## 一、`min_os`：索引能声明包的 macOS 下限（实验性）

### 它解决什么问题

在这之前，索引里的版本记录只有 `url` / `file` / `sha256` / `deps`，**没有任何
macOS 版本信息**。于是「这个包能不能在我的系统上跑」只能靠装完再试：轻则启动失败，
重则 dyld 抛一个指向某个 dylib 的错，跟自己想装的东西看起来毫无关系。

现在版本记录可以带一个可选字段：

```
sha256: "2d7534…"
file: "jq-macos-arm64"
url: "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-arm64"
min_os: "14.0"
```

值从产物里自动提取：所有 Mach-O 的 `LC_BUILD_VERSION.minos`（老工具链是
`LC_VERSION_MIN_MACOSX.version`）取**最大值**。`tmux@3.6` 本体是 12.0，但它带的
`libevent` dylib 是 12.1，所以整包记为 12.1。

### 安装时的行为

| 情况 | 行为 |
| --- | --- |
| 记录里没有 `min_os` | 静默放行 |
| 本机 ≥ 声明 | 静默放行 |
| 本机 < 声明，默认 | 黄字警告 + `Continue installing anyway? [y/N]` |
| 答复 `y` / `Y` | 继续安装 |
| 其它任何答复（直接回车、`yes`、非交互读不到） | 中止，**不下载** |
| 带 `-s`（含 `-sS`） | 不询问，直接中止。纯 `-s` 一个字都不输出，`-sS` 才把原因打出来 |
| 带 `-F` / `--force` | 不问，直接装 —— **再看 `-s` 也压不住它** |

实际长这样：

```
🌊 Warning: pandoc@3.13 declares macOS 15.0 or later, this machine is 12.7.6.
🌊          It may still work — that declaration is the build-time
🌊          minimum, not a guarantee.
🌊 Continue installing anyway? [y/N]
```

`wave info <包名>` 也会多一行：

```
🌊 Requires macOS:     14.0 or later
```

### 为什么只是询问，不是硬拦截

`minos` 是**构建时**的声明，不等于真实的 API 需求。两种情况都真实存在：

| 包 | 声明 | 实际 |
| --- | --- | --- |
| `jq@1.8.2` | 14.0 | 在 macOS 12.7.6 上实测照常输出 `jq-1.8.2` |
| `pandoc@3.13` | 15.0 | 可能真的调用了新符号 |
| `ipsw@3.1.7xx` | **27.2** | Go 用 Xcode 27 beta 链接，SDK 版本被原样写进 `minos` |
| `ollama@0.3x` | **26.2** | 同上 |

客户端分辨不了这四种情况。硬拦下来的话，`jq` 会在本来能用的机器上装不了，
`ipsw` 更是在**任何**已发布的 macOS 上都装不了 —— 而它实际跑得动。

所以把选择交给用户，`-F` 是给批量和 CI 场景留的门。

### 数据

全库真实软件包 100% 覆盖：

| 架构 | 有 `min_os` | 总数 |
| --- | --- | --- |
| arm64 | 96 | 112 |
| amd64 | 89 | 106 |

未覆盖的 33 条都不该有：`test_*`（负向与格式测试样本，Bottle 里没有真实产物）
和 `fileicon`（bash 脚本，不是 Mach-O）。

两架构的下限差得很明显，如实记录、没有互相补齐：

| 包 | arm64 | amd64 |
| --- | --- | --- |
| `tmux` | 12.1 | 10.9 |
| `atuin` | 11.0 | 10.12 |
| `wget` | 11.1 | 10.15 |

全库分布：`11.0` 74 条、`10.12` 29 条、`10.13` 15 条、`13.0` 11 条、`12.0` 11 条、
`15.0` 10 条、其余零星。

回填工具在 `infosource` 仓库：`scripts/backfill_min_os_from_bottle.py`（下载全部
产物）与 `scripts/backfill_min_os.py`（读本机安装树）。两者都幂等、都支持 `--dry-run`。

### 这一版仍存在的问题

- **依赖链的门槛不会提前算出来**：装 `wget` 时若某个传递依赖要求更高的系统，
  询问发生在装那个依赖的时候，报错指向的是依赖而不是 `wget`。
- 字段还是实验性的，4.3 才定稿。如果 4.3 之前发现语义有问题，还来得及改。

---

## 二、`--zh`：安装程序中文输出

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" -- --zh
```

安装选项必须写在 `--` 之后 —— 那个 `--` 用来结束 bash 自己的选项，否则 `--zh`
会被当成脚本名而丢掉（安装程序会提示这一点）。

覆盖范围包括安装程序本身和它调用的更新脚本：

```
██╗    ██╗ █████╗ ██╗   ██╗███████╗
...
🌊 欢迎使用 MacWave 4.2.1！
🌊 从镜像安装：…
🌊 检测到架构：arm64
🌊 目录选项：1（来自 --dir-option）
🌊 正在获取更新命令……
🌊 正在检查自带 Python 版本……
🌊 正在安装 MacWave 4.2.1
🌊 正在创建独立的 Python 环境……
🌊 安装完成！
🌊 MacWave 已安装到：~/.local/macwave
```

实现上没有引 gettext，也没有依赖外部工具 —— 这个脚本要在裸 macOS 上跑，多一个
依赖就多一处装不上。文案直接写两份，由 `mw_say()` 按 `MACWAVE_LANG` 选；语言通过
环境变量一路传给底下的更新脚本，所以不会中英混杂。

默认仍是英文：终端不一定有中文 locale，反过来会让英文用户看到乱码或问号。

---

## 三、两处「说得更清楚」

### 旗标拼错时给候选

```
🌊 Error: illegal option --connect-time for `wave install`
🌊           you ran: wave install yq --connect-time=1min
🌊 Next      Did you mean --connect-timeout?
🌊           `wave install --help` lists the flags this command accepts
```

用 `difflib` 只在**当前命令的白名单**里匹配，不跨命令猜。实测：

| 输入 | 建议 |
| --- | --- |
| `--connect-time` | `--connect-timeout` |
| `--limt-rate` | `--limit-rate` |
| `--max-tme` | `--max-time` |
| `--unkown-flag` | （无建议，不瞎猜） |

没有候选时输出与以前逐字一致，脚本匹配不受影响。

### 裸二进制包也提示安全检查

4.2.0 装 `yq` 这类无扩展名的产物时，这一段是**完全静默**的：不解压 → 临时目录
不存在 → 检查函数直接 return，连提示都不打。用户看到的是：

```
🌊 Extracting package...
🌊 Successfully installed yq@4.54.1
```

「解压」之后直接「装好了」，中间那一步像根本不存在。现在：

```
🌊 Running security checks...
🌊 Single-file payload: nothing was unpacked, so there are no links to check.
```

判断上仍然安全（单个普通文件不可能包含符号链接），但**说不说**和**查不查**是两件事 ——
「悄悄跳过了什么」比「跳过」本身更让人不安。

---

## 四、对外的 macOS 版本口径改了

官网与两个 README 原来写 `macOS Sonoma 14 and above`。这个数字是 09-13 一次
`index.html` 提交抬上去的，并非实测结果（来龙去脉见
[GH-PAGES-HISTORY.md](GH-PAGES-HISTORY.md)）。

实测：2015 款 MacBook Air（macOS 12.7.6 + Xcode CLT 14.2）完整跑通安装、依赖链
与 Mach-O 重定位；自带 CPython 在 x86_64 上声明 `minos 10.15`、arm64 上 `11.0`。

所以现在分三层说：

- **承诺** macOS 12 Monterey 及以上 —— 实测过的下限
- **说明** Intel 的理论地板是 Catalina（10.15），但 12 以下没做过端到端实测
- **补充** 单个软件包可能有自己的下限，`wave info` 可查，安装时会先问一句

同时去掉了 `Xcode Command Line Tools (14.0 or later)` 里的版本号：更老的 CLT
同样提供 `otool` / `install_name_tool` / `codesign`。

---

## 测试

这一版新增/扩充的回归：

| 脚本 | 断言数 | 盯住什么 |
| --- | --- | --- |
| `scripts/minos_test.sh` | 49 | 版本串解析（位数不同也比）、缺失必须静默、非交互往安全侧倒、`-F` 越过、`-s`/`-sS` 的差别、info 三种格式、回填幂等 |
| `scripts/message_test.sh` | 24 | 新增「旗标拼错给候选」与「无候选时不编造」 |
| `scripts/linksafety_test.sh` | 28 | 新增「裸二进制也提示安全检查」 |

三条 CI 线：`format-test`（3.14 / 3.15）、`random-test`（3.14 / 3.15）、
CircleCI `offline-tests`。

## 兼容性

- 索引里没有 `min_os` 的记录行为完全不变；字段缺失时客户端静默放行。
- 4.2.0 及更早的客户端不认 `min_os`，会忽略，向后兼容。
- `-F` 是新增旗标；`--connect-time` 这类拼错仍然被拒绝，只是现在会给出候选。
- `--zh` 是安装程序参数，与 `wave` 命令无关。

## 升级方式

```bash
wave selfupdate
```

或重新运行安装脚本，默认的英文输出不变。

## 本版随附的数据

| 仓库 | 提交 | 内容 |
| --- | --- | --- |
| `infosource` | `c92d1fc` | 172 条 `min_os` 回填 + `backfill_min_os_from_bottle.py` |
| `Selfupdate` | 本版 | `macwavedata/4.2.1/update_commands.sh` |
| `configdata` | 本版 | `latest_version` → 4.2.1 |
| `Pages` | `ae09ad3` | 版本号与 macOS 下限 |
