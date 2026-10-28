# 3.2.2 发布说明

> 面向升级用户的完整说明。技术细节见 [TECHNICAL-GUIDE.md](./TECHNICAL-GUIDE.md)。
>
> 发布日期：2026-10-28 · 构建号：`301A1719` · 发布分支：`3.2`

---

## 一句话

两个只在特定情况下才会遇到、但遇到就完全没法用的 bug：`--proxy` 只对下载包体生效，
以及网络不好时安装器会先报「安装未完成」再说「安装成功」。

---

## 一、`--proxy` 现在覆盖整条命令

### 以前会怎样

```sh
wave install jq --proxy http://proxy.corp:3128
```

这个旗标只影响**下载包体**那一步。在那之前的所有请求 —— 读索引、读 `@common` 元数据、
读依赖元数据 —— 全都绕过它。于是内网用户看到的是：

```
🌊 Error: Cannot fetch @common file.
```

而一个字节都还没下到。参数看起来完全没起作用。

### 现在怎样

`--proxy` 的值会写进进程环境（`HTTPS_PROXY` 等），而 `requests`（`trust_env` 默认开启）、
`urllib` 以及 bash 子脚本里的 `curl` **都读环境变量**。于是：

- 一处赋值，这条命令的**所有**请求都走代理；
- 子进程自动继承，不需要逐个调用点改造；
- `--proxy=http://…` 与 `--proxy http://…` 两种写法都认。

不写这个旗标时不会污染环境变量 —— 你在 shell 里自己设的 `HTTPS_PROXY` 仍然是你的。

---

## 二、安装器不再误报「安装未完成」

### 以前会怎样

安装器自带一个便携 Python 解释器（约 26 MB），取不到时会回落到系统 `python3`，这是
**预期的降级**。但它取不到的那一刻会触发 ERR trap，于是输出变成：

```
🌊 Fetching the bundled Python definition...
🌊 Installation did not finish (exit 1).
🌊 Nothing was removed. Files already downloaded may be left in:
     ~/.local/macwave
...
🌊 Installation complete!
```

先报失败，几百行之后又说成功。国内网络下取不到那份清单是常事，所以这一条很容易撞上，
而且看起来像装坏了。

### 现在怎样

那一步被明确标记为「允许失败」，ERR trap 不再对它喊话。真正的失败（网络断了、权限不够、
磁盘满了）照样会报，一个字都没少。

---

## 三、升级方式

```sh
wave selfupdate
```

或直接重跑安装命令（推荐，能顺便修好被改乱的 PATH）：

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)" && source ~/.zshrc
```

---

## 没有变的东西

- **目录结构没变**，不需要迁移；
- **数据格式没变**，索引与版本数据都不用动；
- **已安装的软件包不受影响**；
- 这两个修复与 4.0 的任何改动无关，是从 4.0 单独摘出来回填到 3.x 的 —— 4.0 的地址层、
  存储方案、镜像功能都没有带进来。
