# MacWave 4.3.2 Release Notes

- Released: 2026-11-08, build `312A1823`
- Branch: `4.3` (same line as 4.3.1; the `v4.3.1` tag stays at `e2532dc`)
- Previous release: [4.3.1](RELEASE-4.3.1.md)

## Two fixes, both in the system-wide install

### 1. 4.3.0 / 4.3.1 silently broke the private Python environment

4.3.0 closed the "tree owned by whoever installed it" hole, but it did so at **all three**
places that used to hand the tree back to the installing user. Only the last one should have
changed. The first two now hand the tree to `root` *before* the steps that still write to it
as an ordinary user:

| Step | Runs as | Writes to |
| --- | --- | --- |
| Bundled Python (`ensure_portable_python`) | the user | `$BASE_DIR/downloads/tmp`, `$BASE_DIR/python` |
| Private venv (`python -m venv`) | the user | `$BASE_DIR/venv` |

Measured on a non-writable tree:

```
mkdir in read-only parent: rc=1
venv in read-only dir:     rc=1
venv over existing root-owned dir: rc=1
```

So on **every** system-wide install (fresh or upgraded), the bundled Python was skipped with
a message blaming the network, the venv was not created, and the dependencies were installed
with `pip --user` into **the installer's** site-packages. The tree then worked for that one
account only — "everyone else can still run the installed packages" was not true.

**As of 4.3.2**: the two early hand-overs are `lend_tree_to_user` — a genuine temporary loan,
with the order asserted by a test (`lend` before the venv, `root` hand-over after). Only the
final one hands the tree to `root`.

### 2. Administrators no longer need `sudo` for packages

The tree was `root:<admin group>` with mode 755: only root could write, so every
`wave install` had to be `sudo wave install`. That is friction with no security gain — the
admin group is exactly the set of people who can already become root — and it failed in a
confusing way, because `sudo` has its own `PATH` and `HOME=/var/root`.

**As of 4.3.2**: the tree is `root:<admin group>` with mode **775**, and **directories carry
setgid**:

| Who | Permission |
| --- | --- |
| Everyone | read + execute → can run the installed packages |
| Administrators (`admin` group) | write → install / upgrade / remove **without `sudo`** |
| Everyone else | no write |

`o-w` stays on: without it, any local account could replace `links/<name>`, which is the
defect this whole rule exists to prevent. Setgid on directories keeps group ownership on
files that one administrator creates, so the next administrator can still write — the same
reason the shared install in LinuxWave uses it.

The runtime check stays, because a user who is **not** in the admin group still cannot write.
Its message now gives the launcher's full path, since `sudo wave install` typically ends in
`command not found`:

```
🌊 Error: no write permission on /opt/macwave
🌊 Response  running as uid 501; this tree is owned by root and writable only by its group
🌊 Next      packages can be installed by an administrator; give the full path (sudo has its own PATH):
🌊             sudo /opt/macwave/lib/wave install <package>
```

## Evidence

The regression, from the tags:

```
$ git show v4.2.5:lib/install.sh | grep -n 'chown -R "$CURRENT_USER"'
702:    sudo chown -R "$CURRENT_USER": "$BASE_DIR"      ← temporary, during install
706:    sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
1131:   sudo chown -R "$CURRENT_USER": "$BASE_DIR"      ← final, and the vulnerability

$ git show v4.3.0:lib/install.sh | grep -n hand_over_system_install
804:    hand_over_system_install "$BASE_DIR"            ← meant "temporary", now means root
900:    hand_over_system_install "$BASE_DIR"            ← same
1233:   hand_over_system_install "$BASE_DIR"            ← correct (final)
```

The permissions now issued, recorded by a stub `sudo` in `scripts/dir_guard_test.sh`:

```
chown -R root:admin /…/sys-level-macwave
chmod -R u+rwX,g+rwX,o+rX,o-w /…/sys-level-macwave
find /…/sys-level-macwave -type d -exec chmod g+s {} +
```

## Upgrading

```bash
wave selfupdate
```

`wave selfupdate` performs the hand-over itself, so an existing system-wide install becomes
`root:<admin group>` 775 without reinstalling. An install that already went through 4.3.x
will also get its bundled Python and venv rebuilt on this run — the tree is writable during
that step again.

If you are on 4.2.1 / 4.2.2 (selfupdate is broken there), use the install command:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

## Regression

`bash scripts/dir_guard_test.sh` — 72 assertions, fully offline:

- the three entries above (`chown` to `root:<group>`, `chmod` with `g+rwX,o-w`, setgid on
  directories) are issued, checked against a stub `sudo` that logs every call;
- exactly **two** `lend_tree_to_user` calls and exactly **one** `hand_over_system_install`;
- the order: loan before `python -m venv`, hand-over after it;
- user-level installs still touch nothing (the stub log stays empty);
- the runtime message carries the launcher's full path, and `install.sh` no longer claims
  that changing packages needs `sudo`.

---

# MacWave 4.3.2 发布说明

- 发布：2026-11-08，构建号 `312A1823`
- 分支：`4.3`（与 4.3.1 同一条线；`v4.3.1` 的 tag 仍在 `e2532dc`）
- 上一版：[4.3.1](RELEASE-4.3.1.md)

## 两处修复，都在系统级安装上

### 1. 4.3.0 / 4.3.1 悄悄弄坏了私有 Python 环境

4.3.0 堵上了「安装树归安装者所有」那个洞，但它是把**三处**「交还给当前用户」一起
换掉的，而只有最后一处该换。前两处现在把树交给 `root`，位置却在**还要以普通用户
身份写树**的步骤之前：

| 步骤 | 以谁的身份 | 写哪里 |
| --- | --- | --- |
| 自带 Python（`ensure_portable_python`） | 用户 | `$BASE_DIR/downloads/tmp`、`$BASE_DIR/python` |
| 私有 venv（`python -m venv`） | 用户 | `$BASE_DIR/venv` |

在不可写的树上实测：

```
mkdir in read-only parent: rc=1
venv in read-only dir:     rc=1
venv over existing root-owned dir: rc=1
```

于是**每一次**系统级安装（全新或升级）都会：自带 Python 被跳过（提示还把原因归到
网络）、venv 建不出来、依赖被 `pip --user` 装进**安装者本人**的 site-packages。那
套安装只有那一个账号能用 —— 「其他人也能运行已装的包」并不成立。

**4.3.2 起**：前两处改成 `lend_tree_to_user`，是真正的「暂时借出」，顺序由测试钉死
（借出在 venv 之前、交给 root 在 venv 之后）。只有最后一处把树交给 `root`。

### 2. 管理员装包不再需要 `sudo`

树原本是 `root:<管理员组>` 755：只有 root 能写，于是每个 `wave install` 都得写成
`sudo wave install`。这份摩擦换不来安全性 —— 管理员组恰恰就是「本来就能变成 root」
的那批人 —— 而且失败时很难懂，因为 `sudo` 有它自己的 `PATH`，`HOME` 也变成
`/var/root`。

**4.3.2 起**：树是 `root:<管理员组>`、权限 **775**，**目录带 setgid**：

| 角色 | 权限 |
| --- | --- |
| 所有人 | 读 + 执行 → 能运行已装的包 |
| 管理员（`admin` 组） | 可写 → 装 / 升 / 卸 **不需要 `sudo`** |
| 其他人 | 不可写 |

`o-w` 保留：少了它，任何本地账号都能替换 `links/<名>`，那正是这条规则要堵的漏洞。
目录上的 setgid 让某个管理员新建的文件沿用同一个组，下一个管理员照样写得进去 ——
与 LinuxWave 共享安装同一条理由。

运行时检查保留，因为**不在**管理员组里的用户依旧写不进去。提示改成启动器的全路径，
因为 `sudo wave install` 通常会以 `command not found` 收场：

```
🌊 Error: no write permission on /opt/macwave
🌊 Response  running as uid 501; this tree is owned by root and writable only by its group
🌊 Next      packages can be installed by an administrator; give the full path (sudo has its own PATH):
🌊             sudo /opt/macwave/lib/wave install <package>
```

## 证据

回归是怎么来的，从 tag 上看：

```
$ git show v4.2.5:lib/install.sh | grep -n 'chown -R "$CURRENT_USER"'
702:    sudo chown -R "$CURRENT_USER": "$BASE_DIR"      ← 临时，安装期间
706:    sudo chown -R "$CURRENT_USER": "$CONFIG_DIR"
1131:   sudo chown -R "$CURRENT_USER": "$BASE_DIR"      ← 最终，也是那个漏洞

$ git show v4.3.0:lib/install.sh | grep -n hand_over_system_install
804:    hand_over_system_install "$BASE_DIR"            ← 本意「临时」，现在是 root
900:    hand_over_system_install "$BASE_DIR"            ← 同上
1233:   hand_over_system_install "$BASE_DIR"            ← 这一处才对（最终）
```

现在实际下发的权限，由 `scripts/dir_guard_test.sh` 里的假 `sudo` 逐条记录：

```
chown -R root:admin /…/sys-level-macwave
chmod -R u+rwX,g+rwX,o+rX,o-w /…/sys-level-macwave
find /…/sys-level-macwave -type d -exec chmod g+s {} +
```

## 升级方式

```bash
wave selfupdate
```

`wave selfupdate` 自己会做属主交还，所以已有的系统级安装不需要重装就会变成
`root:<管理员组>` 775。已经走过 4.3.x 的安装，这次还会把自带 Python 与 venv 重建
一遍 —— 那一步树又可写了。

**如果你在 4.2.1 / 4.2.2**（那两版的 selfupdate 是坏的），改用安装命令：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

## 回归

`bash scripts/dir_guard_test.sh` —— 72 条断言，纯离线：

- 上面三条命令确实下发（对着会记录每次调用的假 `sudo` 核对）；
- `lend_tree_to_user` 恰好 **2** 处、`hand_over_system_install` 恰好 **1** 处；
- 顺序：借出在 `python -m venv` 之前、交还在它之后；
- 用户级安装一条都不动（假 `sudo` 的日志是空的）；
- 运行时报错带启动器全路径；`install.sh` 不再宣称改动软件包需要 `sudo`。
