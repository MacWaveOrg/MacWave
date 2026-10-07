# 🌊 MacWave 
A package manager for macOS/Linux software developers.
# 🌊 Official Website

[macwave.org](https://macwave.org)

# 🌊 What is MacWave? 

MacWave is a **package manager** that runs on **macOS/Linux**, specifically designed to host **iOS/iPadOS jailbreak-related software packages** for jailbreak developers and researchers. These packages are **typically not included in mainstream package managers**. Previously, jailbreak projects required downloading from various scattered sources. Now, you only need a single terminal command.
# 🌊 Install MacWave    
In the terminal, run the following command:        
```
curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/main/install.sh | bash
```
⚠️ **Important**: After installation, **restart your terminal** or **run the following command** to apply PATH changes immediately:
```
source ~/.zshrc
```

(If you are using bash instead of zsh, run ```source ~/.bashrc```)
# 🌊 Download Directory 
Installed binaries are stored in:    
```
~/.local/macwave/bin
```

# 🌊 Command Reference

```
Usage:
  wave <command> [package] [flags]

Commands:
  install     Install a package
  uninstall   Uninstall a package
  list        List installed packages
  search      Search for a package in the index
  info        Display detailed information about a package
  update      Update the package index
  upgrade     Upgrade an installed package to the latest version
  doctor      Check your system for missing dependencies

Flags:
  -h, --help              Show help for any command
  -V, --version           Print version information
  -v, --verbose           Enable verbose output (show detailed logs)

Global Flags (can be used with any command):
  -B, --beta-version      Install the latest beta version (if available)
  -D, --dir string        Specify an output directory (e.g., ~/Desktop) for downloads
  -C, --continue          Resume interrupted downloads (like curl -C -)
      --proxy string      Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)
      --skip-ssl          Skip SSL certificate verification (insecure)
      --limit-rate string Limit download speed (e.g., 200K, 1M, 5M)
      --dry-run           Simulate the installation without making changes
      --json              Output in JSON format (for scripting)
      --ver string        Install a specific version of the package

Examples:
  wave install machox
  wave install ldid --ver 2.1.5
  wave install machox -B
  wave search choma -f
  wave info trollresigner
```

# 🌊 Supported Packages
(Listed in alphabetical order)

```
machox          by Sha0huaZhang
ldid            by Jay Freeman (saurik) / Procursus Team
test_001        by Sha0huaZhang
```
# 🌊 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

# 🌊 Contact Us

Email：[hi@macwave.org](mailto:hi@macwave.org)


