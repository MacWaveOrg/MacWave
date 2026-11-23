# MacWave 4.5.2

Released: 2026-11-23 · build `327A1431` · branch `4.5` ·
previous release [4.5.1](RELEASE-4.5.1.md)

A one-bug patch. If an install of a tree package (`git`, `dtc`, `nvim`, `testdisk`,
`xcodegen`) was interrupted, every later attempt to install that package failed with
`Directory not empty` — and there was no way out except deleting the directory by hand.

## An interrupted install left the package un-installable

Tree packages keep their whole extracted directory under `bin/<name>@<version>/`. The
installer moved the fresh tree into place with

```bash
mv "$source_dir"/* "$target_dir"/
```

`mkdir -p "$target_dir"` had run first, so the target existed. When a previous install had
been interrupted, the target still held a partial tree — and `mv` refuses to merge into a
non-empty directory of the same name:

```
$ wave install git
mv: rename …/share to …/bin/git@2.56.1/share: Directory not empty
🌊 At        step 9/11 (verify and install)
```

Retrying was pointless: the leftover directory was exactly what made the next attempt
fail. The only fix was to find the path and `rm -rf` it by hand.

4.5.2 makes `mw_install_tree` remove the old target before moving anything in:

```bash
mw_assert_inside "$target_dir"
if [[ -e "$target_dir" ]]; then
    rm -rf "$target_dir"
fi
mkdir -p "$target_dir"
```

The path check is now unconditional. It used to run only when the target already existed,
which meant a target that did *not* exist could be created outside `base_dir` — a gap found
while writing the regression for this fix, and closed at the same time.

## Who is affected

Tree packages in the index right now: `git`, `dtc`, `nvim` (0.10.4 / 0.11.7 / 0.12.6),
`testdisk`, `xcodegen`. You are affected only if one of them failed mid-install and you
never got it installed.

Check with:

```
$ wave list --raw | grep -E '^(git|dtc|nvim|testdisk|xcodegen)@'
```

If the package you were installing is there, you are fine. If it is missing and
`wave install <name>` keeps saying `Directory not empty`, upgrade to 4.5.2 and retry — or,
on any version, delete the leftover first:

```
$ rm -rf "$(wave basedir)/bin/<name>@<version>"
```

## Verify the download

```
$ gh release download v4.5.2 -R MacWaveOrg/MacWave -p SHA256SUMS -p SHA256SUMS.asc
$ gpg --verify SHA256SUMS.asc SHA256SUMS
$ shasum -a 256 -c SHA256SUMS
```

---
# MacWave 4.5.2

发布：2026-11-23 · 构建号 `327A1431` · 分支 `4.5` ·
上一个版本 [4.5.1](RELEASE-4.5.1.md)

一个 bug 的补丁。整树包（`git`、`dtc`、`nvim`、`testdisk`、`xcodegen`）的安装要是被
打断过，之后每次重装都会以 `Directory not empty` 失败 —— 除了手工删目录，没有别的出路。

## 装到一半被打断，那个包就再也装不上了

整树包把整棵解压目录放在 `bin/<包名>@<版本>/` 下。安装器是这样把它挪到位的：

```bash
mv "$source_dir"/* "$target_dir"/
```

而在这之前已经 `mkdir -p "$target_dir"`，所以目标目录是存在的。上一次安装被打断时，
目标里还留着半棵树 —— 于是 `mv` 拒绝合并进同名的非空目录：

```
$ wave install git
mv: rename …/share to …/bin/git@2.56.1/share: Directory not empty
🌊 At        step 9/11 (verify and install)
```

重试也没有用：正是那堆残留让下一次安装继续失败。唯一的办法是自己找到路径、`rm -rf` 掉。

4.5.2 让 `mw_install_tree` 在移动之前先清掉旧目标：

```bash
mw_assert_inside "$target_dir"
if [[ -e "$target_dir" ]]; then
    rm -rf "$target_dir"
fi
mkdir -p "$target_dir"
```

路径校验现在是无条件的。原来只有「目标已经存在」这一支才校验，也就是说目标不存在时
可以在 `base_dir` 之外建目录 —— 这个缺口是写这条回归时发现的，一并补上。

## 谁受影响

目前索引里的整树包：`git`、`dtc`、`nvim`（0.10.4 / 0.11.7 / 0.12.6）、`testdisk`、
`xcodegen`。只有其中某个包在安装中途失败、并且一直没装成功的人才会碰到这个问题。

自查：

```
$ wave list --raw | grep -E '^(git|dtc|nvim|testdisk|xcodegen)@'
```

要装的包在里面，说明没受影响。如果它不在、而 `wave install <包名>` 一直报
`Directory not empty`，升级到 4.5.2 后重试即可；在任何版本上也可以先手动删掉残留：

```
$ rm -rf "$(wave basedir)/bin/<包名>@<版本>"
```

## 校验下载

```
$ gh release download v4.5.2 -R MacWaveOrg/MacWave -p SHA256SUMS -p SHA256SUMS.asc
$ gpg --verify SHA256SUMS.asc SHA256SUMS
$ shasum -a 256 -c SHA256SUMS
```
