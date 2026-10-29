# MacWave 4.0.0 发布说明

> 本文面向从 3.x 升级的用户，说明 4.0 的变更范围、迁移方式与已知限制。
> 设计细节参见 [TECHNICAL-GUIDE.md](./TECHNICAL-GUIDE.md)，
> 数据层的文件布局参见 [DATA-LAYER.md](./DATA-LAYER.md)，
> 自建镜像站的步骤参见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)。
>
> 发布分支：`4.0`

---

## 概述

MacWave 4.0 的主要变更在于**软件包的来源**。此前，每条包记录只保存一个指向上游的
URL，实际下载发生于第三方服务器。4.0 改由 CI 预先取回上游产物、校验其 SHA-256、
并按统一规则命名后存入项目自有的存储，客户端仅从该存储取用。

此项变更同时缓解了国内用户的可用性问题：`github.com` 在其网络环境下往往并非缓慢，
而是无法建立连接。

---

## 变更动因

旧实现存在三项风险：

1. **供应链风险。** 上游被攻破或引入漏洞时，影响会直接传导至 MacWave 用户；
2. **可用性风险。** 上游服务中断、删除 Release 或更换 CDN 时，用户将无法安装；
3. **负载风险。** 用户规模增长会给第三方服务器造成计划外的压力。

上述风险均有实测依据。自中国大陆一条线路对 `github.com` 连续测试三次，其中两次在
20 秒内未能完成 TCP 握手；同一时段国内镜像站响应时间为 37 至 78 毫秒。而 MacWave
的产物体积偏大（pandoc 为 40 MB，ollama 为 172.9 MB），在此类链路条件下难以完成下载。

---

## 用户可见的变更

### 国内用户可获得显著的速度提升

通过两个环境变量指定镜像地址，写入 `~/.zshrc` 后长期生效：

```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps
```

两个变量均未设置时，客户端仍使用官方地址。**不设置任何变量时，行为与 3.x 一致。**

### `--proxy` 现在作用于全部请求

此前该旗标仅影响「下载包体」这一步，获取索引、包元数据与依赖信息时仍绕过代理。
内网用户在下载任何数据之前即会遇到 `Cannot fetch @common file`，表现形同参数未生效。

现在该旗标作用于这条命令的**全部请求**：其值被写入 `HTTPS_PROXY` 等环境变量，
`requests`、`urllib` 以及子脚本中的 `curl` 均读取环境变量，因而一处设置即可全局覆盖，
子进程亦随之继承。

```bash
wave install jq --proxy http://proxy.corp:3128
```

### 新增 `--install-from-source`

该选项绕过 MacWave 自有存储，直接从上游取用产物，依赖亦一并回上游：

```bash
wave install jq --install-from-source
```

仅提供长参数形式：现有短字母已被占用，且短选项一经公布便难以收回。

---

## 数据格式的变更（不影响 3.x）

版本记录新增一个字段：

```
sha256: "…"
file: "jq-macos-arm64"          # 新增
url: "https://github.com/…"     # 保留，但 4.0 不读
```

`file` 记录上游产物的文件名。4.0 仅从中提取**扩展名**，用以判定解压方式；
存储中的产物按 `<名字>@<版本>.<架构><扩展名>` 命名。由于字节原样搬运、未经重新打包，
校验值仍与上游公布值一致。

**3.x 只读取 `sha256` 与 `url`，会忽略新增字段**，因此该数据可提前落地，无需等待 4.0 发布。
当前索引共 231 条记录，覆盖率 100%。

`url` 予以保留但 4.0 不再读取，供 2.x 至 3.x 使用，亦便于追溯上游来源。

---

## 4.0 不支持 selfupdate

跨大版本升级本就不通过 `wave selfupdate` 完成，4.0 沿用此规则。3.x 用户在检查更新时
将看到以下提示：

```
🌊 MacWave 4 is a new major version, so it cannot be installed with selfupdate.
🌊 Your version: 3.2.1. Please install 4.0.0 from the website:
   https://macwave.org
🌊 Your current installation has not been changed.
```

该提示由旧版脚本自身产生：跨大版本守卫在其发布时即已内置。因此**无需为 3.x 准备迁移
脚本**，只需在旧 `configdata` 中写入 4.0 的版本号，所有 3.x 安装便会进入该守卫分支。

---

## 本版随附的数据

4.0 发布时，自有存储中已包含索引登记的全部可用产物：

| 仓库 | Release 数 | 资产数 |
| --- | --- | --- |
| `MacWaveOrg/Bottle` | 36 | 159 |
| `MacWaveOrg/Deps` | 18 | 50 |
| 合计 | 54 | 209 |

共 209 个产物，全量镜像约 2.0 GB。每条资产在入库前均经 SHA-256 校验，与索引记录逐字比对。

索引中另有 12 条记录未纳入存储，原因如下：

| 记录 | 原因 |
| --- | --- |
| `test_no_sha256`（2 条） | 测试夹具，按设计不含校验值 |
| `test_wrong_sha256`（2 条） | 测试夹具，按设计校验值错误 |
| `test_001`（2 条） | 上游 Release 已删除 |
| `ldid@2.1.5-procursus` 系列（6 条） | 索引校验值与上游不符，属既存数据缺陷 |

上述记录在 3.x 下同样无法安装，并非 4.0 引入的问题；相关数据修正将单独处理。

---

## 安装

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/4.0/lib/install.sh)" && source ~/.zshrc
```

国内用户可以先把变量写在同一条命令前面（详见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)）。

---

## 已知限制

### 版本记录必须包含 `file` 字段

4.0 要求版本记录中包含 `file` 字段；缺失时将直接报错并指明为数据缺陷，
**不会静默回退至 `url`**。静默回退等同于放弃本版本要解决的问题，且难以被察觉。

现有索引 231 条记录已全部补齐（其中 52 条指向上游的裸可执行文件，无扩展名，
此为合法形态）。

### 「列出版本」仍依赖 GitHub API

`wave search`、`info`、`upgrade` 在获取版本列表时使用 `api.github.com` 的 contents
接口，该服务与索引文件不在同一主机。设置 `MACWAVE_API_DOMAIN`（即启用镜像）后，
将改读镜像自备的 `<前缀>/pkg/pkginfo_<架构>/versions` 清单（每行一个版本号）。
镜像未提供该文件时，上述命令的版本列表无法获取，其余功能不受影响。

### 镜像站的建设成本

镜像站是一棵纯静态文件树，`nginx`、对象存储或任意文件服务器均可承载，
无需数据库，亦无需专用软件。完整步骤参见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)。

### 版本列表依赖的索引清单尚未生成

启用镜像后，「列出版本」改读镜像自备的 `versions` 清单。该清单未包含在 `infosource`
仓库中，需另行生成；在此之前，镜像环境下的 `wave search`、`info`、`upgrade`
无法列出可用版本，指定版本安装（如 `wave install jq@1.8.2`）不受影响。

---

## 自 3.x 升级的注意事项

**不能使用 `wave selfupdate`。** 客户端将输出前述「major version」提示，
按提示前往官网重新安装即可。

**已安装的软件包不受影响。** 4.0 安装于同一位置，沿用 `bin/`、`links/` 与配置目录，
先前安装的软件包继续可用。

**配置目录不变。** 仍为 `/opt/macwave_config` 或 `~/.config/macwave_config`，系统级优先。

---

## 相关仓库

| 仓库 | 4.0 起的职责 |
| --- | --- |
| `MacWaveOrg/MacWave` | 程序代码 |
| `MacWaveOrg/infosource` | 包索引（4.0 起版本记录含 `file`） |
| `MacWaveOrg/Selfupdate` | 自更新数据：`macwavedata/latest.toml` 与按版本冻结的 `update_commands.sh` |
| `MacWaveOrg/Bottle` | 预编译软件包（Release，一个包一个 tag） |
| `MacWaveOrg/Deps` | 依赖库（同形态） |
| `MacWaveOrg/Python` | 自带 CPython 的版本指针与各架构校验值 |
| `MacWaveOrg/configdata` | **4.0 起仅为 3.x 保留**，不再接收新版本 |
| `MacWaveOrg/Pages` | 官网 |
| `MacWaveOrg/docs` | `docs.macwave.org` |
