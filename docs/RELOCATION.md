# Relocation: why artifacts carry `@loader_path` instead of an absolute path

Applies to MacWave 4.6 and later. Linux side: see the same subject under
`$ORIGIN` at the end of this document.

---

## 1. The problem

A Mach-O records **paths**, not names:

```
$ otool -L ~/.local/macwave/bin/aria2c@1.37.0/aria2c
	/Users/you/.local/macwave/deps/openssl/openssl@3.0.15/lib/libssl.3.dylib
	/usr/lib/libSystem.B.dylib
```

The first line is an ordinary absolute path. Before 4.6 that was what every artifact
contained, so after unpacking MacWave had to rewrite it to the user's `base_dir` and
re-sign the file. Three consequences:

| Symptom | Cause |
|---|---|
| Install is slow and can fail | every Mach-O is rewritten with `install_name_tool`, then re-signed |
| The tree cannot be moved | every path names one specific directory |
| "Install" means "bytes differ per user" | sha256 only describes what was downloaded, not what ends up on disk |

`RELOCATION` is about removing all three, without giving up `wave basedir --set`.

---

## 2. Three ways to write the reference

Same dependency, three encodings:

| | Encoding | Behaviour |
|---|---|---|
| A | `/Users/you/.local/macwave/deps/.../libssl.3.dylib` | works only at that exact path |
| B | `@loader_path/../../../deps/.../libssl.3.dylib` | resolved relative to the file that contains the load command |
| C | `@rpath/libssl.3.dylib` + `LC_RPATH=@loader_path/../../..` | resolved by searching the run-path stack |

**MacWave uses B.** Reason: MacWave keeps several versions of the same library on
disk at once (`deps/openssl@3.0.15` and `deps/openssl@3.2.0`). Under C both dylibs
would advertise the same name — `@rpath/libssl.3.dylib` — and dyld loads whichever
the run-path stack finds first. Two packages that need different versions would end
up sharing one, silently. Under B the two are different strings, so they stay
different libraries.

C is only better when you want a stable indirection (`deps/openssl/current` →
`openssl@3.2.0`) so an upgrade is a symlink flip. That directly contradicts
"the closure is pinned", so MacWave does not do it.

`LC_ID_DYLIB` still becomes `@rpath/<basename>`: it is the name *others* use when
linking against this library, and `@loader_path` would resolve relative to the
*loader*, which is the wrong meaning. Nothing in MacWave loads a library by its
id — every reference is explicit — so the id is advisory.

---

## 3. Who does what

| Stage | Tool | Action |
|---|---|---|
| Build (CI) | `scripts/relocate_rpath.py <stage-dir>` | rewrite references to `@loader_path/...`, ids to `@rpath/...`, ad-hoc sign |
| Install | `surfboard/transfer.sh` | new artifacts: **nothing**, only check `@loader_path` targets exist. Old artifacts: rewrite to absolute (4.5 behaviour) |
| Migrate an old tree | `wave transfer <pkg>` / `--all` | `transfer.sh --relative`: rewrite in place, re-sign |
| Move the tree | `wave basedir --set <path>` | copy, verify entry count, rewrite `config.json`; refuses unless everything is already relative |

The build stage requires the staging tree to look like the runtime tree:

```
<stage>/bin/<name>@<version>/...
<stage>/deps/<dep>/<dep>@<version>/lib/...
```

Relative paths are computed from that layout, so if staging differs from the installed
layout the numbers are wrong. This is the same constraint as MacPorts `destroot`.

Both tools share one judgement — "is this artifact position-independent?" — implemented
once, in `transfer.sh --check`, which is read-only and does not build a dependency index.

---

## 4. Verifying by hand

```bash
# No absolute references left (the only allowed ones are Apple's)
otool -L bin/jq@1.8.2/jq | grep -c '^/Users\|^/opt'      # expect 0

# The signature survived: nothing was rewritten after signing
codesign --verify --verbose=2 bin/jq@1.8.2/jq            # expect "satisfies its Designated Requirement"

# Still works after moving the tree
mv ~/.local/macwave /tmp/mw && /tmp/mw/links/jq --version

# Two versions of the same library stay separate
otool -L bin/A@1.0/A | grep openssl     # .../openssl@3.0.15/...
otool -L bin/B@1.0/B | grep openssl     # .../openssl@3.2.0/...
```

`wave transfer <pkg> --dry-run` reports what would change; `wave basedir --set <path> --dry-run`
reports the copy size and the config file it would rewrite. Neither touches anything.

---

## 5. The Linux side is the same idea, different mechanism

`ELF` records only the library **name** in `DT_NEEDED` (`libcrypto.so.3`), so there is
nothing to rewrite. The search path is separate and can be relative:

```bash
patchelf --set-rpath '$ORIGIN/../../deps/openssl@3.0.15/lib' deps/foo/lib/libfoo.so
```

Two differences matter for maintenance:

| | ELF | Mach-O |
|---|---|---|
| What carries the path | `DT_RUNPATH` (a search list) | `LC_LOAD_DYLIB` (the path itself) |
| Cost of a change | none, no signature | must re-sign; needs `-headerpad` |
| Search path inherited? | **no** — every `.so` needs its own `$ORIGIN` | **yes** — the run-path stack accumulates along the load chain |
| Equivalent of `@executable_path` | none | exists |

Because `DT_NEEDED` holds only a name, LinuxWave today still has to run `patchelf` at
install time. That is the remaining thing to move into the build: while it stays there,
"the sha256 in the index" does not describe the file that ends up on disk, and `patchelf`
is a runtime requirement users can get wrong (the installer warns and skips relocation
when it is missing, which produces a broken install).

Related commands, side by side:

| Purpose | Linux | macOS |
|---|---|---|
| List dependencies | `readelf -d x \| grep NEEDED` | `otool -L x` |
| Show own name | `readelf -d x \| grep SONAME` | `otool -D x` |
| Show search path | `patchelf --print-rpath x` | `otool -l x \| grep -A2 LC_RPATH` |
| Set search path | `patchelf --set-rpath '$ORIGIN/../lib' x` | `install_name_tool -add_rpath @loader_path/../lib x` |
| Change a reference | `patchelf --replace-needed a.so b.so` | `install_name_tool -change a b x` |
| Change own name | `patchelf --set-soname` | `install_name_tool -id` |
| Trace loading | `LD_DEBUG=libs cmd` | `DYLD_PRINT_LIBRARIES=1 cmd` |
| After the change | — | `codesign --force --sign - x` |

---

## 6. Known limits

- **Relative layout is fixed.** You may choose `base_dir`; you may not split `bin/`
  and `deps/` onto different disks, or move `deps/` elsewhere. Move the tree whole.
- **Only Mach-O/ELF are rewritten.** Text files keep absolute paths: `.pc` files,
  `openssl.cnf`, `#!/abs/path` scripts, a bundled interpreter's `sys.prefix`. Those are
  handled at build time (placeholder, or read an environment variable), not here.
- **`@rpath`-based plugins** written by upstream may still carry absolute paths; the
  build-side tool reports anything it cannot map instead of guessing.
- **Old artifacts never gain this property by themselves.** `wave reinstall <pkg>`
  fetches the build-time relocated copy; `wave transfer <pkg>` converts what is already
  installed. Both are idempotent.
