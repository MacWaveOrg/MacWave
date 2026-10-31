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

Also in scope:

- bypassing the cross-major guard in `selfupdate.sh`
- making `wave selfupdate` fetch code from somewhere other than the configured source
- a crafted index record that makes the client delete files outside its own tree
- leaking the mirror password through an error message, a log, or a `-v` trace

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
| 4.1.x | ✅ |
| 4.0.x | ❌ |
| 3.x and older | ❌ |

## For maintainers

If a mirror password is exposed (in an issue, a log, a screenshot, a release
asset), rotate it first and investigate second — assume it is already
harvested. The rotation script is `deploy/rotate-mirror-password.sh`; it never
prints the new value.
