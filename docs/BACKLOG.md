# 待办与已记录的需求

这里只记「已经想清楚、还没做」的东西。做完一项就把条目删掉，结论落到代码与文档里 ——
不要把它养成第二份文档。

---

## 4.4.1

### 进度条占一行刷新，用户按过回车才另起一行

**现状。** 下载进度有两种画法，各说各的：

| 场景 | 实现 | 表现 |
| --- | --- | --- |
| 交互（非 `--raw`） | `rich` 的 `Progress`（`pkg/pkginstaller.py:594`） | 原地刷新，天然只占一行 |
| `--raw` | `pkg/pkginstaller.py` 的 `_emit()`（`:504`） | 每 10% **打一行** `####....  30%` |

用户看到的就是后者：`wave install test_bin_gz --raw` 打了 10 行。

**需求。** 进度条始终在**同一行**上刷新（`\r` + 覆盖），不要刷屏；例外是用户自己按过
回车 —— 这时不能再覆盖（会吃掉用户刚敲的东西 / 那一行已经是一个新行），改为另起一行继续。

**要一起想清楚的三点。**

1. **`--raw` 的契约会被改掉。** 现在 `--raw` 的定义是「机器可读：没有光标控制，每 10%
   一行」。改成 `\r` 就是**引入光标控制**，与「日志可以原样重定向到文件」矛盾 ——
   重定向到文件时 `\r` 会把所有进度挤成一行超长文本。
   建议：**TTY 上才用 `\r`，非 TTY（管道/重定向）保持每 10% 一行**。这样 `--raw` 的
   契约变成「无颜色、无艺术字、无 spinner；进度行在终端里原地刷新，重定向时逐行」。
2. **「用户按过回车」怎么判。** 纯 Python 拿不到「刚才有人敲了回车」这个事件（除非
   读 stdin，会与 `--ci` / 管道冲突）。可行的近似：每次刷新前查终端宽度，若当前行
   已经超过宽度则换行；或者干脆用一个**行内标记**：`\r` 之前若检测到别的东西写过
   这一行（记录上次写出的字节数，实际列宽变了）就换行。
   如果做不到，就把这条降级成「**只保证 TTY 下原地刷新**，任何其它写入自然打断它」，
   并在文档里写明 —— 不要假装能检测按键。
3. **测试要跟着改。** `scripts/raw_test.sh:169` 断言「至少一行形如 `rawpkg: ####.... 40%`
   并且最后到 100%」。重定向到文件时行为不变（逐行），所以它**应该仍然通过** ——
   如果改成无条件 `\r`，它会红，那就说明第 1 点没做对。

**验收。**

- `wave install <pkg> --raw` 在终端里只占一行，`30%` 被 `40%` 覆盖。
- `wave install <pkg> --raw > /tmp/log` 时 `/tmp/log` 里仍是逐行 10 条（可 `grep ' 100%'`）。
- `wave install <pkg>`（非 raw）表现不变。
- 进度进行中按回车，后续刷新另起一行，不回退覆盖。

### `wave manual --colour`：接受英式拼写

**现状。** 手册上色只认 `--color`（`cli/manual.py:113` 直接比字符串 `"--color"`，
`cli/flags.py:88` 的白名单里也只有它），文档里写的是 `Colour headings and flags` ——
说明文字用的是英式拼写，旗标却是美式，看着别扭。有人因此敲了 `--colour` 被当成
「不认的旗标」拒掉。

**需求。** `--colour` 与 `--color` 等价。

**落点（三处，别漏）。**

1. `cli/flags.py` 的 `manual = {"--color"}` 加上 `--colour`。**注意别直接塞进
   `ALIASES`**：那条机制是给「改名」用的，`describe()` 会说 `<旧名> is the old name of
   <新名>`（`:196`），而对拼写变体这是**错的** —— 需要一个新的映射（例如
   `SPELLINGS = {"--colour": "--color"}`），让 `describe()` 答
   `--colour is the British spelling of --color`。
2. `cli/manual.py` 的判定改成「两个名字任意一个出现即上色」，`rest` 过滤也要同时
   去掉两者（`:113`、`:114`）。
3. 文档：`cli/commands.py:332/336/342` 的用法行与示例、`cli/help_zh.py:161` 的中文
   说明、`man/` 里对应条目、README 若提到。

**验收。**

- `wave manual install --colour` 与 `--color` 输出一致（有颜色）。
- `wave manual install --colour` 不报「不认的旗标」。
- `wave -h` 里 `manual` 那一行仍只显示规范写法 `--color`（别名不进帮助，只进白名单）。
- `scripts/commands_test.sh`（帮助里的旗标必须在 `flags.ALL` 里）与 `flags_test.sh`
  （`describe()` 的措辞）都要跟着补一条。


---

## 下个版本：rc 目标改成 `.zshrc`，并清掉旧的 `.zprofile` 行

> **2026-11-20 决定：先搁置。** MacWave 继续用 `~/.zprofile` / `~/.bash_profile`，
> LinuxWave 那边单独用 `~/.zshrc` / `~/.bashrc`（已改）。两个项目的前提不同：
> macOS 的终端默认起**登录** shell，`.zprofile` 一定会被读到；Linux 图形终端的
> 终端模拟器起的是**非登录**交互 shell，只有 rc 会被读。等哪天真要统一时再回来
> 看这一条 —— 下面的论证本身仍然成立。

**背景。** 4.4 把 shellenv 那一行写进 `~/.zprofile`（zsh）/ `~/.bash_profile`（bash），
理由是「PATH 是登录级的东西，`.zprofile` 每个登录 shell 只跑一次」。
这个理由在 macOS 上成立但不必要，在 Linux 上则直接不成立（图形终端起的是
**非登录**交互 shell，`.zprofile` 根本不读）。

**结论：改用 `.zshrc` / `.bashrc`，只写一处。**

- `.zshrc` 在**登录 shell 里也会被读**（`zshenv → zprofile → zshrc`），是超集；
  `.zprofile` 能做的它都能做，反过来不成立。
- 「嵌套 shell 重复 prepend」这个唯一真实的优势已经不存在了 —— `wave shellenv`
  的输出自带 `case ":$PATH:"` 守卫，重复 eval 是空操作。
- 「`.zshrc` 非交互不读，所以 `ssh host cmd`/cron 看不见」这条论据是**错的**：
  `ssh host cmd` 是非交互**非登录**，`.zprofile` 同样不读，只有 `.zshenv` 读。
  真要在意那种场景就用 `.zshenv` 或绝对路径，不要靠 `.zprofile`。

**要做的三件事。**

1. `lib/install.sh` 的 `RC_FILE` 选择改成 `.zshrc` / `.bashrc`（`sh/dash` 仍 `.profile`）。
   注释里的理由同步改对，别再留「PATH 是登录级的」那段。
2. **迁移**：升级/卸载时把旧版写进 `.zprofile` / `.bash_profile` 的那一行一并摘掉，
   否则用户文件里会留一行指向可能已失效的路径（这一条比"两个都写"重要得多）。
3. **不要两个都写**：两处同一行，卸载要清两处，用户还会困惑哪行算数。

**验收。** 新装只写 `.zshrc`；从 4.4 升级后 `.zprofile` 里那行消失；`wave shellenv`
执行两次 PATH 不变长。
