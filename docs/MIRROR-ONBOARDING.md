# 把新产品接到镜像站上（以 LinuxWave 为例）

这份文档给要接入 `mirror.repohub.top` 的**另一个产品**用。
它只讲「镜像站这一侧要准备什么、你的客户端要遵守什么」，不重复 MacWave 的内部实现。

MacWave 自己的存储层契约见 [DATA-LAYER.md](./DATA-LAYER.md)。

---

## 一、镜像站的目录约定

同一个站点下，**每个产品一层目录**，与 MacWave 平级：

```
mirror.repohub.top/
├── index.html                  产品选择页（公开）
├── macwave.html                MacWave 页面（公开，含账号获取方式）
├── images/                     站点图片（公开）
│   ├── mascot.png  macwave.png  linuxwave.png  oclp.png
└── MacWave/                    数据（basic auth）
    ├── core/4.0/…
    ├── selfupdate/…
    ├── infosource/…
    ├── bottle/…
    ├── deps/…
    └── python/…
└── LinuxWave/                  数据（同样 basic auth）
    ├── core/…
    ├── selfupdate/…
    ├── infosource/…
    └── bottle/…
```

**为什么产品名要大写开头**：与 `MacWave` 保持一致，URL 一眼能看出层级。
目录名一经公布就不要再改 —— 用户 `~/.zshrc` 里写的是完整地址。

### 现在就能建的空骨架

```bash
BASE=/www/wwwroot/mirror.repohub.top/LinuxWave
mkdir -p "$BASE"/{core,selfupdate,infosource,bottle,deps}
chown -R www:www "$BASE"
chmod -R 755 "$BASE"
```

`auth_basic` 已在 `server` 级生效，所以新建目录**自动需要密码**，不用改 nginx。
（前提：不要在这些目录里放 `auth_basic off`。）

---

## 二、客户端要遵守的四条

### 1. 用自己的变量前缀

```
LINUXWAVE_API_DOMAIN
LINUXWAVE_SELFUPDATE_DOMAIN
LINUXWAVE_BOTTLE_DOMAIN
LINUXWAVE_DEPS_DOMAIN
LINUXWAVE_CORE_DOMAIN
LINUXWAVE_PIP_INDEX        （若也用 pip）
```

**不要复用 `MACWAVE_*`**：两个产品可能装在同一台机器上，共用前缀会让它们互相干扰，
而且用户无法只给其中一个换镜像。

### 2. 地址一律是「前缀 + 纯文件路径」

镜像站只会 `rsync` + `nginx`，不理解任何协议：

| 可以 | 不可以 |
| --- | --- |
| `GET <域名>/bottle/<包>/<文件>` | OCI registry（要先换 token、按 digest 取） |
| 静态 `versions` 清单（一行一条） | 需要服务端计算的 API |
| HTTP Basic Auth | 自定义签名头、动态 token |

MacWave 4.0 之所以从 GHCR 改回 Releases，就是因为这一点（见 DATA-LAYER 第一节）。

### 3. 版本指针必须是**可被 CI 校验的纯文本**

MacWave 的做法：

```
selfupdate/<产品>data/latest.toml     version = "4.1.0" 等
infosource/pkg/pkginfo_<架构>/versions          一行一个包名
infosource/pkg/pkginfo_<架构>/<包名>/versions    一行一条版本记录
```

因为「指针」是手写的、而真正决定装哪一版的是**版本目录**，两者一旦不同步，
客户端就会一直装旧版本**且不报错**。MacWave 用
`scripts/sync_latest_pointer.py` + 一个定时 workflow 守着这件事，建议照做。

### 4. 密码不要出现在日志里

凡是打印地址的地方都要脱敏。MacWave 的规则：

- 默认把 `user:pass@` 里的密码换成**固定 6 个星号**（不随长度变化，否则泄露长度）
- 需要明文时用显式旗标（`--show-password`）
- 有凭据时不要去 `urllib`/`requests` 的默认日志路径（它们会把完整 URL 打进异常）

---

## 三、索引与产物的形状（可直接照抄）

### 3.1 产物命名

```
<包名>@<版本>.<架构><扩展名>
例：jq@1.8.2.arm64.tar.gz
```

架构取值**不能照抄 mac 的**：Linux 要区分 glibc / musl，可能是
`x86_64-gnu`、`aarch64-musl` 之类。这一层自己定，但要固定下来 ——
文件名就是 URL，改了等于全部失效。

### 3.2 索引记录

```
infosource/pkg/pkginfo_<架构>/<包名>/<包名>@<版本>
```

内容：

```
sha256: "<64 位小写十六进制>"
file: "<上游文件名>"                # 只用来取扩展名
url: "<上游地址>"                   # 保留供追溯，客户端默认不读
deps: "<依赖>"                      # 可选，多行
```

`<包名>@common` 放与该版本无关的元信息（描述、许可证、`bin_name` 等）。

### 3.3 版本清单（镜像自备）

```
pkg/pkginfo_<架构>/versions              一行一个包名
pkg/pkginfo_<架构>/<包名>/versions        一行一条版本记录文件名
```

**只列镜像里真实存在的产物**。索引里有记录但产物没同步时，若仍写进清单，
用户会解析出一个装不上的版本，直到下载阶段才 404 —— 报错位置离原因太远。

---

## 三点五、LinuxWave 已经落地的形态（实测，可直接对照）

这一节记录 2026-10-29 实际做出来的样子，后面的产品照这个抄就行。

### 存放仓库

与 MacWave 完全同构：**资产放 Release，不放仓库文件**（git 单文件 100 MiB 上限）。

| 仓库 | Release 数 | 资产数 | 体积 |
| --- | --- | --- | --- |
| `LinuxWaveOrg/Bottle` | 23 | 69 | 493.3 MB |
| `LinuxWaveOrg/Deps` | 15 | 30 | 93.6 MB |

```
tag    = 包名
资产名 = <包名>@<版本>.<架构><扩展名>
```

### 扩展名不统一，这是重点

`infosource` 里 99 条记录的实际格式分布：

| 后缀 | 条数 | 说明 |
| --- | --- | --- |
| `.tar.bz2` | 38 | conda 归档为主 |
| `.tar.gz` | 35 | GitHub Release 上游 |
| `.conda` | 14 | conda-forge 新格式 |
| `.zip` | 4 | |
| **无扩展名** | 8 | 裸可执行文件：`jq-linux-amd64`、`yq_linux_arm64` 等 |

所以 `file` 字段是**必需**的：只看 `url` 无法判断 `ldid_linux_x86_64` 是压缩包还是裸二进制。
判断扩展名要用与客户端**同一份**后缀表，别自己拍脑袋 —— 漏掉 `.conda` 会让 14 个包
的落盘名少一截，解压器选错。

### 上游来源与可达性

99 条里 45 个来自 GitHub Release、52 个来自 conda（`repo.continuum.io` / `conda.anaconda.org`）、
2 个来自第三方（`ffmpeg.martin-riedl.de`）。

从**国内机器**实测：

| 主机 | 直连 |
| --- | --- |
| `github.com`、`raw.githubusercontent.com` | ❌ 连不上 |
| `conda.anaconda.org`、`repo.continuum.io` | ✅ 可下 |
| `ffmpeg.martin-riedl.de` | ❌ 传输中被重置 |

GitHub 那 45 个走 `gh api -H "Accept: application/octet-stream"` 取，实测下载后 sha256
与索引一致。第三方那个只能在有代理的机器上取。

### 镜像站上完整的一棵树

```
/www/wwwroot/mirror.repohub.top/LinuxWave/
├── bottle/<包名>/<包名>@<版本>.<架构><扩展名>            69 个   ← 产物
├── deps/<包名>/<包名>@<版本>.<架构><扩展名>              30 个   ← 依赖产物
├── infosource/                                          311 个  ← 索引 + 生成的版本清单
│   ├── pkg/pkginfo_<架构>/versions                        一行一个包名
│   ├── pkg/pkginfo_<架构>/<包名>/versions                 一行一条版本记录名
│   ├── pkg/pkginfo_<架构>/<包名>/_<包名>@<版本>
│   ├── pkg/pkginfo_<架构>/<包名>/_<包名>@common
│   └── deps/depsinfo_<架构>/<依赖>/…
├── core/3.1/                                             87 个  ← 当前发布线
├── core/main/                                            87 个  ← HEAD 安装
└── selfupdate/                                           21 个  ← = configdata 全量
    ├── versiondata/{latest_version,files_info,latest_test_version}
    ├── pythondata/latest_python
    └── updatedata/<版本>/{dir_structure_change,transfer_commands}
```

合计 **506 个文件 / 4.0 MB**（不含产物），全量与本地逐字节对账通过。

四条对齐客户端拼接规则的细节：

- **`core` 必须按分支铺目录**：`install.sh` 是 `BASE_URL="$CORE_URL/$BRANCH"`，分支名是一层真实目录。
  `BRANCH` 取自 `versiondata/latest_version` 的 `branch` 字段，所以**换发布线就等于换目录名** ——
  3.1 与 main 都要有，否则切分支那一刻 404。
- **`selfupdate` 与 `python` 可以指同一个目录**：客户端这两个默认值本来就都指 `configdata`，
  一棵树同时满足 `versiondata/` 与 `pythondata/`，不必镜像两份。
- **版本清单必须带 `_包名@` 前缀**。客户端是 `fname.split("@")[1]` 取版本号、并跳过 `@common`，
  所以写 `0.26.1` 会解析失败，必须写 `_bat@0.26.1`。
- **`deps` 侧不需要清单**：`depsinstaller.py` 只按明确的 `_{依赖}@{版本}` 取，没有任何列举调用。
  只有 `pkg` 侧要生成 `versions`。

### 六个变量里只有四个现在真的起作用

这是查客户端代码得出的（2026-10-29，`main` = `f108eca`），**照抄时别假设全部生效**：

| 变量 | `install.sh` | `selfupdate.sh` | `selfupdate.py` | 生效 |
| --- | --- | --- | --- | --- |
| `LINUXWAVE_API_DOMAIN` | ✓ | ✓ | | ✅ |
| `LINUXWAVE_CORE_DOMAIN` | ✓ | ✓ | | ✅ |
| `LINUXWAVE_SELFUPDATE_DOMAIN` | ✓ | ✓ | ✓ | ✅ |
| `LINUXWAVE_PYTHON_DOMAIN` | ✓ | ✓ | | ✅ |
| `LINUXWAVE_BOTTLE_DOMAIN` | — | — | — | ❌ 已定义未接线 |
| `LINUXWAVE_DEPS_DOMAIN` | — | — | — | ❌ 已定义未接线 |

原因：`lib/domains.py` 的 `resolve_payload()`（决定「从哪取、文件叫什么」）**没有调用方**，
`pkg/pkginstaller.py:602→641` 仍然读索引的 `url` 直连上游。所以镜像的 588 MB 产物
在这个接线完成之前不会被任何客户端取用。已提 `LinuxWaveOrg/LinuxWave#3` 记录此状态。

**给自己的提醒**：接到新产品时，别只看「变量在 `domains.py` 里定义了」就写进页面 ——
要 grep 一遍调用点。定义与生效是两件事。

### 灌数据的流程（可复现）

1. 拉 `infosource`，解析每条记录的 `sha256` / `url`；
2. 按来源分流：GitHub 走 `gh api`，conda 走 `curl`；
3. 每个文件下完立刻比对索引里的 `sha256`，不一致就丢弃并记账；
4. 以 `<包名>@<版本>.<架构><扩展名>` 命名，推进 `Bottle` / `Deps` 的 Release；
5. 上传后再从远端回读抽样校验，确认字节没被中间环节改坏；
6. 按同样的树铺到镜像站，服务器端再跑一遍全量 sha256。

**每一步都校验，且都留可重跑的命令** —— 588 MB 传一半断掉是常态。

### 四个已踩过的坑

| 坑 | 症状 | 处理 |
| --- | --- | --- |
| 记录名 `_tree@2.2.1` 已含包名，再拼 `<包名>@` 得到 `tree@tree@2.2.1.arm64` | 71 个文件全错名 | 资产名一律用 `记录名.架构+后缀`，不要重复拼包名 |
| macOS 自带 `openrsync` 不支持 `--chown`，`bash 3.2` 在 UTF-8 locale 下 `$var` 紧贴中文会吞字节 | `arch?: unbound variable`、`RSYNC_CHOWN[@]: unbound variable` | `--chown` 先探测再决定；变量一律写 `${var}`；空数组不要直接展开 |
| `while read` 循环里调用 `ssh` 不加重定向 | ssh 抢走循环的 stdin，**循环静默地只跑第一轮**（21 条抽样只报了 1 条就说「完成」） | `ssh -n` 或 `</dev/null`；这类「只做了一半还报成功」的故障比报错更难发现 |
| 把需要本地文件的脚本用 `ssh host 'bash -s' < script` 执行 | 脚本跑到服务器上，找不到本地文件，还试图 ssh 回自己 → `Host key verification failed` | 需要**本地**文件的脚本用 `bash script`；只有纯粹的服务器端操作才用 `bash -s` |

---

## 四、接入步骤

### 第 1 步：镜像站建目录

见第一节。

### 第 2 步：准备数据

把产物放进 `LinuxWave/bottle/<包名>/<文件名>`，
索引放进 `LinuxWave/infosource/…`，
自更新数据放进 `LinuxWave/selfupdate/…`。

**不需要**通知 MacWave 那边 —— 两个产品互不读取对方的目录。

### 第 3 步：页面

新建 `linuxwave.html`（可复制 [macwave.html](https://mirror.repohub.top/macwave.html)
的结构）：输入账号密码 → 生成可粘贴的 `export` 命令。

三点要注意：

- 口令要做**百分号编码**再拼进 URL（否则密码里的 `"` `$` 空格会破坏 shell 语法）
- 每行写全地址，不要用 `$B` 前缀变量 —— 这样任意一行能单独替换
- 命令写成 `cat >> ~/.zshrc <<'EOF'` 的形式，写进去才长期生效

### 第 4 步：放行页面文件

`auth_basic` 在 `server` 级，所以顶层静态文件需要单独放行。现有规则已经覆盖了
顶层 `.html` / `.png` / `.css` / `.js` / `.svg` / `.ico` / `.webp`：

```nginx
location ~ ^/[^/]+[.](?:html|png|css|js|svg|ico|webp)$ {
    auth_basic off;
}
```

图片放在站点根目录的 `images/` 下（不是 `LinuxWave/` 里面），就自动公开。

### 第 5 步：在首页加卡片

`index.html` 里把 LinuxWave 那张卡的「未上线，敬请期待」改成链接：

```html
<a class="card" href="./linuxwave.html">
  <img class="icon" src="./images/linuxwave.png" alt="" width="44" height="44">
  <span class="text">
    <span class="name">LinuxWave</span>
    <span class="desc">Linux 包管理器</span>
  </span>
  <span class="badge ok">可用</span>
</a>
```

---

## 五、验收清单

```bash
# 1) 目录需要密码（401），页面不需要（200）
curl -so /dev/null -w '%{http_code}\n' https://mirror.repohub.top/LinuxWave/
curl -so /dev/null -w '%{http_code}\n' https://mirror.repohub.top/linuxwave.html

# 2) 带凭据能取到数据（200）
curl -so /dev/null -w '%{http_code}\n' -u USER:PASS \
  https://mirror.repohub.top/LinuxWave/selfupdate/latest.toml

# 3) 产物字节与索引一致 —— 唯一能证明「原样搬运」的检查
curl -fsSL -u USER:PASS \
  https://mirror.repohub.top/LinuxWave/bottle/<包名>/<文件> | shasum -a 256

# 4) 用镜像装一次
LINUXWAVE_SELFUPDATE_DOMAIN=... LINUXWAVE_BOTTLE_DOMAIN=... \
  <你的安装命令>
```

---

## 六、不建议复用的部分

| 项 | 原因 |
| --- | --- |
| 架构取值表 | macOS `arm64`/`amd64`；Linux 还要分 glibc/musl |
| 解压器分发 | MacWave 按扩展名走 `pkgunzip.sh`；Linux 要按 `deb`/`rpm`/`AppImage` 另写 |
| 目录结构与迁移逻辑 | `update_commands.sh` 里的迁移段落必须按自己的历史写 |
| 变量名 | 必须换前缀 |
| 自带运行时的形式 | 若不自带就不需要 `python_url.toml` 那一块 |

---

## 七点五、账号编号约定

认证方式是**每个产品一份 nginx `auth_basic` 用户文件**，各产品的账号只在自己那份里，
文件名靠用户名分段来区分「这个账号属于谁」。

| 产品 | 用户名 | 现状 |
| --- | --- | --- |
| MacWave | `REPOHUBUSER1`、`REPOHUBUSER2`、`REPOHUBUSER3` | 已启用 |
| LinuxWave | `REPOHUBUSER10001` 起 | 已启用（10001–10003） |
| （以后的产品） | `REPOHUBUSER20001` 起 | 预留 |

### 为什么分段

| 做法 | 问题 |
| --- | --- |
| 所有产品共用 `REPOHUBUSER1` | 一个产品泄露的账号可以取到另一个产品的数据；也无法单独吊销 |
| 各产品从 1 开始各自编号 | `REPOHUBUSER1` 会重复，文件里只能留一个 |
| ❌ 用同一批账号 | 同上，且无法按产品停用 |

分段编号让「吊销 LinuxWave 全部账号」不影响 MacWave，反之亦然。

### 建账号

```bash
HTPASSWD=/www/server/nginx/conf/macwave.htpasswd

# LinuxWave 第一个账号
user=REPOHUBUSER10001
# 严格 24 位：openssl + cut 偶尔只出 23 位（base64 尾部填充被 tr 删掉），改用 secrets
pass="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')"

htpasswd -b "$HTPASSWD" "$user" "$pass"
printf '%s  %s\n' "$user" "$pass" >> /root/macwave-passwords.txt
chmod 600 /root/macwave-passwords.txt

echo "$user  $pass"
```

几点：

- **不要加 `-c`**。`-c` 会**新建并清空**文件，把 MacWave 现有账号一起抹掉。
  文件已存在时只用 `-b` 追加；要改某个账号的口令，同样用 `-b`（同名覆盖）。
- 哈希算法用默认值即可：Linux 的 `httpd-tools` 写 `$2y$`（bcrypt），
  macOS 自带的写法是 `$apr1$`，**nginx 两种都认**。不要用 `-p`（明文）。
- 口令生成不要用 `openssl rand -base64 18 | cut -c1-24` —— `tr` 删掉 `/+` 后
  偶尔只剩 23 位。用上面那条 `secrets` 命令可稳定得到 24 位。
- nginx **不需要 reload**：`auth_basic_user_file` 每次请求都会重新读文件。
- 明文统一记在 `/root/macwave-passwords.txt`（`chmod 600`），发信时从这里取。

### 密码明文存放

每个账号一个文件，文件名就是编号，便于按账号单独发送、单独作废：

```
~/LinuxWaveMirror/password/10001     ← 只含 REPOHUBUSER10001 的密码
~/LinuxWaveMirror/password/10002
~/LinuxWaveMirror/password/10003
```

目录 `700`、文件 `600`。为什么不用一个汇总文件：给某个用户发密码时只读那一个文件，
不会顺带看到别人的；作废某个账号就删掉对应文件。

MacWave 的旧账号仍在 `/root/macwave-passwords.txt`，可以照此迁移，但迁移时注意
`~/LinuxWaveMirror` 只应放 LinuxWave 的编号（10001 起），别把 1/2/3 混进来。

### 按产品隔离访问（已启用）

nginx 的 `auth_basic_user_file` 是 **location 级**的指令，所以在
`location ^~ /LinuxWave/` 里指另一份用户文件，两个产品的账号就互不相通。

```nginx
# server 级保持 MacWave 的账号文件作为默认
auth_basic           "MacWave mirror";
auth_basic_user_file /www/server/nginx/conf/macwave.htpasswd;

# LinuxWave 用自己的账号文件
location ^~ /LinuxWave/ {
    auth_basic           "LinuxWave mirror";
    auth_basic_user_file /www/server/nginx/conf/linuxwave.htpasswd;

    # ^~ 会跳过外层的正则 location，所以 @ 缓存规则要在里面重复一次
    location ~ "@" {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
}
```

要点：

- **必须用 `^~`**：普通前缀 location 会被外层 `location ~ "@"` 正则抢走，
  那样 @ 文件就落回 MacWave 的账号文件，隔离在那些文件上失效。
- 嵌套的 `location ~ "@"` 只负责补回缓存头，认证从父级继承。
- 顶层页面（`linuxwave.html`、图标）走的是另一条正则 location，不受影响，
  仍然公开。
- 改完 `nginx -t` 通过再 reload；`auth_basic_user_file` 每次请求都读文件，
  所以**加账号不用 reload**，只有改配置才需要。

### 验证

判据只有两条 —— 两个产品的账号**不能跨读**：

| 身份 | `/MacWave/…` | `/LinuxWave/…` |
| --- | --- | --- |
| 不带口令 | `401` | `401` |
| `REPOHUBUSER10001`（LinuxWave） | **`401`** | `200` |
| `REPOHUBUSER1`（MacWave） | `200` | **`401`** |

加粗那两格就是「隔离生效」。隔离前它们都是 `200`。

从外网不解码文件内容也能确认配置真的挂上了：看 realm 文字即可，两边必须不同：

```bash
curl -sI https://mirror.repohub.top/MacWave/core/4.0/   | grep -i www-authenticate
# WWW-Authenticate: Basic realm="MacWave Mirror"

curl -sI https://mirror.repohub.top/LinuxWave/probe.txt | grep -i www-authenticate
# WWW-Authenticate: Basic realm="LinuxWave mirror"
```

#### 归一化绕过已实测无效

nginx 会先把 URI 解码并归一化（`..`、`//`、`%XX`）**再**匹配 location，
所以下面这些都不构成绕过，全部返回 `401`（需要在本地文件不存在时测，否则会变成别的状态码）：

```
/LinuxWave                  ← 无尾斜杠
/linuxwave/probe.txt        ← 大小写
//LinuxWave/probe.txt       ← 双斜杠
/./LinuxWave/probe.txt      ← 点段
/MacWave/../LinuxWave/probe.txt
/LinuxWave/../MacWave/core/4.0/
/Linux%57ave/probe.txt      ← URL 编码字母
/LinuxWave%2Fprobe.txt      ← 编码斜杠
/LinuxWave/core/..%2Fprobe.txt
```

测这些时务必带 `curl --path-as-is`，否则 curl 自己会把 `..` 和 `//` 先规整掉，
测的就不是 nginx 了。

#### 脚本化时的三个坑（都踩过）

| 坑 | 后果 | 做法 |
| --- | --- | --- |
| `htpasswd -b` 在**文件不存在**时报 `use '-c' to create it` | 首次建账号直接失败 | 文件不存在/为空用 `-c`，已存在只能用 `-b`（`-c` 会清空整份文件） |
| 用 `[[ -x $c ]]` 探测候选可执行文件 | **同名目录**也让 `-x` 为真，会把目录当程序 | 用 `[[ -f $c && -x $c ]]`；遍历候选列表时先 `shift` 掉命令名，否则相对路径会命中当前目录里的同名目录 |
| 服务器没有 `htpasswd`（`httpd-tools` 未装） | 卡在建账号 | 用 `openssl passwd -apr1 -salt $(openssl rand -hex 4) '<口令>'` 生成 `$apr1$`，**nginx 原生支持**，不必装包 |

最后一行的产物可以用 `htpasswd -vb <文件> <用户> <口令>` 反查（它与 nginx 的校验等价），
用来确认生成的口令和文件里的哈希是对得上的。

---

## 七、和 MacWave 的约定

- **账号按产品分段编号**，见第七点五节。MacWave 用 `REPOHUBUSER1…`，LinuxWave 从
  `REPOHUBUSER10001` 起 —— 不要混用，否则一个产品泄露的账号能取到另一个产品的数据
- 目录互不干扰：MacWave 的任何工具都不会读写 `LinuxWave/`，反之亦然
- 带宽与磁盘共享同一台机器，产物体积请留意（MacWave 全量约 2 GB）
