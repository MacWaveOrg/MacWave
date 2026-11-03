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

**如果你还在 4.1.x 或更早的版本上，请尽快升级。** 这不是一次常规改进 —— 下面这个
实验里，一个 776 字节的包在旧版本上可以读完你的私钥、并用你的身份往任意路径写文件。
4.2.0 是第一个拦住它的版本。数据见第一节。

| 你会看到 | 说明 |
| --- | --- |
| ✅ 安装时多一行 `🌊 Running security checks...` | 解压之后、落盘之前的一步，正常情况下不会再有别的输出 |
| ✅ 恶意产物被拒绝，指明是哪个链接指向哪里 | 见第二节的报错形状 |
| ✅ 正常包完全不受影响 | 本机已装树的 2413 个链接全部合规，见第四节 |

---

## 一、实验：旧版本上，一个 776 字节的包能做到什么

这不是推演出来的风险。下面这个包只有 776 字节，内容就是三个符号链接加一个短脚本：

```
./lib/evil_read   -> /usr/local/test/test_read      读：任意可读文件
./lib/evil_write  -> /usr/local/test/test_write     写：任意可写路径
./lib/evil_exec   -> /usr/local/test/test_excute    执行：任意可执行文件
./lib/hook.sh     通过上面三个链接依次「读 → 执行 → 写」
```

靶子放在 `/usr/local/test/` 下 —— 那里**不在**本版的豁免清单里（SIP 不保护它，
也可能有用户数据），所以它能检验规则不是「按路径前缀一刀切放行」。

### 四种安装方式的对照

> 表中 **✅ = 被拦住（对你安全）**，**❌ = 逃逸成功（对你危险）** —— 两种视角容易看反，
> 这里统一按「你的利益」着色。

| 安装方式 | 读到 `test_read` | 执行 `test_excute` | 写入 `test_write` | 判定 |
| --- | --- | --- | --- | --- |
| 直接 `tar xzf`（无包管理器） | ❌ 读到 `BAD! YOU READ IT!` | ❌ 打印 `Execution successful!` | ❌ 被写成 `write_on_purpose` | 💀 完全暴露 |
| **MacWave 4.1.5** | ❌ 同上 | ❌ 同上 | ❌ 同上 | 💀 完全暴露 |
| **MacWave 4.2.0** · 依赖形态 `tree` | ✅ 拒绝安装 | ✅ 拒绝安装 | ✅ 拒绝安装 | 🛡️ 已拦住 |
| **MacWave 4.2.0** · 软件包形态 `binary` | ✅ 拒绝安装 | ✅ 拒绝安装 | ✅ 拒绝安装 | 🛡️ 已拦住 |

**旧版本（直接解包与 4.1.5 完全一致）的实际输出：**

```
--- READ  through evil_read ---
    Try to READ the file!

    BAD! YOU READ IT!          ← 读穿到树外
--- EXEC  through evil_exec ---
    Execution successful!
    BAD!                       ← 执行了树外的可执行文件
--- WRITE through evil_write ---
    wrote write_on_purpose     ← 往树外写了文件
```

三行 `BAD!` 就是答案：**旧版本上一份 776 字节的产物，能读、能执行、能写安装树之外的
任意位置**。如果那个读的目标换成 `~/.ssh/id_rsa`、浏览器 cookie、Keychain 导出的私钥，
效果一样 —— 区别只在于靶子文件名。

**4.2.0 上，同一份包停在这里：**

```
🌊 Extraction successful!
🌊 Running security checks...
🌊 Error: 3 symbolic link(s) in evil@1.0 point outside /…/extract_24397
   …/lib/evil_write -> /usr/local/test/test_write
   …/lib/evil_exec  -> /usr/local/test/test_excute
   …/lib/evil_read  -> /usr/local/test/test_read
🌊 Only these locations are exempt: /bin, /sbin, /usr/bin, /usr/sbin, /usr/lib, /usr/libexec, /System, /Library/Apple
🌊 Refusing this payload. Report it to the index maintainer.
🌊 Error: evil@1.0 was not installed.
```

三条链接**全部点名**，一条都没漏。

### 拒绝之后没有留下任何东西

| 检查项 | 期望 | 实测 |
| --- | --- | --- |
| 安装目录 `deps/evil/evil@1.0` | 不应存在 | ✅ 没有创建 |
| 解压临时目录 `downloads/tmp/extract_*` | 应被清掉 | ✅ 已清空，只剩原始 tar |
| 靶子 `test_write` | 不应被写 | ✅ 与测试前逐字节一致 |
| 靶子 `test_read` | 不应被改 | ✅ 未变动 |
| 靶子 `test_excute` | 不应被改 | ✅ 未变动 |

第一行与第二行是关键：被拒绝时先删掉解压临时目录再退出，否则恶意文件会原样躺在
`downloads/tmp` 里，等着下一次被碰到或被打包带走。

### 同一份 4.2.0 代码，合法包照常装

为了防止把「拦截」做成「误杀」，用**同一个安装流程**装了一个含下列链接的合法包：

| 包内链接 | 指向 | 类型 | 结果 |
| --- | --- | --- | --- |
| `ok_rel` | `./tool` | 树内相对 | ✅ 放行并落盘 |
| `ok_system` | `/usr/bin/php` | 例外：`/usr/bin` | ✅ 放行并落盘 |
| `ok_fw` | `/System/Library/Frameworks/AppKit.framework/AppKit` | 例外：`/System` | ✅ 放行并落盘 |

三条都没被误判。也就是说这道防线区分的是「在不在安装根目录内」，不是「像不像系统路径」。

---

## 二、产物里的符号链接不得跳出安装根目录

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

## 三、测试

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

## 四、为什么不担心误杀

上线前扫过本机已装树（`deps/`、`bin/`、`links/` 三个目录，不跟随目录链接）：

| 分类 | 数量 | 判定 |
| --- | --- | --- |
| 落在安装根目录内 | **2413** | ✅ 放行 |
| 落在豁免的系统位置 | 0 | ✅ 放行 |
| 越界（会被拒绝） | **0** | — |
| 悬空且指向树外 | 0 | — |

2413 个链接全部合规 —— 这些都是从同一批 Deps 产物里解出来的，所以「合法产物里的
链接长什么样」有实测依据，不是按直觉设计出来的规则。

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

**升级完可以自己验证一次**（0.2 秒，不需要装任何东西）：

```bash
mkdir -p /tmp/t/lib && ln -s /etc/hosts /tmp/t/lib/evil && touch /tmp/t/lib/ok && ln -s ./ok /tmp/t/lib/fine
python3 ~/.local/macwave/lib/configpaths.py --check-links /tmp/t
```

| 版本 | 实际输出 | 退出码 | 判定 |
| --- | --- | --- | --- |
| **4.2.0 起** | `Error: 1 symbolic link(s) in /tmp/t point outside /private/tmp/t`，并指出 `lib/evil -> /private/etc/hosts` | 1 | ✅ 查到了 |
| **4.1.x** | `This module is not meant to be run directly.` | 1 | ❌ 没有这道检查 |

4.1.x 那两行不是「检查通过」，而是**它根本不认识这个入口** —— 那道检查在旧版本里
不存在。想确认自己在哪个版本上，看输出里有没有点名那个越界的链接即可。

删掉 `/tmp/t/lib/evil` 再跑一次，4.2.0 会安静返回 0（这正是「放行合法链接」的日常形态）。

系统前缀安装的把路径换成 `/opt/macwave/lib/configpaths.py`。

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
