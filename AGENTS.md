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
互相看见。细节见 [`docs/CODE-MAP.md`](./docs/CODE-MAP.md) 的 2.5 节与 3.5 节。

### 怎么跑

| 命令 | 说明 |
| --- | --- |
| `bash scripts/<name>_test.sh` | 回归脚本，共 17 个；按上面分类判断要不要额外隔离 |
| `python3 scripts/random_test.py` | 随机化端到端，自建沙箱（随机 `HOME` + 随机 `base_dir`） |
| `python3 scripts/random_test.py --dry-run` | 只选包与生成参数，不执行任何 `wave` 命令 |

### CI 两条都要绿

合并与发版的判据是**两条流水线都成功**，缺一条都不算通过：

- **GitHub Actions `Format Test`** —— 权威，macOS runner，跑全部端到端（十几个分钟）；
- **CircleCI `quick-feedback`** —— Docker、纯离线，一两分钟给结论。

有一条红就停下，别因为另一条绿就放过。CircleCI 只跑离线的子集，但这不代表它是可选项；
面板上看不到 pipeline 也不等于绿，先确认 GitHub App 触发是否还生效。
详见 [`docs/RELEASE-CHECKLIST.md`](./docs/RELEASE-CHECKLIST.md) 第 8 步。

## 其它约定

细节在 [`.cursor/rules/style.mdc`](./.cursor/rules/style.mdc)，要点：

- Python 文件头：`#!/usr/bin/env python3` → 空行 → `# 文件名` → 空行 → 代码
- 注释与文档用中文；终端文案用英文（终端可能没有中文 locale）
- 终端输出以 `🌊` 开头；但 `-sS` 的输出例外，一律不带 `🌊`（脚本要读它）
- 报错必须给出下一步；地址进输出前必须打码
- 测试：见上节「测试」—— 会改动系统的测试必须先设 `MACWAVE_TEST`

发布流程见 [`docs/RELEASE-CHECKLIST.md`](./docs/RELEASE-CHECKLIST.md)，
加软件包见 [`docs/ADD-PACKAGE-CHECKLIST.md`](./docs/ADD-PACKAGE-CHECKLIST.md)。
