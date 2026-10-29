# 数据层与镜像布局

这份文档描述 MacWave 4.0 的**存储层契约**：客户端从哪里取什么、每类数据的文件树
长什么样、发布时哪些事必须保持不变。任何产品要复用这套基础设施（例如 LinuxWave），
只需要照做第 6 节与第 7 节，不需要读客户端代码。

## 一、设计约束

四条硬约束决定了下面所有形状，改动任何一个之前先看这里。

| 约束 | 后果 |
| --- | --- |
| 镜像站必须能用 `rsync` + `nginx` **原样提供** | 地址一律是「域名 + 纯文件路径」，不使用任何需要服务端理解的协议（不用 OCI registry） |
| git 单文件硬限 100 MiB | 二进制不走仓库 blob，走 Releases 或独立存储 |
| 国内直连 `github.com` 经常 20 秒内建不起 TCP | 每个地址都必须能被环境变量整体换掉 |
| 校验值要与上游一致 | 字节**原样搬运，不重打包**，所以能直接用官方 SHA256 |

## 二、七个地址

所有对外地址只有一个来源：[`lib/domains.py`](../lib/domains.py) 的 `ENV_NAME` / `DEFAULTS`。
shell 侧（`install.sh`、`selfupdate.sh`）有一份逐字对应的副本，因为安装器是
`curl | bash` 直接执行的，没有本地文件可以 `source`。

| 环境变量 | 内容 | 默认值 |
| --- | --- | --- |
| `MACWAVE_API_DOMAIN` | 索引与「列出版本」的清单 | `raw.githubusercontent.com/MacWaveOrg/infosource/main` |
| `MACWAVE_BOTTLE_DOMAIN` | 预编译二进制包 | `github.com/MacWaveOrg/Bottle/releases/download` |
| `MACWAVE_DEPS_DOMAIN` | 依赖二进制 | `github.com/MacWaveOrg/Deps/releases/download` |
| `MACWAVE_CORE_DOMAIN` | MacWave 自身代码（按分支） | `raw.githubusercontent.com/MacWaveOrg/MacWave` |
| `MACWAVE_PYTHON_DOMAIN` | 自带 CPython | `raw.githubusercontent.com/MacWaveOrg/Python/main` |
| `MACWAVE_SELFUPDATE_DOMAIN` | 自更新数据 | `raw.githubusercontent.com/MacWaveOrg/Selfupdate/main` |
| `MACWAVE_PKG_SOURCECODE_DOMAIN` | 源码包（预留，当前为空） | 空 |

校验规则（`domains._validate`）：

- 只要 `https://` 与 `file://`；
- `http://` 仅在回环地址（`127.0.0.1` / `localhost` / `::1`）上接受，供本地测试；
- 末尾斜杠循环去掉，所以设置值带不带 `/` 都可以；
- 空值表示「没有配置」，`require_domain()` 会报错并指名该设哪个变量。

**七个别名全部可单独覆盖**。只换镜像而保留其余默认值也是合法用法。

## 三、五类数据的文件树

### 3.1 二进制包（Bottle / Deps）

```
<MACWAVE_BOTTLE_DOMAIN>/            ← GitHub Releases 时这里是 .../releases/download
    <包名>/
        <包名>@<版本>.<架构><扩展名>
```

实例：

```
默认  https://github.com/MacWaveOrg/Bottle/releases/download/jq/jq%401.7.1.arm64.tar.gz
镜像  https://mirror.example.cn/MacWave/bottle/jq/jq%401.7.1.arm64.tar.gz
                                                  ↑ 域名之后完全相同
```

规则：

- **架构必须写进文件名**。arm64 与 amd64 是同名同版本的两条索引记录，去掉架构就撞名。
- **扩展名取自上游文件名**。字节不重打包，压缩格式因此不统一（`.tar.gz` / `.zip` /
  `.tar.xz` / 裸可执行文件…），而客户端靠扩展名选解压器。所以索引里必须有 `file` 字段
  记上游文件名，见 3.2。
- 文件名里的 `@` 与 `+` 按 URL 规范编码成 `%40` / `%2B`。nginx 会自动解码回原字符去
  找文件，镜像站无需任何特殊处理。
- 生成规则在 `domains.payload_filename()`，地址在 `domains.payload_url()`。两处都只有
  一份实现，包与依赖共用。

### 3.2 索引（infosource）

```
<MACWAVE_API_DOMAIN>/
    pkg/
        pkginfo_arm64/<包名>/<版本>      一条记录一个文件
        pkginfo_amd64/<包名>/<版本>
```

记录是 `field: "value"` 的平铺文本。4.0 起新增 `file` 字段（上游那份文件的名字）：

```
package: "jq"
version: "1.7.1"
url: "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-arm64"
file: "jq-macos-arm64"
sha256: "..."
```

- `file` 决定落盘名里的扩展名，**必填**（`resolve_payload()` 缺它会报数据缺陷）。
- `url` 在 4.0 **不读**，除非带 `--install-from-source`。
- 3.x 不认 `file`，会忽略，所以这次改动对 3.x 是安全的。

「列出版本 / 列出软件包」目前走 GitHub contents API，它属于 `api.github.com`，与索引不是
一台机器，镜像站无法等价提供。因此设置了 `MACWAVE_API_DOMAIN` 时要求镜像自己提供清单：

```
<MACWAVE_API_DOMAIN>/pkg/pkginfo_<arch>/versions             一行一个包名
<MACWAVE_API_DOMAIN>/pkg/pkginfo_<arch>/<包名>/versions       一行一个版本号
```

### 3.3 自更新数据（Selfupdate）

```
<MACWAVE_SELFUPDATE_DOMAIN>/
    macwavedata/
        latest.toml                 哪个版本是最新的（唯一入口）
        <版本>/
            update_commands.sh      那个版本具体怎么装，随版本冻结
```

`latest.toml` 是平铺 TOML：

```toml
version = "4.0.0"
release_date = "2026-11-XX"
build_number = "400A0000"
branch = "4.0"
```

为什么分两个文件：`latest.toml` 每次发版都变，`update_commands.sh` 按版本冻结。混在一起
就没法让装了旧版本的用户继续用他们那份说明——而旧版本仍在运行。

`update_commands.sh` 取代了 3.x 的 `files_info`（缩进树清单）与 `updatedata/`（迁移开关），
同时承担两件事：**下载哪些文件**、**目录结构变更时怎么迁移**。它由
`scripts/build_update_commands.py` 生成，通过环境变量与客户端交互：

| 变量 | 含义 |
| --- | --- |
| `MACWAVE_INSTALL_DIR` | 安装根目录 |
| `MACWAVE_CONFIG_DIR` | 配置目录 |
| `MACWAVE_CORE_URL` | 代码地址前缀（不含分支） |
| `MACWAVE_BRANCH` | 代码分支 |
| `MACWAVE_TARGET_VERSION` | 目标版本 |
| `MACWAVE_CURRENT_VERSION` | 已装版本；**为空表示首次安装**，走全量清单 |
| `MACWAVE_FILE_TIMEOUT` | 单文件超时秒数 |
| `MACWAVE_NEED_SUDO` | `1` 表示安装目录需要 sudo |
| `MACWAVE_SILENT` | `1` 表示少打印 |
| `MACWAVE_DRY_RUN` | `1` 表示只报告不落盘 |

`MACWAVE_CURRENT_VERSION` 是区分「首次安装」与「增量升级」的唯一开关，这就是为什么一个
脚本能同时服务 `install.sh` 与 `wave selfupdate`。

### 3.4 自带解释器（Python）

```
<MACWAVE_PYTHON_DOMAIN>/
    pythondata/
        latest.toml                     现在用哪个版本（唯一入口）
        <版本>/
            python_url.toml             各架构的上游地址与校验值
            <上游同名文件>               我们自己托管的那份字节
```

```toml
# pythondata/3.14.9/python_url.toml
[arm64]
arm64_url = "https://github.com/astral-sh/python-build-standalone/releases/download/.../cpython-3.14.9+...-aarch64-apple-darwin-install_only.tar.gz"
arm64_sha256 = "226d..."

[amd64]
amd64_url = "https://.../cpython-3.14.9+...-x86_64-apple-darwin-install_only.tar.gz"
amd64_sha256 = "600c..."
```

两条下载路径共用一份 `sha256`，因为字节原样搬运、文件名取上游 URL 末段：

| 场景 | 取哪里 |
| --- | --- |
| 默认 | 本仓库 `pythondata/<版本>/<文件名>` |
| `--install-python-from-source` | `python_url.toml` 里的 `*_url`（上游） |

客户端取值顺序：**先读 `latest.toml` → 本机已有该版本且能跑就直接用（不发网络请求）→
否则读 `python_url.toml` 下载校验。** 第一步必须先问：否则「本机已有 3.14.9」会让升级到
「要求 3.15」的版本时永远发现不了自己落后。

### 3.5 自身代码（core）

```
<MACWAVE_CORE_DOMAIN>/<分支>/<仓库内路径>
```

3.x 与 4.0 相同的 22 个文件：`lib/` 7 个、`pkg/` 8 个、`surfboard/` 7 个。
`update_commands.sh` 里的 `want <路径> <是否 +x>` 逐条列出。

## 四、客户端取值顺序

1. 读 `macwavedata/latest.toml` 拿到目标版本与分支；
2. 取 `macwavedata/<版本>/update_commands.sh`（先 `bash -n` 校验，再执行）；
3. 脚本按 `MACWAVE_CURRENT_VERSION` 空 / 不空选全量或增量清单，从 `<core>/<分支>/…` 下载；
4. 每个文件先写 `<目标>.macwave-part` 再 `mv`，重试期间目标位置不会出现半个文件；
5. 全部就位后才写 `VERSION.json`。任一步失败即 `exit` 非零，客户端据此判定「什么都没更新」。

`--install-from-source` / `--install-python-from-source` 是**唯一**会绕开自有存储、
直接回上游的两条路。

## 五、三条发布铁律

1. **只增不删**。历史版本必须一直可下载——装了旧版本的用户仍然在取。
2. **同名不覆盖**。同一个文件名代表同一份字节；要换内容就换名字（新版本号）。
3. **字节原样**。不解压、不重新压缩、不改权限位。这样校验值与上游一致，出事时能对账。

## 六、镜像站如何原样复制

镜像只需要一条 `rsync`，把「域名之后的路径」原样铺开。以 `/srv/mirror` 为站点根、
对外域名 `https://mirror.example.cn` 为例：

| 环境变量 | 站点内目录 | 上游来源 |
| --- | --- | --- |
| `MACWAVE_BOTTLE_DOMAIN=https://mirror.example.cn/MacWave/bottle` | `MacWave/bottle/<包名>/<文件>` | `Bottle` 仓库的全部 Release 资产 |
| `MACWAVE_DEPS_DOMAIN=https://mirror.example.cn/MacWave/deps` | `MacWave/deps/<包名>/<文件>` | `Deps` 仓库的全部 Release 资产 |
| `MACWAVE_API_DOMAIN=https://mirror.example.cn/MacWave/infosource` | `MacWave/infosource/pkg/...` | `infosource` 仓库内容 |
| `MACWAVE_SELFUPDATE_DOMAIN=https://mirror.example.cn/MacWave/selfupdate` | `MacWave/selfupdate/macwavedata/...` | `Selfupdate` 仓库内容 |
| `MACWAVE_PYTHON_DOMAIN=https://mirror.example.cn/MacWave/python` | `MacWave/python/pythondata/...` | `Python` 仓库内容 |
| `MACWAVE_CORE_DOMAIN=https://mirror.example.cn/MacWave/core` | `MacWave/core/<分支>/lib/...` | `MacWave` 仓库各分支 |

`MacWave/` 这一层是为了让同一个镜像域名能被多个产品共用（LinuxWave 将来用
`/LinuxWave`），所以它不是固定前缀，而是环境变量值的一部分。

搭建步骤（服务器、DNS、nginx 缓存头、SSL、验证命令）见 [MIRROR-SETUP.md](MIRROR-SETUP.md)。

## 七、复用这套基础设施（含 LinuxWave）

要接一个新语言包管理器，只需要做四件事，客户端代码一行都不用看：

1. **建三个数据仓库**，照抄 3.1 / 3.3 / 3.4 的形状，把 `MacWave` 换成自己的产品名：

   ```
   <Org>/Bottle      二进制，Release 资产命名 <包名>@<版本>.<架构><扩展名>
   <Org>/Selfupdate  <产品>data/latest.toml + <产品>data/<版本>/update_commands.sh
   <Org>/Python      解释器（若自身不自带运行时则不需要）
   ```

2. **定义自己的地址变量**。不要复用 `MACWAVE_*`，否则两个产品在同一台机器上会互相干扰。
   LinuxWave 用 `LINUXWAVE_*`。

3. **生成 `update_commands.sh` 而不是手写**。契约只有第 3.3 节那几个环境变量；脚本必须
   **幂等**，失败必须 `exit` 非零。

4. **在镜像上单独一层目录**（`/LinuxWave`），与 `/MacWave` 平级。

不能直接复用的部分：

| 项 | 原因 |
| --- | --- |
| 文件名规则里的「架构」取值 | macOS 是 `arm64` / `amd64`，Linux 还要区分 glibc / musl，需要自己的取值表 |
| 包格式解压器 | macOS 侧按扩展名分发（`pkg/pkgunzip.sh`），Linux 侧要按 `deb` / `rpm` / `AppImage` 另写 |
| `MACWAVE_*` 变量名 | 见上，必须换前缀 |
| `python_url.toml` 的具体字段 | 若不自带运行时就不需要这一块 |

## 八、镜像自检清单

复制完成后，把地址变量指向镜像，逐条验证：

```bash
# 1. 版本指针（应等于官方最新版本）
curl -fsSL "$MACWAVE_SELFUPDATE_DOMAIN/macwavedata/latest.toml"

# 2. 该版本的更新脚本存在且是合法 shell
curl -fsSL "$MACWAVE_SELFUPDATE_DOMAIN/macwavedata/<版本>/update_commands.sh" | bash -n

# 3. 索引里的 sha256 与实际文件逐字相同
curl -fsSL "$MACWAVE_BOTTLE_DOMAIN/<包名>/<包名>%40<版本>.<架构><扩展名>" | shasum -a 256

# 4. 解释器指针
curl -fsSL "$MACWAVE_PYTHON_DOMAIN/pythondata/latest.toml"

# 5. 首次安装（不碰现有安装）
MACWAVE_BOTTLE_DOMAIN=... MACWAVE_API_DOMAIN=... \
MACWAVE_SELFUPDATE_DOMAIN=... MACWAVE_PYTHON_DOMAIN=... MACWAVE_CORE_DOMAIN=... \
  bash lib/install.sh
```

第 3 条是唯一能证明「字节原样」的检查，务必做一次。
