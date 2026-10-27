# 3.2.1 发布说明

> 面向升级用户的完整说明。技术细节见 [TECHNICAL-GUIDE.md](./TECHNICAL-GUIDE.md)。
>
> 发布日期：2026-10-27 · 构建号：`300A1345` · 发布分支：`3.2`

---

## 一句话

`wave upgrade` 里那个「同时移除旧版本」的旗标，现在有四种写法，完全等价，其中包含一个真正的短参数 `-X`。

---

## 这次改了什么

以前只有一个合法写法 `--remove-old-version`，另外还有一个缩写 `--rov`。问题在于单复数记不牢 —— 有人写 `-version`，有人写 `-versions`，写错的那一半人会直接拿到 `illegal fields` 的报错，而这条错误信息完全没提示「你是不是想写另一个」。

现在四种写法都收：

```sh
wave upgrade jq --remove-old-version      # 原有
wave upgrade jq --remove-old-versions     # 新增，单复数都认
wave upgrade jq --rov                     # 新增，缩写
wave upgrade jq -X                        # 新增，短参数
```

`-X` 也认混在短旗标簇里的写法，`-Xv` 等于 `-X -v`，与 `-abc` 拆成 `-a -b -c` 的既有规则一致。

### 为什么短参数是 `-X`

一开始就想给个短参数，但没有合适的字母：`R` 与 `r` 需要留给将来的递归（recursive）、反转（reverse）、回滚（rollback），占了它们以后就没得用了。

`X` 没有别的含义，不影响任何预留；而且它的形状像「删除」的叉，算是一种象形，比记一个缩写更容易回想起来。

---

## 旧版用户可能会看到一次停顿

如果你从 **3.2.0 或更早** 升级，`wave selfupdate` 有可能在

```
🌊 Removing stale bytecode cache: surfboard/__pycache__
```

之后停住不动，最长约一分钟。

**这不是卡死，也无需担心。** 那一段是旧版脚本在联网确认自带解释器的版本声明，
期间没有任何输出，看上去像挂住了。三点说明：

- **不影响功能**，等它继续即可，升级会正常完成。
- 这次的更新脚本改成了「先看本机有没有能用的解释器，没有才联网」，所以**更新完成之后这一步不再发请求**，停顿随之消失。
- 即使中途按 Ctrl+C 也没关系：自更新是幂等的，失败不会留下半升级状态，重跑一次即可。

---

## 升级方式

```sh
wave selfupdate
```

从 2.x 或更早升级仍需重装：

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/MacWaveOrg/MacWave/HEAD/lib/install.sh)"
```

---

## 兼容性

- 没有目录结构变更，`updatedata/3.2.1/` 只有一份「无需迁移」的声明。
- 环境要求与 3.2.0 相同，自带 CPython 仍为 3.14.9，已装好的用户不会重新下载。
- `--remove-old-version` 与 `--rov` 的行为一个字都没变，只是多了两个等价的写法。
- `wave upgrade` 的其余行为全部不变：先装新的再清理旧的、索引落后时只提示不降级、非交互时一个都不删。
