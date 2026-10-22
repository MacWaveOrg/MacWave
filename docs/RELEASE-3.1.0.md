# 3.1.0 发布说明

> 面向升级用户的完整说明。技术细节见 [TECHNICAL-GUIDE.md](./TECHNICAL-GUIDE.md) 与
> [CI-AND-PITFALLS_20261018.md](./CI-AND-PITFALLS_20261018.md)。
>
> 发布日期：2026-10-22 · 构建号：`295A2033` · 发布分支：`3.1`

---

## 一句话

**MacWave 从此自带 Python。** 你不需要在机器上装 Python，也不用担心 Homebrew、pyenv 或
系统自带的 `python3` 升级之后把 MacWave 弄坏。

---

## 环境要求（变了）

| | 3.0.x 及更早 | **3.1.0 起** |
| --- | --- | --- |
| Python | **必须自己装 3.14+**，且要和 `pip3` 装依赖时的解释器一致 | **不需要装**。MacWave 自带一份 CPython 3.14 |
| macOS | Sonoma 14 及以上 | Sonoma 14 及以上（不变） |
| Xcode Command Line Tools | 14.0 及以上 | 14.0 及以上（不变，`otool` / `install_name_tool` / `codesign` 要用） |
| 磁盘占用 | — | 多出约 40–60 MB（自带的解释器），另加一个虚拟环境 |

> 官方安装命令没有变化：
> `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"`

### 如果你的 `python3` 是 Homebrew 的

3.0.5 之前，这会是个隐患：安装时依赖装进「当时的」解释器，运行时却用「后来的」解释器。
本机真实发生过一次 —— Homebrew 把 `python3` 从 3.14 换到 3.15，之后**所有命令**都报
`'pkgversionparser' module is not available.`（其实是 `packaging` 不在新解释器里）。

3.1.0 之后这个问题在结构上不存在了：解释器由 MacWave 自己管理，路径固定。

---

## 运行时目录有什么变化

安装根目录下新增两项：

```
<安装目录>/
├── python/
│   ├── 3.14.13/          自带的 CPython
│   └── current -> 3.14.13
├── venv/                 用自带解释器创建的虚拟环境，三个依赖装在这里
├── lib/
│   ├── wave.py           入口脚本（Python）
│   └── wave              ★ 变更为 shell 启动器（不再是一份 Python 脚本副本）
└── ...
```

`lib/wave` 现在是一个 **sh 启动器**，它按下列顺序挑选一个**真正能 import 到依赖**的解释器：

1. `venv/bin/python3`（正常情况就是它）
2. `python/current/bin/python3`（自带解释器；venv 坏掉时用）
3. 安装时记录的解释器路径
4. PATH 上的 `python3`（最后兜底，`wave.py` 会明确指出缺哪个依赖）

> **如果你有脚本直接读取 `lib/wave` 的内容**（比如解析 `COMMANDS` 表），请改读 `lib/wave.py`。
> 仓库内的脚本（如 `scripts/selfupdate_test.sh`）已经同步改好。

---

## 升级

```bash
wave selfupdate
```

升级到 3.1.0 会自动：

1. 创建 `python/` 并下载自带的解释器（校验 sha256 后才解包）
2. 用它创建 `venv/`，装好 `requests` / `packaging` / `rich`
3. 重写 `lib/wave` 启动器
4. 更新 `VERSION.json`

**如果下载失败**（网络问题）：安装器/自更新会打印警告，回退到系统 `python3`，
**安装照常完成**。等网络恢复后再跑一次 `wave selfupdate` 即可补齐。

同一大版本内可以自更新；**跨大版本仍需用 `install.sh`**（这条规则没变）。

---

## 从 3.0.x 或更早升级

| 起点 | 做法 |
| --- | --- |
| 3.0.x | `wave selfupdate` 即可 |
| 2.6.x | 需先用 `install.sh` 装到 3.x（跨大版本守卫会拒绝自更新） |
| 2.5 之前 | 必须用 `install.sh`：既跨大版本，又涉及 2.5 的配置目录迁移 |

---

## 其它变化

- **依赖缺失的报错不再误导人**：以前 `except ImportError` 会把「缺第三方包」报成
  「模块不可用」；现在会直接说是哪个包缺了，并给出安装命令。
- **启动时统一自检**：任何命令缺少依赖都会以同一种方式失败，而不是只有碰巧用到
  版本比较的那些命令报错。
- 自更新脚本与安装脚本共用同一套「自带解释器」逻辑，避免两条路径漂移。

---

## 已知限制

- **首次安装/升级需要联网下载解释器**（约 40–60 MB）。离线环境请先把对应架构的压缩包
  放到安装根目录的 `downloads/tmp/`，或先用系统 Python 完成安装再补。
- 自带的解释器按架构分发（`arm64` / `amd64`），**不提供 universal 二进制**。
- 升级过程对每个请求都有超时、对失败的单文件会自动重试（3 次，404 这类不重试），
  并且先写分片再 `mv`：重试期间不会把半个文件留在安装树里。中途放弃时 `VERSION.json`
  仍是旧值，网络恢复后再跑一次 `wave selfupdate` 即会继续。
- `wave selfupdate --max-time=1min` 可以把每个请求的超时调大，适应用户的慢网。
