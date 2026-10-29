# 搭建 MacWave 镜像站（宝塔 + 香港轻量服务器）

面向国内用户。**为什么要做镜像**：从大陆访问 `github.com` 极不稳定 —— 实测连测三次，两次在 20 秒内连 TCP 都没建立；同一时刻国内镜像站 37~78 ms 就返回了。MacWave 的产物又偏大（pandoc 40 MB、ollama 172.9 MB），这种链路基本下不完。

## 整体链路

```
上游（jqlang/jq、conda-forge…）
   │  ① GitHub Actions 抓取（Runner 就在 GitHub 机房内，不受大陆出口影响）
   ▼
MacWaveOrg/Bottle · Releases      每个包一个 tag，资产名 <包名>@<版本>.<架构><扩展名>
   │  ② 香港服务器同步（国际链路，正常）
   ▼
mirror.repohub.top/MacWave       宝塔 + nginx，纯静态文件树
   │  ③ 大陆用户下载（20~50 ms）
   ▼
用户机器
```

三段的职责不能混：**抓上游只在 Actions 里做**，香港只负责「复制 + 服务」，用户的机器只读镜像。

## 为什么根目录是 `MacWave/` 而不是整个域名

域名顶层留给别的产品。LinuxWave 很可能也要镜像站，那时它用 `mirror.repohub.top/LinuxWave`，
两套互不干扰：

```
/www/wwwroot/mirror.repohub.top/
├── MacWave/          ← 本项目
│   ├── bottle/
│   ├── deps/
│   └── selfupdate/
└── LinuxWave/        ← 预留，现在不用创建
```

`LinuxWave/` 只是**预留位置**，知道有这回事即可，本文任何一步都不需要建它。将来 LinuxWave
要镜像时，它用 `mirror.repohub.top/LinuxWave`，与这里互不干扰。

所以本文所有路径都带 `MacWave/` 这一层，环境变量的值也要带上。
**注意大小写**：目录名是 `MacWave`，首字母大写，与仓库名一致。Linux 上无所谓，但保持一致省得以后混。

## 前置条件

| 项 | 说明 |
| --- | --- |
| 服务器 | 香港轻量应用服务器，1 核 1G 起，**30 Mbps 峰值带宽**，Ubuntu 22.04 / Debian 12 |
| 域名 | 一条 A 记录指向服务器公网 IP |
| 备案 | **不需要**。备案只针对中国大陆境内的服务器 |
| SSL | 宝塔里用 Let's Encrypt 免费申请 |

**不要买大陆节点**：那需要 ICP 备案，而备案要求域名在工信部批复的注册服务机构注册 —— 在 NameSilo 这类海外注册商注册的域名通常过不了。

**带宽是重点**。轻量服务器标的都是峰值带宽：

| 带宽 | 实际速度 | 下 ollama（172.9 MB） |
| --- | --- | --- |
| 5 Mbps | ~0.6 MB/s | 约 5 分钟 |
| 30 Mbps | ~3.7 MB/s | 约 47 秒 |

另外留意月流量包（通常 1 TB）。那是给**用户下载**算的，超出会限速或另计费。

## 第一步：服务器与宝塔

购买后记下**公网 IP** 和 root 密码，SSH 登录，按宝塔官网给出的对应系统命令安装面板。

装完先做三件安全事：

1. 面板设置里改掉默认端口 8888（该端口被全网扫描）；
2. 开启「面板 SSL」；
3. 软件商店只装 **Nginx**，**不装 PHP、不建数据库** —— 镜像站没有任何后端逻辑，少一个攻击面。

## 第二步：DNS

加一条 A 记录：

```
mirror.repohub.top    A    <服务器公网 IP>
```

生效判断：`ping mirror.repohub.top` 返回的正是那个 IP。**必须在下一步之前生效**，否则 SSL 申请会失败。

## 第三步：建站

宝塔 → 网站 → 添加站点：

| 项 | 值 |
| --- | --- |
| 域名 | `mirror.repohub.top` |
| 根目录 | `/www/wwwroot/mirror.repohub.top`（站点根；MacWave 的数据在它下面的 `MacWave/`） |
| PHP 版本 | **纯静态** |
| 数据库 | 不创建 |

## 第四步：放入文件

最终必须是这个结构：

```
/www/wwwroot/mirror.repohub.top/
└── MacWave/
    ├── bottle/
    │   └── jq/
    │       └── jq@1.7.1.arm64
    └── deps/
        └── libidn2/
            └── libidn2@2.3.7.arm64.tar.gz
```

**这一步最容易出错**：很多压缩工具会在外面多包一层目录，解出来变成 `.../mirror/bottle/...`，于是 URL 里凭空多出 `/mirror`，全部 404。

检查方法：

```bash
ls /www/wwwroot/mirror.repohub.top/MacWave/
# 必须直接看到 bottle 和 deps，不能再多一层 MacWave/MacWave/
```

文件怎么来，两种方式：

**方式 A（推荐，从 GitHub Releases 拉）**

在服务器上执行，它按索引里的清单逐个下载并校验 sha256：

```bash
git clone --depth 1 https://github.com/MacWaveOrg/MacWave /tmp/macwave-src
git clone --depth 1 https://github.com/MacWaveOrg/infosource /tmp/infosource

python3 /tmp/macwave-src/scripts/sync_payloads.py \
  --infosource /tmp/infosource \
  --out /www/wwwroot/mirror.repohub.top/MacWave \
  --source payload \
  --jobs 6
```

`--source payload` 表示「从我们自己的 Release 取」而不是打扰上游。首次全量约 1.5 GB，之后重复运行只补新增（已存在且校验通过的文件会跳过）。

**方式 B（少量文件）**：从 Release 页面手动下载附件，用宝塔「文件」上传。

## 第五步：nginx 缓存头

文件永不覆盖（要改就发新的版本后缀，例如 `1.7.1-1`），所以可以放心让客户端长期缓存。

宝塔 → 网站 → 设置 → 配置文件，在 `server { }` 内加入：

```nginx
# 文件名里带 @（URL 中是 %40），nginx 会自动解码，这里只加缓存头
location ~ @ {
    add_header Cache-Control "public, max-age=31536000, immutable";
}

location ~* \.(tar\.gz|tgz|zip|tar\.bz2|tar\.xz|conda)$ {
    add_header Cache-Control "public, max-age=31536000, immutable";
}
```

改完在宝塔里重载 nginx。

## 第六步：SSL

宝塔 → 网站 → 设置 → SSL → Let's Encrypt，申请后打开「强制 HTTPS」。

## 第七步：验证

浏览器直接打开（注意 `@` 在 URL 里写作 `%40`）：

```
https://mirror.repohub.top/MacWave/bottle/jq/jq%401.7.1.arm64
```

能下载就说明镜像站可用。再量一下速度：

```bash
curl -o /dev/null -w '速度 %{speed_download} B/s\n' \
  https://mirror.repohub.top/MacWave/bottle/jq/jq%401.7.1.arm64
```

同时确认校验值没被中间环节改坏：

```bash
curl -fsSL https://mirror.repohub.top/MacWave/bottle/jq/jq%401.7.1.arm64 | shasum -a 256
# 与 infosource 里 _jq@1.7.1 的 sha256 应当逐字相同
```

## 第八步：首次安装就走镜像

前面几节假设 MacWave 已经装好了。但首次安装时用户还没有 `~/.zshrc` 里的那几行，所以要把变量
写在**同一条命令的前面**：

```bash
MACWAVE_CORE_DOMAIN=https://mirror.repohub.top/MacWave/core \
MACWAVE_SELFUPDATE_DOMAIN=https://mirror.repohub.top/MacWave/selfupdate \
MACWAVE_PYTHON_DOMAIN=https://mirror.repohub.top/MacWave/python \
/bin/bash -c "$(curl -fsSL https://mirror.repohub.top/MacWave/core/lib/install.sh)"
```

这里出现了另外两个变量，含义与前面不同：

| 变量 | 取什么 | 镜像要承载 |
| --- | --- | --- |
| `MACWAVE_CORE_DOMAIN` | MacWave 自身的代码（`lib/`、`pkg/`、`surfboard/`） | `<根>/MacWave/core/<分支>/…` |
| `MACWAVE_PYTHON_DOMAIN` | 自带 CPython（独立仓库） | `<根>/MacWave/python/pythondata/…` |

`core/` 的形状有个坑：客户端按 **`<CORE_DOMAIN>/<分支>/<路径>`** 取文件
（`BASE_URL="$CORE_URL/$BRANCH"`），所以分支名必须是一层真实目录：

```
MacWave/core/4.0/lib/wave.py        ← 正确
MacWave/core/lib/wave.py            ← 错误，缺了分支这一层，会 404
```

在镜像服务器上按分支铺：

```bash
for branch in 4.0 3.2; do
  git clone --depth 1 --branch "$branch" https://github.com/MacWaveOrg/MacWave \
    "/www/wwwroot/mirror.repohub.top/MacWave/core/$branch"
  rm -rf "/www/wwwroot/mirror.repohub.top/MacWave/core/$branch/.git"
done
```

⚠️ 但这里有个现实问题：**MacWave 自身的代码更新频率高**，而 `core/` 是 git 克隆的副本，
不会自动跟着走。镜像它意味着你要定期重新拉取，否则用户拿到的是旧代码。

**所以我的建议是：`core` 保持官方地址，不去镜像它。** 它只有几百 KB、只在下
载 MacWave 本身时请求一次，不是慢的主要来源——真正大的是 `bottle` 的几十到几百 MB。
绝大多数用户只需要镜像 `bottle` 和 `deps`。

## 第九步：让已装好的 MacWave 用它

已经装好、只是下载慢的情况。三行写进 `~/.zshrc`：

```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.repohub.top/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.repohub.top/MacWave/deps
export MACWAVE_SELFUPDATE_DOMAIN=https://mirror.repohub.top/MacWave/selfupdate
```

写进 `~/.zshrc` 长期生效，然后 `source ~/.zshrc`。

前两个变量的值里带 `/bottle` 与 `/deps`，因为镜像根目录下就是这两棵子树。想再镜像自更新数据的话，把 `MacWaveOrg/Selfupdate` 的内容放到 `.../selfupdate/`，第三个变量才需要设。

验证真的走了镜像：

```bash
curl -sI "$MACWAVE_BOTTLE_DOMAIN/jq/jq%401.8.2.arm64" | head -1
# 期望 HTTP/2 200
wave install jq
```

## 第十步：切回官方地址

**用户迟早会问这个。** 两种方式，效果不同：

| 方式 | 命令 | 何时失效 |
| --- | --- | --- |
| **改配置（推荐）** | 从 `~/.zshrc` 删掉那几行 `export`，再 `source ~/.zshrc` | 永久 |
| **临时关掉** | `unset MACWAVE_BOTTLE_DOMAIN MACWAVE_DEPS_DOMAIN MACWAVE_SELFUPDATE_DOMAIN` | 只影响当前终端，新开窗口又回来 |

确认已切回：

```bash
echo "${MACWAVE_BOTTLE_DOMAIN:-(未设置 → 用官方地址)}"
```

**一个变量都不设 = 与 3.x 完全相同的地址。** 这就是默认值仍指向官方源的原因：不设就是原样。

**可以只镜像一部分。** 三个变量互相独立，没设的那个继续用官方地址。例如只镜像二进制、自更新仍走官方：

```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.repohub.top/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.repohub.top/MacWave/deps
# 不设 MACWAVE_SELFUPDATE_DOMAIN
```

## 哪些操作受这些变量影响

| 操作 | 受镜像变量影响 | 说明 |
| --- | --- | --- |
| `wave install <包>` | ✅ | 二进制走 `BOTTLE` / `DEPS` |
| `wave upgrade <包>` | ✅ | 同上 |
| `wave selfupdate` | ✅ | 版本数据与文件清单走 `SELFUPDATE` |
| `wave search` / `wave info` | ⚠️ 部分 | 索引走 `API`；但「列版本」目前仍走 `api.github.com` |
| `curl … install.sh` 首次安装 | ❌ | 除非按第十步把变量写在命令前 |
| `git clone` 源码 | ❌ | git 不认这些变量 |

最后一行最容易误会：**`MACWAVE_*_DOMAIN` 只管 MacWave 自己发的请求**，管不到 `git` 和 `curl` 的下载。

## 可选的第三块：自更新数据与解释器

这两块不是二进制，体积很小（解释器归档除外，每架构约 26 MB），直接从仓库复制即可：

```bash
git clone --depth 1 https://github.com/MacWaveOrg/Selfupdate \
  /www/wwwroot/mirror.repohub.top/MacWave/selfupdate
rm -rf /www/wwwroot/mirror.repohub.top/MacWave/selfupdate/.git

git clone --depth 1 https://github.com/MacWaveOrg/Python \
  /www/wwwroot/mirror.repohub.top/MacWave/python
rm -rf /www/wwwroot/mirror.repohub.top/MacWave/python/.git
```

目录形状与每类数据的确切规则见 [DATA-LAYER.md](DATA-LAYER.md)。

## 让服务器自己盯着（日常巡检）

镜像站是外部依赖：它坏了不会有任何人主动告诉你。用户那边只会看到「下载失败」，
多半也不会来反馈 —— 等你发现时可能已经坏了一周。

所以装一个每天跑一次的体检。三个文件，都放服务器 `/root/mirror-check/`，
源文件在仓库 [scripts/mirror-check/](../scripts/mirror-check/)：

| 文件 | 作用 |
| --- | --- |
| `check.sh` | 体检本体，只读。退出码 = 失败项数，0 表示全绿 |
| `run.sh` | cron 包装：跑 `check.sh` → 记一行到 `history.log`（留 120 行）→ 失败建 `ALERT`、通过删 `ALERT` |
| `install.sh` | 落地：`chmod +x`、写 cron 行、立刻试跑一次 |

```bash
# Mac 上（ControlPath 指向已有的 ssh 连接，一轮只输一次密码）
rsync -a -e "ssh -o ControlPath=$HOME/.ssh/cm-lw" \
  scripts/mirror-check/ root@<服务器>:/root/mirror-check/

# 服务器上
bash /root/mirror-check/install.sh
```

装完 cron 里多一行，每天 04:17 跑。**时间刻意不取整点**，避开全网都在打 GitHub 的时刻。

### 它查什么

| 段 | 内容 | 为什么必须查 |
| --- | --- | --- |
| 0 | 三棵树各自的文件数下限（886 / 69 / 30） | 目录被清空时，「有文件」类断言会**全部真空真** |
| 1 | 六个公开页与图片 200 | 页面 401 或 404 都意味着首页打不开 |
| 2 | 数据目录无凭据 401 | 公开可下 = 镜像被白嫖 |
| 3–4 | 两边账号交叉访问（各自 200、对方 401） | 隔离失效时最容易出的事故 |
| 5 | 两边 `realm` 必须不同 | realm 相同会导致浏览器把一方的凭据发给另一方 |
| 6 | 8 种路径归一化绕过（大小写、`//`、`./`、`%57`、`%2F`…） | 写错一条就是免费下载 |
| 7 | 三个真实产物的 `content-length` 与磁盘一致 | 挡「200 但内容是 404 页」这种空壳 |

### 怎么读结果

```bash
tail -5  /root/mirror-check/history.log   # 最近几次的结论
cat      /root/mirror-check/last-run.log  # 本次完整输出
ls       /root/mirror-check/ALERT         # 存在 = 当前有故障
```

`rc` 就是失败项数。**没有邮件通道** —— 服务器没装 MTA，`mail` 必然失败，所以报警只落在
`ALERT` 文件里。要真正「有人知道」，得靠外部监控盯这个文件，或者自己每天看一眼 `history.log`。

### 写这类脚本的五个坑（都踩过）

| 坑 | 后果 | 做法 |
| --- | --- | --- |
| `find … \| sort \| head -1` 配 `set -o pipefail` | `head` 读完一行就退出，`sort` 继续写吃 SIGPIPE，管道返回 141。**输出有值但函数返回非零** —— 大目录（886 个文件、路径约 62 KB，正好塞满管道）必失败，小目录（69 个）正常，极难查 | 先全量捕获再在 bash 里取首行：`all=$(… \| sort); all=${all%%$'\n'*}` |
| 挑靶子挑到点文件 | nginx 的 `location ~ /\.` 在认证**之前**返回 404，断言「应 401」必然假红 | 排除含点段的路径；客户端本来就不取这类文件 |
| 挑靶子挑到目录 | 目录请求返回 404 而不是 401，同样假红 | 只挑 `-type f` |
| 空目录静默通过 | 目录被清空时检查全绿 | 先断言数量下限 |
| 报完不销账 | 一次故障后 `ALERT` 永远存在，之后就没人看了 | 失败建、通过删，**双向** |

另外两条与 bash 3.2 有关，写任何服务器脚本都要注意：变量紧贴中文必须写 `${var}`（否则
locale 会把中文首字节吃进变量名）；`"${ARR[@]}"` 在空数组上会报 unbound，改用单一变量。

## 常见问题

**404，但文件确实在。** 按顺序查这三条：

1. 目录是不是多套了一层（`MacWave/MacWave/bottle`）：
   `ls /www/wwwroot/mirror.repohub.top/MacWave/` 应当直接列出 `bottle`、`deps`；
2. 环境变量是不是漏了 `MacWave`：
   要写 `https://mirror.repohub.top/MacWave/bottle`，不是 `https://mirror.repohub.top/bottle`；
3. 环境变量是不是又漏了 `bottle` / `deps` 后缀（客户端只往后再接 `/<包名>/<文件名>`）。

**`@` 到底要不要编码。** 两种形式 nginx 都接受：`jq%401.7.1.arm64` 与 `jq@1.7.1.arm64` 指向同一个文件。客户端拼地址时会编码（与 GitHub 给出的规范地址一致）。

**下载是 200 但内容是 404 页面。** 宝塔的「伪静态」或默认站点配置接管了请求。镜像站不需要任何 rewrite 规则，把伪静态设为「无」。

**速度慢。** 先确认带宽档位（5 Mbps 与 30 Mbps 差 6 倍）；再看是不是撞上月流量包上限被限速了。

**服务器要同步很久。** 首次全量 1.5 GB。`sync_payloads.py` 可以重复运行，中断后再跑会从已完成的继续（同名同校验值的直接跳过）。
