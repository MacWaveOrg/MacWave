# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private reporting: go to
[Security → Advisories → Report a vulnerability](https://github.com/MacWaveOrg/MacWave/security/advisories/new).
That channel is visible only to the maintainers.

If you cannot use it, email **hi@macwave.org** with `SECURITY` in the subject.

What helps us most:

- the version (`wave -V`) and macOS version
- the command you ran, with **credentials removed** — that means replacing
  `https://user:password@mirror/...` with `https://user:***@mirror/...`
- what you expected versus what happened

We aim to acknowledge within three working days. We will tell you whether we
agree it is a security issue, and keep you informed until it is fixed. Please
give us a reasonable window before publishing.

## What counts as a security issue here

MacWave downloads executable software and then runs it. Its security model
rests on a small number of guarantees; a break in any of these is a
vulnerability:

| Guarantee | Where it lives |
|---|---|
| **The download matches what the index says.** Every payload is verified against the `sha256` in `infosource` before it is unpacked. A record without a checksum is refused, not trusted. | `pkg/pkginstaller.py`, `lib/domains.py` |
| **Only the mirror is contacted.** The `url` field in the index is not followed during a normal install — payloads come from MacWave's own store, which the mirror serves. `--install-from-source` is the deliberate exception. | `lib/domains.py` (`resolve_payload`) |
| **Package-controlled names cannot escape their directory.** Package names, versions and `bin_name` come from remote data but are used as path components, so they pass a whitelist and a containment check. | `lib/configpaths.py` |
| **Credentials do not appear in output.** Mirror URLs carry a user and password; anything printed or logged is redacted first. | `lib/domains.py` (`redact_url`) |
| **Extraction stays inside the target directory.** `.conda` payloads go through Python's `filter='tar'`, which is explicit; plain `.zip` / `.tar.*` rely on `unzip` and `tar` themselves refusing `../` entries. | `pkg/pkgunzip.sh` |
| **A payload's links cannot leave the install root.** After extraction, every symbolic link in the tree is resolved and rejected if it lands outside `base_dir`, except the exempt system locations listed below. A refusal removes the extracted tree, so nothing half-installed is left behind. | `lib/configpaths.py` (`assert_links_inside`), `surfboard/depsmanager.sh` |

### Symbolic links: the rule and its one exception

**If a package contains symbolic links, every link must be checked for whether it
escapes `base_dir`. A link that resolves outside the install root is a defect and
must be refused.**

The threat is two-sided, and both halves matter:

| What a malicious package could do with an escaping link | Why it is a vulnerability |
| --- | --- |
| Point a link at a private file (`~/.ssh/id_rsa`, `~/Library/Messages/…`) and ship a binary that reads through it | Exfiltrates data the user never granted access to |
| Point a link at a path MacWave later **writes** through — the `install_name_tool` rewrite in `surfboard/transfer.sh`, the `.part` → `mv` rename, an uninstall `rm -rf` | Writes or deletes files outside the install tree, as the user |

**Status: enforced from 4.2 onward.** The extraction tools do not provide this, so
it is checked afterwards, on the extracted tree, before anything is installed:

| Path | Escaping symlink reaches disk | Then checked |
| --- | --- | --- |
| `.zip` / `.tar.*` via `unzip` / `tar` | yes | ✓ refused |
| `.conda` via `tarfile.extractall(filter='tar')` | yes | ✓ refused |

`filter='data'` would refuse absolute link targets by itself, but it also refuses
what conda packages legitimately need, so the check cannot be delegated to it.
The enforcement lives in `lib/configpaths.py` (`escaping_links` /
`assert_links_inside`) and is called from `surfboard/depsmanager.sh` right after
extraction, for both the `tree` and `binary` install shapes. On refusal the
extraction directory is removed, so a rejected payload does not stay on disk.

This is separate from the "`../` entries in an archive" check above. An archive can
contain a perfectly legal member whose *name* stays inside the destination while its
*link target* points anywhere:

```
lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
```

`../` filtering does not see that. Neither does `tar`'s.

**System library locations are exempt.** A link landing under the system locations
below is not refused:

```
/bin   /sbin   /usr/bin   /usr/sbin   /usr/lib   /usr/libexec
/System   /Library/Apple      (and subdirectories)
```

Two reasons, and both are needed:

1. **SIP protects them.** System Integrity Protection (SIP) refuses writes to these
   paths even from root, so the "write through the link" half of the threat does not
   apply. A link into `/usr/bin` is also how some upstream payloads legitimately
   reference the system tools they expect.
2. **They hold no private files.** The read half does not apply either: these trees
   contain only operating-system binaries and libraries, nothing user-specific.

Everything else stays inside the rule. `/Users`, `/Applications`, `/Library` outside
`Apple/`, `/private`, `/opt`, `/etc`, `/var` are **not** exempt — those hold user data,
and SIP does not protect most of them.

Also in scope:

- bypassing the cross-major guard in `selfupdate.sh`
- making `wave selfupdate` fetch code from somewhere other than the configured source
- a crafted index record that makes the client delete files outside its own tree
- leaking the mirror password through an error message, a log, or a `-v` trace
- a payload whose symbolic link resolves outside `base_dir`, other than into the
  exempt system locations listed above
- a system-wide install whose tree is writable by a normal user —
  `install.sh` **and** `selfupdate` must both leave it at `root:<admin group>` 775
  (directory setgid), and `uninstall.sh` must never `rm -rf` a directory that is not a
  MacWave install

### Ownership of a system-wide tree

A system-wide install puts executables on the system `PATH`, so the tree must not be
writable by a normal user: whoever can replace `links/<name>` can usually get it executed
by another account, or by root. The rule is `root:<admin group>` with mode **775** and
setgid on directories:

| Who | Permission |
| --- | --- |
| Everyone | read + execute → can run the installed packages |
| Administrators (`admin` group) | write → install / upgrade / remove without `sudo` |
| Everyone else | no write |

Writing is limited to the same group that can already `sudo`, so the group bit does not
grant anyone new power; it removes the need to re-authenticate for every package. The
`o-w` bit is what keeps other local accounts out — dropping it would be the
local-privilege-escalation defect this rule exists to prevent.

It holds on all entry points:

| Entry point | Where |
| --- | --- |
| Fresh install | `install.sh` (`hand_over_system_install`) |
| `wave selfupdate` | `selfupdate.sh` (`hand_over_system_install`, after all writes) |
| `wave uninstall` | `uninstall.sh` (`skip_reason`: refuses system directories, `$HOME`, and anything without `lib/wave.py`) |

Regression: `scripts/dir_guard_test.sh`.

## Not security issues

- **A package is malicious.** MacWave verifies that a payload matches the index,
  not that the software is benign. Report that to the upstream project.
- **The `test_*` packages in `infosource` have wrong checksums.** They are
  negative test fixtures and are supposed to be broken. `test_no_sha256` has no
  checksum; `test_wrong_sha256` has a wrong one.
- **You ran `--install-from-source` and got an upstream file.** That flag
  deliberately bypasses the mirror.
- **`--skip-ssl` accepted a bad certificate.** The flag says it is insecure, in
  its own help text.

## Supported versions

Fixes land on the current release line and are published through
`wave selfupdate`. Older major versions do not receive security backports —
crossing a major version requires reinstalling from
[macwave.org](https://macwave.org), by design.

| Version | Supported |
| --- | --- |
| 4.3.x | ✅ |
| 4.2.x | ❌ |
| 4.1.x | ❌ |
| 4.0.x | ❌ |
| 3.x and older | ❌ |

## For maintainers

If a mirror password is exposed (in an issue, a log, a screenshot, a release
asset), rotate it first and investigate second — assume it is already
harvested. The rotation script is `deploy/rotate-mirror-password.sh`; it never
prints the new value.
