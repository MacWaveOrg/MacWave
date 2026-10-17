# MacWave CI 与踩坑记录

面向要对接 MacWave（尤其是把它移植到别的平台，比如 LinuxWave）的同学。
这里记录 CI 怎么跑、怎么在本机安全复现、以及这一路上踩过的坑 —— 每个坑都写了
**现象 / 根因 / 修法**，因为几乎每一个都是"看起来像 A，其实是 B"。

---

## 一、CI 长什么样

`.github/workflows/format-test.yml` 里两个 job，各自跑 `['3.14', '3.15']` 矩阵
（`fail-fast: false`，一条挂了不取消另一条，否则看不出是哪个 Python 的问题）：

| job | 内容 |
| --- | --- |
| `format-test` | 部署脚本 → 配置路径测试 → 依赖数据审计 → 格式测试 → **依赖链测试** → 版本化链接测试 → selfupdate 测试 |
| `random-test` | 随机化端到端回归（`scripts/random_test.py`） |

`format-test` 里的**依赖链测试**（`scripts/deps_test.sh`）是覆盖最宽的一环：
它会扫 `infosource` 里所有声明了 `deps:` 的包，各取最高版本，逐个跑
「装 → 二进制能跑 → 没有未解析库引用 → 写了引用计数标记 → 卸 → 整条依赖链被级联清理」。
当前是 `btop`、`htop`、`ncdu`、`tmux`、`wget` 五个。

---

## 二、本机安全复现：`MACWAVE_TEST`

端到端回归会装包、改配置、删目录，以前只能在 CI 上跑。现在设一个环境变量就能
把整个程序关进一个目录里：

```bash
export MACWAVE_TEST=~/.test/macwave
python3 lib/wave.py install btop
```

程序会把 `~/.test/macwave` **当作 `/`**：

| 平时 | 测试模式下 |
| --- | --- |
| `/opt/macwave_config` | `~/.test/macwave/opt/macwave_config` |
| `$HOME` | `~/.test/macwave/Users/<你>` |
| `~/.config/macwave_config` | `~/.test/macwave/Users/<你>/.config/macwave_config` |

要点：

- 没设 `MACWAVE_TEST` 时行为**一个字节都不变**（shell 侧靠 `SYS_ROOT=""`，
  `"$SYS_ROOT/opt/..."` 就还是 `"/opt/..."`）。
- Python 侧所有路径都从 `lib/configpaths.py` 的 `rooted()` 出，所以只改一处。
- `install.sh` / `selfupdate.sh` / `uninstall.sh` 可能被 `curl` 直接执行，拿不到
  Python 的变量，所以它们各自解析一遍，并导出 `MACWAVE_TEST_ROOT` 给下游。
- 被 Python 调用的那些 shell（`depsmanager.sh`、`transfer.sh`、`pkgunzip.sh`）不用改：
  它们的路径来自 `BASE_DIR`，且继承重定向后的 `HOME`。

⚠️ **没设这个变量时不要在开发机跑随机回归** —— 早期版本真的把开发机上的
`~/.config/macwave_config/` 清掉过。

---

## 三、踩坑清单

### 1. CI 里 Python 3.15 "假绿"

**现象**：3.15 那条线报 success，但它其实跑在 3.14 上。
**根因**：`actions/setup-python` 的清单里还没有 3.15.0 正式版（报
`The version '3.15' ... was not found`），runner 自带的 Homebrew 也没有
`python@3.15`（`No available formula`）。改用 `astral-sh/setup-uv` 之后，
setup-uv **只把解释器登记给自己用**，PATH 上的 `python3` 还是 Homebrew 的 3.14，
`pip install` 被 PEP 668 挡下（`externally-managed-environment`）。
**修法**：用 uv 建一个带 pip 的 venv 插到 PATH 最前，并**加一步断言**
（`python3 -c 'sys.version_info[:2] == 矩阵版本'`），版本不符直接失败，
免得再次悄悄跑错版本还报绿。

### 2. 安全检查跟随了软链接，把正常操作判成越界

**现象**：`wave link` / `wave unlink` / `wave uninstall` / `install --unlink`
全部报错退出：

```
Error: Unsafe uninstall path escapes …/links: …/bin/htop@3.5.3/htop
```

**根因**：加固时写的 `assert_inside()` 用 `Path.resolve()` 归一化，会**跟随最后一段**
的软链接。而 `links/` 里放的就是软链接（指向 `bin/<名字>@<版本>/<名字>`），
于是"删除这个链接"被解析成"删除 bin 里的可执行文件"，判定为逃出 `links/`。
**修法**：拆成两个函数 —— 会被**写进去**或**递归删除**的路径用严格的
`assert_inside()`（跟随软链接）；只是**操作链接本身**（删除/重指）的用
`assert_inside_entry()`（只校验父目录 + 文件名，不跟随最后一段）。

### 3. `wave info <包名>@<版本>` 被整串拒掉

**现象**：`wave info htop@latest` 报 `Unsafe package name: 'htop@latest'`。
**根因**：白名单校验被套在了整个 token 上，而 `名字@版本` 是 `link`/`install`/
`uninstall` 一直都支持的写法（`@` 不在允许字符集里）。
**修法**：`info` 也按 `名字@版本` 解析，并像其它命令一样忽略 flag。

### 4. 依赖树索引漏掉软链接 —— `btop` 的 `libc++.1.dylib`（**最隐蔽的一个**）

**现象**：`btop --version` 能跑，但安装时报

```
Warning: 1 library reference(s) exist in this installation but could not be linked:
  @rpath/libc++.1.dylib  (被 btop 引用)
```

**根因**：conda 的 `libcxx` 包里，`lib/libc++.1.dylib` 是**指向 `libc++.1.0.dylib`
的软链接**（真实 Mach-O 只有 `libc++.1.0.dylib` 一个）。而依赖树索引用的是
`find -type f`，**软链接一个都没进索引**：

- 重写引用时查不到 `libc++.1.dylib` → 接不上；
- 名字表（用来分辨"我们自己的库"和"外部未声明的库"）同样漏了它 →
  于是被误判成**外部库**，只打一句 `Note` 就放过去了，静悄悄地什么也没做。

**修法**：索引的范围改成 `find <root> \( -type f -o -type l \)`，保留原来的
`[[ -f ]]` 判断（它会跳过悬空链接）。

**排错过程本身也踩了坑**，值得记：

- 诊断信息一开始只记"引用名"，不记"是哪个文件引用的"，分不清是目标文件自己引用
  自己、还是某次重定位发生得太早（依赖还没装）。补上文件名之后才定位到是
  **对 btop 自己的第二次重定位**。
- 然后我加了一个"索引里同名条目 N"的计数，**结果恒为 0** —— 因为我拿的是
  完整引用名 `@rpath/libc++.1.dylib` 去 grep 索引，而索引的键是 **basename**
  `libc++.1.dylib`。这种"诊断本身有 bug"最费时间，所以后来直接改成
  **把索引打印出来**，不再靠推理。

### 5. 依赖数据：`--ver` / 版本 / 路径全链路

- 依赖产物 URL 曾经在 `surfboard/depsinfo_<arch>/` 下，3.0 起搬到独立仓库
  `MacWaveOrg/infosource` 的 `deps/depsinfo_<arch>/`。**改数据前先确认改的是哪个仓库** ——
  我在这上面推错过一次（MacWave 仓库里还留着一个旧结构的 `infosource` 分支镜像）。
- `tmux@3.6` 的二进制需要 `_tiparm_s`，而 infosource 里的 `ncurses@6.4`（只有
  `_tiparm`）和 conda-forge 的 `6.6`（两个都没有）都**不导出**它 ——
  `_tiparm_s` 其实是 defaults 渠道 `ncurses@6.5` 的 **`libtinfow.6.dylib`** 导出的，
  `libncursesw.6.dylib` 再 reexport 它。所以 tmux 3.6 依赖要写 `ncurses@6.5`
  （3.3a 只用 `_tparm`，留在 6.4 没问题）。
  **教训**：查符号别只看主库，`nm -g <dir>/*.dylib` 全扫一遍。
- `ncdu` 引用 `@rpath/libz.1.dylib` 但只声明了 `ncurses` + `zstd` —— `libz` 是
  **zlib** 提供的，漏声明了。
- **卸载必须给 `bin_name`，不是包名**：安装目录是 `bin/<bin_name>@<版本>`，
  两者可能不同（如包 `choma` → `bin_name` `ChOma`）。
- 依赖数据按 `<名字>@<最高版本>` 取，包里 `_<名字>@common` 里才有 `bin_name`。

### 6. `--skip-ssl` 极慢（**尚未修**）

**现象**：`--skip-ssl` 装一个 1MB 的包要 **3~6 分钟**（正常几秒）：

```
… still running: wave install lsd@1.2.0 --skip-ssl (361s)
```

实测 `eza` 461 秒、`wget` 190~206 秒。随机回归里这个用例要装两遍（回答 n / y 各一遍），
于是单它一个就能吃掉十几分钟，最终把整轮拖过 step timeout。
**下一步**：看 `pkg/pkginstaller.py` 里 `--skip-ssl` 那条路径为什么慢（怀疑每一步都在
等 SSL 超时后重试），这是**还没解决**的坑。

### 7. CI 超时不该等于"判定失败"

**现象**：一轮 `random-test` 被 100 分钟的 step timeout 杀掉，日志尾部全是
`Terminate orphan process`，结论只能是一个干巴巴的失败。

**根因**：外部 timeout 是给整个进程组发 SIGKILL，脚本里**捕获不到**，所以
"没跑完"和"测出 bug"分不开。
**修法**：让脚本自己管预算 —— `random_test.py` 加了 `--time-budget`，每条命令发起前
检查 deadline，用尽就抛 `TimeBudgetExhausted` 由 main 接住，**标注成 SKIP 后照常汇总**。
CI 传 145 分钟，step timeout 165 分钟只当兜底。
（顺便记一下平台的硬限制：**单个 job 最长 6 小时**，不是 10 小时。）

### 8. 依赖链测试本来只测一个包

**现象**：CI 日志里 `install wget@1.25.0` 永远只有它一个。
**根因**：`deps_test.sh` 只接**一个**位置参数，默认值是 `wget@1.25.0`，
而 workflow 调它时**不带参数**。跟包体积、跟 40MB 上限都无关。
**修法**：不带参数时自动扫 `infosource` 找出所有带依赖的包，逐个跑，一个失败不中断其它的。

### 9. GitHub API 限流

`api.github.com` 未认证只有 **60 次/小时**，而 CI runner 共用出口 IP，很容易踩到。
`pkg/pkginstaller.py` 与 `pkg/pkginfohelper.py` 在拿到 `GH_TOKEN` 时会带上鉴权
（**只发给 api.github.com**），CI 里已经传了 `GITHUB_TOKEN`。
回归脚本会把限流/403 识别成 **SKIP**（环境问题），而不是 FAIL。

### 10. 其它零碎但很费时间的

- **Python 输出块缓冲**：管道下 stdout 是块缓冲的，CI 日志会"二十分钟没有输出"，
  看起来像卡死。用 `-u` / `PYTHONUNBUFFERED=1`，回归脚本额外做了 flush + 心跳。
- **pty 里的 `input()`**：不喂换行会永远阻塞。
- **macOS 没有 `timeout` 命令**（别在脚本里用它）。
- **macOS 的 `bsdtar` 没有 `--mtime`**（打确定性归档要用 Python 的 `tarfile`）。
- **`gh api .../logs` 会拒绝含终端转义的输出**，改用 `curl -H "Authorization: Bearer $(gh auth token)"`。
- **GitHub Actions 的 job 日志在 job 结束前拿不到**（`BlobNotFound`）。
- **`.conda` 是 zip 包着 `.tar.zst`**，需要 `compression.zstd`（这也是 Python 下限是 3.14 的原因）。
- **Python 3.15 的 `Path.resolve()` / `re` 等没有影响本项目的行为**；
  3.15 起 UTF-8 模式默认开启（PEP 686），`argparse` 的 dest 推断有变。
- 终端里 `gh` 会把看起来像密钥的字面量打码显示，别据此判断源码内容（用 `hexdump` 核对）。

---

## 四、移植到 Linux（LinuxWave）要点

1. **软链接索引那个坑是平台无关的**（`find -type f` 漏 symlink），Linux 上同样要按
   basename 收录软链接，否则 `libfoo.so.1 -> libfoo.so.1.2.3` 这类库一样接不上。
2. macOS 用 `install_name_tool` + `otool -L`，Linux 是 `patchelf --replace-needed` / `--set-rpath`
   + `readelf -d`；**"库引用 → 实际路径"的索引逻辑可以照抄，工具层要换**。
3. `_tiparm_s` 这类是 macOS/conda 构建的产物差异，Linux 侧对应的是
   `libncurses.so.6` 的 soname 与符号版本，别照搬版本号，照抄**方法**（全库扫符号）。
4. `dylib` / `@rpath` / `LC_ID_DYLIB` 这套概念换到 Linux 是 `.so` / `$ORIGIN` + RPATH / SONAME。
5. 权限模型不同：macOS 上 `/opt` 要 sudo，Linux 上通常也是，但 `MACWAVE_TEST`
   的隔离思路（把某个目录当 `/`）可以直接复用，能省下大量"只能在 CI 上试"的时间。
6. CI 里 `MACWAVE_TEST` 能替掉现在"`sudo mkdir /opt/...` + 手工改 HOME"那套 setup。

---

## 五、2026-10-17：一次「长红」的完整复盘

这一轮 Format Test 从 10-11 起断断续续红了两天，中间夹着几次「看起来绿了又红」。
真正的原因只有一个，但排查路径上有好几处会把人带偏，所以单独记下来。

### 11. `set -e` 撞上 `[[ 条件 ]] && 命令`：空依赖树让安装失败

**现象**：Format Test 的每一个测试包都报 `FAIL: install test_bin_*`，但日志里明明
写着 `Successfully installed`、`Binary installed to …`、`Link created at …`；紧接着
Random Test 也有零星几个包 `exit=0 <- 实际 1`，并且都伴随「不带版本号的链接不存在」。

**原因**：路径重写脚本在建立「库文件名 → 实际路径」的兜底索引时，是这样遍历的：

```
for tree in "$BASE_DIR"/deps/*/*; do
    [[ -d "$tree" ]] && index_tree "$tree" "$MAP_FILE"
done
```

一个依赖都没装时，通配符不展开，`[[ -d ]]` 为假，`&&` 整个表达式返回 1。脚本开头有
`set -e`，于是**立刻中止**。此时包本体已经解压、带版本号的链接也建好了，所以前面的
成功日志全是真的 —— 失败发生在最后的重定位阶段，而那一步之后才是「建不带版本号链接」。

Format Test 的测试包恰好都没有依赖，所以**每一个**都踩中；Random Test 只影响「第一个
带依赖的包装好之前」被抽到的那几个，于是表现成随机、偶发，最容易被当成 flaky。

**引入**：`01a0a71`（把索引改成一次扫完以提速）—— 提速本身是对的，错在把循环体写成
了 `[[ ]] && 命令` 这种「条件为假就返回非零」的形式。

**修复**：`6a87b86`，四处都改成显式 `if … then … fi`。空依赖树变成真正的 no-op。

**教训**：`set -e` 的规则是「任何一条命令返回非零就退出」，而 `[[ ]] && cmd` 在条件为假时
**整体返回 1**。循环体、函数体里用这种写法，正常分支也会变成致命错误。要么写 `if`，
要么在末尾补 `|| true` —— 前者更清楚。

### 12. 限速校验用单次采样差值，把 token bucket 的突发放大成「超速」

**现象**：Random Test 偶发一条失败：`--limit-rate 400K: 瞬时未超速（峰值 873K/s，
容差 x2.0）`，而同一次运行的「全程平均」判定是通过的（2.1MB / 9.1s = 231K/s）。

**原因**：瞬时速率取的是相邻两个 0.2 秒采样点的差值。限速器是 token bucket，允许
成批放行；一次 8KB 的突发落在某个 0.2 秒区间里，就会算出几百 K/s 的尖峰。那既不是
持续超速，也不影响用户体感，但断言会失败。

**修复**：`4b9ef56`，改成「至少 1 秒滑动窗口内的平均速率」再取最大。用失败现场的数据
复算，旧算法 875K/s、新算法 479K/s（通过）；同时构造一个真实的 1MB/s 持续下载，新算法
仍然读到 1024K/s（会失败）—— 也就是说放宽的是噪声，不是判定本身。

**教训**：给「速率」下断言时，必须先定义测量窗口。采样间隔天然抖动，单点差值测的是
瞬时吞吐，不是限速器的行为。另外，**修 flaky 断言要证明它仍能抓到真问题**，否则就是
在把测试改绿。

### 13. 索引里的记录指向了已被删除的文件

**现象**：`wave install test_no_sha256` 报
`ErrorCode 404 - The URL or file does not exist`。

**原因**：这两个包是**故意做坏的负向测试样本**（一个缺 `sha256`，一个 `sha256` 全错），
用来验证安装器的两条错误分支。它们的载荷文件原本在仓库根目录，`04564a1`（"completely
replace main with 2.1.0"）重写主干时把它们删了，但索引记录没跟着改。更糟的是两个架构
还不一致：arm64 指向根目录，amd64 指向 `test/` —— 而 `test/` 这个目录**从来没有存在过**。

**修复**：`d5350d6` 把两个文件恢复到 `test/`，索引侧 `030a8aa` 把四个记录统一指向新路径。

**教训**：数据仓库和代码仓库是**两个独立的生命周期**。删除代码仓库里的文件时，没有任何
机制会提醒你索引还在引用它。凡是索引里出现的 URL，都应当能在对应分支上取到；负向测试
样本尤其容易漏，因为它们平时不会被安装。校验器现在能检查 URL 是否 HTTPS，但**不会
联网确认它是否 200** —— 需要的话得用审计脚本的 `--check-urls`。

### 14. 分支保护一上，`GITHUB_TOKEN` 的镜像工作流立刻失效

**现象**：给所有分支加「必须经 PR」的规则集之后，`sync-release-branch` 推送会被拒绝。

**原因**：`GITHUB_TOKEN` 代表的是 GitHub Actions 机器人，而规则集的 bypass 名单只接受
**组织管理员、团队、部署密钥、已安装的 GitHub App**。机器人身份无法进入名单。这一点
无法通过改工作流权限绕开（`permissions: contents: write` 只影响 token 的能力，不影响
规则集的豁免判断）。

**修复**：镜像工作流改用 PAT（属主是组织管理员，天然在 bypass 名单里）。同时要注意
PAT 触发的 push 会**再次触发**同一工作流 —— 第二次运行会发现两侧已相等而退出，所以
不会循环，但注释里要写清楚，否则下一个人会以为有 bug。

**教训**：加分支保护之前，先找出所有「以机器人身份直接 push」的地方。除了镜像，还包括
自动化开 PR（那是 `create-pull-request`，走 PR 不走 push，不受影响）。这类改动必须和
规则集**同一次**完成，否则会出现「保护刚生效、流水线就断」的窗口。

### 15. 自动化 PR 不能请求作者本人 review

**现象**：`discover` 作业在最后一步失败：
`Review cannot be requested from pull request author.`（422）。

**原因**：工作流用 `reviewers: <维护者>` 指定审阅人，而 PR 是用同一个维护者的 PAT 开的
—— GitHub 不允许把 PR 作者设为审阅人。

**修复**：`a812389` 之前的那次修正改为 `assignees:`。指派同样能起到「通知到人」的作用，
且没有这个限制。

**教训**：用 PAT 开 PR 时，「谁来审」和「谁来开」必须分开考虑。若坚持要 review 请求，
就得用一个**不是** PR 作者的账号来开 PR。

### 16. 这几件事共同的排查方法

顺序比技巧重要：

1. **先确认红的是不是自己刚改的。** 看 `gh run list` 里失败运行对应的 commit，和
   `git log` 对时间。这次的红从 10-11 就开始了，与文档提交无关。
2. **从最早的那次红开始看。** 后面的红往往只是同一个根因的重复。
3. **区分「作业红」和「断言红」。** 作业整体红可能只是某一条断言；`--log-failed` 里
   先找 `##[error]`，再看它前面最后一条成功日志 —— 卡在哪一步比错误文本更有信息量。
4. **成功日志与退出码矛盾时，信退出码。** `Successfully installed` 之后仍然 `exit 1`，
   说明失败在更后面，别被前面的输出骗了。
5. **用真实数据回放。** 校验器那类改动，拿一个**已经合并过的历史提交**跑一遍，比构造
   测试用例更有说服力（这次就是回放 `df541ed` 才发现会把正常提交判红）。
6. **修完 flaky 要构造反例。** 限速那条改完后，特意模拟一个真超速的场景，确认新算法
   仍然会失败。

### 17. 这轮留下的两个待办

- **索引记录的 URL 没有定期可达性检查。** 目前只能靠审计脚本手动带 `--check-urls`。
  可以考虑加进每日流水线，把 404 在用户发现之前暴露出来。
- **`test_*` 这类负向样本没有任何自动化在用。** 它们靠人工记得才能验证。若要让它们
  真正有价值，应当在 CI 里对它们跑一遍并断言**预期的那条错误**，而不是只让它们存在。
