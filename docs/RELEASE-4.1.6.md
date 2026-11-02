# MacWave 4.1.6 发布说明

> 本文说明 4.1.6 的变更范围与升级方式。
> 这是一个**结构性版本**：传输层从 `lib/` 拆到顶层的 `net/`，安装树因此多一个目录。
> 同时补掉了 `--skip-ssl` 在三处请求点上的漏用。
> 数据格式无变化，但**升级时会清理 `lib/` 下三个旧文件** —— 见第二节。
>
> 发布分支：`4.1`

---

## 概述

`lib/` 一直在同时装三类东西：命令层（`wave` / `help` / `latest` / `mirrorinfo` /
`selfupdate`）、进程基础设施（`configpaths` / `configerror` / `flags` / `quiet` /
`steplog`）、以及传输层（`domains` / `tls` / `timeouts`）。最后这一类回答的是
「怎么连、连多久、连到哪」，与 `pkg/`、`surfboard/` 一样是一个独立组件。

本版把它拆出去：

```
lib/     命令层 + 进程基础设施
net/     传输层：地址表、TLS 策略、三档超时
pkg/     软件包层
surfboard/  依赖与二进制修复
```

**导入语句一行都没改。** `net/` 进了 `sys.path`，所以 `import tls`、`import domains`
照样成立 —— 这也是先做单一清单（第三节）再做搬迁的原因：改的是「哪些目录要进
`sys.path`」，不是几十处 `import`。

| 你可能会看到 | 说明 |
| --- | --- |
| 安装树里多一个 `net/` 目录 | 正常。`lib/` 里那三个文件被移到了这里 |
| `wave -V`、`wave list` 一切照旧 | 无数据格式变化，无配置变化 |
| 升级日志里出现 `Downloading net/…` | 本版新增的文件，三份 |

---

## 一、传输层独立成 `net/`

| 文件 | 职责 |
| --- | --- |
| `net/domains.py` | 所有对外地址的唯一来源：七个 `MACWAVE_*_DOMAIN` 环境变量、默认值、校验与归一化 |
| `net/tls.py` | `--skip-ssl` 的唯一实现：`request_kwargs()` / `urlopen_kwargs()` / `curl_flags()` |
| `net/timeouts.py` | 三档超时（连接 / 读数据 / 总时长）的解析与折算 |

### 搬家本身不修任何东西

必须说清楚：把文件挪进 `net/` **不会**让漏用策略的调用点变少。4.1.5 一天里修了
三处「旗标被解析、却没作用于请求」，三处都在调用点上，而调用点分散在 `pkg/`、
`surfboard/` 与 shell 脚本里 —— 搬到哪个目录都拦不住。

真正拦住它的是同批加入的**契约测试** `scripts/net_policy_test.sh`。它用 AST
（不是正则）检查每个请求点：

| 断言 | 覆盖 |
| --- | --- |
| 每个 `requests.*` 调用都带 `**tls.request_kwargs()` | 19 处请求点 |
| 每个 `urlopen` 调用都带 `**tls.urlopen_kwargs()` | 含 `curl` 回退分支 |
| 每个 `curl` 都有超时，SSL 旗标只来自 `tls.curl_flags()` | shell 与 Python 里组装的都算 |
| SSL 开关只出现在 `net/tls.py` | 别处不许 import `ssl` / `urllib3`，不许自己传 `verify=` |

用 AST 而非 grep，是因为请求调用普遍跨行写：

```python
response = requests.get(url, timeout=...,
                        **tls.request_kwargs())
```

正则对这种写法要么漏判要么误判，而且注释与 `echo "...curl..."` 里的文本也会被
当成真调用。

### 它当场抓到的三处漏用

新测试第一次跑就红了三处，都是 4.1.5 漏掉的同类缺陷：

| # | 位置 | 影响 |
| --- | --- | --- |
| 1 | `pkg/pkginstaller.py` 拼错包名时取名字清单的请求 | 自签证书环境下拿不到「你是不是想装 X」的建议 |
| 2 | `net/domains.py` 的 `fetch_text()`：`urlopen` 分支 | `--skip-ssl` 在该路径不生效 |
| 3 | `net/domains.py` 的 `fetch_text()`：`curl` 分支 | 同上，且没有 `-k` |

第 2、3 处所在函数目前**没有调用方**（`selfupdate.py` 与 `depsinstaller.py` 各有
一份自己的实现）。保留它并按契约补齐，是因为它随时可能被用上；删掉它属于另一件事。

---

## 二、升级时的迁移（用户可见）

升级到 4.1.6 时，安装树的目录结构会变。本版按这个顺序处理：

1. **先下载 `net/` 下的三个新文件**（清单里排在 delta 的最前面）；
2. 再按清单更新其余变动文件；
3. **最后清掉 `lib/` 下三个旧文件**：`lib/tls.py`、`lib/timeouts.py`、`lib/domains.py`。

第 1 步排在最前不是排版偏好：新模块常被改动过的老模块 `import`。若老模块先落地、
新模块后落地，中途一次网络失败就会留下「`lib/wave.py` 已经 `import net`、但 `net/`
还不存在」的安装树 —— 那种树上 `wave` 起不来，连重跑 `wave selfupdate` 都做不到，
只能重新执行安装脚本。

第 3 步只是清理：不删也能跑（已经没有代码 `import` 它们），但留着会让
「安装树里到底有哪份 `tls.py`」变成两说，下次改策略时容易改到没人用的那一份。

旧文件清理失败会让整次更新失败并保留版本号不变 —— 宁可停在旧版本，也不留下
结构不一致的安装树。

---

## 三、组件清单收敛为一个来源（开发侧）

「哪些目录要装进安装树、要加进 `sys.path`、要拷进测试沙箱」原先散在二十多处硬编码里：
清单生成器、`lib/wave.py`、9 个测试脚本的 `cp -R` 与 `sys.path`、CI 的工作目录。
加一个顶层组件时漏一处不会报错，只会得到一个缺目录的安装树。

本版把它们收敛到 **`scripts/components.txt`** 一行一个，`scripts/structure_test.sh`
盯着「各处是否跟着这份清单走」。

顺带修掉一个一直存在、只是尚未触发的缺陷：清单生成器用 `git ls-tree --name-only`
列举文件，**不递归**。一旦 `lib/` 下出现子目录，输出里只会出现目录名（如 `lib/net`），
它会被当成**文件**写进清单，客户端去 `curl .../lib/net` 必然 404，安装直接失败。
现在改用 `-r`，并在 `scripts/update_commands_test.sh` 里加了一条用临时仓库
造子目录的断言钉住它（35 → 42 条）。

---

## 四、测试

回归脚本从 17 个增加到 19 个，新增的两个都是纯离线、秒级：

| 脚本 | 断言 | 内容 |
| --- | --- | --- |
| `scripts/structure_test.sh` | 6 | 清单里的每个组件，`wave.py` 都建了 `sys.path`、`install.sh` 都建了目录、`selfupdate.sh` 都认识；两条流水线的沙箱与 lint 目标都读同一份清单；脚本里不许再手写第二份「lib pkg surfboard」 |
| `scripts/net_policy_test.sh` | 4 | 见第一节 |

`scripts/update_commands_test.sh` 新增两段：子目录必须被递归列举（第 10 段）、
迁移段必须清掉旧位置的三个文件（第 11 段，真起一个本地服务 + 假安装树跑一遍）。
总断言数 35 → 42。

两条流水线（GitHub Actions `Format Test` 与 CircleCI `quick-feedback`）都已接入
上述两个新脚本。

---

## 兼容性

- **不涉及数据格式变更**，配置与索引都不变。
- **不涉及命令行变更**：没有新增、删除或改变任何旗标。
- 安装树多一个 `net/` 目录，`lib/` 少三个文件 —— **只影响安装了 MacWave 的机器**，
  不影响任何软件包本身。
- 手工维护安装树的人（把 `lib/` 里的文件复制到别处）需要跟着搬到 `net/`。

---

## 升级方式

```bash
wave selfupdate
```

4.x 内部升级，不需要 sudo，不改数据格式。迁移步骤已包含在 `update_commands.sh` 里，
无需手工操作。

若 `net/` 三个文件缺失，所有命令都会在导入阶段失败 —— 请不要手工裁剪本版的清单。

---

## 已知限制

- `net/domains.py` 的 `fetch_text()` 目前没有调用方，本版只是按契约补齐了它的
  策略。将来启用它时不需要再改 `tls` 的接线。
- 结构重组不改变任何用户可见行为。本版唯一的用户可见变化是安装树的目录布局，
  以及第一节表格里三处 `--skip-ssl` 现在真的生效了。
- `scripts/` 不在安装树内，其中的工具（清单生成器、回归脚本）不随 `wave selfupdate`
  更新，只在仓库里演进。

---

## 本版随附的数据

无数据格式变更。

```
macwavedata/latest.toml                  哪个版本是最新的
macwavedata/4.1.6/update_commands.sh     这一版具体怎么装
```

`update_commands.sh` 按版本冻结，发布后不再修改。

```
version       4.1.6
release_date  2026-11-02
build_number  306A1357
branch        4.1
```
