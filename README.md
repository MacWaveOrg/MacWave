# 🌊 MacWave 
A package manager for macOS/Linux jailbreak developers.
# 🌊 Official Website

[www.macwave.org](https://macwave.org)

# 🌊 What is MacWave? 

MacWave is a **package manager** that runs on **macOS/Linux**, specifically designed to host **iOS/iPadOS jailbreak-related software packages** for jailbreak developers and researchers. These packages are **typically not included in mainstream package managers**. Previously, jailbreak projects required downloading from various scattered sources. Now, you only need a single terminal command.
# 🌊 Install MacWave    
In the terminal, run the following command:        
```
/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/latest/install.sh)"
```
⚠️ **Important**: After installation, **restart your terminal** or **run the following command** to apply PATH changes immediately:
```
source ~/.zshrc
```

(If you are using bash instead of zsh, run ```source ~/.bashrc```)

# Uninstall MacWave

In the terminal, run the following command:     

```
/bin/bash -c "INSTALL_DIR=\"\$HOME/.local/macwave\"; echo -e \"\033[31mYou are deleting MacWave, are you sure? [Y/n]\033[0m\"; read -n 1 -r; echo; if [[ ! \$REPLY =~ ^[Yy]\$ ]]; then echo \"🌊 Uninstall cancelled.\"; exit 0; fi; if [ -d \"\$INSTALL_DIR\" ]; then echo \"🌊 Removing \$INSTALL_DIR...\"; rm -rf \"\$INSTALL_DIR\"; else echo \"🌊 MacWave installation directory not found. Skipping.\"; fi; for RC_FILE in \"\$HOME/.zshrc\" \"\$HOME/.bashrc\"; do if [ -f \"\$RC_FILE\" ]; then sed -i '' '/# MacWave/d' \"\$RC_FILE\" 2>/dev/null || true; sed -i '' '/export PATH=\".*macwave\\/bin/d' \"\$RC_FILE\" 2>/dev/null || true; echo \"🌊 Removed MacWave PATH entries from \$RC_FILE\"; fi; done; echo \"\"; echo \"🌊 MacWave has been uninstalled.\"; echo \"🌊 Please restart your terminal to apply changes.\""
```

⚠️ **Important:** This command **permanently removes MacWave and its configuration files**. Make sure you have **copied the entire command correctly** before pressing Enter.

# 🌊 Download Directory 
Installed binaries are stored in:    
```
~/.local/macwave/bin
```

# 🌊 Command Reference

```
usage: wave <command> [package] [flags]

MacWave 1.0.0 🌊
A package manager for macOS/Linux jailbreak developers.

positional arguments:
  {install,uninstall,list,search,info,update,upgrade,doctor}
                        Commands
    install             Install a package
    uninstall           Uninstall a package
    list                List installed packages
    search              Search for a package in the index
    info                Display detailed information about a package
    update              Update the package index
    upgrade             Upgrade an installed package to the latest version
    doctor              Check your system for missing dependencies

options:
  -h, --help            show this help message and exit
  -V, --version         show program's version number and exit
  -v, --verbose         Enable verbose output (show detailed debug logs, including exception stack traces)  
  -B, --beta-version    Install the latest beta version (if available)
  --proxy string        Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)
  --skip-ssl            Skip SSL certificate verification (insecure, with interactive confirmation)   
  --limit-rate string   Limit download speed (e.g., 200K, 1M, 5M)
  --dry-run             Simulate the installation without making changes
  --json                Output in JSON format (for scripting)

Global Flags (can be used with any command):  
  -B, --beta-version    Install the latest beta version (if available)
  -D, --dir string      Specify an output directory (e.g., ~/Desktop) for downloads
  -C, --continue        Resume interrupted downloads (like curl -C -, but just -C, DON'T use -C -!)
  --proxy string        Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)
  --skip-ssl            Skip SSL certificate verification (insecure, with interactive confirmation)
  --limit-rate string   Limit download speed (e.g., 200K, 1M, 5M)
  --dry-run             Simulate the installation without making changes
  --json                Output in JSON format (for scripting)
  --ver string          Install a specific version of the package  

For more details, visit: https://macwave.org
```

# 🌊 Supported Packages
(Listed in alphabetical order)

```
ldid            by Jay Freeman (saurik) / Procursus Team
machox          by Sha0huaZhang
palera1n        by palera1n Team (Nick Chan, Ploosh, Samara, Mineek, staturnz, kokshidoll) (versions 2.0–2.4)
test_001        by Sha0huaZhang
trollrestore    by JJTech0130
```
# 🌊 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.
# 🌊 Special Thanks to
**Haxx** (Daniel Stenberg, Linus, Bjorn, Kjell, et al.) for **cURL**
# 🌊 Credits
```
cURL            by Haxx (Daniel Stenberg, Linus, Bjorn, Kjell, et al.)
ldid            by Jay Freeman (saurik) / Procursus Team
MachOX          by Sha0huaZhang (WAVRS Dev Team)
palera1n        by palera1n Team (Nick Chan, Ploosh, Samara, Mineek, staturnz, kokshidoll)
TrollRestore    by JJTech0130
```
# 🌊 Contact Us

Email：[hi@macwave.org](mailto:hi@macwave.org)


