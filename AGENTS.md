# AGENTS.md

给在此仓库工作的编码代理（Codex、Claude Code、Copilot 等）的项目约定。

`CLAUDE.md` 是指向本文件的符号链接 —— Claude Code 读 `CLAUDE.md`，Codex 读 `AGENTS.md`，两者指向同一份内容，改这里就够，不要分别维护。

## 代码风格

- **缩进一律 4 个空格**，不用制表符。`python` 与 `shell` 都是。
- 唯一权威是根目录的 [`.editorconfig`](./.editorconfig)：`indent_style = space`、`indent_size = 4`。
  JSON / YAML 例外，那些文件用 2 空格。
- 不要为了让 `git diff` 好看去重排缩进；只改你要改的行。

## 其它约定

细节在 [`.cursor/rules/style.mdc`](./.cursor/rules/style.mdc)，要点：

- Python 文件头：`#!/usr/bin/env python3` → 空行 → `# 文件名` → 空行 → 代码
- 注释与文档用中文；终端文案用英文（终端可能没有中文 locale）
- 终端输出以 `🌊` 开头；但 `-sS` 的输出例外，一律不带 `🌊`（脚本要读它）
- 报错必须给出下一步；地址进输出前必须打码
- 测试：`bash scripts/<name>_test.sh`，端到端测试必须设 `MACWAVE_TEST`

发布流程见 [`docs/RELEASE-CHECKLIST.md`](./docs/RELEASE-CHECKLIST.md)，
加软件包见 [`docs/ADD-PACKAGE-CHECKLIST.md`](./docs/ADD-PACKAGE-CHECKLIST.md)。
