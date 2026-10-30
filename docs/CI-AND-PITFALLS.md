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

### 10. 升级「成功」了，但两个 404 和一次覆盖都没被当成失败（4.1.1）

**现象**：`wave selfupdate` 从 4.1.0 升 4.1.1，终端里是这样：

```
🌊 Downloading pkg/__pycache__...
curl: (56) The requested URL returned error: 404      ← 重试了 3 次
🌊 Error: cannot download pkg/__pycache__
🌊   https://REPOHUBUSER1:RCtSwVprSAa8sfFaLd2PXgyH@mirror.repohub.top/...
🌊 Downloading surfboard/__pycache__...
curl: (56) ... 404
🌊 Error: cannot download surfboard/__pycache__
...
🌊 MacWave has been updated to 4.1.1!                 ← 居然报成功
```

**这一条里其实有三个独立的问题**，前两个是同一个根因的两个后果。

#### 10.1 清单里的 `__pycache__` 从哪来 —— 发版命令自己带的

`docs/RELEASE-CHECKLIST.md` 第 4 步原本写的是：

```bash
--files lib/*.py lib/*.sh pkg/* surfboard/*
```

**shell 通配符在真实工作区里展开**，`pkg/*` 会匹配到 `pkg/__pycache__` 这个
**目录**，`lib/*.sh` 会匹配到 `lib/install.sh` 与 `lib/uninstall.sh`。四条脏
条目一条不少：

```
lib/install.sh          ← 本该被 EXCLUDED 挡掉
lib/uninstall.sh        ← 同上
pkg/__pycache__         ← 目录，git 里根本不存在
surfboard/__pycache__   ← 同上
```

而生成器里那两行过滤（`name == "__pycache__"`、`repo_path in EXCLUDED`）**只写在
`files_from_git()` 里**。`--files` 是另一条入口，直接 `files = args.files` 就往下
走了 —— 过滤器根本没经过。

> 这就是「过滤器写在某个入口里」的典型后果：换条入口就全漏。

**修法**：把两个过滤器收进 `sanitize(paths)`，放在「清单到手之后」这一处，
不管来自 `--files` 还是 git 都要过；被丢掉的条目打印出来（清单少一行没人知道）。
文档也改成省略 `--files`（按 `--ref` 读仓库树，那里没有 `__pycache__`），
确实要显式传时用 `git ls-tree` 而不是 shell 通配符。

#### 10.2 为什么 404 了还报成功

`want` 失败时 `return 1`，而调用它的是：

```bash
install_delta() {
    want lib/configerror.py 0
    want lib/configpaths.py 0
    ...几十行裸调用...
}
```

**没有 `|| exit`，脚本也没有 `set -e`，调用方 `install_delta || return 1` 拿不到
任何信号** —— `return 1` 的返回值被下一行 `want` 覆盖了。

于是脚本退出码 0 → `lib/selfupdate.sh` 认为成功 → 写 `VERSION.json` →
**版本号前进了，但安装树少了文件**。这种状态最难查：用户以为升好了，
下次报错的地方和原因隔了几百行。

**修法**：`want` 里改成 `exit 1`（不是 `return`）。同一类的还有两处也静默忽略：

```bash
run mv -f "$partial" "$destination"     # 权限不足时文件还在 .macwave-part 里
run chmod +x "$destination"             # 装好了但命令跑不起来 → command not found
```

都改成检查返回值。`--delta` 过滤后为空也要硬失败 —— 一条 `want` 都没有的
`install_delta` 会瞬间成功返回，等于「升级了但什么都没换」，连报错都没有。

> **判断标准**：子脚本里每一个「可能失败的动作」都要问一句「失败了谁看得见」。
> 答案若是「没人」，就得 `exit`，而不是 `return`/忽略。

#### 10.3 报错把镜像密码打进了终端

`want` 失败时 `echo "🌊   $url"`，而用镜像时 `MACWAVE_CORE_URL` 是
`https://<用户>:<密码>@mirror/...`。这段输出会被贴进 issue、群聊、截图。

模板里加 `redact_url`，`pkg/pkginfohelper.py` 与 `surfboard/depsinstaller.py`
里同样的 `print` 也改用 `domains.redact_url`。

**只在 `//` 之后、第一个 `/` 之前找 `@`** —— 路径里的 `@` 是合法文件名
（`jq@1.8.2.arm64`），拿整条串找最后一个 `@` 会把包名当成密码位置，把地址改坏。

#### 10.4 已经发出去的坏产物也要修

光改代码不够：`Selfupdate/macwavedata/4.1.1/update_commands.sh` 已经在线上，
**所有从 4.1.0 升上来的人都会踩**。所以按新生成器重发了一份（25 个文件，
逐字节核对过本地与线上）。改代码只保护下一个版本，改数据才保护这一个版本。

**新增回归** `scripts/update_commands_test.sh`（30 条，已进 `format-test`），
钉死上面每一条。其中「`mv` 覆盖失败」用 `chflags uchg` 把目标文件设为不可变
来制造 —— 这个场景平时几乎不可能自然复现，但一旦发生后果就是静默半成品。

### 11. 其它零碎但很费时间的

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
