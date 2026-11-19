# MacWave 4.4.0

Released: 2026-11-19 · build `323D1315` · branch `4.4` ·
previous stable 4.3.4 ·
detail per stage: [beta1](RELEASE-4.4.0-beta1.md) · [beta2](RELEASE-4.4.0-beta2.md) ·
[beta3](RELEASE-4.4.0-beta3.md) · [rc](RELEASE-4.4.0-rc.md)

> This file supersedes the 2026-11-09 draft that carried build `313B1740`; that plan became
> 4.4.0-beta1 and the line has moved on since.

4.4 is a "make the failure happen earlier" release. Almost everything in it moves a problem
from *after* the user has committed — installed, configured, half-running — to *before*
anything is downloaded, and says what to do instead. Two structural changes ride along: the
installer now knows what machine it is on, and the download path can be checked against a
key.

## Bottom line first

| Area | Before 4.4 | Now |
| --- | --- | --- |
| Wrong machine (iOS, Android, ChromeOS, old macOS) | installed, then every command failed | refused before download, with the reason and an alternative |
| Elevation | "is the target outside `$HOME`" | write permission, confirmed by a real write probe |
| Sealed system volume / SIP | not considered | checked before download; unsealed systems continue with a warning |
| Scripted install | spinner, ANSI, `--help` fetched the network | `--raw`, `--print-usage`, `--help` offline |
| Version comparison | three implementations | one (`lib/versioncompare.py`), channels and build numbers included |
| Download integrity | transport only | checksums pinned to a signed manifest (**experimental, warn-only**) |

## 1. Which machine are we on

`lib/install.sh` decides this first, before the version request, before `sudo`, before
anything is written.

- **macOS older than 10.15** — refused by version. The bundled interpreter and the command
  set do not exist there.
- **iOS** — refused. iOS also reports `Darwin`, so the kernel alone cannot tell them apart;
  the decision uses `hw.model`, `hw.machine` and `version.plist`, i.e. information the
  kernel supplies. Jailbreak traces (`/var/jb`, `/private/var/mobile`) are only a fallback:
  new-style rootless jailbreaks hide deliberately, old-style rooted ones never create
  `/var/jb`, so trusting them gets both directions wrong. Creating `/var/jb` on a Mac does
  not fool it.
- **Android and ChromeOS** — refused. Both can run `bash` and look installable; Android has
  no glibc, ChromeOS is a container. Better to say so once than to fail at the first
  command.
- Each refusal prints what was detected and where to go instead.

**Elevation and the system volume**

- Permission *bits* are only the first check: an empty probe file is created in the nearest
  existing directory and immediately removed. `Permission denied` means `sudo`; anything
  else (ENOSPC, read-only mount) is a hard error, because dressing an environment problem up
  as a password prompt wastes the user's time.
- Targets inside SIP's range are checked for a sealed system volume first — that refusal is
  the kernel's and `sudo` does not help. Unsealed systems (OCLP and friends) warn and
  continue. Unknown state proceeds: otherwise every container and every 10.x box is locked
  out.
- `--skip-probe` keeps the old bits-only check; `--dry-run` never writes, so it uses bits.

## 2. The installer, as something a script can drive

- `--raw`: no ASCII art, no colour, no spinner, no cursor movement; downloads print one
  `####` line per 10% (unknown length → per MiB). Same semantics as `wave install --raw`.
- `--print-usage` prints usage and continues; `--help` prints usage and stops — and neither
  touches the network any more. Arguments are parsed exactly once, before the version
  request.
- **Agreement** is asked once, normalised (`y`/`yes`/empty → yes, `n`/`no` → no, anything
  else asks again, three times, then counts as no), and *recorded* — 4.3 promised to write
  `AGREEMENT.json` and did not. Upgrades across a major version no longer ask: the
  "reinstall from the release page" guard speaks first.
- **Rollback never deletes an existing installation.** The tree is only removed if this run
  created it (`TREE_PREEXISTED`); otherwise the message is "your existing installation is
  untouched, re-run the installer to continue".
- An incomplete tree is repaired rather than trusted: `VERSION.json` plus `lib/wave.py`
  existing was not proof that the last update finished.
- Installer exit codes have meaning now (`0` done, `1` refused/failed, `2` usage, `3`
  needs privileges, `4` platform), so CI and wrappers can branch on them.

**One more thing, deliberately vague:** the installer opens and closes with a little
terminal decoration, and there are one or two other small things in there for people who
read the script end to end. They are not listed here on purpose.

## 3. One CLI, one parser, one command table

- Common flags (`--verbose`, `--resume`, `--skip-ssl`, `--proxy`, `--max-time`,
  `--limit-rate`, …) go through a single `cli/common.parse()`. A malformed `--proxy` or
  `--max-time` now fails with the same wording and the same exit code in
  `install`/`selfupdate`/`latest`/`info`/`mirror` — they used to differ per command.
- Subcommands and their help live in `cli/commands.py`; `wave -h`, `-h --zh` and the 15
  per-command help pages are generated from it, and `scripts/commands_test.sh` keeps the
  metadata honest.
- `--unlink` is now `--no-link` (the old name still works and is labelled as the old name).
- `wave selfupdate --dry-run`: prints the plan — current → target, branch, whether the
  agreement will be asked, the three timeouts — before the agreement question, then exits.
  Nothing is downloaded, nothing is written.
- `wave shellenv` and `wave manual` are documented in both READMEs and on the website.

## 4. Network failures that say what to do

- TLS failures are classified into five kinds — expired (`notAfter` printed), self-signed or
  private CA, incomplete chain, hostname mismatch, plain network — each with its own next
  step. Hostname mismatch says *do not* bypass, and why.
- `MACWAVE_CACERT` points at an extra root certificate (PEM); it is validated up front
  rather than silently ignored, and applies to `requests`, `urllib` and `curl` alike.
  Precedence: `--skip-ssl` > `MACWAVE_CACERT` > system store.
- Every `MACWAVE_*` variable that is actually read is listed in `config/envvar.py`, and
  `scripts/check_domain_defaults.py` fails if a documented name, a package-index name, or an
  unregistered name appears. Six variables that were written and never read were removed.

## 5. Versions, channels, builds

- `lib/versioncompare.py` is the only version comparison in the project (three used to
  exist, and a beta counted as *newer* than its release).
- Channel follows what is installed: `X.Y.Z-rc` reads `rcdata/latest.toml`, everything else
  reads `macwavedata/latest.toml`. Betas are still refused — they have no pointer of their
  own, and following the stable one mixes two lines in one tree.
- Build numbers are part of the decision now, not just decoration: same version, newer build
  means a newer build. Format is `<days since 2026-01-01><letter><HHMM>`, the letter
  encoding channel and weekday: `A`-`G` stable (Mon-Sun), `H` special dates, `I`-`O` beta
  (`P` special), `R` always for RC.
- When the RC line closes, the client crosses to stable as a **full** install.

## 6. Experimental signing

4.4 is the first line that ships a key: an OpenPGP key in `Keys/` with its fingerprint
pinned in `net/signature.py`, plus an RSA key for machines, because LibreSSL on macOS
cannot verify OpenPGP. `latest.toml` gets a detached signature, the update script is pinned
by a hash inside that signed data, and every downloaded file carries its own hash.

**A failed check warns and continues.** Enforcement (`MACWAVE_STRICT_HASHES=1`) is the
intended default later, once a signed line has been in the field: old clients run their own
old scripts, so turning it on now would lock them out. The full table, the switches and the
key layout are in [the RC notes](RELEASE-4.4.0-rc.md) and
[Keys/README.md](../Keys/README.md).

## 7. Smaller things worth knowing

- `wave uninstall` exit codes have meanings, and a failure part-way no longer aborts the
  rest of the removal; the `sed` fallback removes the `# MacWave` marker line too.
- Dependencies without a checksum are refused instead of installed (index data defect, not
  a user problem).
- Documentation: `AGENTS.md` gained the CI-ONLY boundary rules, `docs/CODE-MAP.md` moved
  `config/` to where it actually lives, and the manual documents `MACWAVE_CACERT`.

## Upgrading

| From | How |
| --- | --- |
| 4.3.x | installer, or `wave selfupdate` once this release is the stable pointer |
| 4.4.0-beta1/2/3 | `wave selfupdate` refuses on purpose — reinstall from the release page |
| 4.4.0-rc | `wave selfupdate` crosses to this release as a full install |

## Verifying the download

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # everything OK
```

Signing key fingerprint: `7220E218395DE865AACC339167F14E52D0E229FB`
(`MacWave Release <macwaveorg@outlook.com>`).
