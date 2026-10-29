## 🌊 MacWave

面向 macOS 软件开发者的包管理器。

Linux 用户？请看 [LinuxWave](https://github.com/LinuxWaveOrg/LinuxWave)

[English](./README.md) · **简体中文**

## 🌊 官方网站

[macwave.org](https://macwave.org)

## 🌊 支持的 macOS 版本
macOS Sonoma 14 及以上
## 🌊 最新版本

3.2.1，发布于 2026-10-27

## 🌊 关于MacWave

MacWave 是一个**面向 macOS 的包管理器**，用于分发 macOS 软件开发者日常依赖的命令行工具。Linux 由兄弟项目 LinuxWave 覆盖。

## 🌊 为什么选择 MacWave

1. **占用小。** 安装器按文件拉取，而不是 clone 整个仓库；也不保留需要同步的软件包缓存。
2. **一条命令装一个软件包。** 常用工具按名字安装，不必再逐个寻找发布页。
3. **版本化存储。** 每个二进制文件都存放在 `package@version` 之下，多个版本可以共存，且都不会遮蔽系统工具。
4. **可选的免版本号链接。** `wave link <软件包>` 会创建一个不带版本号的 `软件包` 快捷方式，指向已安装的最高版本；安装或卸载版本时，它会自动改指。
5. **天然隔离。** MacWave 安装的一切都留在自己的目录中，绝不覆盖或链接 macOS 系统库，因此即使跨越大版本升级 macOS，环境依然完整可用。
6. **元数据不会过期。** 软件包数据在请求时从 `MacWaveOrg/infosource` 仓库读取。
7. **十种归档格式，均由 CI 覆盖。** 无扩展名二进制文件、`.zip`、`.tar.gz`、`.tar.bz2`、`.tar.xz`、`.tar`、`.gz`、`.xz`、`.bz2` 与 `.conda`。
8. **先校验，后解压。** 缺少 SHA256 或校验不符的软件包会被拒绝，绝不「给出警告后照常安装」。
9. **支持断点续传。** 传输中断后可用 `-C` 继续。
10. **实现透明。** 只用 Python 与 Shell，并自带解释器 —— 无需另装运行时，行为也没有藏在运行时里。
11. **依赖自动处理。** 需要库的软件包会在记录中声明；MacWave 按引用计数安装、追踪并移除这些库。

## 🌊 安装 MacWave

在终端中运行：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" && source ~/.zshrc
```

（如果你使用的是 bash 而非 zsh，请运行 ```source ~/.bashrc```）

**环境要求：macOS Sonoma 14 及以上、Xcode Command Line Tools（14.0 及以上）。**

**你不需要自己安装 Python。** MacWave 自带一份 CPython，放在
`<安装目录>/python/` 下，并在旁边建私有运行环境；因此 PATH 上的 `python3`
（Homebrew、pyenv、系统自带的）都不会影响它。
若自带的那份下载失败，安装器会回退到系统的 `python3` 并明确提示。

> **本仓库存放的是源码，不是安装结果。** 在 clone 里运行 `wave`、或把 clone 中的目录
> 加入 `PATH`，都会按设计失败 —— 见[不要从仓库里直接运行](#不要从仓库里直接运行)。

### 无人值守安装

面向脚本与批量场景，安装器提供若干参数，全程不会停下来等待输入。
参数放在 `--` 之后 —— `--` 会结束 bash 自身的选项：

```bash
# 脚本已在本地
bash install.sh --silent --dir-option=1

# 直接从仓库执行
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" \
  -- --silent --dir-option=2
```

`--silent`（`-S`）会自动应答目录菜单与许可协议；当选中的目录需要提权时，它要求免密 sudo
或以 root 运行。`--dir-option=N` 免菜单直接选定第 `N` 项（Intel 机器为 1-4，Apple 芯片为
1-3）；自定义项要附上路径，写成 `--dir-option=4=/opt/my-macwave`，或直接写 `--dir-option=~/my-macwave`。
完整参数列表可运行 `install.sh --help` 查看。

> **注意参数的位置。** 写成
> `/bin/bash -c "$(curl ...)" --silent` 会让 `--silent` 变成脚本名（`$0`），从而被静默丢弃；
> 安装器检测到这种用法时会给出警告。正确写法是把参数放在 `--` 之后。

`uninstall.sh` 同样支持脚本化调用：`--force` 跳过确认，而确认本身需要一个终端
（因此在 CI 里请使用 `--force`）：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/uninstall.sh)" -- --force
```

## 🌊 下载目录
已安装的二进制文件存储于（可选）：    
```
1. ~/.local/macwave
2. /opt/macwave
3. /usr/local/macwave（仅 Intel Mac）
4. 自定义
```
配置文件存储于（系统级安装始终优先）：
```
1. /opt/macwave_config          系统级安装（需要 sudo）
2. ~/.config/macwave_config     用户级安装（无需 sudo）
```
## 🌊 使用镜像站（4.0 起）
MacWave 用到的每个地址都能替换，所以换镜像是一组环境变量而不是命令。要查当前生效的是哪个地址，用 `wave mirror` —— 它会列出每一项的来源（环境变量还是内置默认值）与地址，密码默认脱敏。

**这件事对国内用户最要紧**：`github.com` 常常不是慢，而是连不上。从一条国内线路实测：三次里两次在 20 秒内连 TCP 都没建立，而同一时刻国内镜像站 37~78 毫秒就返回了。

### 换成镜像站
```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps
```
其余地址继续用官方源，所以镜像站只需要镜像它承载的那部分内容。

路径里的 `MacWave/` 是为了让一个镜像域名能共用：以后 LinuxWave 可以放在同一台机器的 `/LinuxWave`，两边都不独占域名根。

### 全量镜像

上面两行只覆盖大文件的下载。当 `github.com` 与 `raw.githubusercontent.com` 是**连不上**而不是慢的时候，让 MacWave 能跑起来的那几个文件仍然在 GitHub 上：软件包索引、自更新数据、自带解释器、MacWave 自身代码。把它们全部指向镜像：

```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps
export MACWAVE_API_DOMAIN=https://mirror.example.cn/MacWave/infosource
export MACWAVE_SELFUPDATE_DOMAIN=https://mirror.example.cn/MacWave/selfupdate
export MACWAVE_PYTHON_DOMAIN=https://mirror.example.cn/MacWave/python
export MACWAVE_CORE_DOMAIN=https://mirror.example.cn/MacWave/core
export MACWAVE_PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
```

`MACWAVE_PIP_INDEX` 是唯一不一样的那个：它只影响 `pip` 安装的三个 Python 依赖（`requests`、`toml`、`colorama`），所以可以指向任意 PyPI 镜像。其余六个都是同一个镜像域名下的路径，因此一个账号就能覆盖全部。

### 一次写入，长期生效

`export` 只在当前终端有效，关掉就没了。把这个块追加进 `~/.zshrc`，此后每个终端自动继承：

```bash
cat >> ~/.zshrc <<'MWMIRROR'

# MacWave mirror — 删掉这一块就恢复官方地址
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps
export MACWAVE_API_DOMAIN=https://mirror.example.cn/MacWave/infosource
export MACWAVE_SELFUPDATE_DOMAIN=https://mirror.example.cn/MacWave/selfupdate
export MACWAVE_PYTHON_DOMAIN=https://mirror.example.cn/MacWave/python
export MACWAVE_CORE_DOMAIN=https://mirror.example.cn/MacWave/core
export MACWAVE_PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
MWMIRROR
source ~/.zshrc
```

跑一次就够。新开的终端自己会读到，末尾那句 `source` 只是让**当前**这个终端立刻生效。用不上的行可以删掉 —— 少写几行也能用，没设的变量会回落到官方地址。

四点需要注意：

- **口令要做百分号编码。** 密码里直接写 `@`、`:`、`/`、`"`、`$` 会破坏 URL 或 shell。改成 `%40`、`%24` 这类写法 —— `curl` 与 `requests` 都会在发出 Basic Auth 之前先解码。项目镜像页给出的就是编码后的形式。
- **`<<'MWMIRROR'` 的引号不能省。** 省了的话 shell 会在写入时就展开 `$`，哪怕密码里没有 `%` 也会被悄悄写坏。加上引号，文件里保留的就是你打的原样 —— 但 `.zshrc` 被读取时 `$` 仍会展开，所以还是要做百分号编码。
- **跑两次会追加两份。** 两份都会被求值、以最后一个为准，所以不至于出错，但正确做法是改已有的那一块，而不是再加一份。
- **这个文件是明文。** 用项目镜像时密码就明文躺在 `~/.zshrc` 里；如果这台机器还有别的账号，记得 `chmod 600 ~/.zshrc`。

无论最后写成什么样，`wave mirror` 都会列出每一项实际生效的地址，并标明它来自环境变量还是内置默认值。

### 受信任用户专用镜像

除了自己搭，还有一个**由项目维护的国内镜像**，只对受信任的用户开放，地址不公开。
需要的话写信给 [hi@macwave.org](mailto:hi@macwave.org?subject=申请%20MacWave%20镜像账号) 索取账号和密码。

账号是一组用户名 + 密码，直接写进 URL：

```bash
export MACWAVE_BOTTLE_DOMAIN="https://<用户名>:<密码>@<镜像地址>/MacWave/bottle"
export MACWAVE_DEPS_DOMAIN="https://<用户名>:<密码>@<镜像地址>/MacWave/deps"
```

要全量的话，同一组凭据分别写进六个路径即可 —— 镜像站六个都提供。

- `curl` 与 `requests` 都支持 URL 里带凭据，所以客户端不需要额外配置。
- 这两行会写进 `~/.zshrc`，**那是明文文件**：别把它提交进任何仓库，也别忘了密码对人可见。
- 报错时 MacWave 会把地址里的口令换成 `***` 再打印，所以贴日志求助不会顺便泄露密码。
- 镜像承载全部六个路径，所以把账号写进上面的全量配置后，「`github.com` 整体连不上」也能解决，不只是「大文件下不动」。

### 全部变量
| 变量 | 取什么 | 默认 |
| --- | --- | --- |
| `MACWAVE_BOTTLE_DOMAIN` | 预编译软件包 | GitHub Releases |
| `MACWAVE_DEPS_DOMAIN` | 依赖库 | GitHub Releases |
| `MACWAVE_API_DOMAIN` | 软件包索引 | raw.githubusercontent 上的 `infosource` |
| `MACWAVE_SELFUPDATE_DOMAIN` | 自更新数据 | raw.githubusercontent 上的 `Selfupdate` |
| `MACWAVE_PYTHON_DOMAIN` | 自带解释器 | raw.githubusercontent 上的 `Python` |
| `MACWAVE_CORE_DOMAIN` | MacWave 自身文件 | raw.githubusercontent 上的 `MacWave` |
| `MACWAVE_PKG_SOURCECODE_DOMAIN` | 软件包源码（预留） | — |
| `MACWAVE_PIP_INDEX` | `pip` 的索引（只影响三个 Python 依赖） | `https://pypi.org/simple` |

变量的值是**包名之前那一段**：客户端会往 bottle / deps 的地址后接 `/<包名>/<包名>@<版本>.<架构><扩展名>`，往其他地址后接 `/pkg/…`、`/macwavedata/…`、`/pythondata/…`。末尾斜杠会被自动去掉，写不写都行。

每类数据的确切文件树与命名规则见 [docs/DATA-LAYER.md](docs/DATA-LAYER.md)。

### 先验证再用
```bash
curl -o /dev/null -w '%{speed_download} B/s\n' \
  "$MACWAVE_BOTTLE_DOMAIN/jq/jq%401.8.2.arm64"
```
能快速下载、并且 `wave install jq` 成功，说明镜像可用。每个产物都会用索引里记录的 SHA-256 校验，所以镜像即使下发了被篡改的字节也会明确失败，而不是悄悄装进系统。

### 公司内网
这和「镜像慢」是两个问题：内网是**连不上**，不是距离远。加 `--proxy`，它会作用于这条命令的**所有**请求，而不只是下载包体那一步：
```bash
wave install jq --proxy http://proxy.corp:3128
```
在环境里设 `HTTPS_PROXY` 效果相同，而且能覆盖你忘记加旗标的命令。

### 自己架镜像站
镜像站就是一棵静态文件树，`nginx`、对象存储或任何文件服务器都行 —— 不需要特殊软件，也不需要数据库。搭建步骤（含建议加的两行 `Cache-Control`）见 [docs/MIRROR-SETUP.md](docs/MIRROR-SETUP.md)。

## 🌊 卸载 MacWave

要从系统中彻底移除 MacWave，请在终端中运行以下命令：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/uninstall.sh)"
```

## 🌊 运行软件包
要运行某个软件包，请使用带版本号的名称：
```
{package_name}@{version}
```
或者先用 `wave link {package_name}` 创建一次免版本号的快捷方式，之后直接运行：
```
{package_name}
```
不含版本号的链接始终指向已安装的最高版本，并在你安装或卸载版本时自动改指。

## 🌊 软链接管理

从 MacWave 2.4 起，建立不含版本号的软链接后，MacWave 会自动维护它指向的版本：

1. 最高版本被卸载后，不含版本号的软链接会改指向剩余版本中的最高版本，被卸载版本自己的软链接一并撤销。
2. 安装会把不含版本号的软链接指向本次安装的版本；本次安装加上 `--unlink` 可跳过这一步。
3. 某软件包不再有任何版本时，不含版本号的软链接会被撤销。
4. 无论何种情况，含版本号的名称始终可以调用，即使存在不含版本号的软链接。

手动 `wave unlink {package_name}` 过的软件包会被记住，之后的卸载不会重新为它建立链接。

## 🌊 命令参考

```
Usage:
  wave <command> [package] [flags]

Commands:
  install     Install a package (Latest Version)
  upgrade     Install a package at the latest version
  uninstall   Uninstall a package
  list        List installed packages
  search      Search for a package in the index
  info        Display detailed information about a package
  selfupdate  Update MacWave itself
  link        Link installed packages without a version number
  unlink      Remove those unversioned links
  linkquery   Show which version an unversioned link points to
  mirror      Show which address each kind of data is fetched from

Flags:
  -h, --help              Show help for any command
  -V, --version           Print version information
  -v, --verbose           Enable verbose output (show detailed logs)

Global Flags (can be used with any command):
  -C, --continue          Resume interrupted downloads (like curl -C -)
      --proxy string      Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)
      --skip-ssl          Skip SSL certificate verification (insecure)
      --limit-rate string Limit download speed (e.g., 200K, 1M, 5M)
      --max-time string   Timeout for each request, for install and selfupdate
                          (e.g., 40s, 1min, 1min20s, 2h; bare numbers are seconds)
      --ver string        Install a specific version of the package

Special Flags:
wave install <pkgname>@<version>   Download certain version(s) of a package
wave upgrade <pkgname>             把软件包更新到最新版本
    --remove-old-version           移除比刚装上的版本更旧的版本
    --remove-old-versions          同 --remove-old-version
    --rov                          同 --remove-old-version
    -X                             同 --remove-old-version
    --unlink                       Leave the unversioned link alone (install / uninstall)
    --all, -a                      Apply to every installed package (link / unlink / linkquery)

Self Update:
wave selfupdate                    Update MacWave itself
wave selfupdate --max-time=2min    Same, but give each request two minutes

Unversioned Links:
wave link <name>                   Link a package to its highest installed version
wave linkquery <name>              Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)
wave unlink <name>                 Remove that link

Mirror Configuration:
wave mirror                        Show the address each source is fetched from
    --json / --yaml / --toml       Print the same information in that format
    --raw                          Print ready-to-paste export lines
    --only-set                     With --raw: export only the sources you overrode
    --show-password                Print passwords instead of six asterisks
    --hide-user                    Mask the user name too

```

卸载某个版本会把链接改指向次高版本，没有版本剩余时则删除该链接。`uninstall --unlink`
保持链接原样，但**拒绝执行**会让链接指向“你正在卸载的那个版本”的操作。
## 🌊 演示图片

<p align="center">
  <img src="images/demo1.png" alt="demo1" width="80%" style="max-width: 720px;">
</p>

## 🌊 支持的软件包
（按字母顺序排列）

```
bat           by David Peter
btop          by Aristocratos
choma         by opa334
dust          by bootandy
eza           by Christina Sørensen and the eza community
fd            by David Peter
ffmpeg        by FFmpeg Team
fileicon      by Michael Klement
fzf           by Junegunn Choi
htop          by Hisham Muhammad and the htop team
ipsw          by blacktop
jq            by Stephen Dolan, Nicolas Williams, et al.
ldid          by Jay Freeman (saurik) / Procursus Team
lsd           by Abin Simon
ncdu          by Yoran Heling
palera1n      by palera1n Team
pandoc        by John MacFarlane
rg            by Andrew Gallant
tmux          by Nicholas Marriott and contributors
tree          by Steve Baker, Thomas Moore, et al.
trollrestore  by JJTech (@JJTech0130)
wget          by GNU Project
yq            by Mike Farah
zoxide        by Ajeet D'Souza
```
## 🌊 面向开发者

MacWave 由纯 Python 与 Shell 写成，没有构建步骤 —— 本仓库里的文件就是实际运行的代码。
内部实现见 [`docs/TECHNICAL-GUIDE.md`](./docs/TECHNICAL-GUIDE.md) 与
[`docs/CODE-MAP.md`](./docs/CODE-MAP.md)。

若要阅读或修改源码，先把仓库克隆下来：

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/MacWaveOrg/MacWave.git macwave
cd macwave
```

在该目录里运行任何东西之前，请先读下面一节。

### 从最新发布分支切出

所有新开发都基于最新的发布分支（当前是 `4.1`），不要从更旧的版本分支切：

```bash
git switch -c 4.2 4.1
```

旧分支停在旧内容上，缺少后续修复 —— 从它切出去等于把已经解决的问题重新引入。
发布顺序与分支策略见 [`docs/RELEASE-CHECKLIST.md`](./docs/RELEASE-CHECKLIST.md)。

### 不要从仓库里直接运行

本仓库是源码，不是安装结果。在仓库目录里运行 `wave`，或把仓库中的目录加入 `PATH`，
都会**按设计**失败：MacWave 依赖 `install.sh` 写出的配置文件，而该文件记录了安装目录
以及其旁各部分的布局。

完整的 clone 会报：

```
🌊 Error: MacWave is a git clone!
```

shallow clone 会报：

```
🌊 Error: MacWave is a shallow clone!
```

两者之后都会给出同样的建议：用 `install.sh` 安装、选择目录，然后使用安装出来的
`wave`。若要验证正在修改的代码，请在临时根目录下安装一份丢弃副本，或直接运行
`scripts/` 下的脚本 —— 它们作用于当前已有的那份安装。

### 仓库分工

| 仓库 | 存放内容 |
| --- | --- |
| `MacWaveOrg/MacWave` | 程序本体 |
| `MacWaveOrg/infosource` | 软件包索引，每个软件包、每种架构各一个目录 |
| `MacWaveOrg/configdata` | 已发布的版本、自更新的文件清单、自带的解释器 |

### 源码结构

| 目录 | 职责 |
| --- | --- |
| `lib/` | 入口、帮助、配置路径、自更新 |
| `pkg/` | 安装、升级、卸载、链接、版本号解析 |
| `surfboard/` | 依赖解析、解压、Mach-O 重定位 |
| `scripts/` | 测试与数据审计 |

每个命令都是一个模块，各自只有一个处理函数，由 `lib/wave.py` 统一分派。
所有 Mach-O 改写都集中在 `surfboard/`。

### 收录一个软件包

记录放在 `infosource` 的 `pkg/pkginfo_<架构>/<软件包名>/` 下，分两类文件：

- `_<软件包名>@common` —— 所有版本共用的元数据：`des`、`hom`、`lic`、`aut`，
  以及 `bin_name`，即二进制文件安装后的名字。
- `_<软件包名>@<版本号>` —— 每个版本一个文件，包含 `url` 与 `sha256`；当这个软件包
  需要 MacWave 一并安装的库时，再加上 `deps`。

`sha256` 是必填项。缺少它的记录会被拒绝安装，而不是给出警告后照常安装。
依赖写成 `name@version` 并采用引用计数，因此移除一个软件包不会连带删掉其他软件包
仍在使用的库。

### 运行测试

每个脚本都会完整跑一遍，结果以 `PASS` 或 `FAIL` 呈现：

```bash
bash scripts/configpath_test.sh    # 配置目录的解析规则
bash scripts/format_test.sh        # 全部受支持的归档格式
bash scripts/deps_test.sh          # 依赖安装与级联清理
bash scripts/link_test.sh          # 不含版本号的软链接
bash scripts/upgrade_test.sh       # wave upgrade（离线）
bash scripts/selfupdate_test.sh    # 自更新，最后一步会真的更新一遍
python3 scripts/random_test.py     # 随机化端到端回归，需要联网
python3 scripts/audit_deps.py data # 用已装的库审计索引数据
```

`random_test.py --dry-run` 只挑选软件包并打印计划，不访问网络。

### 参与贡献

所有分支都经由 PR 合入，且至少需要一次批准；禁止强制推送与删除分支。
提交 PR 前请先运行上表中的测试，并说明运行了哪些。报告缺陷时，请附上
`wave --version`、`sw_vers` 与 `uname -m` 的输出。

## 🌊 许可证

本项目基于 **MIT 许可证** 发布 —— 详见 [LICENSE](LICENSE) 文件。

## 🌊 联系我们

Email：[hi@macwave.org](mailto:hi@macwave.org)


