# Contributing to MacWave

Thanks for helping. This file is short on purpose — the details that matter
live in the checklists, and repeating them here would create a second copy that
drifts.

## Before you write code

Read these, depending on what you are doing:

| If you are… | Read |
| --- | --- |
| adding or updating a package | [docs/ADD-PACKAGE-CHECKLIST.md](../docs/ADD-PACKAGE-CHECKLIST.md) |
| preparing a release | [docs/RELEASE-CHECKLIST.md](../docs/RELEASE-CHECKLIST.md) |
| touching CI, or wondering why a test is flaky | [docs/CI-AND-PITFALLS.md](../docs/CI-AND-PITFALLS.md) |
| trying to understand the layout | [docs/CODE-MAP.md](../docs/CODE-MAP.md) |

## Style

Enforced, not suggested — both run in CI, so you will find out either way.

```bash
ruff check lib pkg surfboard scripts        # 配置在 pyproject.toml
shellcheck -S warning lib/*.sh pkg/*.sh surfboard/*.sh scripts/*.sh
```

- 4 spaces, no tabs (`.editorconfig`)
- comments and docs in Chinese; terminal output in English — the terminal may
  have no Chinese locale
- terminal output starts with `🌊`, except under `-sS`: that output is read by
  scripts and therefore carries no emoji

## Running the tests

```bash
bash scripts/flags_test.sh        # 每个测试独立，可以单跑
bash scripts/upgrade_test.sh
bash scripts/depsync_test.sh      # 改了依赖？这一条会告诉你有几处没跟上
```

Anything that installs or uninstalls for real must set `MACWAVE_TEST`, or it
will write into `~/.local/macwave`:

```bash
MACWAVE_TEST=/tmp/mw-test bash scripts/format_test.sh
```

`format_test`, `deps_test` and `sandbox_test` need network or macOS signing
tools; they run in GitHub Actions but may fail on a plane.

## Branches

Branch off the current release line — not `main`, and never an old version
branch, which is missing later fixes. The reasoning is in
[RELEASE-CHECKLIST.md](../docs/RELEASE-CHECKLIST.md) §1.5.

```bash
git switch -c 4.1-my-feature 4.1
```

## Pull requests

Fill in the template. The one question reviewers will ask if you skip it:
**how did you verify this?** "Tests pass" is fine if you name them;
"works on my machine" is not.

If your change touches any of the following, say so explicitly — these affect
every user rather than one command:

- `lib/install.sh`, `lib/uninstall.sh`
- `lib/selfupdate.sh`, `Selfupdate/macwavedata/**`
- `.github/workflows/**`
- anything that changes what `update_commands.sh` downloads

## Reporting bugs

Use the issue form. It asks for the three things that make a report actionable:
version, macOS version, and the `-v` output. Without them the first reply is
always a request for them.

**Security problems do not go in issues** — see [SECURITY.md](../SECURITY.md).

## Licensing

Contributions are under the MIT License (see [LICENSE](../LICENSE)).
