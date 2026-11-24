# 发布检查清单

这份文档只讲一件事：**发一个版本时按什么顺序做、为什么顺序不能乱**。
每一条都对应一次真实踩过的坑，写在「为什么」里。

适用于 4.0 起的自更新机制（`Selfupdate` 仓库 + `configdata` 指针）。

---

## 一、先搞清三条指针各管什么

发布出问题，十次有九次是这三处之一没对齐。

| 指针 | 谁读它 | 作用 |
| --- | --- | --- |
| `MacWaveOrg/Selfupdate` 的 `macwavedata/latest.toml` | **4.x 客户端** | 4.x 的 `wave selfupdate` 据此知道该升到哪个版本 |
| `MacWaveOrg/configdata` 的 `versiondata/latest_version` | **3.x 客户端** | 3.x 的旧 `selfupdate.sh` 据此判断「有新版本」，并读 `update_command` |
| `MacWaveOrg/Pages` 的 `index.html` + `i18n.js` | 人 | 官网显示的版本号、安装说明与支持包清单 |

外加按版本冻结的一份脚本：

```
Selfupdate/macwavedata/<版本>/update_commands.sh
```

它由 `scripts/build_update_commands.py` 生成，**一个版本一份，永不修改**。

---

## 一点五、分支策略：永远从最新版切出去

**所有新开发都基于最新发布分支（当前是 `4.1`），不从 `main`、更不从旧版本分支切。**

| 要做的事 | 从哪切 |
| --- | --- |
| 下一个功能（如 4.2） | `4.1`（或届时最新的发布分支） |
| 给旧版本打补丁 | 该版本分支 + 显式基准点（见第三节） |
| ❌ 从 `4.0`、`3.2` 切 | 会带着已知问题出发，且历史早已分叉 |

`main` 与当前发布分支由 workflow 保持同步，所以「从最新版切」等价于「从 main 切」，
但**用发布分支名更明确**：它一眼就能看出这条线是从哪个版本延续下来的。

```bash
# 正确
git switch -c 4.2 4.1

# 也正确（两者内容一致，但可读性差）
git switch -c 4.2 main
```

### 为什么不能从旧分支切

旧分支停在旧内容上，缺后续修复。以本项目为例：`4.0` 分支缺少
`ldid` 的索引修正、`-v` 的失败定位、以及 `wave mirror`。从它切出去，
等于把这些问题重新引入一遍。

---

## 一点六、构建号（`build_number`）怎么算

每次发版都要换一个，格式固定 8 个字符：

```
323R1250
└┬┘│└─┬─┘
 │ │  └── 发布时刻 HHMM（24 小时制）
 │ └───── 字母：见下表（正式版 A–G／H 特殊日期，Beta I–O／P，RC 固定 R）
 └─────── 今天距离 2026-01-01 的天数，3 位补零（2026-01-01 → 001）
```

字母规则：

| 普通版本 | Beta 版 | RC 版本 |
| --- | --- | --- |
| `A`-`G` 对应周一-周日，`H` 为特殊日期 | `I`-`O` 对应周一-周日，`P` 为特殊日期 | `R` |

例：2026-11-19 是周四、距年初 323 天，12:50 发布一个 RC → `323R1250`。

取当前值一行命令（别手算，闰年与跨年是坑）：

```bash
printf '%sA%s\n' "$(( ( $(date +%s) - $(date -j -f %Y-%m-%d 2026-01-01 +%s) ) / 86400 + 1 ))" "$(date +%H%M)"
# Beta 把 A 换成当天的 I-O（周一=I）；RC 直接用 R
```

三条容易错的地方：

- **第四位不是「第几次构建」。** 它编码的是渠道与周几：正式版 `A`-`G`、Beta `I`-`O`、
  RC 永远是 `R`。4.3.3 之前所有构建号第四位都是 `A`，多数与真实周几不符 —— 这条
  规则以前没被实现过。**历史号不回改**：它只是标识，改了会让旧发布说明、
  `Selfupdate/<版本>/` 目录与 tag 对不上。
- **`HHMM` 只用于区分同一天内的多次发布**，不参与版本比较。客户端比的是
  `version`（PEP 440），版本相同时才比构建号的天数与时分（`lib/versioncompare.py`
  的 `build_key` / `is_newer_build`），字母只给人看。
- **三处必须写同一个值**：`configdata/versiondata/latest_version`、
  对应渠道的探针（正式版 `macwavedata/latest.toml`、RC `rcdata/latest.toml`）、
  发布说明头部「发布日期 · 构建号」那一行。

---

## 二、正确的发布顺序

### 第 1 步：在版本分支上完成功能与文档

```bash
git switch -c 4.1          # 从 main 切出，保证历史连续
# ……开发、跑测试……
```

分支名用 `大版本.次版本`（`4.1`、`3.2`），因为 `configdata` 的 `branch` 字段要引用它。

#### 4.3 起：把 `min_os` 从实验转正

`min_os` 在 4.2 是实验性的：客户端能读、数据部分回填、行为只提示不拦截
（完整矩阵见 [`AGENTS.md`](../AGENTS.md) 的「包级元数据」一节）。4.3 转正时按这条
清单做，缺一项都会让旧系统用户在某些包上静默失败：

| 项 | 为什么 |
| --- | --- |
| ~~把 `infosource` 全库的 `min_os` 回填完（`arm64` 与 `amd64` 两套）~~ **已完成**（`infosource` `c92d1fc`） | 覆盖到真实软件包 100%；缺的只有 `test_*` 与 `fileicon`，它们本来就没有 Mach-O |
| `backfill_min_os_from_bottle.py --dry-run` 要看到真实包 `no-minos=0` | 有产物读不出 `minos`，说明提取漏了某种形态（裸二进制 / tar / zip / `.conda` / 单文件 `.gz` / `LC_VERSION_MIN_MACOSX`） |
| 复核「询问式」是否仍是想要的形态 | 现在是：警告 + `[y/N]`，只有 `y`/`Y` 继续；`-s` 直接拒绝、`-sS` 才说原因；`-F` 强制越过。改成硬拦截前必须确认 `jq` 这类「声明保守」的包不被误杀 —— 它声明 14.0 却在 12.7.6 上实测能跑 |
| ~~更新对外文案（官网与 Release）~~ **已完成** | 官网与两个 README 改成 `macOS Monterey 12 and above`（实测下限），README 里另写明 Intel 的理论地板 10.15 与「12 以下未实测」的边界 |
| 在 `AGENTS.md`、本文件去掉「实验性」字样 | 否则后来的人会按旧语义改代码 |

### 第 2 步：**先改 `configdata` 的 `branch`，再合并到 main**

这一步的顺序是最容易搞错的，见第三节。

```bash
# configdata/versiondata/latest_version
version: "<新版本>"
build_number: "<构建号，算法见一点六>"
branch: "4.1"
update_command: <<< …/MacWave/4.1/lib/selfupdate.sh >>>
```

### 第 3 步：合并到 main（保留历史）

用**合并提交**，不要 squash、不要 force：

```bash
git switch main
git merge --no-ff 4.1 -m "Merge 4.1 into main"
```

通过 API 操作时同理：提交的 `parents` 必须同时包含 main 与分支的头。

### 第 4 步：生成并推送 `update_commands.sh`

```bash
PREV=$(git describe --tags --abbrev=0)   # 上一个正式 tag

python3 scripts/build_update_commands.py \
    --version <新版本> \
    --branch  <新分支> \
    --delta "$(git diff --name-only "$PREV" <新分支> -- lib pkg surfboard | grep -E '\.(py|sh)$')" \
    --new   "$(git diff --diff-filter=A --name-only "$PREV" <新分支> -- lib pkg surfboard | grep -E '\.(py|sh)$')" \
    --out /tmp/update_commands.sh
```

**`--new` 不能省。** 它把「上一版还不存在」的文件排到 delta 的最前面。
不排在最前，升级中途一旦失败，安装树里就会出现「某个模块 import 一个还没下载到的
模块」的状态 —— `wave` 自身起不来，连 `wave selfupdate` 都救不回来，只能人工重装。
4.1.5 加入 `lib/tls.py` 时就踩在这一点上。

**不要手写 `--files 'pkg/*'` 这类通配符。** 4.1.1 就是这么发出去的，而且出了两个问题：

```bash
# 这一行的通配符在真实工作区里会展开成：
#   lib/install.sh、lib/uninstall.sh   —— 本该被 EXCLUDED 挡掉
#   pkg/__pycache__、surfboard/__pycache__ —— 目录，git 里根本不存在
--files lib/*.py lib/*.sh pkg/* surfboard/*
```

结果客户端升级时对两个 `__pycache__` 各重试 3 次再报 404，还把 `lib/install.sh`
当成普通文件下载、覆盖了安装目录里的副本。

现在生成器会对 `--files` 也做过滤（`sanitize()`），上面这行不会再产出坏清单；
但**省略 `--files`、让它按 `--ref` 读仓库树**仍然是最稳的写法 —— 仓库树里没有
`__pycache__`，也不会把工作区里未提交的东西带进去。确实需要显式传时，
用 `git ls-tree` 而不是 shell 通配符：

```bash
--files $(git ls-tree --name-only -r <ref> lib pkg surfboard)
```

确认清单内容对得上，且没有不该出现的东西：

```bash
grep -c 'want ' /tmp/update_commands.sh          # 文件数是不是预期
grep 'want lib/<新模块>.py' /tmp/update_commands.sh   # 这一版新增的模块在不在

# 这三类一律不该出现，出现了就说明清单是脏的
grep -E 'want (lib/(install|uninstall)\.sh|.*__pycache__|.*\.pyc)' /tmp/update_commands.sh && echo '❌ 清单有脏条目'
```

推到 `Selfupdate/macwavedata/<新版本>/update_commands.sh`。

生成器会从 `<ref>:lib/selfupdate.py` 里抄 `AGREEMENT_ID` 写进脚本（
`AGREEMENT_ID="…"` 那行），这是用户协议闸门的判据。抄不到时它会打印
`no AGREEMENT_ID` 的警告 —— **看到这条就别推**，空值等于这一版不会被任何人问到协议。

协议闸门为什么必须在生成物里、而不是客户端里：升级时跑的是**已装那一版**的
`lib/selfupdate.py`，它的常量永远是旧的（4.5.2 → 4.6.0 就是这么漏掉的，
2026-11-24 实测）。所以：

- 改协议（含改许可证）只需要改 `lib/selfupdate.py` 的两个常量与官网落款，
  **不必**碰生成器或模板；
- 但**已经发布出去的版本**，如果当时生成的脚本里没有闸门或闸门里的标识是旧的，
  就得重跑本步 + 第 5 步（换 `update_commands_sha256`）并重签，老客户端才会被问。

### 第 5 步：更新 `Selfupdate` 的 `latest.toml`

> 4.4 起 `latest.toml` 多一个字段，用来钉住「即将被 bash 执行的那个脚本」：
>
> ```toml
> update_commands_sha256 = "…"   # 第 4 步生成器最后一行会打印出来
> ```
>
> 同目录再放一份签名（机器验，openssl；给人验的 GPG 签名在 Release 附件里）。
> 私钥带口令，会问一次：
>
> ```bash
> openssl dgst -sha256 -sign ~/MD/密钥/private/macwave-rsa.key \
>     -out macwavedata/latest.toml.sig macwavedata/latest.toml
>
> # 发之前自己先验一遍，用的是仓库里那份公钥（= 客户端手里那份）
> openssl dgst -sha256 -verify Keys/macwave-rsa.pub.pem \
>     -signature macwavedata/latest.toml.sig macwavedata/latest.toml
> ```
>
> 客户端验签用的公钥**内嵌在** `lib/install.sh` / `lib/selfupdate.sh` 里，
> 与 `Keys/macwave-rsa.pub.pem` 逐字相同（`scripts/signature_test.sh` 会比对）。
> 换钥那天记得跑 `python3 scripts/embed_rsa_pub.py`。
>
> 4.4 客户端拿到它会**只警告**不符；`MACWAVE_STRICT_HASHES=1` 时才失败。

```toml
version = "<新版本>"
release_date = "YYYY-MM-DD"
build_number = "<构建号，算法见一点六>"
branch = "<新分支>"
```

### 第 5.5 步：发 RC（渠道隔离，不要碰正式版探针）

RC 走**自己的探针**，正式版用户完全看不到它：

```
Selfupdate/rcdata/latest.toml              ← RC 探针（只此一份，正式版探针不动）
Selfupdate/macwavedata/<版本>/update_commands.sh   ← 两渠道共用，按版本冻结
```

**版本号**用 `4.4.1-rc`（PEP 440 会把没编号的 `-rc` 补成 `rc0`，所以同一个
`X.Y.Z-rc` 反复发多次都合法）。**构建号**字母固定 `R`，例如 `323R1250`：

```toml
# Selfupdate/rcdata/latest.toml
version = "4.4.1-rc"
build_number = "323R1250"
branch = "4.4"                 # RC 也在发布分支上，不能写 main
update_commands_sha256 = "<第 4 步生成器打印的那一行>"
```

三条与正式版不同的地方：

- **探针路径不同**（`rcdata/` 而不是 `macwavedata/`）。这正是为了让两者互不覆盖：
  正式版探针每次发版都被改写，RC 一天可能发好几次。
- **`version` 是预发布**，客户端据此选渠道。装的是 RC → `wave selfupdate` 只读
  `rcdata/latest.toml`；装的是正式版 → 永远不读它。
- **`build` 必填**。同一版本可能构建多次，只比 `version` 会得出「已是最新」。
  构建号进入 `VERSION.json` 的 `build` 字段，比较规则见
  `lib/versioncompare.py` 的 `newer_release()`。

装一台 RC 试用（`MACWAVE_CHANNEL=rc` 让安装器读 RC 探针）：

```bash
MACWAVE_CHANNEL=rc /bin/bash -c \
  "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"
```

RC 渠道收尾（正式版已经比 RC 新）时，客户端会**全量**切到正式版：置
`MACWAVE_FULL_INSTALL=1`，把安装树整体替换，而不是把正式版的增量铺在 RC 树上 ——
后者就是 2026-11-15 那次「两条分支混装、wave 启动即崩」的成因。

`latest.toml.sig` 对 RC 探针同样有效：签名的是探针内容，与它放在哪个路径无关。
RC 探针建议也签，否则 `wave selfupdate` 在 RC 上会打「这份数据没有签名」的警告。

### 第 6 步：更新官网版本号与 Release 正文

官网的版本号**不在 `index.html` 里，主要在 `i18n.js`**，而且有 9 处。只改
`index.html` 是 2026-11-24 那次 4.6.0 发版漏掉的地方（站上一直显示 4.5.2）：

| 文件 | 位置 | 处数 |
| --- | --- | --- |
| `Pages/index.html` | `.version-block` 里的静态兜底 `<span class="v-line">` | 2 行（版本 + 日期） |
| `Pages/i18n.js` | 每种语言的 `'version.block'` | **8 处**（zh-Hans / zh-Hant / fr / ja / ko / ru / de / es） |
| `Pages/i18n.js` | 每种语言的 `'agreement.notice'` 落款日期与版本 | 8 处，与协议的 `AGREEMENT_ID` / 生效日期保持一致 |

改完必须做这两条校验（第二条输出为空才算过）：

```bash
cd ~/Projects/MacWaveOrg/Pages
python3 scripts/check_version.py          # 直接跑闸门，与 CI 同一条命令
```

**这一步现在有 CI 兜底**：`Pages` 仓库的 `Website version check` 会读 Selfupdate 的
`macwavedata/latest.toml`，逐条比对 `i18n.js` 的全部 `version.block` 与
`index.html` 的两行兜底；每日还会定时跑一次，所以「发版了但官网没动」也会红。
本地用同一条命令复现：`python3 scripts/check_version.py`。

- GitHub Release：正文用 `docs/RELEASE-<版本>.md`

#### 正文必须双语，英文在前

Release 页面的默认读者是美国那边的用户，中文读者则两边都看得懂。所以每一份
`docs/RELEASE-<版本>.md` 都写成两段，中间用 `---` 隔开：

```
# MacWave <版本> Release Notes     ← 英文全文
...
---
# MacWave <版本> 发布说明           ← 中文全文（原文不动，整段接在后面）
```

- **两段各自完整**，不是摘要 + 全文。英文段要能独立读懂，包括表格、代码块、实测数据。
- **英文在前**，中文在后。判定标准很简单：把文件从头往下读，第一屏必须是英文。
- 中文段是原文，**不因为补英文而改写**；要改就两边一起改（同一处结论、同一组数字
  必须一致，否则英文段单独被引用时就是错的）。
- 标题前缀同理，英文在前：`[Urgent security update 紧急安全更新]`、
  `[Critical fix 紧急修复]`，不是中文在前。
- 只做 `gh release edit --notes-file` 是不够的——**仓库里那份文件也要一起改**，
  否则下次有人照着文件重新 `--notes-file`，英文段会整个消失。

补历史版本时（模板见 `docs/RELEASE-4.2.3.md` ~ `4.3.0`），顺序是：改文件 → 跑
`bash scripts/markdown_test.sh` → `gh release edit --notes-file` → 抽查正文第一行是不是英文。

### 第 7 步：建 Tag 与 Release

```bash
gh api --method POST repos/MacWaveOrg/MacWave/git/refs \
  -f ref="refs/tags/v<版本>" -f sha="<main 的提交>"
gh release create v<版本> --repo MacWaveOrg/MacWave --title "MacWave <版本>" --notes-file docs/RELEASE-<版本>.md
```

先建 tag 再建 Release。`--target-commitish` 只在 tag 不存在时有效，
tag 已存在却仍传 `--target` 会报 `Release.target_commitish is invalid`。

#### 安全版本：标题带前缀，正文带证据

**凡属安全修复的版本，标题必须加前缀。** 理由很实际：Release 列表里一眼扫过去，
读者需要知道「这一版要不要立刻升」。没有前缀时，一次堵住提权路径的修复和一次
调超时的改动长得一模一样。安全修复分两档，别混用：

| 档 | 前缀 | 什么时候用 |
| --- | --- | --- |
| 紧急 | `[Urgent security update 紧急安全更新]` | 旧版本会让**这台机器被人接管或数据被拿走**，或者**旧版装出来的结果是坏的**（装完即坏、权限被打乱）。看到这类问题，升级不是「建议」而是必须 |
| 一般 | `[Security update 安全更新]` | 其余安全修复：限定条件下的弱点、加固性质的收紧、还没被证明能直接接管的情形 |

判不准就往紧急那边靠——前缀写重了只让人早升一版，写轻了会让人放着不提权漏洞不修。

```bash
# 紧急安全版本
gh release create v<版本> --repo MacWaveOrg/MacWave \
  --title "[Urgent security update 紧急安全更新] MacWave <版本>" --notes-file docs/RELEASE-<版本>.md

# 一般安全版本
gh release create v<版本> --repo MacWaveOrg/MacWave \
  --title "[Security update 安全更新] MacWave <版本>" --notes-file docs/RELEASE-<版本>.md

# 非安全版本
gh release create v<版本> --repo MacWaveOrg/MacWave \
  --title "MacWave <版本>" --notes-file docs/RELEASE-<版本>.md
```

已经发布但漏了前缀（或档位定轻了）时补上：

```bash
TITLE="[Urgent security update 紧急安全更新] MacWave <版本>"
gh release edit v<版本> --repo MacWaveOrg/MacWave --title "$TITLE"
```

已定的档位：4.2.0（产物符号链接可逃出安装根目录，读到私钥、以用户身份任意写）
与 4.3.0（装到 `/opt`、`/usr/local` 时把整棵树 chown 给安装者）都是**紧急**。
tag 不可变但标题可变，改档位不需要动 tag。

**正文里要有可复现的证据，而不是只写「修了 X」。** 一份安全版本的说明至少包含：

| 要素 | 为什么 |
| --- | --- |
| 一个**具体**的威胁场景（哪个文件、哪条路径、能读到或写到什么） | 「存在路径穿越风险」不构成让人升级的理由 |
| **旧版本与新版并排的实测数据**（表格：旧版怎么样、新版怎么样） | 让人相信这不是推演出来的 |
| 拒绝之后**没有留下副作用**（安装目录、临时目录、数据文件逐项核对） | 否则读者会怀疑「拦是拦了，东西是不是已经落地了」 |
| 一个**正面对照**（合法的东西照常工作） | 否则读者会怀疑新版本会误杀自己常用的包 |
| 用户**自己能跑**的验证命令，并写清旧版本上的输出为什么看起来不同 | 让人亲眼确认自己是否已受保护 |

4.2.0 是这一条的样板：`docs/RELEASE-4.2.0.md` 第一节用一份 776 字节的包做了
四种安装方式的对照，并附上了旧版本上「读 / 执行 / 写」三条逃逸的实际输出。

**判色要按读者的利益来。** 对照表里「攻击是否成功」和「防护是否生效」是反的，
用 ✅ 表示「攻击成功」会让人读成「没问题」。统一规定：**✅ = 被拦住（对用户安全）、
❌ = 逃逸成功（对用户危险）**，并在表头写明这句。

#### Release 上必须附全部源码

**硬规则：每个 Release 都必须附上该 tag 下的全部源码，缺了就等于这版没发完。**
不是「以后补」—— 是当场补，补完才算发布完成。这条与第 7 步的 tag / 正文是同级的交付项，
不是可选的附加品。

判据只有一个，能用命令验：

```
资产数 = 该 tag 下 .py / .sh 的个数 + 4（两个归档 + `SHA256SUMS` + `SHA256SUMS.asc`）
```

这行字是 2026-11 才写下的，起因是 `v4.3.1` 与 `v4.3.2` 两个 Release 各有 **0 个资产**
（`v4.3.0` 有 75 个），而且零反馈：客户端装代码走分支下的文件，资产为零的 Release 照样
装得上；只有想离线核对或做第三方审计的人才会发现「下载不到源码」，那时已经过去好几版。

守卫工作流 `.github/workflows/release-assets-check.yml` **只放在 `main` 上就够** ——
`release` 事件读的是默认分支的工作流定义，所以它对任何 tag 生效，发布分支（`4.3`、`4.4`）
不必各存一份。它**只查不补**：自动补一份内容不对的资产，比缺着更难发现。

`release: published` 在第一个资产上传之前就会触发，所以守卫发现资产不齐时会隔 120 秒
重查，最多三次（`v4.4.0-beta2` 第一次真跑就是这样误报的：它看到 14 个资产，而实际当时
还在传）。三次之后仍不齐才判红 —— 那才是真的漏了。

每个 Release 除了 GitHub 自动生成的 Source code，还要**手工再附两样东西**，
这个习惯从 3.2.1 一直延续下来，不要断：

| 附什么 | 资产名 | 内容 |
| --- | --- | --- |
| 扁平源码文件 | 原文件名（`wave.py`、`mirrorinfo.py`…） | 该 tag 下的每个 `.py` / `.sh`，**不带目录** |
| 源码树归档 | `MacWave-<版本>.tar`、`MacWave-<版本>.tar.gz` | 整棵源码树，顶层目录 `MacWave-<版本>/` |

```bash
TAG=v<版本>

# 1) 列该 tag 下全部 py/sh —— 必须排除 . 开头的目录（见下面「文件名会撞」）
gh api "repos/MacWaveOrg/MacWave/git/trees/$TAG?recursive=1" \
  --jq '.tree[] | select(.type=="blob") | .path' | grep -E '\.(py|sh)$' | grep -v '^\.' > /tmp/src.txt

# 2) 下载并扁平上传（--clobber 让重复执行安全）
mkdir -p /tmp/rel
while read -r p; do
  gh api -H "Accept: application/vnd.github.raw" \
    "repos/MacWaveOrg/MacWave/contents/$p?ref=$TAG" > "/tmp/rel/$(basename "$p")"
done < /tmp/src.txt
# 一次传整批。不要写成 `for f in …; do gh release upload "$f"; done` ——
# 每个文件一次 API 调用，96 个文件要五分钟以上，而守卫的等待窗口只有
# 3 × 120 秒（见下面「五个容易踩的点」最后一条）。2026-11-22 发 4.5.0
# 就是这么红的：重查三次时只传上去 55 个。
gh release upload "$TAG" /tmp/rel/* -R MacWaveOrg/MacWave --clobber

# 3) 整棵源码树打包，顶层目录名必须是 MacWave-<版本>/
rm -rf /tmp/arc && mkdir -p /tmp/arc && cd /tmp/arc
gh api "repos/MacWaveOrg/MacWave/tarball/$TAG" > src.tar.gz && tar xzf src.tar.gz
mv MacWaveOrg-MacWave-* "MacWave-<版本>"
tar --no-xattrs -cf "MacWave-<版本>.tar" "MacWave-<版本>"
gzip -9 -c "MacWave-<版本>.tar" > "MacWave-<版本>.tar.gz"
gh release upload "$TAG" "MacWave-<版本>.tar" "MacWave-<版本>.tar.gz" -R MacWaveOrg/MacWave --clobber
```

核对：

```bash
gh release view "$TAG" -R MacWaveOrg/MacWave --json assets --jq '.assets | length'
# 应等于 py/sh 文件数 + 4（4.3.3 是 77 + 4 = 81）
```

五个容易踩的点：

- **文件名会撞。** 扁平化后同名的两个文件只会剩一个，而且**后写的那个静默覆盖前一个**，
  不报错、资产数少一也不明显。**2026-11-19 又踩了一次**：`lib/install.sh` 与
  `scripts/mirror-check/install.sh` 同名，按上面的循环上传（字母序，`lib/` 在前）
  最后留下的是镜像巡检那个 —— Release 里的 `install.sh` 就不再是安装器了。
  现在守卫工作流要求那个文件叫 **`mirror-check-install.sh`**，所以补一句：

  ```bash
  # 循化上传之后，把巡检脚本按带前缀的名字补上
  gh api -H "Accept: application/vnd.github.raw" \
    "repos/MacWaveOrg/MacWave/contents/scripts/mirror-check/install.sh?ref=$TAG" \
    > /tmp/mirror-check-install.sh
  gh release upload "$TAG" /tmp/mirror-check-install.sh -R MacWaveOrg/MacWave --clobber
  ```

  校验一行：`gh api repos/MacWaveOrg/MacWave/releases/tags/$TAG \
    --jq '.assets[] | select(.name=="install.sh") | .size'` 必须等于 `wc -c lib/install.sh`
  （约 139 KB），不是 1 KB 级。已知的另一处：
  - `.Pseudocode/pkg/pkginstaller.py` 与 `pkg/pkginstaller.py` 同名。
    所以第 1 步要 `grep -v '^\.'` —— 那个目录只是早期伪代码，本来就不该出现在资产里。
  - `lib/install.sh`（主安装器）与 `scripts/mirror-check/install.sh`（镜像巡检）同名。
    主安装器保留原名，巡检脚本上传为 `mirror-check-install.sh`（4.3.0 起）。

  上传前先自查撞名，再逐文件比对 blob 哈希（只数个数看不出覆盖）：

  ```bash
  # 撞名自查：应为空
  while read -r p; do basename "$p"; done < /tmp/src.txt | sort | uniq -d

  # 内容自查：把 <改名的映射> 写进循环，其余同名
  while read -r p; do
    want=$(git rev-parse "$TAG:$p"); got=$(git hash-object "/tmp/rel/$(basename "$p")")
    [ "$want" = "$got" ] || echo "不一致: $p"
  done < /tmp/src.txt
  ```

- **`gh release upload` 必须带 `--clobber`。** 否则重跑报 422。
- **macOS 上打归档要加 `--no-xattrs`。** 不加时 bsdtar 会把扩展属性写进 pax 头，Linux 解包多出 `._*`。
  打完务必解包 `diff -r` 一遍，确认与原树逐文件一致。
- **比哈希时要照顾符号链接。** 仓库里 `CLAUDE.md` 是指向 `AGENTS.md` 的链接（mode `120000`），
  归档会正确保留成链接。此时 `git hash-object <解包出来的链接>` 会**跟随链接**读到
  `AGENTS.md` 的内容，和 blob 里存的链接目标字符串（`AGENTS.md`）当然对不上 ——
  看着像资产坏了，其实是判据用错了。按 mode 分开判：

  ```bash
  # mode 120000 的比链接目标，其余比 blob 哈希
  want=$(git cat-file -p "$TAG:$p"); got=$(readlink "$解包目录/$p")
  ```

  用 `diff -r` 复核时它默认跟随链接比内容，同样验不出链接指向错没错，别只靠它。
- **归档要从 tag 建，不要从工作副本建。** 3.2.1 的 tar 就比 tag 少两个文件
  （`sync-payloads.yml`、`RELEASE-3.2.2.md`），是 tag 之后又改过导致的不一致。

为什么还要附这些：4.x 的自更新已经改成从**分支下的文件**取（见 `update_commands.sh` 的
`want`），Release 资产不参与安装流程。附源码是为了给人看 —— 离线核对、第三方审计、
以及「这一版到底包含哪些文件」有个确定的答案。

#### 漏了没人会喊：`.github/workflows/release-assets-check.yml` 会

**4.3.1 与 4.3.2 两个 Release 各有 0 个资产**（4.3.0 有 75 个）。原因是这一步零反馈：
客户端装代码走分支下的文件，一个资产为零的 Release 装起来完全正常；只有想离线核对
或做第三方审计的人才会发现「下载不到源码」，而那时已经过去好几版了。

所以加了守卫，判据是**数量与名字都要对**：

```
期望资产数 = 该 tag 下全部 .py/.sh（排除 . 开头的目录）+ 2 个归档 + 2 份签名
（4.3.3 及以前发布的版本没有签名对，守卫按 publishedAt 放行；见下一节）
```

| 触发 | 什么时候 |
| --- | --- |
| `release: published` | 发完立刻查，漏了就红 |
| 每天定时 | 网页上手工建的 Release 也能兜到 |
| `workflow_dispatch` | 可带 `tag` 只查某一个版本 |

它**只查不补**。补资产要处理撞名、比 blob 哈希、归档从 tag 建，自动补一份内容不对的
资产比缺着更难发现。手工补的办法就是本节上面那段脚本；补完再跑一次这个工作流确认。

自查任意几个版本（不需要 workflow）：

```bash
# 期望 vs 实际，逐个 tag 比
for tag in v4.3.0 v4.3.1 v4.3.2; do
    gh release view "$tag" --json assets --jq '.assets | length' \
        | xargs -I{} echo "$tag 实际 {}"
done
```

#### beta 只能在它自己的 Release 上装

`MACWAVE_VERSION` / `MACWAVE_BRANCH` 这两个环境变量是 beta 的**唯一**安装口：

```bash
MACWAVE_VERSION=4.4.0-beta2 MACWAVE_BRANCH=4.4 \
  /bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/download/v4.4.0-beta2/install.sh)"
```

`install.sh` 从发布指针（`latest.toml`）读版本号，**不从它被下载的那个 URL 读** ——
只写 tag URL、不带这两个变量，装的其实是当前正式版。`4.4.0-beta2` 的说明第一版就写
错过这一点，等于让人白装一次。

三条连带规则：

- **`latest.toml` 永远不写 beta。** 写进去所有人的常规更新都会跳上 beta。
- **beta 上 `wave selfupdate` 一律拒绝**（`lib/selfupdate.py` 与 `lib/selfupdate.sh`
  各一处，共用 `lib/versioncompare.py` 的判定）。理由是 beta 与正式版在不同分支上，
  而 selfupdate 的增量按 `latest.toml` 的分支算 —— 盖到一棵 beta 树上就是两条线
  混在一起（2026-11-15 那次 `wave` 启动即崩，就是这么来的）。
- **回稳定线也是重装**：
  `/bin/bash -c "$(curl -fsSL https://github.com/MacWaveOrg/MacWave/releases/latest/download/install.sh)"`。

写 beta 的发布说明时，安装命令必须是上面那两行带变量的形式，且明说「不带变量会装到
正式版」。

#### 签名：`SHA256SUMS` + `SHA256SUMS.asc`

> **实验性支持（4.4 起）。** 客户端侧的验签与哈希钉住已经接进 `install.sh` /
> `selfupdate.sh` / `update_commands.sh`，但**验不过只警告、不拦安装**：
> 老客户端跑的是自己那份老脚本，逼它们验签等于让它们装不上。要变强制，得先让
> 带签名对的版本铺开，再把 `MACWAVE_STRICT_HASHES` 默认打开（按客户端版本门控）。
> 现状与开关见 `Keys/description.md`。

资产传完之后再补两份文件，让**任何人**能核对「这批字节确实是 MacWave 发的」：

```bash
cd /tmp/rel && ls | grep -vE '^SHA256SUMS' | xargs shasum -a 256 > SHA256SUMS
gpg --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS
gpg --verify SHA256SUMS.asc SHA256SUMS
shasum -a 256 -c SHA256SUMS
gh release upload "$TAG" SHA256SUMS SHA256SUMS.asc -R MacWaveOrg/MacWave --clobber
```

（前一版这里把 `# Good signature` 与 `# 全部 OK` 写在同一行末尾当注释。2026-11-22
实测：有人粘进终端后 gpg 报「无法打开已签名的数据 '#'」、shasum 报「#: No such file
or directory」—— 那个 `#` 连同后面的词变成了参数。仓库里其它文档也有行尾注释的写法，
平时没事；但**一步错就白跑一遍的步骤（建 tag、传资产、签名、推指针）不要靠 shell 的
注释规则**，说明一律放正文。）

三条不能省：

- **签清单，不逐文件签。** 验一次 `SHA256SUMS.asc` 就覆盖全部资产；逐个签是 79 次
  操作、零额外收益。
- **生成清单要 `grep -v '^SHA256SUMS'`。** 第二次跑的时候它已经在目录里，把自己算进去，
  下一次 `-c` 必然失败。
- **`.asc` 要 armored。** 能直接贴进 Release 正文与 Issue，拿到的人不看文档也知道
  `gpg --verify`。
- **守卫的等待窗口是 6 分钟，不是「等多久都行」。** `release: published` 在第一个
  资产上传之前就触发，所以它重查 3 次、每次间隔 120 秒；三次之后仍不齐就判红。
  96 个文件逐个上传会超过这个窗口 —— 2026-11-22 的 4.5.0 就这样红了一次
  （重查时只到 55/98），资产其实没错，只是还没传完。两种应对：**一次传整批**
  （见上面第 2 步），或者先 `gh release create --draft`、传完再
  `gh release edit "$TAG" --draft=false`（`published` 那一刻资产已经齐了）。

公钥与指纹要发在**至少两个渠道**（仓库 `Keys/`、README、官网、Release 正文），
单渠道公布等于没公布 —— 能换资产的人通常也能换那一个渠道。

`Keys/` 里的公钥还会随安装树一起下发（列在 `scripts/assets.txt` 里，装到
`<base_dir>/Keys/`），客户端因此握着验签的信任根。轮换期间目录里可以同时有两把，
验签程序对任意一把验通即可；验签实现与结果语义见 `net/signature.py`。

守卫工作流按 `publishedAt` 判断：**2026-12-01 起发布的 Release 必须带这两份**，
更早的（含补发的旧版本）允许没有。判据是发布日期，不是 tag 号 —— 补发一个旧版本时
不该被要求补签。只有一份（缺 `.asc` 或只有 `.asc`）在任何日期都是错误：那比完全没有
更糟，用户会以为「有签名」，去验时 404。

密钥的生成、备份、轮换与格式说明见 `~/MD/密钥/`（不在仓库里，私钥相关的东西一律
不进版本控制）。

### 第 8 步：等 CI 绿 —— 两条流水线都要绿

**GitHub Actions 与 CircleCI 都成功，才算发布完成。缺一条就不算通过。**

| 流水线 | 在哪看 | 跑什么 |
| --- | --- | --- |
| GitHub Actions `Format Test` | 仓库 Actions 页 | 4 个 job（3.14 / 3.15 × `format-test` / `random-test`），macOS runner，含真实下载与端到端 |
| CircleCI `quick-feedback` | CircleCI 面板 | 纯离线那批：ruff、shellcheck、`domains` / `flags` / `depsync` / `message` / `markdown` 等 |

几条不能含糊的：

- **任一为红就停下，不要发版。** CircleCI 只跑离线的子集，定位是「一两分钟给结论」，
  但这不等于它是可选项 —— 它红说明这份代码本身有问题，不能因为 `Format Test` 绿就跳过。
- **两条都在 push 时触发**，`4.1` 与 `main` 各自都要确认，不能只看一边。
- **先确认新发布分支在被触发列表里。** 两处白名单都是显式列出来的，不是通配：
  `.github/workflows/format-test.yml` 的 `on.push.branches` / `on.pull_request.branches`，
  与 `.circleci/config.yml` 的 `workflows.quick-feedback.jobs.offline-tests.filters.branches.only`。
  漏一处两份文件里都有注释警告，但**漏了不会有任何提示** —— 推上去只是静静地没有流水线，
  CircleCI 面板上连记录都不出现。自查：

  ```bash
  grep -n 'branches: \[' .github/workflows/format-test.yml
  grep -n -A12 'only:' .circleci/config.yml
  ```

  2026-11-22 发现 4.4 与 4.5 都不在名单里，所以 4.4 全线的推送从来没跑过这两条流水线。
- CircleCI 需要 GitHub App 授权才会跑。面板上**看不到 pipeline** 本身就是问题，
  先确认触发，再说「绿」。
- 合并提交内容零变化时也应重跑一遍确认。

#### 两条覆盖的范围不同，一条绿不能替另一条

`random-test` 只在 GitHub Actions 里跑，CircleCI 没有它；CircleCI 的离线段
GitHub 也跑，但慢得多。**2026-10-31 发 4.1.5 时实测过**：提交 `668083c` 的
CircleCI 是绿的，而 GitHub 的 `random-test (3.15)` 因为一处预测错误红了。
只看一边就会把红当成绿。

#### 本机怎么查 CircleCI

装一次（1.13 起 `setup` 改成必须显式传参、且会校验 token，不再支持交互式）：

```bash
brew install circleci
circleci auth login          # 浏览器授权，不产生长期 token
```

查最近几次运行 —— **必须在仓库目录里跑**，否则它读不到 git remote 推不出项目：

```bash
cd MacWave
circleci run list --project gh/MacWaveOrg/MacWave --branch 4.1 --limit 5
```

输出里 `Status` 一列就是结论（`succeeded` / `failed` / `running`）。单个运行看细节：

```bash
circleci run get <ID>            # ID 是上面表格里那一列
circleci workflow list           # 该运行里有哪些 job
```

若改用 Personal API Token 而不是浏览器授权，**不要用 `circleci setup`**（token 会
留在 shell 历史里），直接写配置文件（`read -rs` 不回显）：

```bash
mkdir -p ~/.circleci && umask 077
read -rsp "token: " T; echo
printf 'host: https://circleci.com\ntoken: %s\n' "$T" > ~/.circleci/cli.yml
unset T && chmod 600 ~/.circleci/cli.yml
```

#### 少推送：CircleCI 额度有限

两条流水线都在 push 时触发，CircleCI 的额度是有限的。所以发版相关的推送要克制：

- **没有实质内容的改动不要单独推**：只改文档、README、注释、版本号，留在本地攒着，
  跟下一次真正改代码的提交一起推。
- **一次改动只推一次**；不要用空提交去「试探」CI 是否会跑。
- **例外**：要随 tag 交付的文件（`docs/RELEASE-*.md`、`lib/`、`pkg/` 等）必须在
  打 tag **之前**推上去 —— 文档攒着没问题，但漏推会让 tag 里缺文件（3.2.1 的 tar
  就少过两个文件，见第 7 步）。
- **纯文档推送用 `[skip ci]`**：提交信息里带这个标记，整次推送两条流水线都不跑，
  不花 CircleCI 额度。但 `sync-release-branch.yml` 同样会被跳过，`main` 不会自动
  跟上，需要手动补跑：`gh workflow run sync-release-branch.yml --repo MacWaveOrg/MacWave`。
  代码改动与发版前的提交不要带这个标记。
- 该规则只针对 MacWave 仓库，详见 [AGENTS.md](../AGENTS.md) 的「推送」一节。

---

## 三、为什么 `configdata` 必须**先**改

`sync-release-branch.yml` 的规则是：读 `configdata` 的 `branch` 拿到「发布分支」，
然后让 `main` 与该分支**互为镜像**（谁落后就快进谁）。

于是有两种顺序，结果完全不同：

| 顺序 | 发生什么 |
| --- | --- |
| **先**改 `branch` → 再合并（正确） | workflow 认为发布分支是新分支，`main` 与它内容一致，直接退出。旧分支（如 `4.0`）原地不动 |
| **先**合并 → 才发现要改（错误） | 此刻 `branch` 还指向 `4.0`，而 `main` 已领先 → workflow 把 **`4.0` 快进到 main**，旧分支被塞进新版本代码 |

第二种的后果不是灾难性的（新代码通常向后兼容），但它破坏了一个重要预期：
**旧发布分支应当停在该大版本的最后一次发布上**。`4.0` 分支里出现 4.1 的代码，
将来想从 4.0 分支取一个 4.0.x 补丁就会混乱。

注意这个 workflow **只维护 `main` 与「当前发布分支」这一对**：`configdata` 指向谁，
谁才会被同步，历史分支（`1.0.0`、`2.5`、`4.0`…）它一概不碰。所以发布后把 `branch`
切走，旧分支就自动冻结了 —— 这也是事后止血最省力的办法。

**2026-10-29 发 4.1.0 时踩过这个坑**：先合并、后改指针，`4.0` 被快进到了 `ec1fbc7`。

### 已经发生了怎么办

改写历史能把旧分支退回去，但那会抹掉提交 —— 本项目已经因为一次 force 对齐，
不得不额外补 9 个合并提交才把历史接回来。**不要再来一次。**

推荐做法是接受现状，并用 tag 标出「本应停在这里」的位置：

```bash
# annotated tag 需要两步：先建 tag 对象，再让 ref 指向它
OBJECT=$(gh api "repos/MacWaveOrg/MacWave/commits/4.0" --jq '.sha')
TAG_SHA=$(gh api --method POST repos/MacWaveOrg/MacWave/git/tags \
    -f tag="4.0-final" \
    -f message="Last content of the 4.0 line before 4.1 arrived on this branch" \
    -f object="$OBJECT" -f type=commit --jq '.sha')
gh api --method POST repos/MacWaveOrg/MacWave/git/refs \
    -f ref="refs/tags/4.0-final" -f sha="$TAG_SHA"
```

之后想从 4.0 取补丁时，以 `4.0-final` 为基准而不是分支头。

**2026-10-29 的实际情形**：`4.0` 被快进到 `ec1fbc7`（4.1 的合并提交）。
把 `configdata` 的 `branch` 改到 `4.1` 之后，`4.0` 就停在 `ec1fbc7` 不再前进。
该提交与 `v4.1.0` 内容相同，所以从 `4.0` 取补丁必须显式用 `4.0-final` 之类的
基准点，否则会连 4.1 的功能一起带走。

---

## 四、绝对不要做的三件事

### 1. 不要对 `main` 用 `force` 对齐

```bash
# ❌ 这会切断历史：被覆盖的那些提交从 main 的祖先链里消失
gh api --method PATCH repos/…/git/refs/heads/main -f sha=<别的分支> -F force=true
```

要「让 main 等于某个分支」，正确做法是**造一个合并提交**，父提交是二者：

```python
{"message": "...", "tree": <目标分支的 tree>, "parents": [<main 的头>, <分支的头>]}
```

树取自目标分支，内容零变化；两条历史却都保住了。

### 2. 不要用 `contents` API 提交 `.sh` 文件

`PUT /repos/…/contents/<path>` **不带 mode**，会把 `100755` 重置成 `100644`。
测试脚本因此变得不能直接执行 —— CI 用 `bash` 调用所以不会红，但这是个陷阱。

需要保留权限位时改用 Git Data API：

```python
{"path": "scripts/x.sh", "mode": "100755", "type": "blob", "sha": <blob>}
```

**2026-10-29 踩过**：`scripts/selfupdate_test.sh` 的可执行位就是这么丢的，靠 `144f11f` 补回。

### 3. 不要在数据仓库里靠人记着改指针

`latest.toml` 是**手写的指针**，而真正决定装哪一版的是版本目录。只加了目录、
忘了改指针，客户端就会一直装着旧版本，**而且不报错** —— 现象只是「怎么更新都没变」。

这个已经自动化：`.github/workflows/sync-data-pointers.yml`

| 触发 | 行为 |
| --- | --- |
| `push` / `pull_request` | 只检查（`--check`），不一致就让 CI 红 |
| 每天定时 / 手动 | 把 `latest.toml` 改成实际最高的版本目录并提交 |

本地也可以手动查：

```bash
python3 scripts/sync_latest_pointer.py --data-dir <Selfupdate 检出> \
    --subdir macwavedata --require update_commands.sh --check
```

---

## 五、一个已知的数据坑：上游替换同名资产

`ldid` 的 `procursus` / `procursus1` / `procursus2` 三个版本，索引里的 `sha256`
与上游**同名的资产**不一致 —— 上游在发布后用同样的文件名重新上传了不同字节。

排查方法：把上游字节下回来算一遍，与索引记录比对。

```python
# 通过 API 下载（github.com 被墙时 objects.githubusercontent.com 也不通，
# 只有 api.github.com 可用，所以要带 Accept: application/octet-stream）
gh api -H "Accept: application/octet-stream" \
    repos/<owner>/<repo>/releases/assets/<asset-id> > /tmp/f
shasum -a 256 /tmp/f
```

两种处理方式：

| 情况 | 处理 |
| --- | --- |
| 旧字节已无法取回，且该版本从未成功发布过 | 更新索引的 `sha256` 为上游现值，然后发布 |
| 该版本已经有人装过（存储里有旧字节） | **不要**改索引，否则已装用户与索引对不上；改为发新版本号 |

**2026-10-29 处理**：`ldid` 在 `Bottle` 里从来没有发布过（早期同步把它 `--skip` 了），
所以旧字节无人持有，直接更新索引 6 条记录的 `sha256` 是安全的。

---

## 六、发完之后要同步镜像

镜像站不会自己变。产物与清单都要重新拉：

```bash
# 1) 更新索引检出（否则 sha256 还是旧值，同步会校验失败）
cd /opt/macwaveorg/infosource && git pull --ff-only

# 2) 拉产物
cd /opt/macwaveorg/MacWave && python3 scripts/sync_payloads.py \
    --infosource /opt/macwaveorg/infosource \
    --out /www/wwwroot/mirror.repohub.top/MacWave \
    --only <包名> --source payload

# 3) 重新生成版本清单 —— 少了这步，镜像里有的包也「查不到」
python3 scripts/build_versions_index.py \
    --infosource /opt/macwaveorg/infosource \
    --mirror /www/wwwroot/mirror.repohub.top/MacWave

# 4) 把清单同步到对外目录（写入的是 /opt/…，对外服务的是 /www/…，两者不是同一个目录）
rsync -a --chown=www:www --chmod=D755,F644 \
    --include='*/' --include='versions' --exclude='*' \
    /opt/macwaveorg/infosource/ \
    /www/wwwroot/mirror.repohub.top/MacWave/infosource/
```

第 3 步最容易漏：`build_versions_index.py` **只登记镜像里真实存在的产物**，
产物没同步就不会出现在清单里；清单生成了没 rsync，对外又看不到。

### 5) 冒烟：按清单逐条打分

产物齐了不等于客户端能装。客户端是**照着 `update_commands.sh` 里的 `want` 清单
一个一个下载**的，任何一个路径不是 200，整个更新就失败。2026-11-24 发 4.6.0 时，
镜像上 360 个文件全在，但 `info/LICENSE` 被 nginx 的「敏感文件」规则挡成 404
（见 [MIRROR-SETUP 第五步](MIRROR-SETUP.md#宝塔的敏感文件规则会误杀-core-树)），
用户在最后一个文件上失败，日志看着却像「镜像没同步」。

所以发完镜像必须拿清单当靶子打一遍（替换成实际的版本与站点凭据）：

```bash
cd /opt/macwaveorg/MacWave
python3 scripts/build_update_commands.py --version 4.6.0 --branch 4.6 \
    --ref 4.6 --out /tmp/uc.sh
grep -E '^[[:space:]]*want[[:space:]]' /tmp/uc.sh | awk '{print $2}' | sort -u > /tmp/mf.txt

while read -r p; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$MIRROR_USER:$MIRROR_PASS" \
        "https://mirror.repohub.top/MacWave/core/4.6/$p")
    [ "$code" = 200 ] || echo "  ✗ $code $p"
done < /tmp/mf.txt
```

一条都不打印才算过。`grep` 里那个 `^[[:space:]]*want` 不能省：生成脚本的**注释**里
也有一行 `want <仓库内路径> …` 作为格式说明，漏了就白得三条假 404。

有条件的话再补一次真实客户端冒烟（另一个 `MACWAVE_BASE_DIR` 或另一台机器）：
`wave selfupdate` 走到最后并打印新版本号。

---

## 七、一句话版本

```
先改 configdata 的 branch → 合并要 merge 不要 force → 生成 update_commands.sh
→ 改 Selfupdate 的 latest.toml → 官网与 Release → 建 tag → 等 CI
→ 镜像：pull 索引 / 拉产物 / 生成清单 / rsync 清单 / 按清单逐条打分
```

安全版本额外两条：**标题按档位加 `[Urgent security update 紧急安全更新]` 或
`[Security update 安全更新]`**、**正文带可复现的对照数据**（见第 7 步）。
