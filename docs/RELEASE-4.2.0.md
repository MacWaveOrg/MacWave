# MacWave 4.2.0 发布说明

> 本文说明 4.2.0 的变更范围与升级方式。
> 这是一个**安全版本**：加了第一道针对「产物自带符号链接」的防线 —— 链接解析后
> 落在安装根目录之外就拒绝安装。命令行、数据格式、安装布局都不变。
>
> 发布分支：`4.2`

---

## 概述

MacWave 会下载可执行软件然后运行它。此前有一处缺口：归档解压只过滤成员**名字**里的
`../`，与符号链接的**目标**无关。一个产物里可以合法地包含

```
lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
```

名字老实待在目标目录内，指向的地方却是任何位置。本版把这个口子堵上。

| 你会看到 | 说明 |
| --- | --- |
| 安装时多一行 `🌊 Running security checks...` | 解压之后、落盘之前的一步，正常情况下不会再有别的输出 |
| 恶意产物被拒绝，指明是哪个链接指向哪里 | 见第一节 |
| 正常包完全不受影响 | 本机已装树的 2413 个链接全部合规，见第三节 |

---

## 一、产物里的符号链接不得跳出安装根目录

新增的规则：**一个产物自带的符号链接，解析后必须落在安装根目录内；落在外面一律拒绝。**

威胁是两面的，缺一半都不成立：

| 攻击者用越界链接能做什么 | 后果 |
| --- | --- |
| 链接指向隐私文件（`~/.ssh/id_rsa`、`~/Library/Messages/…`），再附带一个读它的程序 | 读到用户从未授权的内容 |
| 链接指向 MacWave 之后**要写入**的路径 —— 动态库重定位改写、`.part` → `mv` 落盘、卸载时的 `rm -rf` | 以用户身份在安装树之外写文件、删文件 |

### 为什么不能交给解压工具

实测（Python 3.15.2），三种解压路径都指望不上：

| 路径 | 越界链接 | 结果 |
| --- | --- | --- |
| `.zip` / `.tar.*`，走 `unzip` / `tar` | 被解出来 | 工具不管链接目标 |
| `.conda`，走 `tarfile.extractall(filter='tar')` | 被解出来 | 同上 |
| 同上，`filter='data'` | 拒绝（`AbsoluteLinkError`） | 但会连 conda 包需要的合法链接一起拒 |

最后一行是关键：能拒的那个选项用不了，能用的那个不拒。所以检查只能**解压之后自己做**。

### 做在哪

```
产物 → 解压到临时目录 → 检查链接 → 落盘 → 重定位 → 建链接
                          ↑
              lib/configpaths.py       assert_links_inside()
              surfboard/depsmanager.sh mw_assert_no_escaping_links()
```

`tree`（依赖）与 `binary`（软件包）两种安装形态都要过这一关。

被拒绝时先删掉解压临时目录再退出 —— 正常路径上那一步由调用方在装完之后执行，
而这条路径是 `exit`，轮不到它，不删就会把恶意文件原样留在 `downloads/tmp` 里。

报错的形状：

```
🌊 Running security checks...
🌊 Error: 1 symbolic link(s) in bad@1.0 point outside /…/downloads/tmp/extract_12059
   …/lib/evil -> /private/etc/passwd
🌊 A link that leaves the install root can read private files, or make a later write (relocation, rename, uninstall) land outside the tree.
🌊 Only these locations are exempt: /bin, /sbin, /usr/bin, /usr/sbin, /usr/lib, /usr/libexec, /System, /Library/Apple
🌊 Refusing this payload. Report it to the index maintainer.
🌊 Error: bad@1.0 was not installed.
```

### 唯一的例外：系统库位置

链接落在下面这些位置（含子目录）时不算越界：

```
/bin   /sbin   /usr/bin   /usr/sbin   /usr/lib   /usr/libexec
/System   /Library/Apple
```

两条理由必须同时成立，所以只给这几处开口子：

1. **SIP 提供保护。** 系统完整性保护连 root 都拒绝写这些路径，「顺着链接去写」不成立；
   上游产物里本来就有指向 `/usr/bin` 的正常引用。
2. **那里不含隐私文件。** 只有操作系统自带的二进制与库，「顺着链接去读」也不成立。

其余一律不例外：`/Users`、`/Applications`、`/Library` 里 `Apple/` 以外的部分、
`/private`、`/opt`、`/etc`、`/var` —— 都有用户数据，且大多不受 SIP 保护。

判定按**路径分段**比较，不是字符串前缀：`/usrlocal` 不会被当成 `/usr`。

### 边界

- **悬空链接**照常判定。`resolve()` 不要求目标存在，词法上跑出根目录就算越界 ——
  一个指向 `/opt/nothing-here` 的悬空链接，等目标出现时就变成真越界了。
- **指向目录的链接**同样检查，不只是指向文件的。
- **我们自己建的链接不受影响**：`links/<名>` 由 `pkg/linker.py` 按固定形状生成
  （相对路径，永远指向 `bin/`），形状上不可能越界。

---

## 二、测试

新增 `scripts/linksafety_test.sh`，25 条断言，纯离线：

| 覆盖 | 内容 |
| --- | --- |
| 判定 | 树内相对 / 树内绝对 / 悬空但在树内 → 放行；绝对越界 / 相对爬出 / 指向目录 / 悬空但指向外面 → 拒绝 |
| 豁免 | `/usr/bin`、`/usr/lib`、`/System/…`、`/Library/Apple/…` 放行；`$WORK/fake_usr` 不算 `/usr` |
| 报错 | 点名越界的那一条、说明后果、列出豁免清单、给出下一步 |
| 真实漏斗 | 把带越界链接的产物丢进 `downloads/tmp`，走一遍完整的 `mw_install_artifact`：拒绝、**不留安装目录**、解压临时目录已清理 |
| 防误杀 | 含 `/usr/lib` 链接的合法产物必须装成功 |
| 防绕过 | `tree` 与 `binary` 两个调用点都必须存在 |

两条流水线（GitHub Actions `Format Test` 与 CircleCI `quick-feedback`）都已接入。

---

## 三、为什么不担心误杀

上线前扫过本机已装树：**2413 个符号链接，全部落在安装根目录内**，没有一个越界、
也没有一个指向系统位置。这些都是从同一批 Deps 产物里解出来的，所以「合法产物里
的链接长什么样」有实测依据。

---

## 兼容性

- **不涉及命令行变更**：没有新增、删除或改变任何旗标。
- **不涉及数据格式变更**：索引、配置都不变。
- **不涉及安装布局变更**：装的还是 `lib/`、`net/`、`pkg/`、`surfboard/` 这四个目录。
- 唯一的行为变化是新增的拒绝逻辑，只对越界链接生效。

---

## 升级方式

```bash
wave selfupdate
```

4.x 内部升级，不需要 sudo，不改数据格式，无迁移步骤。

---

## 已知限制

- 检查发生在**解压之后**，所以越界链接会短暂存在于 `downloads/tmp/extract_*` 里
  （随后被删）。真正危险的是「顺着它写」与「顺着它读」，两者都要等落盘之后才可能发生。
- 只检查产物里的链接。**已经装好的树上若存在历史遗留的越界链接，本版不会去清理** ——
  本机实测为零，但升级前装过的树没有这道防线。
- 不判断链接目标「安不安全」，只判断「在不在安装根目录内、或是否在豁免的系统位置」。
  一个指向 `/etc` 的链接会被拒绝，一个指向 `/usr/bin` 的链接会被放行，与目标本身是什么无关。

---

## 索引侧的两处修正（不在本仓库，但同批上线）

- `dust@1.2.7` 之前缺 `file` 字段，客户端在下载之前就拒绝了它
  （`No file field for dust@1.2.7`）。产物已补发到 `Bottle`，两个架构都在，
  `file` 字段按上游名回填。
- `ipsw@3.1.741` 从索引中**移除**：上游在这一版把工具本身改名成 `ipswd`，
  包里已经没有名为 `ipsw` 的可执行文件。`bin_name` 写在 `_ipsw@common` 里、对所有
  版本生效，单独改 3.1.741 会让 3.1.728–3.1.739 全部失效。
  没有这条记录之后，`wave install ipsw` 会解析到 3.1.739，装上仍是完好的。
  要恢复 3.1.741，需要另建一个 `ipswd` 包，不是补一条记录能解决的。

---

## 本版随附的数据

无数据格式变更。

```
macwavedata/latest.toml                  哪个版本是最新的
macwavedata/4.2.0/update_commands.sh     这一版具体怎么装
```

`update_commands.sh` 按版本冻结，发布后不再修改。

```
version       4.2.0
release_date  2026-11-03
build_number  307A1409
branch        4.2
```
