# AGENTS.md

给在此仓库工作的编码代理（Codex、Claude Code、Copilot 等）的项目约定。

`CLAUDE.md` 是指向本文件的符号链接 —— Claude Code 读 `CLAUDE.md`，Codex 读 `AGENTS.md`，两者指向同一份内容，改这里就够，不要分别维护。

## 与用户交流

- **和用户说话一律用中文**：回复、澄清提问、总结、报错解释都是。
  这与下文「注释与文档用中文、终端文案用英文」是两件事，各管一处，不要混。
- 代码标识符、命令、路径、终端输出保持原样，不要为说中文而翻译它们。

## 凭据（本机环境）

本机 `~/.zshrc` 里有 MacWave 的镜像环境变量（`MACWAVE_*_DOMAIN` 等），其中若干项
带着密码。

- **禁止直接读取 `~/.zshrc`**：`cat`、`grep`、`sed`、`source` 一律不行，也不要把它
  的内容复制到别处或贴进对话。
- 需要知道当前生效的地址时，**只用 `wave mirror`**：它默认把密码打码成固定的六个
  星号，星号个数与真实长度无关。
- **禁止给 `wave mirror` 加 `--show-password`** —— 也不要把它写进任何测试、脚本或
  CI 步骤。那会把密码打进入终端、日志与构建产物。
- 输出要转给别人时，再加 `--hide-user`，连用户名一起盖掉。

## 网络（本机环境）

**本机访问 `raw.githubusercontent.com` 经常连不上** —— 实测 `curl` 直接返回退出码 35
（SSL 连接错误），不是慢，是握手就断。这是本机的链路问题，重试通常也无效，别把它
当成代码或配置错误去排查。

取仓库里的文件内容，**优先用 `gh api`**，它走 `api.github.com`，同一条链路上正常：

```bash
gh api repos/MacWaveOrg/configdata/contents/versiondata/latest_version \
  -H "Accept: application/vnd.github.raw"

gh api repos/MacWaveOrg/MacWave/contents/lib/wave.py \
  -H "Accept: application/vnd.github.raw"
```

两点边界：

- **被测行为本身不能换。** 客户端真从 raw 地址取数的那部分（`install.sh`、
  `selfupdate.sh`、`domains.py` 的默认值）照旧用 raw —— 那是要验证的对象，
  用 `gh api` 绕过去等于没测。
- **`git` / `gh` 拉代码不受影响**，只有「用 curl 抓单个 raw 文件」这条路会挂。

## 安全：符号链接不得跳出 base_dir

**若一个软件包（payload）里含有符号链接，必须检测它是否跳转到 `base_dir` 之外。
凡是解析后落在安装根目录外的链接，一律当作缺陷处理，不许跟随。**

这条规则防两件事，缺一半都不成立：

| 攻击者用越界链接能做什么 | 为什么算漏洞 |
| --- | --- |
| 链接指向隐私文件（`~/.ssh/id_rsa`、`~/Library/Messages/…`），再附带一个读它的程序 | 读到用户从未授权的内容 |
| 链接指向 MacWave 之后**要写入**的路径 —— `surfboard/transfer.sh` 的 `install_name_tool` 改写、`.part` → `mv` 落盘、卸载时的 `rm -rf` | 以用户身份在安装树之外写文件、删文件 |

这与「归档里的 `../` 条目」不是同一件事。一个成员的名字可以老老实实待在目标目录内，
而它的**链接目标**指向任何地方：

```
lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
```

`../` 过滤看不见这个，`tar` 自己也不管。

### 唯一的例外：系统库位置

链接落在下面这些位置（含子目录）时不算越界：

```
/bin   /sbin   /usr/bin   /usr/sbin   /usr/lib   /usr/libexec
/System   /Library/Apple
```

两条理由必须同时成立，所以只给这几处开口子：

1. **SIP 提供保护。** 系统完整性保护（SIP）连 root 都拒绝写这些路径，
   「顺着链接去写」那半边威胁不成立；而上游产物里本来就有指向 `/usr/bin` 的正常引用。
2. **那里不含隐私文件。** 只有操作系统自带的二进制与库，没有用户数据，
   「顺着链接去读」那半边也不成立。

其余一律不例外：`/Users`、`/Applications`、`/Library` 里 `Apple/` 以外的部分、`/private`、
`/opt`、`/etc`、`/var` —— 都有用户数据，且大多不受 SIP 保护。

### 实现位置（4.2 起生效）

解压工具自己不做这件事，所以检查放在**解压之后、落盘之前**：

| 环节 | 位置 |
| --- | --- |
| 规则与豁免清单 | [`lib/configpaths.py`](./lib/configpaths.py) 的 `SYSTEM_LINK_PREFIXES` / `escaping_links()` / `assert_links_inside()` |
| 调用点 | [`surfboard/depsmanager.sh`](./surfboard/depsmanager.sh) 的 `mw_assert_no_escaping_links()`，`tree` 与 `binary` 两种形态都调 |
| 回归 | [`scripts/linksafety_test.sh`](./scripts/linksafety_test.sh)：六种链接的判定、报错内容、真实漏斗拒绝且不留半成品、「合法产物不被误杀」 |

`assert_links_inside()` 是唯一实现，别在别处抄第二份。拒绝时会先删掉解压临时目录
再退出 —— 正常路径上由调用方在装完之后删，而这条路径是 `exit`，轮不到那一步。

新增或修改解压、落盘、重定位、卸载这几条路径时，按这条规则处理链接：

- 落点在 `base_dir` 内 → 放行；
- 落在上面那几处系统位置 → 放行；
- 其它 → 拒绝，且报错要指出是哪个成员、指向哪里。

相邻的两个工具函数别混用：[`lib/configpaths.py`](./lib/configpaths.py) 里
`assert_inside()` 会跟随最后一段软链接，`assert_inside_entry()` 不跟随 —— 判断
「链接本身在不在树内」用后者，判断「顺着它写会不会跑出去」用前者。

### 安全版本怎么对外说

安全修复的版本，**Release 标题必须带 `[安全更新 Security update]` 前缀**，正文要有
可复现的证据而不是「修了 X」：具体威胁场景、新旧版本并排的实测数据、拒绝之后没有
副作用、一个正面对照、以及用户自己能跑的自查命令。

**对照表里的 ✅/❌ 一律按读者的利益着色**：✅ = 被拦住（对用户安全）、
❌ = 逃逸成功（对用户危险），并在表头写明这句 —— 「攻击是否成功」和「防护是否生效」
是反的，不写清楚就会被读反。

细则与命令见 [`docs/RELEASE-CHECKLIST.md`](./docs/RELEASE-CHECKLIST.md) 第 7 步，
样板是 [`docs/RELEASE-4.2.0.md`](./docs/RELEASE-4.2.0.md) 第一节。

## 代码风格

- **缩进一律 4 个空格**，不用制表符。`python` 与 `shell` 都是。
- 唯一权威是根目录的 [`.editorconfig`](./.editorconfig)：`indent_style = space`、`indent_size = 4`。
  JSON / YAML 例外，那些文件用 2 空格。
- 不要为了让 `git diff` 好看去重排缩进；只改你要改的行。

## 测试

### 硬规则：不能碰真实安装

判断标准只有一条：**这条测试会不会改动「配置里那个安装目录」**。

- **自带隔离的脚本，直接跑就好**：`message_test.sh`、`sandbox_test.sh` 用临时 `HOME`
  与临时配置；`flags_test.sh`、`latest_test.sh`、`info_format_test.sh`、`upgrade_test.sh`
  自己设 `MACWAVE_TEST`；`configpath_test.sh`、`domains_test.sh`、`depsync_test.sh`、
  `markdown_test.sh`、`suggest_test.sh`、`update_commands_test.sh` 全程不碰安装目录。
- **不要从外面 `export MACWAVE_TEST` 再跑整套脚本**：它会盖住这些脚本自己的隔离，
  把本来能过的测试打成一串红。实测 `export MACWAVE_TEST=…` 后跑 `message_test.sh`，
  11 项全部失败，而报错完全看不出是环境问题。
- **这四个会动真实安装**：`format_test.sh`、`deps_test.sh`、`link_test.sh`、
  `selfupdate_test.sh`。它们读 `/opt/macwave_config` 或 `~/.config/macwave_config`
  里的 `base_dir`，并在其中真装、真卸、真改。**跑之前先确认 `base_dir` 指向哪里**，
  或照 CI 的做法让 `/opt/macwave_config` 指向一个临时安装。

### 手工验证一条命令时

`MACWAVE_TEST=<临时目录>` 是单条命令的隔离手段：程序把该目录当作 `/`，配置目录、
安装目录、下载缓存与 `HOME` 全部挂进去（实现见 `lib/configpaths.py` 的
`_resolve_test_root`，shell 侧读 `MACWAVE_TEST_ROOT`）。不隔离就会读写本机真实的
`~/.local/macwave`、`~/.config/macwave_config`，**包括真删掉你装着的包**。

```bash
MACWAVE_TEST=/tmp/mw-probe python3 lib/wave.py mirror
```

只有在「确实要改动这台机器」时，才在真实环境里跑 `wave install` / `wave uninstall` /
`wave selfupdate`。

### 为什么不隔离会很隐蔽

`config_dir_candidates()` 是**系统级优先**：`/opt/macwave_config` 存在就用它。
CI 会预先写好那份文件，于是同一个脚本在 CI 上读到的是宿主配置，本地却因为文件
不存在而一直是绿的 —— 本地绿、CI 红，报错还指不到原因。同一个脚本里有多个互不
相干的沙箱时，每个沙箱要有**自己的**测试根，否则共享的 `MACWAVE_TEST` 会让它们
互相看见。细节见 [`docs/CODE-MAP.md`](./docs/CODE-MAP.md) 的 2.6 节与 3.5 节。

### 怎么跑

| 命令 | 说明 |
| --- | --- |
| `bash scripts/<name>_test.sh` | 回归脚本，共 20 个；按上面分类判断要不要额外隔离 |
| `bash scripts/structure_test.sh` | 项目结构自检：组件清单与 `wave.py` / `install.sh` / CI 是否一致。纯离线、秒级 |
| `bash scripts/net_policy_test.sh` | 传输层契约：每个请求点是否都带策略。纯离线、秒级 |
| `bash scripts/linksafety_test.sh` | 产物里的符号链接不得跳出 base_dir（系统库位置除外）。纯离线、秒级 |
| `python3 scripts/random_test.py` | 随机化端到端，自建沙箱（随机 `HOME` + 随机 `base_dir`） |
| `python3 scripts/random_test.py --dry-run` | 只选包与生成参数，不执行任何 `wave` 命令 |

### CI 两条都要绿

合并与发版的判据是**两条流水线都成功**，缺一条都不算通过：

- **GitHub Actions `Format Test`** —— 权威，macOS runner，跑全部端到端（十几个分钟）；
- **CircleCI `quick-feedback`** —— Docker、纯离线，一两分钟给结论。

有一条红就停下，别因为另一条绿就放过。CircleCI 只跑离线的子集，但这不代表它是可选项；
面板上看不到 pipeline 也不等于绿，先确认 GitHub App 触发是否还生效。
详见 [`docs/RELEASE-CHECKLIST.md`](./docs/RELEASE-CHECKLIST.md) 第 8 步。

### 随机测试里的假设必须能确定性证伪

`random_test.py` 随机选包、随机拼参数去跑真实命令，再拿 `predict()` 的结果和实际退出码
比对。这个结构有个反复咬人的失效模式：**`predict()` 里只要有一条分支是凭印象写的，
红的是测试而不是代码**，而且由随机种子决定哪天红 —— 你不知道自己什么时候会撞上。

2026-10-31 一天里它连红四次，四次都是同一类错误：把注释或经验当成了事实。

| 断言 | 实际行为 | 我原来的假设 |
| --- | --- | --- |
| `latest --all --bogus` | 拒绝，exit 1 | 静默忽略 |
| 未知旗标 | 只有 `install`/`upgrade`/`info`/`mirror`/`latest` 拒绝 | 所有命令都拒绝 |
| `install -CsX` | `-X` 对 install 非法、被 `-s` 吞掉、零输出 | 抄了 upgrade 的例子，当成合法 |
| `mirror --only-set` | 必须配 `--raw`，否则 exit 1 | 一律成功 |

**规矩：新增或修改 `predict()` 的任何一条分支，先在本地把这些分支穷举钉死，再推。**

做法是直接调用被测的真实解析器（`help.py`、`mirrorinfo.parse_args` 等），把所有参数组合
跑一遍，与 `predict()` 逐组比对 —— 而不是等随机种子抽到某一组：

```python
# 例：mirror 的 7 个旗标，取 0~3 个，共 64 组，逐组比对退出码
for n in range(4):
    for combo in itertools.combinations(FLAGS, n):
        ...
```

几十行、一两秒的事，比一次 CI 往返便宜得多。阶段 0（`phase_flag_sanity`）与阶段 7
（`phase_flag_matrix`）就是把这几处踩过的假设固化成了常驻断言：以后加命令或加旗标，
往这两处补一条，不要只靠随机抽样兜底。

## 推送（仅限本仓库）

**CircleCI 的额度有限**，每次 push 都要花掉一轮 `quick-feedback`。所以：

- **没有实质内容的改动不要单独推。** 只改文档、README、注释、版本号这类，留在本地提交里，
  攒到下一次真正改代码时一起推。
- **一次改动只推一次。** 改一处推一次，额度全花在往返上，还把「是哪次提交坏的」搅浑。
- **不要为了看 CI 变绿去推空提交或 `--allow-empty`。** 想验证行为用
  `python3 scripts/random_test.py --dry-run` 或对应的本地脚本。
- **提交本身不受限制** —— 本地随时可以提交，受限的只是推送频率。
- **例外：要进发布的内容必须在打 tag 前推上去。** 文档改动攒着没问题，但
  `docs/RELEASE-*.md` 这类要随 tag 一起交付的，得在打 tag 前那一次推送里带上，否则
  tag 里就缺文件（3.2.1 的 tar 就少过两个文件）。

### 纯文档推送用 `[skip ci]`

CircleCI 与 GitHub Actions 都认提交信息里的 `[ci skip]` / `[skip ci]`：只要推送里
**最后一条**提交带这个标记，整次推送都不建 pipeline，CircleCI 面板上也不会出现这条
记录。纯文档、注释、README 的推送就走这条路 —— 既不给 CircleCI 花额度，也不用等
`Format Test` 跑十几分钟：

```bash
git commit -m "docs: 补充发布说明 [skip ci]"
git push origin 4.1
```

四条注意：

- **只标记纯文档提交。** 碰了 `lib/`、`pkg/`、`surfboard/`、`scripts/` 就照常跑，
  双绿门槛见上一节。
- **`sync-release-branch.yml` 也会被跳过** —— 往 `4.1` 推 `[skip ci]` 之后 `main`
  不会自动跟上。要么等下一次正常推送（它会自己补），要么手动跑一次：
  `gh workflow run sync-release-branch.yml --repo MacWaveOrg/MacWave`。
- **被跳过的提交不显示任何状态**，别把「没看到红线」当成「绿了」。要发版的内容
  该跑还得跑，被跳过的提交从未被验证过。
- 通过 API、定时任务触发的 pipeline **不会被跳过**，`[skip ci]` 只对 push 有效；
  fork 的 PR 也不支持。

这条规则只对 MacWave 生效，本机其它仓库不适用。

## 其它约定

细节在 [`.cursor/rules/style.mdc`](./.cursor/rules/style.mdc)，要点：

- Python 文件头：`#!/usr/bin/env python3` → 空行 → `# 文件名` → 空行 → 代码
- 注释与文档用中文；终端文案用英文（终端可能没有中文 locale）
- 终端输出以 `🌊` 开头；但 `-sS` 的输出例外，一律不带 `🌊`（脚本要读它）
- 报错必须给出下一步；地址进输出前必须打码
- 测试：见「测试」一节 —— 会改动系统的测试必须先设 `MACWAVE_TEST`
- 推送：见「推送」一节 —— 没有实质内容不要单独推，CircleCI 额度有限

发布流程见 [`docs/RELEASE-CHECKLIST.md`](./docs/RELEASE-CHECKLIST.md)，
加软件包见 [`docs/ADD-PACKAGE-CHECKLIST.md`](./docs/ADD-PACKAGE-CHECKLIST.md)。
