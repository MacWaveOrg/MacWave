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

## 二、正确的发布顺序

### 第 1 步：在版本分支上完成功能与文档

```bash
git switch -c 4.1          # 从 main 切出，保证历史连续
# ……开发、跑测试……
```

分支名用 `大版本.次版本`（`4.1`、`3.2`），因为 `configdata` 的 `branch` 字段要引用它。

### 第 2 步：**先改 `configdata` 的 `branch`，再合并到 main**

这一步的顺序是最容易搞错的，见第三节。

```bash
# configdata/versiondata/latest_version
version: "<新版本>"
build_number: "<构建号>"
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
python3 scripts/build_update_commands.py \
    --version <新版本> \
    --branch <新分支> \
    --out /tmp/update_commands.sh
```

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
build_number = "<构建号>"
branch = "<新分支>"
```

### 第 6 步：更新官网版本号与 Release 正文

- `Pages/index.html`：中英两处版本号
- GitHub Release：正文用 `docs/RELEASE-<版本>.md`

### 第 7 步：建 Tag 与 Release

```bash
gh api --method POST repos/MacWaveOrg/MacWave/git/refs \
  -f ref="refs/tags/v<版本>" -f sha="<main 的提交>"
gh release create v<版本> --repo MacWaveOrg/MacWave --title "MacWave <版本>" --notes-file docs/RELEASE-<版本>.md
```

先建 tag 再建 Release。`--target-commitish` 只在 tag 不存在时有效，
tag 已存在却仍传 `--target` 会报 `Release.target_commitish is invalid`。

#### Release 上必须附全部源码

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
# 应等于 py/sh 文件数 + 2（4.1.0 是 46 + 2 = 48）
```

四个容易踩的点：

- **文件名会撞。** `.Pseudocode/pkg/pkginstaller.py` 与 `pkg/pkginstaller.py` 同名，扁平化后只剩一个。
  所以第 1 步要 `grep -v '^\.'` —— 那个目录只是早期伪代码，本来就不该出现在资产里。
- **`gh release upload` 必须带 `--clobber`。** 否则重跑报 422。
- **macOS 上打归档要加 `--no-xattrs`。** 不加时 bsdtar 会把扩展属性写进 pax 头，Linux 解包多出 `._*`。
  打完务必解包 `diff -r` 一遍，确认与原树逐文件一致。
- **归档要从 tag 建，不要从工作副本建。** 3.2.1 的 tar 就比 tag 少两个文件
  （`sync-payloads.yml`、`RELEASE-3.2.2.md`），是 tag 之后又改过导致的不一致。

为什么还要附这些：4.x 的自更新已经改成从**分支下的文件**取（见 `update_commands.sh` 的
`want`），Release 资产不参与安装流程。附源码是为了给人看 —— 离线核对、第三方审计、
以及「这一版到底包含哪些文件」有个确定的答案。

### 第 8 步：等 CI 绿

`Format Test` 的 4 个 job 全绿才算发布完成。合并提交内容零变化时也应重跑一遍确认。

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
