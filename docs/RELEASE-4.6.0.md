# MacWave 4.6.0

Released: 2026-11-24 · build `328B1225` · branch `4.6` ·
previous release [4.5.2](RELEASE-4.5.2.md)

This is the release that makes an install **movable**. Until 4.5, every binary MacWave
installed named one absolute directory, so the tree was welded to the path it was
unpacked into. 4.6 ships artifacts that carry relative paths instead; the tree can be
copied to another disk, another account, or another Mac and still run.

Three new commands come with it, one existing behaviour changes, and the project
license moves from MIT to Apache-2.0.

## What changed

### Artifacts are position-independent

A Mach-O records paths, not names. Before 4.6, MacWave rewrote every one of them to the
user's `base_dir` at install time and re-signed the file:

```
$ otool -L ~/.local/macwave/bin/aria2c@1.37.0/aria2c
	/Users/you/.local/macwave/deps/openssl/openssl@3.0.15/lib/libssl.3.dylib
```

Now the reference is relative to the file that contains it, and nothing is rewritten
after unpacking:

```
$ otool -L ~/.local/macwave/bin/aria2c@1.37.0/aria2c
	@loader_path/../../../deps/openssl/openssl@3.0.15/lib/libssl.3.dylib
```

Four consequences, all measured in `scripts/transfer_test.sh`:

| | before | after |
|---|---|---|
| install | rewrite every Mach-O, re-sign, scan the whole dependency tree | unpack, check that `@loader_path` targets exist |
| `codesign --verify` after install | passes only because it was just re-signed | passes because the bytes never changed |
| sha256 in the index | describes the download, not what is on disk | describes the file you end up with |
| move the tree to another path | broken | works, including through `links/` |

The rule is `@loader_path`, not `@rpath`: MacWave keeps several versions of the same
library side by side (`deps/openssl@3.0.15` and `deps/openssl@3.2.0`). Under `@rpath`
both would advertise the same name and dyld would load whichever the search order found
first; two packages needing different versions would silently share one. Under
`@loader_path` they are different strings, so they stay different libraries.

Details, including the Linux-side `$ORIGIN` comparison, are in
[docs/RELOCATION.md](RELOCATION.md).

### `wave reinstall`

Reinstalls **the version you already have**, instead of moving forward like `upgrade`:

```
$ wave reinstall jq
$ wave reinstall jq@1.8.2
$ wave reinstall jq, yq
$ wave reinstall --all
```

It exists because artifacts can be re-published under an unchanged version number — this
very release does that, since the same `jq@1.8.2` now has different bytes. It is also the
way out of a damaged install tree. `--ver` is rejected: the whole point is to keep the
version you have.

### `wave transfer`

Converts packages installed **before** 4.6 into the new form, in place:

```
$ wave transfer jq@1.8.2
$ wave transfer jq          # every installed version of jq
$ wave transfer --all
$ wave transfer --all --dry-run
```

Old and new artifacts can be mixed: each target is checked first (`transfer.sh --check`,
read-only, no dependency index), and targets that are already relative are skipped. That
makes it safe to run again, and it means a tree only gets rewritten where it must.
Dependencies listed in `_DEPS` are transferred too — rewriting only the package would
leave its libraries naming absolute paths, and the tree still could not move.

### `wave basedir --set`

Moves the whole install tree to a new directory and rewrites `base_dir` in `config.json`.
Three confirmations, all typed by hand:

1. `Yes`, after a red warning that names both paths;
2. the **current** install path, typed out;
3. the sentence `Yes, I confirm switching basedir to <new path>.`, character by
   character — untyped characters are grey, typed ones turn black, and a wrong character
   turns red **and does not advance**.

```
$ wave basedir --set ~/apps/macwave --dry-run     # example output
🌊 Dry run: nothing is copied and config.json is not changed.
🌊   from          /Users/you/.local/macwave
🌊   to            /Users/you/apps/macwave
🌊   entries       4821
🌊   size          1.2 GiB
🌊   config file   /Users/you/.config/macwave_config/config.json
🌊   artifacts     all 37 are position-independent
```

`--dry-run` needs no terminal, asks nothing and writes nothing. `--set` refuses to start
while any installed artifact still names an absolute path, and tells you to run
`wave transfer --all` first — moving such a tree would break every package in it. The old
tree is **not** deleted; the command prints the `rm -rf` to run once the new one works.

### One wave at a time

Writing to the install tree is now mutex-protected (`flock` on
`<base_dir>/var/lock/wave.lock`, non-blocking). Two simultaneous `wave install` runs used
to fight over `bin/<name>@<version>/`, `links/`, the reference counts in `.depped_*`, and
the same `downloads/tmp/*.partial` file. A second process now stops immediately and says
who holds the lock:

```
🌊 Error: another wave is running on this install tree
🌊        pid 48213 (install jq)
🌊 Next   wait for it to finish, then run this again
```

The lock is released by the kernel, so a `kill -9` does not leave a file behind that
needs deleting. Commands that only read (`list`, `info`, `search`, `--dry-run`) never
take it.

### `pkg/installed.json` is gone

It recorded name, version, absolute path and install time — every field either derivable
from `bin/<name>@<version>/` or unused. Nothing read it except one line of uninstall
output, while its writer had no lock and rewrote the file by truncating it, so two
processes could silently drop entries. Nothing to migrate: the directory layout was always
the real state.

### License: Apache-2.0

MacWave is now released under the Apache License 2.0 (was MIT). `LICENSE` and `NOTICE`
are in the repository **and** in the install tree (`info/LICENSE`, `info/NOTICE`), since
distributing the program means distributing its license. Packages MacWave installs keep
their own licenses.

The user agreement was re-dated to 2026-11-24 to carry this change, so
`wave selfupdate` asks once on installs at 4.5.2 or earlier. Installs created by the 4.6
installer already recorded the new agreement and are not asked again. Silent mode does
not answer for you: with `-s` the update stops and says to run it without `-s`.

## Upgrading from 4.5.x

Nothing you have installed breaks. Old packages keep working from the path they are in —
they simply cannot be moved. To make the existing tree movable without reinstalling
anything:

```
$ wave transfer --all --dry-run   # see what would change
$ wave transfer --all
$ wave basedir --set ~/apps/macwave
```

Reinstalling (`wave reinstall --all`) gets the build-time relocated artifacts instead and
is the shorter route if you have the bandwidth.

## Verify

Every install already checks the sha256 from the index and refuses a mismatch, so a normal
`wave install` needs no extra step. To check a file by hand, read the value from the index
record (`<api>/pkg/pkginfo_<arch>/<package>/_<package>@<version>`, or `wave mirror` to see
which address that is) and compare:

```
$ shasum -a 256 ~/Downloads/jq@1.8.2.arm64
```

This release is before 2026-12-01, so the `SHA256SUMS` / `SHA256SUMS.asc` pair is not part
of the assets yet.

## Tests

Offline regressions added in this release, both wired into the two CI pipelines:

| script | assertions | covers |
| --- | --- | --- |
| `scripts/transfer_test.sh` | 33 | `--check` does not modify bytes; `@loader_path` depth; run after moving the tree; idempotence; no dependency index is built for an already-relative tree |
| `scripts/basedir_set_test.sh` | 34 | validation, preflight, `--dry-run` side effects, three pty-driven confirmations, wrong answers aborting before any copy |
| `scripts/lock_test.sh` | 16 | contention refused with the holder's pid, lock released after `kill -9`, re-entrant nesting, every mutating module takes it |

---
# MacWave 4.6.0

发布：2026-11-24 · 构建号 `328B1225` · 分支 `4.6` ·
上一个版本 [4.5.2](RELEASE-4.5.2.md)

这一版让一次安装**可以搬走**。到 4.5 为止，MacWave 装进去的每个二进制都写死了一个
绝对目录，于是整棵树被焊在它被解压的那个路径上。4.6 换成带相对路径的产物：树可以
复制到另一块磁盘、另一个账号、另一台 Mac 上，照样能跑。

随之而来三条新命令、一处既有行为的变化，以及项目许可证从 MIT 换成 Apache-2.0。

## 更新了什么

### 产物不再绑定安装目录

Mach-O 记的是路径，不是名字。4.6 之前，MacWave 在安装时把每条路径都改写成用户的
`base_dir`，然后重新签名：

```
$ otool -L ~/.local/macwave/bin/aria2c@1.37.0/aria2c
	/Users/you/.local/macwave/deps/openssl/openssl@3.0.15/lib/libssl.3.dylib
```

现在引用相对于"含有这条引用的文件"本身，解包之后一个字节都不用改：

```
$ otool -L ~/.local/macwave/bin/aria2c@1.37.0/aria2c
	@loader_path/../../../deps/openssl/openssl@3.0.15/lib/libssl.3.dylib
```

四条后果，都在 `scripts/transfer_test.sh` 里断言过：

| | 之前 | 之后 |
|---|---|---|
| 安装 | 改写每个 Mach-O、重新签名、扫整棵依赖树 | 解包，核对 `@loader_path` 指向的目标在不在 |
| 装完 `codesign --verify` | 通过只是因为刚重签过 | 通过是因为字节没变 |
| 索引里的 sha256 | 描述的是下载到的东西，不是磁盘上的东西 | 描述的就是你最后拿到的文件 |
| 把树搬到别的路径 | 坏掉 | 能用，走 `links/` 也一样 |

规矩是 `@loader_path` 而不是 `@rpath`：MacWave 允许同一个库的多份版本并存
（`deps/openssl@3.0.15` 与 `deps/openssl@3.2.0`）。用 `@rpath` 时两者会声明同一个
名字，dyld 按搜索顺序先命中哪个就用哪个 —— 需要不同版本的两个包会静默共用一个。
用 `@loader_path` 时它们是两个不同的字符串，就是两个不同的库。

细节（含 Linux 侧 `$ORIGIN` 的逐项对照）见 [docs/RELOCATION.md](RELOCATION.md)。

### `wave reinstall`

把**已经装着的那个版本**重装一遍，而不是像 `upgrade` 那样往前走：

```
$ wave reinstall jq
$ wave reinstall jq@1.8.2
$ wave reinstall jq, yq
$ wave reinstall --all
```

它存在的原因是：产物可以在版本号不变的情况下重出 —— 这一版自己就是这样，同一个
`jq@1.8.2` 现在的字节已经不同。它也是修好坏掉的安装树的手段。`--ver` 会被拒绝：
这条命令的全部意义就是保持你已有的版本。

### `wave transfer`

把 4.6 **之前**装的包就地转成新形态：

```
$ wave transfer jq@1.8.2
$ wave transfer jq          # jq 的所有已装版本
$ wave transfer --all
$ wave transfer --all --dry-run
```

新旧产物可以混装：每个目标先检查一遍（`transfer.sh --check`，只读、不建索引），
已经是相对形式的直接跳过。所以重复执行安全，而且只改该改的那部分。`_DEPS` 里列出的
依赖也会一起迁移 —— 只改软件包自己的话，它引用的库里那些绝对路径还在，整棵树照样
搬不动。

### `wave basedir --set`

把整棵安装树搬到新目录，并改写 `config.json` 的 `base_dir`。三段确认，全部手动输入：

1. 红字警告（两边的路径都写出来）之后打 `Yes`；
2. 手动输入**当前**安装路径；
3. 逐字打出 `Yes, I confirm switching basedir to <新路径>.` —— 未输入的字是灰色，
   输对变黑，输错的那一位变红且**不前进**。

```
$ wave basedir --set ~/apps/macwave --dry-run     # 示例输出
🌊 Dry run: nothing is copied and config.json is not changed.
🌊   from          /Users/you/.local/macwave
🌊   to            /Users/you/apps/macwave
🌊   entries       4821
🌊   size          1.2 GiB
🌊   config file   /Users/you/.config/macwave_config/config.json
🌊   artifacts     all 37 are position-independent
```

`--dry-run` 不需要终端，不提问，也不写任何东西。`--set` 在还有产物写着绝对路径时
拒绝开始，并提示先跑 `wave transfer --all` —— 那样的树搬过去，每个包都会加载不到库。
旧树**不会被删**：命令会把新树验证通过后该执行的 `rm -rf` 打出来，由你自己决定什么时候删。

### 同一时刻只有一个 wave 改树

写安装树的操作现在有互斥保护（`flock` 锁 `<base_dir>/var/lock/wave.lock`，非阻塞）。
以前两个 `wave install` 同时跑会撞在 `bin/<名>@<版本>/`、`links/`、`.depped_*` 的
引用计数，以及同一个 `downloads/tmp/*.partial` 上。现在第二个进程立刻停下，并说清
是谁在占着：

```
🌊 Error: another wave is running on this install tree
🌊        pid 48213 (install jq)
🌊 Next   wait for it to finish, then run this again
```

锁由内核释放，所以 `kill -9` 不会留下一个需要人删的锁文件。只读的命令
（`list`、`info`、`search` 以及各种 `--dry-run`）从不取锁。

### `pkg/installed.json` 已删除

它记的名字、版本、绝对路径、安装时间——每一项要么能从 `bin/<名>@<版本>/` 推出来，
要么根本没人读。除了卸载时的一句显示文案，没有任何消费者；而它的写入既没有锁、又是
截断式重写，两个进程同时操作会静默丢条目。没有需要迁移的东西：目录布局本来就是真状态。

### 许可证：Apache-2.0

MacWave 现在以 Apache License 2.0 发布（原为 MIT）。`LICENSE` 与 `NOTICE` 既在仓库里，
也**随安装树下发**（`info/LICENSE`、`info/NOTICE`）——分发程序就意味着分发它的许可证。
MacWave 安装的软件包各自保留自己的许可证。

用户协议为此重新落款到 2026-11-24，于是 4.5.2 及更早的安装在 `wave selfupdate` 时会被
问一次。用 4.6 安装器装的机器已经记下了新协议，不会重问。静默模式不替你回答：带 `-s`
时更新会停下，并提示去掉 `-s` 再跑。

> 这道闸门原来只写在客户端（`lib/selfupdate.py`）里，而升级时跑的是**已装那一版**的
> 客户端 —— 它的协议常量还是旧的，于是「记录里就是这一版」直接放行，4.5.2 → 4.6.0 的
> 用户实际上一次都没被问到（2026-11-24 实测）。现在闸门由 `update_commands.sh` 承担：
> 那份脚本从**目标分支**拉下来执行，协议标识随生成物一起下发，任何年龄的客户端都会在
> 装之前被拦一次。

## 从 4.5.x 升级

已经装好的东西不会坏。老包继续在它所在的路径工作 —— 只是搬不走。想让现有的树可以搬动
而不重装任何东西：

```
$ wave transfer --all --dry-run   # 先看会改哪些
$ wave transfer --all
$ wave basedir --set ~/apps/macwave
```

如果你的带宽充裕，`wave reinstall --all` 直接拿构建时就重定位好的产物，是更短的路。

## 校验

每次安装本来就会核对索引里的 sha256，不符直接拒绝，所以正常 `wave install` 不需要额外
动作。要手工核对某个文件，从索引记录里取值（`<api>/pkg/pkginfo_<arch>/<包名>/_<包名>@<版本>`，
用 `wave mirror` 看那个地址是什么），再比对：

```
$ shasum -a 256 ~/Downloads/jq@1.8.2.arm64
```

这一版早于 2026-12-01，所以资产里还没有 `SHA256SUMS` / `SHA256SUMS.asc` 签名对。

## 测试

本版新增的离线回归，都已接进两条流水线：

| 脚本 | 断言数 | 覆盖 |
| --- | --- | --- |
| `scripts/transfer_test.sh` | 33 | `--check` 不改字节；`@loader_path` 的层数；搬走整棵树后仍可运行；幂等；已是相对形式的树不建依赖索引 |
| `scripts/basedir_set_test.sh` | 34 | 校验、预检、`--dry-run` 无副作用、pty 驱动的三段确认、任一段打错都在复制之前中止 |
| `scripts/lock_test.sh` | 16 | 竞争时拒绝并报出持有者 pid、`kill -9` 后锁立即释放、嵌套可重入、每个改树的模块都上了锁 |
