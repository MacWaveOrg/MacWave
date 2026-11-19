# MacWave 4.4.0-rc

Prerelease (release candidate) · build `323R1303` · branch `4.4-261119` ·
previous beta [4.4.0-beta3](RELEASE-4.4.0-beta3.md) · stable line `4.3.4`

This is the last checkpoint before 4.4.0. Nothing in it changes what MacWave does for
people who are not testing it — the three groups of changes below are the last of the
line: the installer now refuses to run on the wrong machine, downloads can be checked
against a key, and the RC line has its own version pointer so it can be published
without touching the stable one.

## Bottom line first

| Area | Before | Now |
| --- | --- | --- |
| Wrong machine | install "succeeded", every command failed afterwards | refused up front, with the reason and where to go next |
| Downloads | trusted the transport | checksums pinned to a signed manifest — **experimental, warn-only** |
| RC publishing | would have overwritten the stable pointer | own pointer in `rcdata/`, stable pointer untouched |

## 1. Experimental signing (expected to be the noisiest thing here)

4.4 is the first line that ships a key, and it is deliberately timid: **a failed check
warns and continues.** Old clients run their own old scripts — making verification
mandatory would lock them out, so the switch to enforcement waits until a signed line has
been in the field.

What is checked, and against what:

| Check | Pinned by | On mismatch |
| --- | --- | --- |
| `latest.toml` (version, branch, manifest hash) | RSA-3072 detached signature `latest.toml.sig` | warning |
| `update_commands.sh` (the script about to be executed by bash) | `update_commands_sha256` in that signed data | warning |
| Every downloaded file | `want <path> <x> <sha256>` — sha256 in the manifest | warning |

- `MACWAVE_WANT_HASHES=1` turns per-file checking on; the client sets it itself once it
  has a manifest hash. Unset = 4.4-before behaviour.
- `MACWAVE_STRICT_HASHES=1` turns warnings into failures. **That is the intended default
  later**, not now.
- Public keys live in `Keys/` and ship with the installation; the fingerprint whitelist
  lives in `net/signature.py` so key exchange shows up in a diff. Two keys, two jobs:
  OpenPGP for people (`gpg --verify SHA256SUMS.asc`), RSA for machines (LibreSSL on macOS
  cannot verify OpenPGP).

## 2. The RC line has its own pointer

```
rcdata/latest.toml                  RC only
macwavedata/latest.toml             stable only
```

- Channel is derived from what is installed: `X.Y.Z-rc` follows the RC pointer, everything
  else follows the stable one. No new state, no new flag.
- Successive builds of the same `X.Y.Z-rc` are told apart by the **build number**
  (`323R1303`), which is stored in `VERSION.json`. Comparing versions alone would report
  "already up to date" forever.
- When the RC line closes and stable is newer, the client crosses over as a **full**
  install (every file replaced). Copying stable increments onto an RC tree is how two
  branches end up in one tree — the 2026-11-15 breakage.
- Betas are still refused: they have no pointer of their own, so following the stable one
  would mix lines.

## 3. Refusing the wrong machine

- Non-macOS is refused before anything is downloaded: iOS (recognised from `hw.model`,
  `hw.machine`, `version.plist` — not from jailbreak traces, which both new and old
  jailbreaks get wrong in opposite directions), Android, ChromeOS.
- macOS older than 10.15 is refused by version, before download.
- Each refusal names what was detected and where the user should go instead, so nobody
  retries twice.

## Upgrading

Nothing to do for 4.3.x users: run the installer (or wait for `wave selfupdate` once
4.4.0 is out).

- **From a beta (4.4.0-beta1/2/3):** `wave selfupdate` refuses on purpose. Reinstall from
  the release page.
- **From this RC:** `wave selfupdate` follows the RC line; once 4.4.0 is out it crosses to
  stable as a full install.

## Verifying the download

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # everything OK
```

Signing key fingerprint: `7220E218395DE865AACC339167F14E52D0E229FB`
(`MacWave Release <macwaveorg@outlook.com>`). Machine-verification key:
`Keys/macwave-rsa.pub.pem`. See [Keys/README.md](../Keys/README.md).
