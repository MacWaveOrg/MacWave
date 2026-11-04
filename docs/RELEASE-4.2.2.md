# MacWave 4.2.2 发布说明

- 发布：2026-11-04，构建号 `308A1440`
- 分支：`4.2`
- 上一版：[4.2.1](RELEASE-4.2.1.md)（同日）

## 概述

**功能与 4.2.1 完全相同。** 这一版只修了一处测试缺陷，运行时代码一个字节没动。

## 为什么会有 4.2.2

4.2.1 发布后，CI 的 `random-test` 红了：

```
✗ install ipsw --continue（续传）: exit=0  <- 实际 1
🌊 Warning: ipsw@3.1.739 declares macOS 27.2 or later, this machine is 26.6.2.
🌊 Continue installing anyway? [y/N]
```

原因是 `8821cd2` 那次修复做得不完整：给随机安装加 `-F`（越过 `min_os` 询问）
时，只加在主安装阶段 `phase_install_cycle` 里。但 random-test 还有五条路径会
自己构造 `install` 命令 —— **续传、Mach-O 重定向中途打断、`--skip-ssl`、
限速、打断后的恢复**。随机抽到 `ipsw`（声明 27.2，runner 是 26.x）时，那几条
路径仍然会被询问拦住，于是「这个包没装上」被记成了失败。

修复见 `f96ef5a`：统一成 `install_args()` 构造器，`-F` 只写一处。负向用例
（非法版本、缺包名、`--max-time` 格式）保持原样 —— 它们本来就期望失败。

## 用户可见的变化

没有。安装内容（29 个文件）与 4.2.1 逐字节相同。

## 升级方式

```bash
wave selfupdate
```

已经装了 4.2.1 的话不升也可以 —— 两版的运行时代码完全一样。

## 本版随附的数据

| 仓库 | 内容 |
| --- | --- |
| `Selfupdate` | `macwavedata/4.2.2/update_commands.sh`（与 4.2.1 同集） |
| `configdata` | `latest_version` → 4.2.2 |
| `Pages` | 版本号 → 4.2.2 |
