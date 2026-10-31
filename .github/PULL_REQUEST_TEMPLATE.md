## 改了什么

<!-- 一两句话。如果这是修复，说清原先哪里不对。 -->

## 为什么

<!-- 关联的 issue：Fixes #123 -->

## 怎么验证的

<!--
  这一节是 review 的重点。「测试通过」可以，但要写出是哪几个。
  手动验证就写出命令和看到的结果。
-->

- [ ] `bash scripts/flags_test.sh`
- [ ] `bash scripts/<其它>_test.sh`
- [ ] 手动跑过：`wave install <包>`

## 影响面

勾选所有适用项。这几类改动影响**所有用户**，不只是你测的那条命令：

- [ ] 动了 `lib/install.sh` / `lib/uninstall.sh`
- [ ] 动了 `lib/selfupdate.sh` 或 `Selfupdate/macwavedata/**`
- [ ] 动了 `.github/workflows/**`
- [ ] 改了 `update_commands.sh` 会下载哪些文件
- [ ] 改了索引格式（`infosource`）
- [ ] 都没有 —— 只影响单条命令

## 升级路径

<!--
  如果是自更新相关的改动：4.x 用户能否直接 wave selfupdate？
  3.x 用户是否需要重装？不确定就写「不确定」。
-->

## 检查

- [ ] `ruff check lib pkg surfboard scripts` 通过
- [ ] `shellcheck -S warning lib/*.sh pkg/*.sh surfboard/*.sh scripts/*.sh` 通过
- [ ] 改了依赖时，`bash scripts/depsync_test.sh` 通过
- [ ] 提交信息说明了「为什么」，不只是「改了什么」
