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
| `MacWaveOrg/Pages` 的 `index.html` | 人 | 官网显示的版本号与安装说明 |

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
318F1457
└┬┘│└─┬─┘
 │ │  └── 发布时刻 HHMM（24 小时制）
 │ └───── 周几的字母：周一=A、周二=B、周三=C、周四=D、周五=E、周六=F、周日=G
 └─────── 当天的「年内第几天」，3 位补零（01-01 → 001，12-31 → 365 或 366）
```

例：2026-11-14 是周六、年内第 318 天，14:52 发布 → `318F1457`。

取当前值一行命令（别手算，闰年与周边界都是坑）：

```bash
printf '%s%s%s\n' "$(date +%j)" "$(date +%u | tr '1-7' 'ABCDEFG')" "$(date +%H%M)"
```

三条容易错的地方：

- **第四位是周几，不是「第几次构建」。** 4.3.3 之前所有构建号第四位都是 `A`
  （`295A2033`、`300A1345`、`307A1409`、`313A1704`……），多数与真实周几不符 ——
  这条规则以前没被实现过。**历史号不回改**：它只是个标识，改了反而让旧发布说明、
  `Selfupdate/<版本>/` 目录与 tag 对不上。
- **`HHMM` 只用于区分同一天内的多次发布**，不参与任何版本比较。客户端比的是
  `version`（PEP 440，4.4 起由 `lib/versioncmp.py` 统一实现），构建号只显示给人看。
- **三处必须写同一个值**：`configdata/versiondata/latest_version`、
  `Selfupdate/macwavedata/latest.toml`、发布说明头部「发布日期 · 构建号」那一行。

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

### 第 5 步：更新 `Selfupdate` 的 `latest.toml`

```toml
version = "<新版本>"
release_date = "YYYY-MM-DD"
build_number = "<构建号，算法见一点六>"
branch = "<新分支>"
```

### 第 6 步：更新官网版本号与 Release 正文

- `Pages/index.html`：中英两处版本号
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
for f in /tmp/rel/*; do gh release upload "$TAG" "$f" -R MacWaveOrg/MacWave --clobber; done

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
  不报错、资产数少一也不明显。已知两处：
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

#### 签名：`SHA256SUMS` + `SHA256SUMS.asc`

资产传完之后再补两份文件，让**任何人**能核对「这批字节确实是 MacWave 发的」：

```bash
cd /tmp/rel && ls | grep -vE '^SHA256SUMS' | xargs shasum -a 256 > SHA256SUMS
gpg --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS
gpg --verify SHA256SUMS.asc SHA256SUMS     # Good signature
shasum -a 256 -c SHA256SUMS                # 全部 OK
gh release upload "$TAG" SHA256SUMS SHA256SUMS.asc -R MacWaveOrg/MacWave --clobber
```

三条不能省：

- **签清单，不逐文件签。** 验一次 `SHA256SUMS.asc` 就覆盖全部资产；逐个签是 79 次
  操作、零额外收益。
- **生成清单要 `grep -v '^SHA256SUMS'`。** 第二次跑的时候它已经在目录里，把自己算进去，
  下一次 `-c` 必然失败。
- **`.asc` 要 armored。** 能直接贴进 Release 正文与 Issue，拿到的人不看文档也知道
  `gpg --verify`。

公钥与指纹要发在**至少两个渠道**（仓库 `keys/`、README、官网、Release 正文），
单渠道公布等于没公布 —— 能换资产的人通常也能换那一个渠道。

守卫工作流按 `publishedAt` 判断：**2026-11-15 起发布的 Release 必须带这两份**，
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

---

## 七、一句话版本

```
先改 configdata 的 branch → 合并要 merge 不要 force → 生成 update_commands.sh
→ 改 Selfupdate 的 latest.toml → 官网与 Release → 建 tag → 等 CI
→ 镜像：pull 索引 / 拉产物 / 生成清单 / rsync 清单
```

安全版本额外两条：**标题按档位加 `[Urgent security update 紧急安全更新]` 或
`[Security update 安全更新]`**、**正文带可复现的对照数据**（见第 7 步）。
