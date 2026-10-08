## 🌊 MacWave

面向 macOS 软件开发者的包管理器。

Linux 用户？请看 [LinuxWave](https://github.com/LinuxWaveOrg/LinuxWave)

[English](./README.md) · **简体中文**

## 🌊 官方网站

[macwave.org](https://macwave.org)

## 🌊 支持的 macOS 版本
macOS Sonoma 14 及以上
## 🌊 最新版本

3.0，发布于 2026-10-08

## 🌊 MacWave 是什么？

MacWave 是一个运行在 **macOS** 上的**包管理器**，旨在为 macOS 软件开发者托管常用软件包。

## 🌊 为什么选择 MacWave

1. **一条命令，安装常用软件包。** 不再需要到处寻找下载链接。
2. **强制 @version。** 每个二进制文件都以 `package@version` 形式存储，因此多个版本可以共存，且不会与系统工具冲突。
3. **可选的免版本号链接。** `wave link <软件包>` 会创建一个不带版本号的 `软件包` 快捷方式，指向已安装的最高版本，并在你安装或卸载版本时自动改指。
4. **无缓存，始终最新。** 软件包元数据实时从 `MacWaveOrg/infosource` 仓库获取。
5. **支持 10 种归档格式，经 CI 验证。** 支持无扩展名二进制文件、`.zip`、`.tar.gz`、`.tar.bz2`、`.tar.xz`、`.tar`、`.gz`、`.xz`、`.bz2`、`.conda`。
6. **先校验，后解压。** 解压前先校验 SHA256。
7. **支持断点续传。** 下载中断了？用 `-C` 继续。
8. **轻量透明。** 纯 Python + Shell，无重型运行时，无隐藏行为。
9. **自动管理依赖。** 支持带依赖的软件包，采用引用计数与自动依赖管理，无需手动处理依赖。

## 🌊 安装 MacWave

在终端中运行：

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" && source ~/.zshrc
```

（如果你使用的是 bash 而非 zsh，请运行 ```source ~/.bashrc```）

**环境要求：Python（3.14 及以上）、Xcode Command Line Tools（14.0 及以上）。**

### 无人值守安装

面向脚本与批量场景，安装器提供若干参数，全程不会停下来等待输入。
参数放在 `--` 之后 —— `--` 会结束 bash 自身的选项：

```
# script already on disk
bash install.sh --silent --dir-option=1

# straight from the repository
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" \
  -- --silent --dir-option=2
```

`--silent`（`-S`）会自动应答目录菜单与许可协议；当选中的目录需要提权时，它要求免密 sudo
或以 root 运行。`--dir-option=N` 免菜单直接选定第 `N` 项（Intel 机器为 1-4，Apple 芯片为
1-3）；自定义项要在 `=` 之后附上路径，例如 `--dir-option=4=/opt/my-macwave`。完整参数列表
可运行 `install.sh --help` 查看。

> **注意参数的位置。** 写成
> `/bin/bash -c "$(curl ...)" --silent` 会让 `--silent` 变成脚本名（`$0`），从而被静默丢弃；
> 安装器检测到这种用法时会给出警告。正确写法是把参数放在 `--` 之后。

`uninstall.sh` 同样支持脚本化调用：`--force` 跳过确认，而确认本身需要一个终端
（因此在 CI 里请使用 `--force`）：

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/uninstall.sh)" -- --force
```

## 🌊 下载目录
已安装的二进制文件存储于（可选）：    
```
1. ~/.local/macwave
2. /opt/macwave
3. /usr/local/macwave (Only Intel Mac)
4. Custom
```
配置文件存储于（系统级安装始终优先）：
```
1. /opt/macwave_config          system-level install (needs sudo)
2. ~/.config/macwave_config     user-level install (no sudo)
```
## 卸载 MacWave

要从系统中彻底移除 MacWave，请在终端中运行以下命令：

```
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
  uninstall   Uninstall a package
  list        List installed packages
  search      Search for a package in the index
  info        Display detailed information about a package
  selfupdate  Update MacWave itself
  link        Link installed packages without a version number
  unlink      Remove those unversioned links
  linkquery   Show which version an unversioned link points to

Flags:
  -h, --help              Show help for any command
  -V, --version           Print version information
  -v, --verbose           Enable verbose output (show detailed logs)

Global Flags (can be used with any command):
  -C, --continue          Resume interrupted downloads (like curl -C -)
      --proxy string      Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)
      --skip-ssl          Skip SSL certificate verification (insecure)
      --limit-rate string Limit download speed (e.g., 200K, 1M, 5M)
      --ver string        Install a specific version of the package

Special Flags:
wave install <pkgname>@<version>   Download certain version(s) of a package
    --unlink                       Leave the unversioned link alone (install / uninstall)
    --all, -a                      Apply to every installed package (link / unlink / linkquery)

Unversioned Links:
wave link <name>                   Link a package to its highest installed version
wave linkquery <name>              Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)
wave unlink <name>                 Remove that link

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
trollrestore  by JJTech (@JJTech0130)
wget          by GNU Project
zoxide        by Ajeet D'Souza
```
## 🌊 许可证

本项目基于 **MIT 许可证** 发布 —— 详见 [LICENSE](LICENSE) 文件。

## 🌊 联系我们

Email：[hi@macwave.org](mailto:hi@macwave.org)


