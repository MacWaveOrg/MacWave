# CI 与踩坑记录 · 补充（2026-10-12）

接着 [CI-AND-PITFALLS.md](./CI-AND-PITFALLS.md) 写。那份写于 CI 全绿**之前**，
当时 `btop` 那条依赖链还是红的、`--skip-ssl` 的慢也没定性。

这一轮：**CI 首次全绿**（`0363615`，`main` 与 `3.0` 都过），依赖链测试
**5 个包 5 ok / 0 failed**。下面把最后几个坑补完，并如实记下"绿得不完全"的部分。

---

## 一、`btop` 的根因：依赖包被摊平了（**这份文档里最重要的一条**）

上一份文档里 `btop` 还是"索引漏软链接"的猜测，**猜错了**。真实根因完全不同。

### 现象

只有 `btop` 红，其它四个（`htop` / `ncdu` / `tmux` / `wget`）都绿：

```
Warning: 1 library reference(s) exist in this installation but could not be linked:
  @rpath/libc++.1.dylib  (被 btop 引用)
```

### 排查过程（值得学的部分）

我先后猜了三次，**三次都错**，最后靠"打印事实"才定位：

| 猜测 | 实测结果 | 结论 |
| --- | --- | --- |
| 解包没还原软链接 | `ls -la` 显示 `libc++.1.dylib -> libc++.1.0.dylib`，**有效** | ✗ |
| 索引漏了软链接（`find -type f`） | 改成 `\( -type f -o -type l \)` 后判定从 `Note` 升成 `Warning`，**但仍然接不上** | 只对了一半 |
| 索引没建起来 | 打印索引：`map=2`（只有 btop 和 _DEPS） | ✓ 但为什么？ |

最后加的这行实测数据是转折点：

```
🌊 [索引] deps/libcxx/libcxx@23.1.2  map=7  tree=14  deps_lib=0  _DEPS=yes
🌊 [索引] bin/btop@1.4.7              map=2  tree=9   deps_lib=0  _DEPS=yes
```

**自相矛盾**：`tree=9` 说明 `"$BASE_DIR"/deps/*/*` 匹配到了 `libcxx@23.1.2`
（2 个自己的文件 + 它的 7 个），可同一时刻 `"$BASE_DIR"/deps/*/*/lib` 是 **0 条**。

答案在诊断输出的路径里（**注意 `libc++` 是文件名，不是 `lib/` 目录**）：

```
/tmp/macwave-test/deps/libcxx/libcxx@23.1.2/libc++.1.0.dylib   ← 直接躺在版本目录下
```

**没有 `lib/` 这一层。** 而同一个包在 conda 里本来是 `lib/libc++.1.0.dylib`。

### 根因

`surfboard/depsmanager.sh` 的 `mw_extract_all` 里有个启发式：

```bash
# 只有一个顶层目录时视为包装目录，下沉一层便于后续搬运
local entries=("$extract_dir"/*)
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
    echo "${entries[0]}"; return 0
fi
```

它假设"唯一顶层目录"是**包装目录**（像 `package-1.0/`）。但 **libcxx 的包里只有
`lib/` 一个顶层目录**（没有 `bin/`、`include/`），于是 `lib/` 被当成包装目录下沉，
库文件被摊平到 `deps/libcxx/libcxx@23.1.2/` 根下 → **`<dep>@<版本>/lib` 这一层
根本不存在**。

这一下把所有矛盾现象都解释通了：

| 观测 | 解释 |
| --- | --- |
| `tree=9` 有 `libc++.1.dylib` | 名字表扫整棵树 ✓ |
| `map=2` 索引里没有 | 索引只扫 `.../lib`，而它不存在 ✗ |
| 判成 MISSING 而非 EXTERNAL | 名字表里有、映射表里没有 |
| **只有 btop 红** | 只有它依赖 libcxx；`ncurses` 有 `lib/`+`include/`+`bin/` ≥2 个顶层目录，**不触发下沉** |
| `deps_lib=0` | `deps/*/*/lib` 一个都匹配不到 |

### 修法（两处，缺一都会留洞）

1. **`mw_extract_all` 不再下沉进内容目录**：`lib` / `bin` / `sbin` / `include` /
   `share` / `man` / `etc` / `libexec` 是内容目录，不是包装目录。
   （否则"只有 `bin/` 的依赖"会被摊平，连可执行文件链接都丢。）
2. **`transfer.sh` 的依赖索引进整棵树**，不再只扫 `lib/`，任何布局都能解析。
   顺带删掉了因此没人用的 `map_add_dir`。

> ⚠️ **权衡**：整棵树进索引后规模从 2 条涨到几千条（`map=6098`），理论上存在
> "同名文件不在 `lib/` 下被误匹配"的可能。当前 5 个包没触发。若将来要收紧，
> 正确做法是**优先 `lib/`，整棵树只作兜底**，而不是完全平等。

---

## 二、依赖链测试的最终成绩

`format-test` 的依赖链测试现在覆盖 5 个带依赖的包，全绿：

```
🌊 Dependency chain test: 5 package(s), 5 ok, 0 failed
```

| 包 | 状态 | 备注 |
| --- | --- | --- |
| `btop@1.4.7` | ✅ | 本轮的摊平修复 |
| `htop@3.5.3` | ✅ | |
| `ncdu@2.9.2` | ✅ | 依赖补了 `zlib` |
| `tmux@3.6` | ✅ | 依赖改用 `ncurses@6.5` |
| `wget@1.25.0` | ✅ | |

索引规模也恢复健康，例如 `bin/wget@1.25.0 map=5314 tree=4427 deps=14`。

---

## 三、"全绿"里两处不完美（下次接手先看这条）

### 1. `random-test (3.14)` 其实**没跑完**，但 job 报了 success

日志：

```
🌊 时间预算用尽：停止发起新命令，直接汇总本轮已跑过的用例
  SKIP  time-budget  <- 本轮未跑完，剩余用例没有执行
```

`--time-budget 145` 用尽后抛 `TimeBudgetExhausted`，被标成 **SKIP**，
而 SKIP 不影响退出码 → job `success`。

**这是有意设计**（"没跑完"不该等于"测出 bug"），但副作用是
**绿灯掩盖了未覆盖率**。想改进的话有两条路：

- 给 job 加一个显式输出（如 `partial=true`），或
- 减少随机用例数，让它**在预算内能跑完**（更实在）。

### 2. 慢的根源是**网络抖动/限流**，不是 MacWave

同一轮 CI、同一脚本：

| job | 耗时 |
| --- | --- |
| `random-test (3.15)` | **11 分钟**（跑完） |
| `random-test (3.14)` | **2 小时 35 分**（预算用尽，没跑完） |

差 14 倍，只可能来自网络。单条命令的实测耗时：

| 命令 | 耗时 |
| --- | --- |
| `wave install tree` | 1055s |
| `wave install bat --limit-rate 400K` | 896s |
| `wave install lsd --skip-ssl` | 862s |
| `wave install lsd` | 823s |
| `wave install palera1n` | 767s |
| `wave install htop` | 691s |

**这些包都只有几十 KB~1MB**（`lsd` 装完才 1MB），正常几秒。所以：

- **不要**据此认为"MacWave 安装慢" —— `format-test` 的依赖链测试装 5 个包 + 14 个依赖
  只用 18 分钟，同样的包同样快。
- `random-test` 一轮要发起 100+ 次网络操作（每次 install 都要拉版本信息、下载、
  可能还有依赖），**天然容易被限流/抖动放大**。
- 之前怀疑的 `--skip-ssl` 特有问题 **不成立**：`lsd` 普通安装 823s、
  `--skip-ssl` 862s，几乎一样 —— 慢与 `--skip-ssl` 无关。

**附带发现**：`--skip-ssl` 的确认是**裸 `input()`**（`pkg/pkginstaller.py:209`），
非交互场景（stdin 是 `/dev/null`）会直接 `EOFError`。同一文件 `:359` 下载失败的
重试提示也是裸 `input()`。`random-test` 在 pty 里每 2 秒喂换行，恰好能把它"答掉"
（读成空串 → 不重试 → `exit 1`），所以没暴露。**建议动手改成：
非 tty 时直接取默认值**（`--skip-ssl` 视为拒绝、重试视为不重试）。

---

## 四、排查方法论的教训（比具体 bug 更值钱）

1. **别推理，打印事实。** 我在这一个 bug 上错了三次，每次都是"看代码觉得应该是这样"。
   真正定位靠的是三行实测输出：引用者是谁、索引有多大、依赖树有几个。
2. **诊断代码自己也会有 bug。** 我加过一个"索引里同名条目 N"的计数，**恒为 0** ——
   因为拿完整引用名 `@rpath/libc++.1.dylib` 去 grep 索引，而索引的键是 **basename**。
   这种"诊断骗人"最费时间。后来改成**直接把索引打印出来**，不再靠推理。
3. **对比出真知。** "只有 btop 红"这个事实就是最强的线索 —— 五个包里唯一依赖
   `libcxx` 的那个。**先找差异，再找原因。**
4. **让环境变量说话。** `map`/`tree`/`deps` 这种规模数字，比任何一句
   "接不上"都更能指出方向。
5. **对"绿"保持怀疑。** 上面那条 SKIP 就是教训：绿灯不等于跑完，
   要看 summary 数字，不只看 job 图标。

---

## 五、给 LinuxWave 的移植清单（在上一份基础上补充）

1. **"唯一顶层目录就下沉一层"这个启发式，Linux 上同样会踩**。conda/conda-forge 的
   包在两边布局一致，`libcxx` 这类"只有 `lib/`"的包在 Linux 上会把 `.so` 摊平。
   移植时优先修这个，或直接别做下沉。
2. **依赖树索引要覆盖任意布局**，不要假设 `<dep>@<版本>/lib` 存在。
3. **诊断信息要带"是谁引用的"**，只记引用名会分不清"目标文件自己引用自己"还是
   "某次 relink 发生得太早"。
4. **非 tty 环境下不要用裸 `input()`**（CI/脚本里必炸）。
5. **测试的时间预算要自己管**，别让 CI 的外部 timeout 当判据 —— 被 SIGKILL 的 job
   分不清"没跑完"和"测出 bug"。
6. **别用"单次耗时"判断性能**：先看同一轮里同类 job 的耗时差异，
   差异大就是环境问题。
