# MacWave 4.1.0 发布说明

> 本文说明 4.1 的变更范围、使用方式与已知限制。
> 新增内容仅一个命令，不涉及数据格式，升级无迁移步骤。
>
> 镜像站的搭建与变量含义参见 [MIRROR-SETUP.md](./MIRROR-SETUP.md)，
> 数据层的文件布局参见 [DATA-LAYER.md](./DATA-LAYER.md)。
>
> 发布分支：`main`

---

## 概述

4.1 新增 `wave mirror`：一条命令列出每一类数据**实际从哪个地址取**，并标明该地址
来自环境变量还是内置默认值。

这不是新功能，而是让已有功能可被观察。4.0 起所有远端地址都可替换，但替换之后
「这次到底走了镜像还是官方地址」只能靠逐个 `echo` 环境变量来推断 —— 而其中几项带着
密码，不方便随手打印。

---

## 变更动因

1. **判断成本高。** 八个来源分散在八个变量里，且每个都有内置默认值。用户看到的是
   「没设」还是「设成了空」在 `echo` 里无从分辨；
2. **凭据容易被贴出去。** 排查问题时最自然的动作是 `echo $MACWAVE_API_DOMAIN`，
   而它的值里有密码，往往就留在群聊记录里了；
3. **镜像是否生效无从确认。** 设了变量不等于生效（拼错名字、没重载 shell 都会失效），
   而失败时的表现是「还是慢」，很容易误判为网络问题。

---

## 用户可见的变更

### `wave mirror`

```
$ wave mirror
Mirror configuration

  api         default  https://raw.githubusercontent.com/MacWaveOrg/infosource/main
  bottle      default  https://github.com/MacWaveOrg/Bottle/releases/download
  deps        default  https://github.com/MacWaveOrg/Deps/releases/download
  core        default  https://raw.githubusercontent.com/MacWaveOrg/MacWave
  python      default  https://raw.githubusercontent.com/MacWaveOrg/Python/main
  selfupdate  default  https://raw.githubusercontent.com/MacWaveOrg/Selfupdate/main
  sourcecode  unset    (not configured)
  pip         default  https://pypi.org/simple

🌊 env = set by MACWAVE_*_DOMAIN, default = built-in address, unset = nothing to point at yet
```

第二列是来源，三种取值：`env`（环境变量设过）、`default`（内置默认值）、
`unset`（无处可指，如尚未启用的 `sourcecode`）。

设了镜像之后，对应行变为 `env`，并在行尾标 `(auth)` —— 即使整行都被遮蔽，也看得出
「这项需要密码」。

### 几处刻意的设计

- **未设置也打印默认值，不留空。** 留空无法区分「没设」与「设成了空」。
- **密码固定显示六个星号**，不随真实长度变化 —— 否则星号个数会泄露密码长度。
- **`(auth)` 标记**：需要认证的来源单独标出。
- **默认值照常打印**，据此可判断当前用的是镜像还是官方地址。

### 参数

| 参数 | 作用 |
| --- | --- |
| `--json` / `--yaml` / `--toml` | 以该格式输出 |
| `--raw` | 输出可直接粘贴的 `export` 行 |
| `--only-set` | 配合 `--raw`：只导出真正覆盖过的项 |
| `--show-password` | 打印真实密码（默认遮蔽） |
| `--hide-user` | 连用户名一起遮蔽 |

四种输出格式**互斥**，同时给两个会报错，而不是悄悄选一个 —— 「哪个生效」不该靠猜。

`--only-set` 解决「默认值要不要钉死」：`--raw` 会把没设过的项也写成 `export`（值是内置
默认值），配置因此完全可复现，但官方日后修改默认地址时这些行会停在旧值上；加
`--only-set` 则只导出真正设过的项，其余继续跟随内置默认值。

`--json` / `--yaml` / `--toml` 结构一致，每项含 `name`、`env`、`source`
（`env` / `default` / `unset`）、`requires_auth`、`user`、`value`。

### 已删除的说法

中文版 README 原有一句「刻意没有 `wave mirror`，就像 Homebrew 没有 `brew mirror`」。
本版新增了该命令，这句已移除，改为说明如何用它确认当前生效的地址。

---

## 兼容性

- **未设置任何环境变量时，行为与 4.0 完全一致**，输出只读不写；
- 新命令只读环境变量与内置默认值，**不联网**，可安全用于脚本与离线排查；
- 不涉及数据格式变更，无需迁移；
- 新增命令不改动任何既有命令的参数或输出。

---

## 本版随附的数据

Release 中共 48 个资产：

- `MacWave-4.1.0.tar` / `MacWave-4.1.0.tar.gz` —— 完整源码归档；
- 46 个扁平展开的 `.py` / `.sh` —— 便于逐个下载查看，解包后与原树逐文件一致。

校验方式与四个注意事项（文件名撞名、`--clobber`、`--no-xattrs`、从 tag 建归档）
记在 [RELEASE-CHECKLIST.md](./RELEASE-CHECKLIST.md) 第七步。

---

## 安装与升级

```
wave selfupdate
```

已装 4.0 的用户无需改动任何配置：镜像变量、数据布局、索引格式均未变化。

---

## 已知限制

- **`sourcecode` 恒为 `unset`。** 该来源尚无对应地址，命令如实显示，不编造默认值；
- **只报告配置，不报告连通性。** 想确认地址真的可用，仍需实际取一次数据 ——
  `wave mirror` 刻意不发请求，以免在离线或受限网络下卡住或误导；
- **不校验变量名拼写。** 拼错的变量（如 `MACWAVE_API_DOMIAN`）不会被 `wave mirror`
  发现，它只是照常显示 `default`。看到 `default` 而你以为设过了，就该去查拼写。

---

## 相关仓库

| 仓库 | 内容 |
| --- | --- |
| `MacWaveOrg/MacWave` | 客户端与安装器 |
| `MacWaveOrg/infosource` | 包索引 |
| `MacWaveOrg/Bottle` / `MacWaveOrg/Deps` | 预取的产物 |
| `MacWaveOrg/Selfupdate` / `MacWaveOrg/Python` | 自更新脚本与解释器 |
