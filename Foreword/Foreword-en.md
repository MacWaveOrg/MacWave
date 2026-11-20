# MacWave / LinuxWave Handbook

### Welcome to Wave World!

Welcome to MacWave / LinuxWave! Before you start, we suggest reading the manual below.

### Basic commands

You are probably already familiar with the basic `wave` commands. To get you up to speed
faster, here are the flag-and-command combinations you are most likely to use:

| Combination | What it does | When to use it | Notes |
| --- | --- | --- | --- |
| `wave -h` | Print help | You are not sure how a command works | `wave -h --zh` prints the Chinese help |
| `wave manual --color` | Print the full manual in colour | Same, but more detail | `wave manual --zh` prints the Chinese manual |
| `wave -V` | Print the MacWave version | Checking which version you are on | |
| `wave install <pkg_name>` | Install a package | Installing software | `wave install <pkg_name>@<pkg_version>` installs one specific version |
| `wave upgrade -X` | Upgrade a package | Everyday upgrades | Aimed at regular users. `-X, --remove-old-versions` deletes the old copies — make sure you do not need them before using it |
| `wave latest <pkg_name>` | Check whether a newer version exists than the one you have | Wondering if a package can be upgraded | `wave latest -a` shows the status of every package |
| `wave selfupdate` | Update MacWave itself | When you want a newer MacWave | |
| `wave list` | List the installed packages and their versions | Seeing what you have installed | `wave list -a` does the same |
| `wave info <pkg_name>` | Show which version of a package you have installed (prints `None` when it is not installed) | Not knowing whether — or which version — you installed | |
| `wave search <pkg_name>` | Search for a package (matches part of the name) | Checking whether `wave` has that package | |
| `wave uninstall <pkg_name>` | Remove a package | Uninstalling software | `wave uninstall <pkg_name>@<pkg_version>` removes one specific version |

For more, run `wave -h`, `wave -h --zh` (Chinese), `wave manual`, or `wave manual --zh` (Chinese).

Note: when you actually run these commands, replace the `<placeholder>` parts with real values.

### Install locations

**The directories below are only our recommendations — you can pick any directory, or a
custom one:**

macOS (single user): `~/.local/macwave`
macOS (shared install): `/opt/macwave`
Linux: `/home/linuxwave/.linuxwave`

Note: on Intel Macs we do not recommend `/usr/local` — it may collide with Homebrew's
default prefix on Intel Macs.

**Configuration files live in (the system-wide location always wins):**

**MacWave:**

1. `/opt/macwave_config` — shared install (needs sudo)
2. `~/.config/macwave_config` — single-user install (no sudo)

**LinuxWave:**

1. `/etc/linuxwave_config` — shared install (needs sudo)
2. `~/.config/linuxwave_config` — single-user install (no sudo)

**Warning: do not edit the configuration files casually — that can make `wave` behave
strangely or in ways you do not expect.**

### Mirrors

If you are in mainland China you most likely need a mirror. For a full mirror, add the
following environment variables to `~/.zshrc` (or `~/.bashrc` if you use bash). A good
mirror will usually tell you which commands to run:

| Variable | What it points at | Default |
| --- | --- | --- |
| `MACWAVE_BOTTLE_DOMAIN` | Prebuilt packages | GitHub Releases |
| `MACWAVE_DEPS_DOMAIN` | Dependency libraries | GitHub Releases |
| `MACWAVE_API_DOMAIN` | Package index | `infosource` on raw.githubusercontent |
| `MACWAVE_SELFUPDATE_DOMAIN` | Self-update data | `Selfupdate` on raw.githubusercontent |
| `MACWAVE_PYTHON_DOMAIN` | The bundled interpreter | `Python` on raw.githubusercontent |
| `MACWAVE_CORE_DOMAIN` | MacWave's own files | `MacWave` on raw.githubusercontent |
| `MACWAVE_PIP_INDEX` | The `pip` index (affects only the three Python dependencies) | `https://pypi.org/simple` |

**The ref segment after `infosource` is not optional:** it is `/HEAD` for MacWave and
`/main` for LinuxWave (the mirror lays files out as `<org>/<repo>/<ref>/…`). Leave it out
and `wave search` / `wave latest` get nothing but 404s when they read the lists.

Run the following to add them:

```zsh
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps
export MACWAVE_API_DOMAIN=https://mirror.example.cn/MacWave/infosource/HEAD
export MACWAVE_SELFUPDATE_DOMAIN=https://mirror.example.cn/MacWave/selfupdate
export MACWAVE_PYTHON_DOMAIN=https://mirror.example.cn/MacWave/python
export MACWAVE_CORE_DOMAIN=https://mirror.example.cn/MacWave/core
export MACWAVE_PIP_INDEX=https://pypi.mirror.example.cn/simple
```

`export` only affects the current terminal; it is gone once you close it. Append the block
to `~/.zshrc` and every terminal inherits it from then on:

```zsh
cat >> ~/.zshrc <<'MWMIRROR'

# MacWave mirror
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps
export MACWAVE_API_DOMAIN=https://mirror.example.cn/MacWave/infosource/HEAD
export MACWAVE_SELFUPDATE_DOMAIN=https://mirror.example.cn/MacWave/selfupdate
export MACWAVE_PYTHON_DOMAIN=https://mirror.example.cn/MacWave/python
export MACWAVE_CORE_DOMAIN=https://mirror.example.cn/MacWave/core
export MACWAVE_PIP_INDEX=https://pypi.mirror.example.cn/simple
MWMIRROR
source ~/.zshrc
```

`MACWAVE_PIP_INDEX` only affects the three Python dependencies `pip` installs
(`requests`, `toml`, `colorama`), so it can point at any PyPI mirror (popular ones in
China include USTC and TUNA).

You only need to run this once. New terminals pick it up by themselves; the trailing
`source` merely makes the current one take effect immediately. Delete any lines you do
not need — fewer lines still work, and an unset variable falls back to the official
address.

If you later want to drop the mirror, delete or comment those lines out.

LinuxWave works the same way: replace `MACWAVE` above with `LINUXWAVE`. Note that Linux
uses `bash` by default.

### Contact

If something goes wrong, open an issue on GitHub or write to `macwaveorg@outlook.com`.

**Have a good surf, waver!**
