## 🌊 MacWave

A package manager for macOS software developers.

Linux? View [LinuxWave](https://github.com/LinuxWaveOrg/LinuxWave)

**English** · [简体中文](./README.zh-Hans.md)

## 🌊 Official Website

[macwave.org](https://macwave.org)

## 🌊 Supported macOS Version
macOS Sonoma 14 and above
## 🌊 Latest Version

3.2.1, Release on 2026-10-27

## 🌊 About MacWave 

MacWave is a **package manager for macOS**, built to distribute the command-line tools that macOS software developers rely on. Its sibling project, LinuxWave, covers Linux.

## 🌊 Why MacWave

1. **Small on disk.** The installer fetches individual files rather than cloning the repository, and there is no package cache to keep in sync.
2. **One command per package.** Common tools are installed by name, without hunting for release pages.
3. **Versioned by design.** Every binary lives under `package@version`, so several versions coexist and none of them shadow a system tool.
4. **Optional unversioned links.** `wave link <package>` creates a plain `package` shortcut that points at the highest installed version and re-points itself whenever versions are installed or removed.
5. **Isolated by construction.** Everything MacWave installs stays inside its own directories; it never overwrites or links against macOS system libraries, so even a major macOS upgrade leaves it intact.
6. **No stale metadata.** Package data is read from the `MacWaveOrg/infosource` repository at request time.
7. **Ten archive formats, covered by CI.** Extensionless binaries, `.zip`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar`, `.gz`, `.xz`, `.bz2`, and `.conda`.
8. **Checksum before extraction.** A package whose SHA256 is missing or does not match is refused, never installed with a warning.
9. **Resumable downloads.** An interrupted transfer continues with `-C`.
10. **Transparent implementation.** Python and Shell only. The interpreter is bundled, so no runtime has to be installed and no behaviour is hidden behind one.
11. **Dependencies handled for you.** Packages that need libraries declare them; MacWave installs, tracks and removes those libraries by reference count.

## 🌊 Install MacWave

In the terminal, run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" && source ~/.zshrc
```

(If you are using bash instead of zsh, run ```source ~/.bashrc```)

**Requirements: macOS Sonoma 14 or later, Xcode Command Line Tools (14.0 or later).**

**You do not need to install Python.** MacWave ships its own CPython under
`<install-dir>/python/` and runs from a private environment beside it, so the
`python3` on your PATH (Homebrew, pyenv, the system one) never affects it.
If that bundled copy cannot be downloaded, the installer falls back to your
system `python3` and tells you so.

> **This repository holds source, not an installation.** Running `wave` from
> inside a clone, or adding directories from the clone to `PATH`, fails by
> design — see [Do Not Run From the Clone](#do-not-run-from-the-clone).

### Unattended install

For scripts and batch use, the installer takes flags so it never waits for input.
Options go after `--`, which ends bash's own options:

```bash
# script already on disk
bash install.sh --silent --dir-option=1

# straight from the repository
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" \
  -- --silent --dir-option=2
```

`--silent` (`-S`) answers the directory menu and the agreement automatically. It
needs passwordless sudo, or root, when the chosen directory requires privilege.
`--dir-option=N` picks menu entry `N` (1-4 on Intel, 1-3 on Apple silicon); for the
custom entry, append the path after `=`, as in `--dir-option=4=/opt/my-macwave`, or just
pass the path on its own, as in `--dir-option=~/my-macwave`. Run `install.sh --help` for
the list.

> **Mind where the options go.** Writing
> `/bin/bash -c "$(curl ...)" --silent` makes `--silent` the script name (`$0`), so
> it is silently dropped; the installer warns when it detects this. The working
> form puts the options after `--`.

`uninstall.sh` is scriptable in the same way: `--force` skips the confirmation,
which otherwise needs a terminal (so use `--force` in CI):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/uninstall.sh)" -- --force
```

## 🌊 Download Directory
Installed binaries are stored in (options):    
```
1. ~/.local/macwave
2. /opt/macwave
3. /usr/local/macwave (Only Intel Mac)
4. Custom
```
Config file is stored in (a system-level install always takes priority):
```
1. /opt/macwave_config          system-level install (needs sudo)
2. ~/.config/macwave_config     user-level install (no sudo)
```
## 🌊 Using a Mirror (4.0 and later)
Every address MacWave contacts is configurable, so switching mirrors is a set of environment variables rather than a command — there is deliberately no `wave mirror`, the same way Homebrew has no `brew mirror`.

**This matters most in mainland China**, where `github.com` is often unreachable rather than merely slow. Measured from one such connection: two out of three attempts failed to open a TCP connection within 20 seconds, while domestic mirrors answered in 37–78 ms.

### Switch to a mirror
```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/macwave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/macwave/deps
```
Put those two lines in `~/.zshrc` so they apply to every shell. Everything else keeps using the official addresses, so a mirror only needs to carry what it mirrors.

### The full set
| Variable | What it fetches | Default |
| --- | --- | --- |
| `MACWAVE_BOTTLE_DOMAIN` | prebuilt packages | GitHub Releases |
| `MACWAVE_DEPS_DOMAIN` | dependency libraries | GitHub Releases |
| `MACWAVE_API_DOMAIN` | package index | `infosource` on raw.githubusercontent |
| `MACWAVE_SELFUPDATE_DOMAIN` | self-update data | `Selfupdate` on raw.githubusercontent |
| `MACWAVE_PYTHON_DOMAIN` | the bundled interpreter | `Selfupdate` on raw.githubusercontent |
| `MACWAVE_CORE_DOMAIN` | MacWave's own files | `MacWave` on raw.githubusercontent |
| `MACWAVE_PKG_SOURCECODE_DOMAIN` | package source (reserved) | — |

A variable's value is the part **before** the package name: the client appends `/<package>/<package>@<version>.<arch><ext>` to the bottle and deps prefixes, and `/pkg/…`, `/deps/…`, `/versiondata/…` to the others. Trailing slashes are stripped, so either form works.

### Check it before trusting it
```bash
curl -o /dev/null -w '%{speed_download} B/s\n' \
  "$MACWAVE_BOTTLE_DOMAIN/jq/jq%401.8.2.arm64"
```
If that downloads quickly and `wave install jq` succeeds, the mirror is good. Every artifact is verified against the SHA-256 recorded in the index, so a mirror that serves altered bytes fails loudly instead of installing something unexpected.

### Corporate networks
A proxy is a different problem from a slow mirror: there the connection is blocked, not distant. Pass `--proxy` and it applies to **every** request the command makes, not just the payload download:
```bash
wave install jq --proxy http://proxy.corp:3128
```
Setting `HTTPS_PROXY` in the environment has the same effect and covers commands you forget to pass the flag to.

### Running your own mirror
A mirror is a static file tree, so `nginx`, an object bucket or any file server will do — no special software and no database. Setup steps, including the two `Cache-Control` lines worth adding, are in [docs/MIRROR-SETUP.md](docs/MIRROR-SETUP.md).

## 🌊 Uninstall MacWave

To completely remove MacWave from your system, run the following command in your terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/uninstall.sh)"
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

## 🌊 Symlink Management

Since MacWave 2.4, once a versionless link exists, MacWave keeps it pointing at the right version on its own:

1. If the highest version is uninstalled, the versionless link moves to the highest version that remains, and the uninstalled version's own link goes with it.
2. An install re-points the versionless link at the version it just installed; add `--unlink` to that install to skip this.
3. If a package has no versions left at all, the versionless link is removed.
4. A versioned name is always callable, whether or not a versionless link exists.

A manual `wave unlink {package_name}` is remembered: a later uninstall will not re-create the link for that package.

## 🌊 Command Reference

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
wave upgrade <pkgname>             Take a package to the latest version
    --remove-old-version           Remove the versions older than the one just installed
    --remove-old-versions          Same as --remove-old-version
    --rov                          Same as --remove-old-version
    -X                             Same as --remove-old-version
    --unlink                       Leave the unversioned link alone (install / uninstall)
    --all, -a                      Apply to every installed package (link / unlink / linkquery)

Self Update:
wave selfupdate                    Update MacWave itself
wave selfupdate --max-time=2min    Same, but give each request two minutes

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
tree          by Steve Baker, Thomas Moore, et al.
trollrestore  by JJTech (@JJTech0130)
wget          by GNU Project
yq            by Mike Farah
zoxide        by Ajeet D'Souza
```
## 🌊 For Developers

MacWave is written in plain Python and Shell. There is no build step: the files
in this repository are the ones that run. Internals are documented in
[`docs/TECHNICAL-GUIDE.md`](./docs/TECHNICAL-GUIDE.md) and
[`docs/CODE-MAP.md`](./docs/CODE-MAP.md).

Clone the source to read or change it:

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/MacWaveOrg/MacWave.git macwave
cd macwave
```

Read the section below before running anything from that directory.

### Do Not Run From the Clone

This repository is source, not an installation. Running `wave` from inside the
clone, or adding the clone's directories to `PATH`, fails on purpose: MacWave
needs the configuration file that `install.sh` writes, and that file records the
installation directory and the layout of everything beside it.

A full clone reports:

```
🌊 Error: MacWave is a git clone!
```

A shallow clone reports:

```
🌊 Error: MacWave is a shallow clone!
```

Both are followed by the same advice — install with `install.sh`, choose a
directory, and use the `wave` that installs. To exercise code you are changing,
install a throwaway copy under a temporary root, or run the scripts in
`scripts/`, which work on whatever installation is already present.

### Repositories

| Repository | Holds |
| --- | --- |
| `MacWaveOrg/MacWave` | The program itself |
| `MacWaveOrg/infosource` | The package index, one directory per package and architecture |
| `MacWaveOrg/configdata` | The published version, the updater's file list, and the bundled interpreter |

### Source layout

| Directory | Responsibility |
| --- | --- |
| `lib/` | Entry point, help, configuration paths, self-update |
| `pkg/` | Install, upgrade, uninstall, links, version parsing |
| `surfboard/` | Dependency resolution, extraction, Mach-O relocation |
| `scripts/` | Tests and data audits |

Each command is a module with a single handler, dispatched from `lib/wave.py`.
All Mach-O rewriting is confined to `surfboard/`.

### Adding a package

Records live in `infosource` under `pkg/pkginfo_<arch>/<name>/`, in two forms:

- `_<name>@common` — metadata shared by every version: `des`, `hom`, `lic`,
  `aut`, and `bin_name`, the name the binary is installed as.
- `_<name>@<version>` — one file per version, carrying `url` and `sha256`, plus
  `deps` when the package needs libraries MacWave must install as well.

`sha256` is mandatory. A record without it is rejected rather than installed
with a warning. Dependencies are written as `name@version` and are reference
counted, so removing one package does not remove a library another still uses.

### Running the tests

Each script runs end to end and reports `PASS` or `FAIL`:

```bash
bash scripts/configpath_test.sh    # configuration directory resolution
bash scripts/format_test.sh        # every supported archive format
bash scripts/deps_test.sh          # dependency install and cascade removal
bash scripts/link_test.sh          # versionless links
bash scripts/upgrade_test.sh       # wave upgrade, offline
bash scripts/selfupdate_test.sh    # self-update; ends by updating for real
python3 scripts/random_test.py     # randomised end-to-end regression, needs network
python3 scripts/audit_deps.py data # audit the index against the installed libraries
```

`random_test.py --dry-run` selects packages and prints the plan without touching
the network.

### Contributing

Every branch is merged through a pull request with at least one approval; force
pushes and branch deletion are blocked. Run the scripts above before opening
one, and state which you ran. A bug report is most useful with the output of
`wave --version`, `sw_vers`, and `uname -m`.

## 🌊 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

## 🌊 Contact Us

Email：[hi@macwave.org](mailto:hi@macwave.org)


