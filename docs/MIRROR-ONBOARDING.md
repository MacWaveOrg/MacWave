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
├── macwave.png  linuxwave.png  产品图标（公开）
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

只要把文件放在**站点根目录**（不是 `LinuxWave/` 里面），就自动公开。

### 第 5 步：在首页加卡片

`index.html` 里把 LinuxWave 那张卡的「未上线，敬请期待」改成链接：

```html
<a class="card" href="./linuxwave.html">
  <img class="icon" src="./linuxwave.png" alt="" width="44" height="44">
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

## 七、和 MacWave 的约定

- 镜像站**共用同一个 basic auth 账号**（在当前规模下没必要分账号）
- 目录互不干扰：MacWave 的任何工具都不会读写 `LinuxWave/`，反之亦然
- 带宽与磁盘共享同一台机器，产物体积请留意（MacWave 全量约 2 GB）
