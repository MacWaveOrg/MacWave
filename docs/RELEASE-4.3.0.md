# MacWave 4.3.0 发布说明

- 发布：2026-11-04，构建号 `308A1849`
- 分支：`4.3`（新建；`4.2` 冻结在 4.2.5）
- 上一版：[4.2.5](RELEASE-4.2.5.md)

## 请务必升级：4.2.0 及更早存在一个能让整台机器被接管的缺陷

这不是「建议升级」，是**需要升级**。下面三条按严重程度排列。

### ① 装到 `/usr/local` 时，会 chown 整个 Homebrew

`install.sh` 收到 `--dir-option=3=/usr/local` 时，旧版校验会放行（它只挡了 `..`、
控制字符、非 ASCII、相对路径和 `/`）。之后安装脚本执行：

```bash
sudo chown -R "$CURRENT_USER": "$BASE_DIR"     # BASE_DIR = /usr/local
```

于是**整个 `/usr/local` 变成当前用户的** —— Homebrew 的全部目录、`brew` 自己的
可执行文件都在里面。而拒绝用户协议时的回滚是 `rm -rf "$BASE_DIR"`，那一步会
**删掉 `/usr/local` 整个目录**。

实测这些路径旧版全部能通过校验：`/usr/local`、`/opt`、`/etc`、`/usr`、`/bin`、
`$HOME`。

**4.3.0 起**：系统目录本身一律拒绝（按完全相等判，`/opt/macwave` 这类子目录不受
影响）；已存在且非空、又不是 MacWave 安装的目录也拒绝。

### ② 系统级安装把用户拥有的二进制放进了系统 PATH

同一条 `chown -R` 的另一个后果：`/opt/macwave` 归「第一个装它的人」所有，于是
`/opt/macwave/links/jq` 是**用户可写**的。任何以该用户身份运行的进程都能替换它，
而它可能被别的用户、脚本甚至 root 执行 —— 这是教科书式的本地提权路径。

**4.3.0 起**：安装树归 `root:<管理员组>`、权限 755。

| 角色 | 权限 |
| --- | --- |
| 所有人 | 读 + 执行 → **能运行已装的包** |
| 管理员 | `sudo wave install` → **能装、能删** |

代价是系统级安装下 `wave install` 需要 `sudo`。这一点现在会**在动手之前就说清楚**
（而不是等下载到一半报 `Permission denied` 并被归因成「网络或代理问题」）。

### ③ 升级脚本在多数 macOS 上直接崩（4.2.1 / 4.2.2）

如果你装过 4.2.1 或 4.2.2，`wave selfupdate` 与官方安装命令都会以
`unbound variable` 失败。原因：中文文案写成 `$MACWAVE_VERSION！`、`$repo_path……`
—— 变量后面紧跟中文标点，`/bin/bash` 3.2 在 UTF-8 locale 下会把那个字符的首字节
读进变量名，`set -u` 于是报「变量不存在」。

4.2.3 已修复，本版继承修复，并新增 `scripts/shell_lint.sh` 在两条流水线上扫这
一类写法。

## 本版新增：`min_os` 转正

`min_os` 从 4.2 的实验状态转为正式特性。索引的版本记录可以声明一个包要求的
macOS 下限，安装时警告并询问。

数据已全库回填：**真实软件包 100% 覆盖**（arm64 96/112、amd64 89/106；缺的只有
`test_*` 负向样本与 `fileicon` 这个 bash 脚本）。

行为矩阵：

| 情况 | 行为 |
| --- | --- |
| 记录里没有 `min_os` | 静默放行 |
| 本机 ≥ 声明 | 静默放行 |
| 本机 < 声明，默认 | 黄字警告 + `Continue installing anyway? [y/N]` |
| 答复 `y` / `Y` | 继续安装 |
| 其它任何答复（含直接回车、非交互） | 中止，**不下载** |
| `-s`（含 `-sS`） | 不询问，直接中止；纯 `-s` 一个字都不输出 |
| `-F` / `--force` | 不问，直接装 —— `-s` 也压不住 |

**为什么是询问而不是硬拦截**：`minos` 是构建时的声明，不等于真实 API 需求。

| 包 | 声明 | 实际 |
| --- | --- | --- |
| `jq@1.8.2` | 14.0 | 在 macOS 12.7.6 上实测照常运行 |
| `pandoc@3.13` | 15.0 | 可能真用到新 API |
| `ipsw@3.1.7xx` | **27.2** | Go 用 Xcode 27 beta 链接，SDK 版本被原样写进 `minos` |
| `ollama@0.3x` | **26.2** | 同上 |

硬拦下来的话，`ipsw` 在**任何**已发布的 macOS 上都装不了 —— 而它实际跑得动。

## 本版新增：命令名打错时的提示

```
$ wave instal jq
🌊 Error: Unknown command or argument.
   wave instal jq
        ^^^^^^

🌊 Did you mean: wave install jq
   instal is not a command. The one you want is install.

   For the full list: wave -h
```

单字母错误（删 / 换 / 插一个字符，穷举 4670 种）**命中 98.1%**，误猜 0.3%。
猜不到时也只留一行 `wave -h`，不再倒五六十行帮助。

## 升级方式

```bash
wave selfupdate
```

**如果你在 4.2.1 / 4.2.2**（那两版的 selfupdate 是坏的），改用安装命令：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

**如果你当初装在 `/opt/macwave` 或 `/usr/local/macwave`**：升级后安装树会归
`root:<管理员组>` 所有，之后装包需要 `sudo wave install <包>`。这是刻意的变化，
理由见上面第 ② 条。

## 分支变化

| 项 | 变化 |
| --- | --- |
| 新分支 | `4.3`（从 4.2.5 之后切出，含全部 4.2.x 历史） |
| `4.2` | 冻结在 4.2.5，不再接收提交 |
| `configdata` | `branch` → `4.3`，`version` → 4.3.0 |
| CI | `format-test` 与 CircleCI 的分支白名单都加了 `4.3` |
| `dependabot.yml` | `target-branch` → `4.3` |

## 本版随附的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.3.0/update_commands.sh` |
| `configdata` | `latest_version` → 4.3.0 / branch 4.3 |
| `Pages` | 版本号 → 4.3.0 |
