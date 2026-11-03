# gh-pages 前史：2026-08-05 至 10-07

`gh-pages` 分支已从本仓库删除，站点迁到独立的 `Pages` 仓库，**不会再有新提交**。
但它的 **292 个提交**一个都没丢：完整历史保存在归档仓库
`MacWaveOrg/legacy-MacWave` 的 `gh-pages` 分支里（"Archived read-only snapshot of
MacWave before the 3.0 repository split"）。

这份文档把它串成一条线，理由有三：一是这段历史埋着 `wave.py` 与 `repo.json` 两个
至今仍在用的东西的祖先；二是它解释了一件容易被误读的事——`main` 上的网站历史看起来
断了，其实是**分叉后只继承了删除的那一半**；三是它记录过 `macOS 10.15` 这个结论，
后来被主动删除，2026-11 实测又重新证明了一次。

## 一、这条线本来就是直线

"极乱"指的是提交内容，不是 git 拓扑。全量实测：

| 指标 | 值 |
| --- | --- |
| 提交总数 | **292** |
| merge 提交 | **0** |
| 分叉点 | 无（在 gh-pages 自身这条线上） |
| 时间跨度 | 08-05 → 10-07（约 2 个月，34 个活跃日） |
| 作者 | 1 人（`Sha0huaZhang`） |
| 根提交 | `e7e2ad0` Initial commit |

乱在三个地方：提交消息没有信息量（`Update index.html` 独占 110 次）、文件反复
Create/Delete、以及两套并存的冗余路径。

## 二、怎么查

本仓库远端有六个 tag 锚点，`git clone` 后直接可用（对象已随 tag 推入）：

| tag | 提交 | 日期 | 事件 |
| --- | --- | --- | --- |
| `ghpages/1-skeleton` | `6c4d8c9` | 08-05 | 骨架日，同日打 `v1.0.0-beta1` |
| `ghpages/2-visual` | `3ced61e` | 08-12 | 页面与 logo 成型 |
| `ghpages/3-domain` | `711ea8f` | 08-16 | `macwave.org` 落地、安装入口三级跳 |
| `ghpages/4-fork` | `43f0073` | 08-28 | **分叉点**，站点最后一次大改 |
| `ghpages/5-darwin14` | `5f7b1b9` | 09-13 | 声明 `10.15` → `Sonoma 14` |
| `ghpages/6-final` | `d83b0bb` | 10-07 | 终点，站点更新到 MacWave 2.6.1 |

```bash
git log --oneline ghpages/6-final          # 292 个提交，全在这一条线上
git log --graph --decorate \
  --simplify-by-decoration ghpages/6-final # 只看六幕边界
```

`6c4d8c9` 上另有远端存在的 lightweight tag `v1.0.0-beta1`（08-05 21:43）。第一幕的
终点就是项目第一个 beta。

## 三、六幕

### ① 骨架日 · 08-05 · 33 提交

一天之内把骨架搭完，顺序就是后来的架构：

| 提交 | 产出 |
| --- | --- |
| `e7e2ad0` | Initial commit |
| — | `README.md` |
| `5b065eb` | `repo.json` —— 包索引雏形，含 `test_001` / 1.0.0 |
| `ef5afc8` | `install.sh` —— 安装脚本第 1 版 |
| `78cb2e4` | `docs/index.html` —— 站点最初在子目录 |
| `ce8d44e` | `wave.py` —— 客户端雏形，头部写着 `Version: 1.0.0` |
| `6c4d8c9` | 当日收尾，打上 `v1.0.0-beta1` |

### ② 视觉与上线 · 08-06~08-12 · 140 提交

08-07 单日 **79 个提交**，基本不是开发：

- `index.html` 改了 27 次
- `Add files via upload` 14 次 —— 网页拖拽上传图片
- `IMG_3199.jpeg → logo2.jpg` 改名 5 次，`IMG_3194.jpeg → logo1.jpg` 3 次
- `Delete logo.jpg` / `logo1` / `logo2` —— 推倒重来

`a388920`（08-07）建出根 `index.html`，从此与 `docs/index.html` 并存到谢幕。
`f3bd89e`（08-07）建出 `test_text.txt`，内容一行 `11` —— 验证 Pages 部署的探针。

### ③ 域名落地 · 08-11~08-16 · 约 50 提交

- `a565e69`（08-11）`Create CNAME`，内容 `macwave.org`
- 同一天 `Create` / `Delete CNAME` 交替 **15 次**（8 组）—— 域名从没变过，这是在
  GitHub Pages 设置界面反复点「Add custom domain」留下的
- `b5a4fca`（08-11）新增 "Supported macOS Version"：**`macOS 10.15 Catalina and above`**
- `4d62011`（08-16）`Rename install-5.sh to install.sh` —— 安装脚本试到第 5 版，
  中间还有一次 `Delete install.sh`
- 08-16 安装入口三级跳，正好是三个实施阶段：

```
raw.githubusercontent.com/Sha0huaZhang/MacWave/main/install.sh   →  直连仓库
github.com/.../releases/download/latest/install.sh               →  借 Release 当 CDN
macwave.org/install.sh                                           →  自有域名
```

### ④ 打磨与分叉 · 08-21~08-28

`fb517e6`（08-24）`Refactor index.html for mobile compatibility` 起，连续 31 个
`index.html` 提交全是打磨。页面行数一路长：322（08-07）→ 546（08-11）→ 587（08-16）
→ 614（08-23）→ 652（08-28）。

**08-28 12:27（`43f0073`）是分叉点**，站点最后一次大改。此后分成两条线：

| 线 | 提交数 | 走向 |
| --- | --- | --- |
| **A：清空** | 3 | 12:31 删 `wave.py` → 13:05 删 `docs/` → 13:06 删 `index.html` 与 `repo/` |
| **B：续命** | 61 | 08-31 起继续维护站点，一直更新到 10-07 的 2.6.1 |

A 线后来并入 `main`，同日下午 14:22 就开始建 `cli/`、`versionparser.py`、
`pkgparser.rb`、`help.py` —— 白天放弃网站，下午转向包管理器内核。

**这解释了 `main` 上网站历史为何看起来断了**：`main` 只继承了 A 线那 3 个删除提交
（`main` 里 `54bcf61` 是祖先），B 线那 61 个站点提交只存在于 `legacy-MacWave` 的
`gh-pages` 分支上。

### ⑤ 硬门槛抬高 · 09-13

`5f7b1b9`（09-13 09:30）只改了一行，但影响最大：

```diff
-            macOS 10.15 Catalina and above
+            macOS Sonoma 14 and above
```

（详见下一节。）

### ⑥ 终点 · 09-22 ~ 10-07 · 53 提交

09-22 起提交密度回升（当日 13 个），站点跟着 2.x 版本走，版本号从 1.0.0 推到 2.4，
最后 `d83b0bb`（10-07 20:43）"Update the site to MacWave 2.6.1"。

次日（10-08）`legacy-MacWave` 归档仓库建立，分支连同 47 个 tag 一并冻结。

## 四、`macOS 10.15` 的来路与消失

| 时间 | 事件 |
| --- | --- |
| 08-11 | `b5a4fca` 建立声明：`macOS 10.15 Catalina and above` |
| 08-11 ~ 09-13 | 保持 **33 天**，期间 `index.html` 被改上百次，这一行一字未动 |
| **09-13 09:30** | `5f7b1b9` 改成 `macOS Sonoma 14 and above`（一行改动） |
| 09-13 ~ 10-07 | 一直是 14，终点 2.6.1 站点写的就是 `Sonoma 14 and above` |

所以它不是"换站时丢的"，而是**被主动抬高的**。那个提交的消息只有 `Update index.html`，
没有说明理由；从时间点看，它落在 MacWave 2.x 开发期，最可能是跟着捆绑 Python 或
系统 API 的需求一起抬上去的——但这一条**只是推测，提交里没有依据**。

2026-11 的实测反而支持最初那个 10.15：x86_64 捆绑 Python 全树 `minos 10.15`、arm64
是 `11.0`；一台 2015 年的 MacBookAir 7,2（macOS 12.7.6 / CLT 14.2）完整跑通安装与
Mach-O 重定位。所以 **Intel 的理论地板是 10.15，实测下限是 12.7.6**，而站点从
09-13 起对外说的是 Sonoma 14+，偏保守了三代。

这件事引出包级元数据的缺口：索引记录目前只有 `sha256` / `file` / `url` / `deps` 与
`@common` 的 `des` / `hom` / `lic` / `aut` / `bin_name`，**没有任何 macOS 版本声明**，
所以无法在安装前告诉用户「这个包要求 15.0，你现在是 12.7.6」。实测本机 140 个产物的
`minos` 跨度是 11.0 到 15.0（`pandoc@3.13` 是 15.0），确实有区分度。

## 五、两条遗产

都被埋在 08-05 那天，后来都活着：

| 遗产 | 当时 | 现在 |
| --- | --- | --- |
| `wave.py` | 雏形 `Version: 1.0.0`；被删时已长到 **1237 行** | [`lib/wave.py`](../lib/wave.py)，306 行，重写后的 |
| `repo.json` | `packages: [{name: test_001, version: 1.0.0, releases: [{os, arch, ...}]}]` | `infosource` 的 `pkg/pkginfo_*/` 的直系祖先 |

那 1237 行没有一行进到今天的代码里，是两次不同的实现。但架构判断留下来了：
客户端要有入口、独立解析器、独立安装器、独立帮助模块。

## 六、乱在哪（全量量化）

| 现象 | 数量 |
| --- | --- |
| 过半提交都在动一个文件 | `index.html` 151 次 / 292 |
| 无信息量的消息 | `Update index.html` 110 次、`更新 index.html` 18 次、`Add files via upload` 21 次 |
| Create/Delete 反复 | `CNAME` 15 次、`logo*.jpg` 33 次 |
| 两套并存 | `docs/index.html` vs `index.html`；`repo/repo.json` vs `repo.json` |
| 试版残留 | `install.sh` ~ `install-5.sh`、`repo-5.json` |
| 当天建当天删 | `logo1.jpg`、`logo3.jpg`、`repo/repo.json` |

按修改次数排序：

| 路径 | 次数 |
| --- | --- |
| `index.html` | 151 |
| `README.md` | 20 |
| `wave.py` | 18 |
| `logo2.jpg` | 15 |
| `CNAME` | 15 |
| `install.sh` | 12 |
| `repo/repo.json` | 9 |
| `logo1.jpg` | 9 |

## 七、归档仓库怎么用

`legacy-MacWave` 是 3.0 分仓前的完整只读快照，除 `gh-pages` 外还留着
`1.0.0` / `1.1.0-beta` / `2.0.0-beta` / `2.0.0-dev` / `2.1.0` / `2.2.0` / `2.3` /
`2.4` / `2.5` / `3.0` / `configdata` / `infosource` / `main` 共 14 个分支与 47 个 tag。
查这段历史不必克隆它——本仓库的 `ghpages/*` tag 已经把这 292 个提交对象带过来了。
需要看分支原貌时再取：

```bash
git remote add legacy https://github.com/MacWaveOrg/legacy-MacWave.git
git fetch legacy gh-pages
git log --oneline legacy/gh-pages
```

## 八、一句话

**292 个提交、2 个月、一个人。从 `Initial commit` 到 `v1.0.0-beta1` 用了一天；
从 beta 到放弃网站用了 23 天；从放弃网站到重建内核用了 76 分钟；而那条被放弃的站点
线又自己活了 40 天，一直更到 2.6.1。**
