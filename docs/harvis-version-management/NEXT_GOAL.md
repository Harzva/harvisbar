# 下一步 Goal

## Goal Objective

`执行 Harvis 版本管理 Phase 4 总验收与整体关闭：只读对账 HVM-FR-001..010、Phase 1–3 源码/测试/安装/API/UI/安全证据；全部通过后创建唯一的 05-验收报告.md、关闭整体 Goal，并把 NEXT_GOAL 改为“无下一 Goal”。`

## Track

`Mainline；Phase 4 总验收与整体关闭进行中`

## 有限阶段状态

- `phase_count: 5`
- `phase_topology: Phase 0 规划锁定 → Phase 1 只读契约与 inspector → Phase 2 窗口与 HarvisBar 入口 → Phase 3 本地候选版与真实验收 → Phase 4 总验收与整体关闭`
- `last_completed_phase: Phase 3 本地候选版与真实验收`
- `current_phase: Phase 4 总验收与整体关闭`
- `current_phase_status: in-progress`
- `bound_phase: Phase 4`
- `next_declared_phase: Phase 4 总验收与整体关闭`
- `final_declared_phase: Phase 4 总验收与整体关闭`
- `phase4_allowed: true`
- `overall_goal_state: in_progress`
- `current_gate: 0.36.1 本地候选 checkpoint/build → 明确安装与隐私操作确认 → FDA off→on → full probe/API/UI 复测`
- `blocker: 当次安装与 macOS 隐私操作尚待用户明确确认；官方 Computer Use 当前不可用`
- `stop_gate: Phase 4 逐项对账与独立复核全部通过后，才创建唯一 05、执行整体关闭并将本文件改为无下一 Goal；若发现 P0/P1 或证据冲突，继续 Phase 4 修复/对账，不回退 Phase 拓扑`

## Phase 3 已完成事实

- source commit：`c2df3a7db32a487a15eeefb357817adade11bcd0`
- source tree：`30c9f28a8353f1d1295b9345de05363affa7c376`
- version：`0.36.0`
- Swift 全量：`509/509`
- 前一候选 Rust 基线：`266/266`；最终 commit 只修改 Swift inspector 与测试
- provenance SHA-256：`3573758088e829d723f1dca726581aaf6674403f33f7d255f8bbcd9b3331d5de`
- staged payload SHA-256：`08079b9b46cd0c8dd1174c72e456d7cfba00883ad39258954be78f6bffe72437`
- bundle payload SHA-256：`0893a5dc26a5771a0c0054c7cf23b566b9464ea0be07571342ac27781ed76bfc`
- cacheKey：`personal/harvis/0.2.0+codex.p2-2e33868a2994858886a10a04d8f72207e61be779df08ad3cdc259c613b79d6d5`
- installed main/receipt/helper/signed system-extension executable SHA-256：分别为 `c260e33247d4fc117bdd38f9eb68b1162230591418794fa92843a28747f38273`、`1e88cfefb954c0d986c0521fcff51b01e822c847ab21d88300cd1c159bccbb7a`、`67778a47d70012a808ab37dc000bee7e3f37d773c3ace337eb5b368abf68a57f`、`0da0fc611ba682155eba5f541c25451aa6793a9a15f2282b6e9656a5d0dbdb67`；receipt unsigned system-extension artifact SHA-256=`77b05c1612f647fba2e40a123a89bb4b0a79bd694e1b1f642a37e1da5bf25554`
- installed verifier=`ok`；deep/strict codesign 通过。
- FDA：只对 HarvisBar 执行 off→退出重开→on→退出重开，最终 toggle=on，未触碰其他条目；ad-hoc `continuityClaim=false`。
- full probe：mode=`rust-service-manager-http`、HTTP `200`、probe/envelope/data 均 `ok=true`、context=`rust-http-api`、checks=`3`、redacted=true、includesLocalAbsolutePaths=false、未返回凭据值。
- 四 API：`/health`、`/bar/status`、`/task-progress`、`/permission-probe` 均 HTTP `200`、`ok=true`、missing/type errors=`0/0`。
- post-cleanup fresh AX：Source ready、Alignment exact、App ready、API `v0.40-rust-alpha` ready、Helper matched、Provenance ready `c2df3a7`、worktrees count/rows=`6/6`；manual refresh 返回“可刷新”并保持一致。
- 前一同版本候选的三尺寸证据继续适用，因为最终 diff 未修改 `HarvisVersionCatalogView` 或 layout；最新候选已完成 standard 五区 JPEG 摘要复验。
- 已移除 3 个 task-owned detached worktree并 unlink 5 个 raw API JSON；`rawRetained=false`。rollback 备份与 candidate stage 按恢复安全要求保留；最终 review P0/P1/P2=`0/0/0`。

## Phase 4 当前 remediation 与允许范围

- 静态终审已发现 shipped FDA guide 与 resolver 的 legacy authority P1；源码已改为 HarvisBar + receipt-bound bundled runtime + fixed helper 模型，workspace/System Extension 已升为本地 `0.36.1` 候选，运行验收尚未完成。
- 核对 `01-需求分析.md`、`02-架构设计.md`、`03-开发计划.md`、`04-闭环测试矩阵.md`、`phase3-acceptance.md`、`phase3-evidence-index.json` 与当前源码/测试/安装证据的一致性。
- 按 HVM-FR-001..010 逐项形成源码、自动测试、真实 UI 与安全证据映射；历史 transaction/source-checkpoint/Acceptance Oracle/HVM-DEP 草案不计入验收分母。
- 复核 Phase 3 evidence index 可解析、无 pending 字段、摘要格式正确、`rawRetained=false`，并确认 rollback 备份仍按要求保留。
- 完成独立静态/视觉/交互终审；P0/P1 必须为 0，任何 P2 必须如实记录。
- 仅在全部门禁通过后创建 `05-验收报告.md`，将 `overall_goal_state` 改为 `closed`，并把本文件覆盖为“无下一 Goal”的最终关闭记录。

## 明确不做

- 已因 Phase 4 P1 进入本地 `0.36.1` candidate remediation；源码/测试/候选构建属于当前范围。安装候选和切换 FDA 必须在动作前获得用户明确确认；不清理 rollback 备份。
- 不恢复或执行已取消的 transaction/source-checkpoint/Acceptance Oracle/distribution coordinator/HVM-DEP 草案。
- 不 fetch/pull/push/tag/publish，不创建或写入 remote，不操作 GitHub/RepoAtlas。
- 不保存或回显凭据、运行进程编号、个人绝对路径、原始 AX 树、原始 API body、原始截图或原始日志。
- 不创建拓扑外 Phase；Phase 4 未通过时不得宣称整体 Goal 已关闭。

## 迭代收尾契约

1. 以磁盘中的源码、提交/tree、真实测试和脱敏 evidence index 为事实源，不仅依赖对话式完成声明。
2. 先核对 Phase 3 `complete` 与所有验收字段，再逐项关闭 HVM-FR-001..010；任何冲突都留在 Phase 4 处理。
3. 只有 Phase 4 门禁全部通过，才能创建唯一的 `05-验收报告.md`、勾选 Phase 4、把 `overall_goal_state` 改为 `closed`。
4. Phase 4 有待修改项时继续 Phase 4，不创建新的 Phase/Goal；引用 05 中的未关闭项，直到 P0/P1=0。
5. 整体关闭后把本文件覆盖为“无下一 Goal”，不自动执行 backlog、remote 或发布工作。
6. 最终回复中的状态、下一步和关闭结论必须与本文件一致。

## 可复制提示词

```text
进入 Developer Mode，继续执行 Harvis 版本管理 Phase 4 总验收与整体关闭。Phase 4 当前正在 FDA/stable-helper remediation；Phase 3 已完成且历史证据保持不变。

先阅读：
@docs/harvis-version-management/01-需求分析.md
@docs/harvis-version-management/02-架构设计.md
@docs/harvis-version-management/03-开发计划.md
@docs/harvis-version-management/04-闭环测试矩阵.md
@docs/harvis-version-management/phase3-acceptance.md
@docs/harvis-version-management/phase3-evidence-index.json
@docs/harvis-version-management/NEXT_GOAL.md

以 source commit c2df3a7db32a487a15eeefb357817adade11bcd0、tree 30c9f28a8353f1d1295b9345de05363affa7c376、version 0.36.0 与 Swift 509/509 为最终 Phase 3 源码/测试基线。candidate、installed identity、FDA、full probe、四 API、fresh AX、前一候选三尺寸适用性、最新 standard 五区摘要与 P0/P1/P2=0 的精确脱敏证据以 phase3-acceptance.md 和 phase3-evidence-index.json 为准。

继续对账 HVM-FR-001..010 的源码、自动测试、真实 UI 与安全证据，并完成 HVM-HLP-010/HVM-SEC-009/HVM-REG-005。历史 transaction/source-checkpoint/Acceptance Oracle/HVM-DEP 草案不属于验收分母。安装 `0.36.1` candidate 和 FDA off→on 必须在动作前获得用户明确确认；不清理 rollback 备份或执行 remote 操作；不得保存或回显凭据、运行进程编号、个人绝对路径、原始 AX/API body、原始截图或原始日志。

运行 JSON parse、逐文件 no-index whitespace、tracked diff、敏感信息扫描与独立 P0/P1 终审。全部门禁通过后才创建唯一的 docs/harvis-version-management/05-验收报告.md，勾选 Phase 4，将 overall_goal_state=closed，并把 NEXT_GOAL 覆盖为“无下一 Goal”。若发现 P0/P1 或证据冲突，继续 Phase 4 修复/对账，不创建拓扑外 Phase，不宣称关闭。
```
