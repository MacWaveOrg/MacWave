# 3.2.0 发布说明

> 面向升级用户的完整说明。技术细节见 [TECHNICAL-GUIDE.md](./TECHNICAL-GUIDE.md)。
>
> 发布日期：2026-10-24 · 构建号：`297A2125` · 发布分支：`3.2`

---

## 一句话

**新增 `wave upgrade`。** 版本本来是共存的，所以以前「升级」只能靠你自己先 `install` 新的、再手动 `uninstall` 旧的。

---

## 新增命令

```sh
wave upgrade jq                          # 装到最新版本，旧版本保留
wave upgrade jq --remove-old-version     # 装到最新版本，并清理旧版本
wave upgrade jq --rov                    # 同上，--rov 是简写
```

不带清理旗标时，行为就是「装最新版本」—— 与 `wave install jq` 相同，只是语义更明确，也不会因为你忘了写而装成某个旧版本。

### `--remove-old-version` 的三档清理

| 情况 | 行为 |
| --- | --- |
| 只有一个旧版本 | 直接移除，不再多问 |
| 有多个旧版本 | 先问「全部移除？」；答 `N` 就按卸载那套编号列表让你挑（`1 3` 或 `1@3`） |
| 读不到输入（CI、管道、`< /dev/null`） | **一个都不删**，并说明原因 |

非交互环境选择「什么都不做」是刻意的：删错版本会让用户丢东西，而少删一次只是留下点占空间的文件。

### 为什么先装再删

清理动作排在下载与安装**之后**。下载失败时旧版本还在，你手上始终有一个能用的版本 —— 而不是「旧的删了、新的没装上」。

### 索引落后时不动手

如果本机已装的版本比索引里的最新版本还新（例如某个版本后来被撤下），`upgrade` 只提示、不下载、也不删任何东西。把降级说成升级是更糟的错误。

---

## 顺带修掉的一个解析缺陷

`wave install --max-time 1min jq` 这种空格写法，以前会把 `1min` 当成包名（`--max-time=1min` 的等号写法没有问题）。现在两者共用同一套包名定位逻辑，`install` 与 `upgrade` 一起修好。

`upgrade` 同时接受 `install` 的所有网络旗标：`-C`、`--proxy`、`--skip-ssl`、`--limit-rate`、`--max-time`、`-v`。

---

## 明确被拒绝的组合

`upgrade` 会**报错退出**而不是静默忽略下面三个，因为它们会悄悄改变语义：

| 输入 | 原因 |
| --- | --- |
| `wave upgrade jq@1.5` | 升级总是取最新版本；装指定版本请用 `wave install jq@1.5` |
| `wave upgrade jq --ver 1.5` | 同上 |
| `wave upgrade jq --unlink` | 会让链接留在旧版本上，而清理正好要把那个版本删掉 |

想要「装最新版本但别动链接」，先 `wave upgrade jq`，再用 `wave link jq@<版本>` 指定。

---

## 升级方式

同大版本内（3.x）直接自更新：

```sh
wave selfupdate
```

> 自更新只更新代码，不会自动帮你升级已装的软件包。升级软件包请用 `wave upgrade`。

从 2.x 或更早升级，仍必须用安装脚本重装：

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

---

## 兼容性

- 没有目录结构变更，`updatedata/3.2.0/` 只有一份「无需迁移」的声明。
- 环境要求与 3.1.0 相同：macOS Sonoma 14+、Xcode Command Line Tools，**不需要自己装 Python**。
- 自带的 CPython 仍为 3.14.9，已在 3.1.0 装好的用户不会重新下载。
- 新增文件 `pkg/upgrader.py` 已加入部署清单，自更新会一并取回。
