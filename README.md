## 🌊 MacWave

A package manager for macOS software developers.

## 🌊 Official Website

[macwave.org](https://macwave.org)

## 🌊 Supported macOS Version
macOS Sonoma14 and above
## 🌊 Latest Version

2.4.2, Release on 2026-09-29

## 🌊 What is MacWave?

MacWave is a **package manager** that runs on **macOS/Linux**, designed to host common software packages for macOS software developers.

## 🌊 Why MacWave

1. **One command, install common packages.** No more scattered download links.
2. **Versioned storage.** Every binary is stored as `package@version`, so multiple versions can coexist without conflicting with system tools.
3. **Optional unversioned links.** `wave link <package>` creates a plain `package` shortcut pointing at the highest installed version, and it re-points itself whenever you install or remove versions.
4. **No cache, always up to date.** Package metadata is fetched live from the `infosource` branch.
5. **10 archive formats, CI-verified.** Supports no-extension binaries, `.zip`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar`, `.gz`, `.xz`, `.bz2`, `.conda`.
6. **Verify first, extract later.** SHA256 is checked before extraction.
7. **Resumable downloads.** Interrupted? Resume with `-C`.
8. **Lightweight and transparent.** Pure Python + Shell. No heavy runtime, no hidden behavior.
9. **Automatically manage dependencies.** Support for software packages with dependencies, using reference counting and automatic dependency management, with no need to handle dependencies manually.

## 🌊 Install MacWave

In the terminal, run:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sha0huaZhang/MacWave/HEAD/lib/install.sh)" && source ~/.zshrc
```

(If you are using bash instead of zsh, run ```source ~/.bashrc```)

**Requirements: Python (3.14 and above), Xcode Command Line Tools (14.0 and above).**

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
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sha0huaZhang/MacWave/HEAD/lib/uninstall.sh)"
```

## 🌊 Run Packages
To run a package, use its versioned name:
```
{package_name}@{version}
```
Or create an unversioned shortcut once with `wave link {package_name}`, then just run:
```
{package_name}
```
The unversioned link always points at the highest installed version, and is re-pointed automatically when you install or remove versions.

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

Uninstalling a version re-points the link to the next highest one, and removes the link
when no version is left. `uninstall --unlink` keeps the link as-is, and **refuses to run**
when that would leave the link pointing at the version you are removing.
## 🌊 Demo Pictures

<p align="center">
  <img src="images/demo1.png" alt="demo1" width="80%" style="max-width: 720px;">
</p>

## 🌊 Supported Packages
(Listed in alphabetical order)

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
## 🌊 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

## 🌊 Contact Us

Email：[hi@macwave.org](mailto:hi@macwave.org)


