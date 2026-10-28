# 4.0.0 发布说明

> 面向升级用户的完整说明。技术细节见 [TECHNICAL-GUIDE.md](./TECHNICAL-GUIDE.md)，
> 自建镜像站的步骤见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)。
>
> 发布日期：待定 · 构建号：`400A0000` · 发布分支：`4.0`

---

## 一句话

MacWave 不再从别人的服务器下载软件包 —— 预编译产物先由 CI 取回、校验，放进我们自己管理的
存储，用户从那里取。顺带解决了国内用户「根本连不上 GitHub」的问题。

---

## 为什么要改

以前的每条包记录只有一条指向上游的 URL，实际下载发生在别人的服务器上。三个隐患：

1. 上游被攻破或出现漏洞，会直接影响我们的用户；
2. 上游崩溃、删 release、换 CDN，用户就装不上；
3. 用户量上来以后会给别人的服务器造成压力。

这三点都不是假设。实测从大陆连 `github.com`：连续三次，两次在 20 秒内**连 TCP 都没建立**；
同一时刻国内镜像站 37~78 ms 就返回了。而 MacWave 的产物偏大（pandoc 40 MB、
ollama 172.9 MB），这种链路基本下不完。

---

## 用户能感觉到的变化

### 国内用户会明显变快

设两个环境变量就能走镜像，写进 `~/.zshrc` 长期生效：

```bash
export MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle
export MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps
```

不设这两个变量时，地址仍是官方源 —— **一个变量都不设，行为与 3.x 完全相同**。

### 内网用户：`--proxy` 现在真能用

以前这个旗标只影响「下载包体」那一步：取索引、取包元数据、取依赖信息全都绕过它，
于是内网用户会在下载任何字节之前就撞上 `Cannot fetch @common file`，看上去像参数没生效。

现在它会作用于**这条命令的所有请求**：值被写进 `HTTPS_PROXY` 等环境变量，
`requests`、`urllib` 和 bash 子脚本里的 `curl` 都读环境变量，因此一处生效、全部覆盖，
子进程也一并继承。

```bash
wave install jq --proxy http://proxy.corp:3128
```

### 新增 `--install-from-source`

绕开 MacWave 自己的存储，直接回上游装（依赖也一并回上游）：

```bash
wave install jq --install-from-source
```

刻意只有长参数：没有合适的短字母，占了以后还得再让出来。

---

## 数据格式的变化（对 3.x 无影响）

版本记录多了一个字段：

```
sha256: "…"
file: "jq-macos-arm64"          # 新增
url: "https://github.com/…"     # 保留，但 4.0 不读
```

`file` 是上游那份文件的名字。4.0 只从它取**扩展名**（决定用 zip 还是 tar.gz 解压），
产物则按 `<名字>@<版本>.<架构><扩展名>` 命名。字节原样搬运、不重打包，所以校验值仍与
上游公布的一致。

**3.x 只读 `sha256` 与 `url`，会忽略新字段**，因此这份数据可以提前落地，不必等 4.0 发布。

`url` 保留但不被 4.0 读取 —— 它留给 2.x-3.x，以及想知道上游来源的人。

---

## 4.0 不允许 selfupdate

跨大版本本来就不允许 `wave selfupdate`，4.0 也一样。3.x 用户会看到：

```
🌊 MacWave 4 is a new major version, so it cannot be installed with selfupdate.
🌊 Your version: 3.2.1. Please install 4.0.0 from the website:
   https://macwave.org
🌊 Your current installation has not been changed.
```

这条信息由旧版脚本自己产生（它本来就有跨大版本守卫），所以**不需要给 3.x 准备迁移脚本**，
只要在旧 `configdata` 里写上 4.0 的版本号，所有 3.x 安装就会走到那条守卫上。

---

## 安装

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/4.0/lib/install.sh)" && source ~/.zshrc
```

国内用户可以先把变量写在同一条命令前面（详见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)）。

---

## 已知限制

### 需要数据侧先补 `file` 字段

4.0 要求版本记录里有 `file`，缺了会直接报错并说明是数据缺陷 —— **不会悄悄回落到 `url`**。
静默回落等于把要解决的问题又带回来，而且没人察觉。

老记录用 `scripts/backfill_file_field.py` 一次性补齐（当前索引 231 条，其中 52 条指向上游的
裸可执行文件，没有扩展名，这是合法形态）。

### 「列版本」仍走 GitHub API

`wave search` / `info` / `upgrade` 取版本列表时用的是 `api.github.com` 的 contents 接口，
它与索引文件不是一台机器。设了 `MACWAVE_API_DOMAIN`（即在使用镜像）时，会改读镜像自己的
`<前缀>/pkg/pkginfo_<架构>/versions` 清单（一行一个版本号）；镜像不提供这个文件时，
这些命令的版本列表取不到，其余功能不受影响。

### 镜像站的搭建成本

镜像站是一棵纯静态文件树，`nginx`、对象存储或任何文件服务器都行 —— 不需要数据库，
不需要特殊软件。完整步骤见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)。

---

## 从 3.2.1 升级要注意什么

**不能 `wave selfupdate`。** 会看到上面那条「major version」提示，按提示去官网重装即可。

**已安装的软件包不受影响。** 4.0 装在同一个位置，`bin/`、`links/` 与配置目录都沿用，
之前装的包照常可用。

**配置目录不变。** 仍是 `/opt/macwave_config` 或 `~/.config/macwave_config`，系统级优先。

---

## 相关仓库

| 仓库 | 4.0 起的职责 |
| --- | --- |
| `MacWaveOrg/MacWave` | 程序代码 |
| `MacWaveOrg/infosource` | 包索引（4.0 起版本记录含 `file`） |
| `MacWaveOrg/Selfupdate` | 自更新数据：版本数据、每版一份文件清单、按版本冻结的更新脚本 |
| `MacWaveOrg/Bottle` | 预编译软件包（Release，一个包一个 tag） |
| `MacWaveOrg/Deps` | 依赖库（同形态） |
| `MacWaveOrg/configdata` | **4.0 起只为 3.x 保留**，不再接收新版本 |
| `MacWaveOrg/Pages` | 官网 |
| `MacWaveOrg/docs` | `docs.macwave.org` |
