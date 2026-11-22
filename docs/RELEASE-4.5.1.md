# MacWave 4.5.1

Released: 2026-11-23 · build `327A0019` · branch `4.5` ·
previous release [4.5.0](RELEASE-4.5.0.md)

4.5.1 is about **handling more than one thing at a time** — several packages in one
command, several versions of one package, and output that says at a glance what points
where. It also fixes one block of noise that every machine with `git` installed was
producing.

## Install and uninstall take lists

```
$ wave install jq, yq, ffmpeg@6.1
$ wave uninstall ffmpeg@6.1@6.0, jq@all
$ wave uninstall jq -a
```

- Commas separate packages; a space works too — `wave install jq yq` installs both.
- Each entry may carry its own `@version`.
- `@all` (the older `@*` still works) means every installed version of that package;
  `-a` / `--all` is the flag form of the same thing.
- `-a` together with an explicit version is refused rather than guessed.
- Without a version and without `-a`, a package with two or more versions asks which to
  remove — and in a non-interactive shell it refuses instead of picking one for you.
- A full-width comma (`，`, `、`) is caught before the names are parsed, and the
  corrected line is printed so it can be copied back:

  ```
  🌊 Error: that is a full-width comma '，' (U+FF0C), not a separator.
  🌊 Use the ASCII comma ',' (U+002C) between packages.
  🌊 Try: wave uninstall one@1.0,two
  ```

- One failing entry no longer aborts the rest: the summary reads
  `Uninstalled 2 of 3 package(s)`, the failing names are listed, and the exit code is 1.

## `wave list`: two columns, and `--raw`

```
🌊 aria2c@1.37.0    neovim@0.11.4
🌊 bash@5.2.37      openssl@3.6.0
🌊 cmatrix@2.0      pandoc@3.13
```

Column-first, the way `brew list` and `ls` do it — fill a column top to bottom, then move
right. One 🌊 per line, and no trailing spaces, so `sed -n '3p'` gives you something you
can paste.

`wave list --raw` is the script form: one name per line, no 🌊, no padding, no columns,
and **no output at all** for an empty list — `wave list --raw | xargs` must not receive a
fake package name.

## `wave linkquery`: `name => version`

```
🌊 7zz           => 26.06
🌊 aria2c        => 1.37.0
🌊 choma         => 1.0-macwaveteam2
```

Names and versions are padded to the widest entry, so `=>` lines up. When the terminal is
wide enough the list is laid out in two columns; on a narrow one it falls back to a single
column. The width comes from `shutil.get_terminal_size`, which honours `COLUMNS` and falls
back to 80 when piped — with the data above, two columns need 73 of those 80.

`wave linkquery` with no arguments now does the same thing as `--all`: asking "where does
everything point" is the only thing an argument-free call can mean.

`wave linkquery --raw` is the script form: one `name@version` per line, no 🌊, no
padding, no columns — every versionless link, including the companion commands of a tree
package. Packages that are not linked simply do not appear, so

```
$ diff <(wave list --raw) <(wave linkquery --raw)
```

is exactly the list of packages that are installed but not linked.

A package that is installed but not linked shows `=> (not linked)` and **does not** make
the command fail — that is a state, not a fault. A link that points at a version which is
no longer installed is still a red `Error` and still exits 1.

## Every executable in a tree package gets a link

A tree package used to link only its main command. That left `git` without
`git-upload-pack`, `dtc` without `fdtget`, `testdisk` without `photorec` — usable as a
name, useless for anything that shells out to a helper. The installer now links every
executable in the package's `bin/` directory, and `wave unlink` removes them together.

## Fixes

- `wave linkquery -a` reported every companion command of a tree package as
  `is not linked` and exited 1 on any machine with `git` installed. The cause was taking
  the *link* name (`git-upload-pack`) and looking for a *package* directory of that name.
  Links are now resolved to the package they belong to, which also makes
  `wave linkquery git-upload-pack` answer `🌊 git-upload-pack => git@2.56.1` instead of
  claiming it is not linked.
- New packages in the index since 4.5.0: `bash`, `circleci`, `dtc`, `mint`, `patch`,
  `scc`, `tar`, `testdisk`, `xcodegen`, `7zz`.

## Verify the download

```
$ gh release download v4.5.1 -R MacWaveOrg/MacWave -p SHA256SUMS -p SHA256SUMS.asc
$ gpg --verify SHA256SUMS.asc SHA256SUMS
$ shasum -a 256 -c SHA256SUMS
```

Every source file in this release is attached flat, alongside
`MacWave-4.5.1.tar` / `MacWave-4.5.1.tar.gz`, `SHA256SUMS` and its detached signature.

---
# MacWave 4.5.1

发布：2026-11-23 · 构建号 `327A0019` · 分支 `4.5` ·
上一个版本 [4.5.0](RELEASE-4.5.0.md)

4.5.1 讲的是**一次处理不止一样东西** —— 一条命令装多个包、卸同一个包的多个版本，
以及「一眼就能看清谁指向哪儿」的输出。顺带修掉一处噪音：凡是装了 `git` 的机器，
`wave linkquery -a` 都会刷一片假报错。

## install 与 uninstall 都收列表

```
$ wave install jq, yq, ffmpeg@6.1
$ wave uninstall ffmpeg@6.1@6.0, jq@all
$ wave uninstall jq -a
```

- 逗号分隔多个包；用空格也可以 —— `wave install jq yq` 会装两个。
- 每个条目可以带自己的 `@版本号`。
- `@all`（旧写法 `@*` 仍然认）表示这个包的全部已装版本；`-a` / `--all` 是同一件事的旗标写法。
- `-a` 与显式版本混用时直接拒绝，不猜谁说了算。
- 不带版本、也不带 `-a`，而这个包装了两个以上版本时会询问删哪个；在非交互环境里
  是拒绝，而不是替你挑一个删掉。
- 全角逗号（`，`、`、`）在解析包名之前就被拦下，并把这行的半角写法原样打出来，
  照着复制即可：

  ```
  🌊 Error: that is a full-width comma '，' (U+FF0C), not a separator.
  🌊 Use the ASCII comma ',' (U+002C) between packages.
  🌊 Try: wave uninstall one@1.0,two
  ```

- 一个条目失败不再拖垮其余：末尾汇总 `Uninstalled 2 of 3 package(s)`，列出失败的名字，
  退出码为 1。

## `wave list`：两竖列，以及 `--raw`

```
🌊 aria2c@1.37.0    neovim@0.11.4
🌊 bash@5.2.37      openssl@3.6.0
🌊 cmatrix@2.0      pandoc@3.13
```

列优先，与 `brew list`、`ls` 一致 —— 先把一列从上填到底，再换到右边。每行只带一个 🌊，
行尾不留空格，所以 `sed -n '3p'` 出来的一行可以直接粘进命令里。

`wave list --raw` 是给脚本的形态：一行一个名字、不带 🌊、不补宽、不分列，
而且列表为空时**一个字符都不输出** —— `wave list --raw | xargs` 不该收到一个假包名。

## `wave linkquery`：`名字 => 版本`

```
🌊 7zz           => 26.06
🌊 aria2c        => 1.37.0
🌊 choma         => 1.0-macwaveteam2
```

名字与版本各自按本次输出里最长的那条补齐，`=>` 才对得齐。终端够宽时排成两列，
窄了就退回一列。宽度取自 `shutil.get_terminal_size`，也就是认 `COLUMNS`，
管道里回落到 80 —— 上面这份数据两列需要 73 列，放得下。

裸 `wave linkquery` 现在与 `--all` 同义：不带参数时，唯一想问的就是「全都指向哪儿」。

`wave linkquery --raw` 是给脚本的形态：一行一个 `名字@版本`，不带 🌊、不补宽、不分列 ——
每一条不带版本号的链接都在里面，包括整树包的附属命令。没链接的包不会出现，于是

```
$ diff <(wave list --raw) <(wave linkquery --raw)
```

差出来的正好就是「装了但没链接」的那些包。

装了但没链接的包显示 `=> (not linked)`，**不影响**退出码 —— 那是状态，不是故障。
而链接指向一个已经不存在的版本时，仍然是红字 `Error`，仍然退出码 1。

## 整树包的每个可执行文件都会建链接

整树包以前只链主命令。于是 `git` 没有 `git-upload-pack`、`dtc` 没有 `fdtget`、
`testdisk` 没有 `photorec` —— 名字能用，但任何要调 helper 的场景都断了。
安装时现在会把该包 `bin/` 下每个可执行文件都链出去，`wave unlink` 会一起摘掉。

## 修复

- `wave linkquery -a` 把整树包的每个附属命令都报成 `is not linked`，并在任何装了
  `git` 的机器上以退出码 1 结束。原因是拿**链接名**（`git-upload-pack`）去找同名的
  **包目录**。现在会先把链接解析到它所属的包，顺带让
  `wave linkquery git-upload-pack` 回答 `🌊 git-upload-pack => git@2.56.1`，
  而不是说它没链接。
- 索引自 4.5.0 以来新增：`bash`、`circleci`、`dtc`、`mint`、`patch`、`scc`、`tar`、
  `testdisk`、`xcodegen`、`7zz`。

## 校验下载

```
$ gh release download v4.5.1 -R MacWaveOrg/MacWave -p SHA256SUMS -p SHA256SUMS.asc
$ gpg --verify SHA256SUMS.asc SHA256SUMS
$ shasum -a 256 -c SHA256SUMS
```

本版的全部源码都以扁平文件附在 Release 上，另有 `MacWave-4.5.1.tar` /
`MacWave-4.5.1.tar.gz`、`SHA256SUMS` 与它的分离签名。
