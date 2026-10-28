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
mirror.repohub.top               宝塔 + nginx，纯静态文件树
   │  ③ 大陆用户下载（20~50 ms）
   ▼
用户机器
```

三段的职责不能混：**抓上游只在 Actions 里做**，香港只负责「复制 + 服务」，用户的机器只读镜像。

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
| 根目录 | `/www/wwwroot/mirror.repohub.top` |
| PHP 版本 | **纯静态** |
| 数据库 | 不创建 |

## 第四步：放入文件

最终必须是这个结构：

```
/www/wwwroot/mirror.repohub.top/
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
ls /www/wwwroot/mirror.repohub.top/
# 必须直接看到 bottle 和 deps，不能再有一层目录
```

文件怎么来，两种方式：

**方式 A（推荐，从 GitHub Releases 拉）**

在服务器上执行，它按索引里的清单逐个下载并校验 sha256：

```bash
git clone --depth 1 https://github.com/MacWaveOrg/MacWave /tmp/macwave-src
git clone --depth 1 https://github.com/MacWaveOrg/infosource /tmp/infosource

python3 /tmp/macwave-src/scripts/sync_payloads.py \
  --infosource /tmp/infosource \
  --out /www/wwwroot/mirror.repohub.top \
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
https://mirror.repohub.top/bottle/jq/jq%401.7.1.arm64
```

能下载就说明镜像站可用。再量一下速度：

```bash
curl -o /dev/null -w '速度 %{speed_download} B/s\n' \
  https://mirror.repohub.top/bottle/jq/jq%401.7.1.arm64
```

同时确认校验值没被中间环节改坏：

```bash
curl -fsSL https://mirror.repohub.top/bottle/jq/jq%401.7.1.arm64 | shasum -a 256
# 与 infosource 里 _jq@1.7.1 的 sha256 应当逐字相同
```

## 第八步：让 MacWave 用它

```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.repohub.top/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.repohub.top/deps
export MACWAVE_SELFUPDATE_DOMAIN=https://mirror.repohub.top/selfupdate
```

写进 `~/.zshrc` 长期生效。

前两个变量的值里带 `/bottle` 与 `/deps`，因为镜像根目录下就是这两棵子树。想再镜像自更新数据的话，把 `MacWaveOrg/Selfupdate` 的内容放到 `.../selfupdate/`，第三个变量才需要设。

## 可选的第三块：自更新数据

自更新数据不是二进制，体积很小，直接从仓库复制即可：

```bash
git clone --depth 1 https://github.com/MacWaveOrg/Selfupdate \
  /www/wwwroot/mirror.repohub.top/selfupdate
rm -rf /www/wwwroot/mirror.repohub.top/selfupdate/.git
```

## 常见问题

**404，但文件确实在。** 九成是第四步多套了一层目录，或者 `MACWAVE_*_DOMAIN` 少了 `/bottle`、`/deps` 后缀。

**`@` 到底要不要编码。** 两种形式 nginx 都接受：`jq%401.7.1.arm64` 与 `jq@1.7.1.arm64` 指向同一个文件。客户端拼地址时会编码（与 GitHub 给出的规范地址一致）。

**下载是 200 但内容是 404 页面。** 宝塔的「伪静态」或默认站点配置接管了请求。镜像站不需要任何 rewrite 规则，把伪静态设为「无」。

**速度慢。** 先确认带宽档位（5 Mbps 与 30 Mbps 差 6 倍）；再看是不是撞上月流量包上限被限速了。

**服务器要同步很久。** 首次全量 1.5 GB。`sync_payloads.py` 可以重复运行，中断后再跑会从已完成的继续（同名同校验值的直接跳过）。
