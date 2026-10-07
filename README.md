## 🌊 MacWave

A package manager for macOS software developers.

## 🌊 Official Website

[macwave.org](https://macwave.org)

## 🌊 Supported macOS Version
macOS Sonoma14 and above
## 🌊 Latest Version

2.3.1, Release on 2026-09-27

## 🌊 What is MacWave?

MacWave is a **package manager** that runs on **macOS/Linux**, designed to host common software packages for macOS software developers.

## 🌊 Why MacWave

1. **One command, install common packages.** No more scattered download links.
2. **Mandatory `@version`.** Every binary is stored as `package@version`, so multiple versions can coexist without conflicting with system tools.
3. **No cache, always up to date.** Package metadata is fetched live from the `infosource` branch.
4. **9 archive formats, CI-verified.** Supports no-extension binaries, `.zip`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar`, `.gz`, `.xz`, `.bz2`.
5. **Verify first, extract later.** SHA256 is checked before extraction.
6. **Resumable downloads.** Interrupted? Resume with `-C`.
7. **Lightweight and transparent.** Pure Python + Shell. No heavy runtime, no hidden behavior.
8.**Automatically manage dependencies.** Support for software packages with dependencies, using reference counting and automatic dependency management, with no need to handle dependencies manually.

## 🌊 Install MacWave

In the terminal, run:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```
```
source ~/.zshrc
```

(If you are using bash instead of zsh, run ```source ~/.bashrc```)

**Requirements: Python (3.13 and above), Xcode Command Line Tools (14.0 and above).**

## 🌊 Download Directory 
Installed binaries are stored in (options):    
```
1. ~/.local/macwave
2. /opt/macwave
3. /usr/local/macwave (Only Intel Mac)
4. Custom
```
Config file is stored in:
```
/opt/macwave_config
```
## Uninstall MacWave

To completely remove MacWave from your system, run the following command in your terminal:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/uninstall.sh)"
```

## 🌊 Run Packages
To run a package, run the following commands in your terminal:
```
{package_name}@{version}
```
**Notes：DO NOT forget the version number, or you CAN NOT run the package**

## 🌊 Command Reference

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

```
## 🌊 Demo Pictures

<p align="center">
  <img src="images/demo1.png" alt="demo1" width="80%" style="max-width: 720px;">
</p>

## 🌊 Supported Packages
(Listed in alphabetical order)

```
bat           by David Peter
choma         by opa334
fd            by David Peter
ffmpeg        by FFmpeg Team
fzf           by Junegunn Choi
jq            by Stephen Dolan, Nicolas Williams, et al.
ldid          by Jay Freeman (saurik) / Procursus Team
lsd           by Abin Simon
palera1n      by palera1n Team
rg            by Andrew Gallant
tmux          by Nicholas Marriott and contributors
trollrestore  by JJTech (@JJTech0130)
wget          by GNU Project
zoxide        by Ajeet D'Souza
```
## 🌊 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

## 🌊 Contact Us

Email：[hi@macwave.org](mailto:hi@macwave.org)


