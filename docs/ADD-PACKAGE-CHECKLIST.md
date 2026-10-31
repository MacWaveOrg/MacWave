# 添加软件包检查清单

这份文档只讲一件事：**把一个新软件包加进 MacWave 时按什么顺序做、每步怎么验**。
每一条都对应一次真实踩过的坑，写在「为什么」里。

配套文档：[RELEASE-CHECKLIST.md](./RELEASE-CHECKLIST.md)（发版本）、
[CI-AND-PITFALLS.md](./CI-AND-PITFALLS.md)（CI 的坑）。

---

## 零、先认清一件事：一个软件包同时存在于五个地方

加包出问题，十次有九次是这五处之一漏了或写岔了。

| # | 位置 | 谁读它 | 漏了的后果 |
| --- | --- | --- | --- |
| 1 | `infosource/pkg/pkginfo_{arm64,amd64}/<包名>/` | `wave install` / `search` / `info` | 装不上，或装到一半 404 |
| 2 | **Bottle 仓库的 Release（tag = 包名）** | `wave install` 的下载步骤 | 索引有记录但下不到文件 |
| 3 | `infosource/README.md` 的 Supported Packages | 人 | 说明与事实不符 |
| 4 | **`MacWave/README.md` + `README.zh-Hans.md`** | 人 | 同上，中英各一份 |
| 5 | **`Pages/index.html`（macwave.org）** | 人 | 官网清单少一个包 |

第 3、4、5 处是**同一份清单的三个副本**，格式一字不差。改就要三处一起改，
下面第 6 步给了自动核对的办法。

> 这三份副本是同形的，所以它们**必然**会一起落后 —— 4.1.4 发布时官网还停在
> 24 个包，而索引里已经有 33 个。谁也没错，只是没人记得改。

---

## 一、选哪些版本

**规则：最近三个大版本，各取最后一个小版本。**

```
delta      0.18.2  0.19.2  0.20.1     ← 三条线各一个
atuin      18.22.0 18.23.0 18.24.4
hyperfine  1.20.0  1.21.0  2.0.0
```

不是「最近三个发布」，也不是「全都收」。理由：同一个大版本内的小版本互相兼容，
用户通常只需要最新那个；而跨大版本时行为可能变（`hyperfine 1.x → 2.0`），
留旧的一条线给人退路就够了。全收会让索引里堆几十条没人装的记录。

### 为什么不选 zip

（本清单只写规则。）

---

## 二、动手前必须确认的三件事

### 1. `bin_name` == 用户在终端敲的命令

`bin_name` 决定 `bin/` 与 `links/` 下的目录名，也决定用户敲什么。

| 情况 | 做法 | 先例 |
| --- | --- | --- |
| 上游产物名就是命令名 | 照抄 | 大多数包 |
| 上游产物名带后缀（`choma_cli`） | 用**用户敲的那个词** | `choma` |
| 上游项目名与命令名不同 | **包名也改成命令名** | `sk`（项目叫 skim） |

最后一条的依据是 `rg`：包名与二进制名一致（`ripgrep` 的包名就是 `rg`）。

```bash
# 加完包之后，一次核对全部，不该有任何输出
python3 - <<'PY'
import re, pathlib
root = pathlib.Path("pkg/pkginfo_arm64")
for d in sorted(p for p in root.iterdir() if p.is_dir()):
    common = d / f"_{d.name}@common"
    if not common.exists():
        continue
    m = re.search(r'^bin_name:\s*"([^"]*)"', common.read_text(), re.M)
    if m and m.group(1) != d.name:
        print(f"{d.name}: bin_name = {m.group(1)}")
PY
```

### 2. 上游给不给 sha256

curl 上游 Release 的 `digest` 字段或 `sha256sums.txt`：

| 情况 | 做法 |
| --- | --- |
| 上游有官方 digest | 直接用 |
| 上游没有 | 先用全零占位，再让 Runner 算（见第 3 步的 `probe_sha`） |

**本地不要下载产物算哈希。** 本机连不上 `raw.githubusercontent.com`，而且
26 MB × 几十个包的流量没必要。

### 3. 这个包有没有依赖

需要动态库的包要在 `deps` 字段登记，否则装完跑不起来。`deps` 写在**版本记录**里
（不是 `@common`），格式是引号包起来的多行列表：

```
deps: "
    libfoo@1.2.3"
```

---

## 三、正确的顺序

### 第 1 步：查清上游的下载地址

每个版本记录需要 `url`（`https://` 开头）与 `file`（上游原始文件名）。

```bash
gh release view <tag> -R <owner>/<repo> --json assets \
  --jq '.assets[] | "\(.name)\t\(.size)\t\(.digest // "-")"'
```

只认**公开 GitHub Release** 的产物。其他来源（自建站点、私有仓库）都不行 ——
`Sync payloads` 的定时任务只能跟进 GitHub Release。

确认文件名里带架构标记（`arm64`/`aarch64`、`amd64`/`x86_64`），且**两个架构各有一个
明确的产物**。通用二进制（universal）与命名含糊的一律按人工处理，不要猜。

### 第 2 步：写索引记录

```
infosource/pkg/pkginfo_arm64/<包名>/_<包名>@common
infosource/pkg/pkginfo_arm64/<包名>/_<包名>@<版本>
infosource/pkg/pkginfo_amd64/<包名>/_<包名>@common
infosource/pkg/pkginfo_amd64/<包名>/_<包名>@<版本>
```

`_<包名>@common`（两个架构各一份）：

```
des: "A syntax-highlighting pager for git, diff, grep, rg --json, and blame output"
hom: "https://dandavison.github.io/delta/"
lic: "MIT"
aut: "dandavison"
bin_name: "delta"
```

`_<包名>@<版本>`：

```
sha256: "<64 位小写十六进制>"
file: "delta-0.20.1-aarch64-apple-darwin.tar.gz"
url: "https://github.com/dandavison/delta/releases/download/0.20.1/delta-0.20.1-aarch64-apple-darwin.tar.gz"
```

要点：

- `aut` 写**上游作者**，会原样出现在四份清单里
- 上游没有官方 digest 时，`sha256` 先写 64 个 `0`，第 3 步会把它换掉
- 不要留空字段，也不要省略 `bin_name`

### 第 3 步：在 GitHub Runner 上补齐 sha256

本地算哈希不可行（见第二节第 2 点）。用 workflow 当探针：

```
Actions → Sync payloads → Run workflow
  kinds          = bottle
  only           = <包名>            ← 只跑这一个，别全量
  publish        = false             ← 先只校验，不上传
  infosource_ref = <你推记录的分支>   ← 记录还在分支上时用这个
  probe_sha      = true              ← 只对全零占位有效
```

日志里会出现：

```
PROBE delta|0.20.1|arm64 bc1839cea69288d4673a24faffbb825d408ca907e0f7d33b1678c9e6cdd5e58e
```

把值回填进 `_<包名>@<版本>`，然后重跑一次（`probe_sha=false`、`publish=false`）
确认不再报校验失败。

> `probe_sha` 只处理 `sha256` 全为零的记录。已经有非零值的记录它一句都不说 ——
> 想让某个包重算，先把那一位改成 0。

### 第 4 步：发布产物到 Bottle 并逐字节回读

```
Actions → Sync payloads → Run workflow
  kinds          = bottle
  only           = <包名>
  publish        = true
  infosource_ref = <分支>
```

产物的形状是固定的（由 `lib/domains.py` 决定，别自己拼）：

```
Bottle Release tag  = <包名>
资产名              = <包名>@<版本>.<架构><扩展名>      例：delta@0.20.1.arm64.tar.gz
```

回读校验，**三个架构的文件都要对得上**：

```bash
PKG=delta
for asset in $(gh release view "$PKG" -R MacWaveOrg/Bottle --json assets --jq '.assets[].name'); do
  printf '%-40s ' "$asset"
  echo "$asset" | grep -q "@" && echo "ok"
done
gh release view "$PKG" -R MacWaveOrg/Bottle --json assets --jq '.assets[].size'
```

包名改过名时（`skim` → `sk`）：新建一个 tag = 新包名的 Release。
**旧的不要删** —— 已经装了旧名的用户还要靠它卸载。

### 第 5 步：在真实客户端上装一次

索引与产物都对，不代表装得上。至少验证两条：

```bash
wave install <包名>            # 装得上
<命令> --version               # 跑得起来（依赖齐不齐在这一步暴露）
wave uninstall <包名>          # 卸得掉，不带版本号的链接被清掉
```

有条件时两个架构都过一遍。**只测 arm64 是本机方便，不是覆盖**。

### 第 6 步：把包加到四份清单（包含官网）

**这一步最容易漏，因为它不在 `infosource` 里。**

四份副本，格式完全相同，`<包名>` 左对齐 + `by <作者>`：

```
atuin            by atuinsh
bat              by David Peter
```

| 文件 | 位置 |
| --- | --- |
| `infosource/README.md` | `# 🌊 Supported Packages` → `(Listed in alphabetical order)` 之后的代码块 |
| `MacWave/README.md` | `## 🌊 Supported Packages` → `(Listed in alphabetical order)` 之后 |
| `MacWave/README.zh-Hans.md` | `## 🌊 支持的软件包` → `（按字母顺序排列）` 之后 |
| **`Pages/index.html`** | `id="supported"` 一节里 `Supported Packages</h2>` 之后的 `<pre>` |

不要手打。从左对齐的码块里删掉多余空格、重新对齐很费神，而且四处对不齐就看不出来。
用索引生成，再写进四个文件：

```bash
cd ~/Projects/MacWaveOrg/infosource
python3 - <<'PY'
import re, pathlib

# 已被官网简化过的署名保持简洁，不要让元数据的长串覆盖它
SIMPLE = {"jq": "Stephen Dolan, Nicolas Williams, et al.",
          "tree": "Steve Baker, Thomas Moore, et al."}

root = pathlib.Path("pkg/pkginfo_arm64")     # arm64 与 amd64 的包集合应当相同
rows = []
for d in sorted(p for p in root.iterdir() if p.is_dir()):
    if d.name.startswith("test_"):           # 测试包不进清单
        continue
    aut = ""
    common = d / f"_{d.name}@common"
    if common.exists():
        m = re.search(r'^aut:\s*"([^"]*)"', common.read_text(), re.M)
        if m:
            aut = m.group(1)
    rows.append((d.name, SIMPLE.get(d.name, aut)))

width = max(len(n) for n, _ in rows) + 2
print("\n".join(f"{n:<{width}}by {a}" for n, a in rows))
PY
```

把输出整段替换进四个文件的代码块，然后核对 —— **四份必须逐行相同**：

```bash
cd ~/Projects/MacWaveOrg
python3 - <<'PY'
import pathlib

def block(path, marker):
    s = pathlib.Path(path).read_text()
    i = s.index(marker)
    if path.endswith(".html"):
        start, end = s.index("<pre>", i) + 5, s.index("</pre>", s.index("<pre>", i) + 5)
    else:
        start = s.index("```\n", i) + 4
        end = s.index("```", start)
    return [l for l in s[start:end].strip().splitlines() if l.strip()]

files = [("MacWave/README.md", "(Listed in alphabetical order)"),
         ("MacWave/README.zh-Hans.md", "（按字母顺序排列）"),
         ("infosource/README.md", "(Listed in alphabetical order)"),
         ("Pages/index.html", "Supported Packages</h2>")]

lists = {f: block(f, m) for f, m in files}
ref_name, ref = next(iter(lists.items()))
for name, got in lists.items():
    print(f"{name:<30} {len(got):>2} 行  {'一致' if got == ref else '不一致 ← 与 ' + ref_name}")
PY
```

再确认清单与索引的**集合**相等（不只是行数）：

```bash
cd ~/Projects/MacWaveOrg
python3 - <<'PY'
import pathlib

html = pathlib.Path("Pages/index.html").read_text()
i = html.index("Supported Packages</h2>")
start = html.index("<pre>", i) + 5
site = [l.split()[0] for l in html[start:html.index("</pre>", start)].strip().splitlines() if l.strip()]
real = sorted(p.name for p in pathlib.Path("infosource/pkg/pkginfo_arm64").iterdir()
              if p.is_dir() and not p.name.startswith("test_"))
print("清单缺:", [x for x in real if x not in site])
print("清单多:", [x for x in site if x not in real])
print("按字母序:", site == sorted(site))
PY
```

### 第 7 步：推送与部署

```bash
# 索引 + 它的 README
cd ~/Projects/MacWaveOrg/infosource && git add -A && git commit -m "Add <包名>" && git push origin main

# MacWave 的两份 README
cd ~/Projects/MacWaveOrg/MacWave && git add README.md README.zh-Hans.md && git commit -m "List <包名>" && git push origin <分支>

# 官网：推上去就自动部署（build_type: legacy，无需手动）
cd ~/Projects/MacWaveOrg/Pages && git add index.html && git commit -m "List <包名>" && git push origin main
```

`macwave.org` 是 GitHub Pages，推送后自动构建，约 1～3 分钟。确认：

```bash
gh api repos/MacWaveOrg/Pages/pages --jq .status     # 等到 built
curl -s https://macwave.org/ | grep -c "<包名>"
```

**`mirror.repohub.top` 不一样**：它是自有服务器，没有自动部署，要自己同步
（见 `docs/MIRROR-SETUP.md`）。镜像不同步时，用镜像的用户装不到新包 ——
索引更新了、产物也发了，但只要镜像没拉，那边的 `wave install` 就找不到记录。

---

## 四、绝对不要做的四件事

### 1. 不要本地打包产物

`sync_payloads.py` 是**字节原样搬运**。自己重新打包会改变字节，
`sha256` 与索引立刻不一致，客户端会拒绝安装（这是对的）。

### 2. 不要用 `contents` API 提交记录

`PUT /repos/…/contents/<path>` 不带 mode，会把 `100755` 重置成 `100644`。
脚本类的包会因此丢可执行位。用 Git Data API，或本地 `git push`。

### 3. 不要把测试包留进清单

`infosource` 里有 `test_001`、`test_bin_*`、`test_no_sha256`、`test_wrong_sha256`
这些**故意存在**的测试记录（`test_wrong_sha256` 的哈希就该是错的）。
它们必须留在索引里（测试要用），但**绝不能出现在四份 Supported Packages 清单里**。
第 6 步的生成脚本已经用 `startswith("test_")` 排除。

### 4. 不要在索引里写 `http://`

`url` 必须是 `https://`。客户端会拒绝明文 http（回环地址除外）。

---

## 五、一次加多个包时

用户一次要六个工具是常态。做法完全一样，只是 `only` 收逗号列表：

```
only = delta,atuin,starship,hyperfine,fx,sk
```

但**`probe_sha` 阶段不要合并**：一条记录算错就得重跑全部。先一次探完（反正只打印），
回填后分开验（`publish=true` 时按包拆开跑，某个包失败不连累其他）。

### 关于「最近三个大版本」的实操

上游 tag 往往比预想的多。先列全再挑：

```bash
gh release list -R <owner>/<repo> --limit 40 --json tagName,publishedAt,isPrerelease \
  --jq '.[] | select(.isPrerelease == false) | "\(.tagName)\t\(.publishedAt[0:10])"'
```

- 跳过 prerelease / rc / beta
- 同一大版本里只留**最新**那个小版本（`0.18.2` 而不是 `0.18.0`）
- 三条线各一个，不多不少

---

## 六、收尾

```bash
# 索引里的记录数与产物数应当对得上
ls ~/Projects/MacWaveOrg/infosource/pkg/pkginfo_arm64 | grep -vc "^test_"
gh release list -R MacWaveOrg/Bottle --limit 100 | wc -l
```

再确认一次第 2 步的 `bin_name` 审计没有输出 —— 加包时最容易顺手把
`bin_name` 写成上游产物名。
