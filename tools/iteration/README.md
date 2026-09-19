# tools/iteration — 持续迭代流程工具链

仓库内版本化的控制面工具（原 skill `continuous-iteration-plan` 的验证器在用户配置目录被删后重建于此，见 `docs/continuous-iteration/LESSONS.md` L-02）。全部只依赖标准库 + 本机 Flutter/Node/Git。

| 文件 | 作用 | 典型命令 |
|---|---|---|
| `iteration_state.py` | 状态机验证/派生/同步/渲染；`--repo-root` 额外校验证据文件、审计报告、工件路径、E-/DEC- id、验收矩阵哈希、代码中引用的缺陷号、DONE 候选的 review_id | `python tools/iteration/iteration_state.py validate --repo-root . docs/continuous-iteration/ITERATION_STATE.json` |
| `test_iteration_state.py` / `test_repo_links.py` | 验证器自测（7 + 14 条） | `cd tools/iteration && python -m unittest -q` |
| `gates.sh` | 在导出目录一键跑 pub get / analyze / test / JS 门 / doc-drift / 秘密扫描 / 脚本自测 / **state**（状态机 `--repo-root` 校验 + gitignore canary；默认 WARN，`--strict-state` 致命）（可选 `--osv`、`--build` debug APK）；证据写 `docs/continuous-iteration/evidence/<prefix>-*.log` + 汇总 JSON | `bash tools/iteration/gates.sh i3 --osv`；检查点终跑 `bash tools/iteration/gates.sh i3 --osv --strict-state` |
| `mutate.py` + `mutations/*.json` | 声明式"回退即失败"变异验证；语料随轮次累积，每轮全量重跑 | `python tools/iteration/mutate.py --export /d/tmp/zr/ci_i3 --spec tools/iteration/mutations/iter2.json --require-green` |
| `prompts/review-r2.md` / `security-r3.md` / `acceptance-te.md` | 零上下文审计提示词模板（覆盖标签槽位、必查通用项、报告落盘条款） | 替换 `{{...}}` 后作为子代理 prompt |
| `STATE_CONTRACT.md` | 状态 JSON 字段合同 | 参考 |
| `assets/ITERATION_STATE.template.json` | 新项目起始模板 | 参考 |

## 一轮的标准顺序

1. 实现有界批次（只改 `lib/ test/ docs/`，不提交）。
2. `bash tools/iteration/gates.sh <prefix> --osv` → 全绿（OSV 允许 BLOCKED；`state` 门此时允许 WARN——若本批翻转了验收行，矩阵哈希与 `history[-1]` 不符是预期的）。
3. 为每个新测试写一条变异到 `mutations/<prefix>.json`，`mutate.py --require-green` 全部 caught。
4. 用 `prompts/review-r2.md` 派零上下文审计 → 返修 → 复核；主代理把两份报告写入 `docs/audits/`。
5. 记账：DEFECTS / EVIDENCE / 状态 JSON（候选、审计、门禁、检查点指纹、计分历史）；`LESSONS.md` 至少一条并落实。
6. **检查点终跑**：`bash tools/iteration/gates.sh <prefix> --osv --strict-state`（此时 `state` 必须 PASS）→ `iteration_state.py sync --repo-root . --reason ...` → `render --repo-root . --output docs/continuous-iteration/EXECUTION_STATE.md`。

## 红线

- 永不在真实工作区跑 `flutter test/analyze/build`（DEC-02）；`gates.sh` 已强制导出。
- 永不做 release 出包、不读密钥文件（D-16 P0）；`--build` 只做 debug。
- 诊断/日志新增字段只允许数字、枚举、短 id。
- 基线导出目录（用来生成评审 patch 的那份）**只读**：需要跑 `gen-l10n` 等生成步骤另开导出目录，否则 diff 会被污染（iter3 F-9）。
- 改含反斜杠/正则/转义的文件（脚本、测试源码、JSON 语料）一律用编辑器工具整文件或精确替换，**不用** shell heredoc 内嵌 python 打补丁——已三次因多层转义静默出错（LESSONS L-09/L-12）。
- `validate --repo-root .` 只有在**所有文件落地之后**跑才算数；`gates.sh` 每轮自动跑（`state` 门），不要手工提前跑一次就当绿（iter3 F-1）。
