# Harvis 版本管理 Phase 3 验收记录

> 本文主体保留 Phase 3 关闭时快照；Phase 4 的当前更正与未完成门禁见文末注记。

## Phase 3 关闭时结论

- `phase: Phase 3 本地候选版与真实验收`
- `status: Complete`
- `acceptance: PASSED`
- `phase4_allowed: true`
- `phase4_status_at_phase3_close: not-started`
- `rawRetained: false`

最终 `0.36.0` 候选的源码、测试、构建、安装身份、FDA、full probe、四 API、production fresh AX 与 UI 摘要已经闭合；最终 review P0/P1/P2=`0/0/0`。Phase 3 已通过，下一 Goal 绑定尚未启动的 Phase 4。

## 已确定的源码与候选事实

| 项目 | 脱敏事实 | 状态 |
| --- | --- | --- |
| Source commit | `c2df3a7db32a487a15eeefb357817adade11bcd0` | 已确认 |
| Source tree | `30c9f28a8353f1d1295b9345de05363affa7c376` | 已确认 |
| Version | `0.36.0` | 已确认 |
| Final change scope | `HarvisVersionInspector` + 对应 tests | 已确认；未修改 `HarvisVersionCatalogView` 或 layout |
| Swift full suite | `509/509` | 通过 |
| Focused full-permission tests | 此前 `5/5` | 通过；分层历史证据 |
| Rust full-suite baseline | 前一候选 `266/266` | 通过；最终补丁仅改 Swift，未伪称本轮重跑 |
| Provenance SHA-256 | `3573758088e829d723f1dca726581aaf6674403f33f7d255f8bbcd9b3331d5de` | 已确认 |
| Staged payload SHA-256 | `08079b9b46cd0c8dd1174c72e456d7cfba00883ad39258954be78f6bffe72437` | 已确认 |
| Bundle payload SHA-256 | `0893a5dc26a5771a0c0054c7cf23b566b9464ea0be07571342ac27781ed76bfc` | 已确认 |
| Cache key | `personal/harvis/0.2.0+codex.p2-2e33868a2994858886a10a04d8f72207e61be779df08ad3cdc259c613b79d6d5` | 已确认 |

候选摘要与下文 installed identity、FDA/full probe、API 和 fresh AX 证据共同构成最终闭环；任何一类都不能单独替代其他门禁。

## Phase 3 门禁清单

- [x] source commit/tree/version 已固定。
- [x] Swift 全量 `509/509` 已通过；此前 focused `5/5` 保留为分层证据。
- [x] 前一候选 Rust 全量 `266/266` 已记录为未受最终 Swift-only 补丁影响的基线。
- [x] provenance、staged payload、bundle payload 三项 SHA-256 已固定。
- [x] production `0.36.0` 前一候选的三尺寸 × 五区、冷启动持久化和逐步 fresh AX 脱敏摘要已归档，`rawRetained=false`。
- [x] FDA 只对 HarvisBar 执行 exact off→退出重开→on→退出重开，最终 toggle=on，其他条目未触碰；ad-hoc `continuityClaim=false`。
- [x] `rust-service-manager-http` bounded full permission probe 通过，HTTP 200，三项检查，结果已脱敏且未返回本地绝对路径或凭据值。
- [x] 已安装 App/receipt/helper/system extension 身份与 current source/candidate 摘要一致；installed verifier=`ok`，deep/strict codesign 通过。
- [x] 版本 UI 的 App/Provenance/Helper 状态均恢复并与候选身份一致。
- [x] `health`、`bar-status`、`task-progress`、`permission-probe` 四 API 最终均 HTTP `200`、`ok=true`、missing/type errors=`0/0`。
- [x] 最新安装候选完成 standard `1060×700` refresh 后的 production 五区 fresh AX/JPEG 摘要复验。
- [x] 最终 diff 未修改 `HarvisVersionCatalogView` 或 layout，前一候选三尺寸布局证据适用性复核通过。
- [x] 独立代码/视觉/安全复核、敏感信息扫描、JSON/whitespace 检查完成，P0/P1/P2=`0/0/0`。

## 前一同版本候选的 UI 结构证据

本节证据来自 production `0.36.0` 的前一候选，source commit=`1ab57d85ffe4e8580996d0c9fa0afef2a1ab580b`。最终 commit 只修改 `HarvisVersionInspector` 与对应测试，没有修改 `HarvisVersionCatalogView` 或 layout；因此这些摘要已通过适用性复核，可作为 compact/standard/large 布局、五区导航和冷启动持久化基线。最新安装候选另完成下节 standard 五区复验，旧证据不单独替代 FDA、安装身份或 API 门禁。

### 冷启动持久化

| Content size | SHA-256 摘要 | 约束 |
| --- | --- | --- |
| `1060×700` | `623028d546042f0a3cf1819637e8685423b5b2566e31131f7548cdc511af0e1a` | production 冷退出/新进程重启；仅保留摘要 |

### Compact

- content：`860×560`
- capture：`860×612`

| 区域 | Detail root | Capture SHA-256 |
| --- | --- | --- |
| Overview | `harvis-version-detail-overview` | `25712088a912ee41efa1ff8adbed63380ba46f8a09510581ff73ee8e19abb8c3` |
| Installed App | `harvis-version-detail-installed-app` | `f2ef0db3cb07ff7db17bb56c45ce7a454f1e31748d1896530334d44f12e46a84` |
| Stable Helper | `harvis-version-detail-stable-helper` | `3d21cee480f136720774e655c8fc4b81fb871be76471db315bc95183e3ff4b76` |
| Source Worktree | `harvis-version-detail-source-worktree` | `90df88dcbd4ded84de16d24cc136846a0f194088e69692c18471b1baba6fa565` |
| Local Worktrees | `harvis-version-detail-local-worktrees` | `057ab1fe50ce6ae9577148e78829fed61ed2affe189c966ac2c8c0dc10da34d6` |

### Standard

- content：`1060×700`
- capture：`1060×752`

| 区域 | Detail root | Capture SHA-256 |
| --- | --- | --- |
| Overview | `harvis-version-detail-overview` | `960e521f70fbc4eace5178c7c3a7af9e1f0cfe56cddc3501003e477633b2053e` |
| Installed App | `harvis-version-detail-installed-app` | `05eef6e838d4c14858eae8be35ff1ea716c9f1e35313bb0bda636c2eeeaa4956` |
| Stable Helper | `harvis-version-detail-stable-helper` | `9d45cf3ba02f5a45238e1d775fbf03733292cc6db27bbeb4f7494f346804170c` |
| Source Worktree | `harvis-version-detail-source-worktree` | `aed00f89e62f5cd690f6cbf17770f4f68b86b11ddf8f46d8a26fb5f3f9233914` |
| Local Worktrees | `harvis-version-detail-local-worktrees` | `576c78600f5dc6be71ec29182bddd750820ca2242508cfb22cec389c636fc1bc` |

### Large

- content：`1280×800`
- CG frame：`1280×852`
- sky capture：downscaled `1154×768`

| 区域 | Detail root | Capture SHA-256 |
| --- | --- | --- |
| Overview | `harvis-version-detail-overview` | `e0bea10ec2c3718a1578784ae6ca48554918e2e23290f394e450d5a140f6dfe4` |
| Installed App | `harvis-version-detail-installed-app` | `2a8d5b92a8d39112c35ba75ba3747e9c04c318b3f83c1ebeab4685202429662e` |
| Stable Helper | `harvis-version-detail-stable-helper` | `d30bb565711b6f4d898b6bcf52fe49a4b4d4f8d824ca2d4df4fedc750f29305e` |
| Source Worktree | `harvis-version-detail-source-worktree` | `980d350c2c94cccebf787e8bb83e49857dbd6ce6de8acf05ccde0427189da55e` |
| Local Worktrees | `harvis-version-detail-local-worktrees` | `831e88ec0e111493987dc03f101f80b917ea9b6710c677106c24c6ff03fdd350` |

## 最新候选 standard 五区证据

- source commit：`c2df3a7db32a487a15eeefb357817adade11bcd0`
- content size：`1060×700`
- format：JPEG
- 每区均重新获取 fresh AX；manual refresh 最终返回“可刷新”，刷新后事实保持一致。

| 区域 | Detail root | JPEG SHA-256 |
| --- | --- | --- |
| Overview | `harvis-version-detail-overview` | `223f410b688ffefe21f56d7f90476a653c986d6d8764443049548a81b13b06f4` |
| Installed App | `harvis-version-detail-installed-app` | `cfb257a7f5d7f800f7b0764ed50d239b890701b2decd5a0f1080b2db6467bcf8` |
| Stable Helper | `harvis-version-detail-stable-helper` | `c9582de54eff1f1b341416400e7ef1ca1835e2fa6de47887f87db47fac90ae12` |
| Source Worktree | `harvis-version-detail-source-worktree` | `9981dff93f7bba3a94880f9c1f09283f7ba00e0a4e95b972068ac9d49d2c9114` |
| Local Worktrees | `harvis-version-detail-local-worktrees` | `01eecacc633c28742a4f655fc2ee2e2dce8e08728e8655e98598e2417a1e305d` |

### AX 断言合同

- window：`harvis-version-catalog-window`
- refresh：`harvis-version-refresh`
- detail roots：`harvis-version-detail-overview`、`harvis-version-detail-installed-app`、`harvis-version-detail-stable-helper`、`harvis-version-detail-source-worktree`、`harvis-version-detail-local-worktrees`
- 前一候选与最新 standard 的每个区域切换后均重新获取 fresh AX；sidebar selected count=`1`，对应 detail root count=`1`。
- `rawRetained=false`；不保留原始截图、原始 AX 树、原始 API body、token、PID、个人绝对路径或原始日志。

## 最终安装与运行证据

| 项目 | 脱敏结果 |
| --- | --- |
| Installed main SHA-256 | `c260e33247d4fc117bdd38f9eb68b1162230591418794fa92843a28747f38273` |
| Receipt SHA-256 | `1e88cfefb954c0d986c0521fcff51b01e822c847ab21d88300cd1c159bccbb7a` |
| Stable helper SHA-256 | `67778a47d70012a808ab37dc000bee7e3f37d773c3ace337eb5b368abf68a57f` |
| Installed signed system-extension executable SHA-256 | `0da0fc611ba682155eba5f541c25451aa6793a9a15f2282b6e9656a5d0dbdb67` |
| Receipt unsigned system-extension artifact SHA-256 | `77b05c1612f647fba2e40a123a89bb4b0a79bd694e1b1f642a37e1da5bf25554` |
| Bundle verification | verifier=`ok`；deep/strict codesign=`passed` |
| FDA | HarvisBar off→退出重开→on→退出重开；final on；other entries touched=false；continuityClaim=false |
| Full probe | mode=`rust-service-manager-http`；HTTP 200；probe/envelope/data ok；context=`rust-http-api`；checks=3；redacted=true；includesLocalAbsolutePaths=false；tokenValueReturned=false |
| Fresh AX | post-cleanup Source ready；Alignment exact；App ready；API `v0.40-rust-alpha` ready；Helper matched；Provenance ready `c2df3a7`；worktrees count/rows=`6/6` |
| Review | P0/P1/P2=`0/0/0` |

### 四 API

| API | HTTP | ok | missing errors | type errors |
| --- | --- | --- | --- | --- |
| `/health` | `200` | `true` | `0` | `0` |
| `/bar/status` | `200` | `true` | `0` | `0` |
| `/task-progress` | `200` | `true` | `0` | `0` |
| `/permission-probe` | `200` | `true` | `0` | `0` |

## 保留与清理

- post-cleanup 已移除 3 个 task-owned detached worktree，并 unlink 5 个 raw API JSON；最新 standard 五区摘要在清理后的 manual refresh 上重新生成。
- `rawRetained=false`；原始截图、AX/API body、日志与本地路径未进入持久证据。
- rollback 备份与 candidate stage 按恢复安全要求保留，本阶段未清理；这不是待完成项。
- 未执行 remote/tag/push/publish。

## 关闭规则

Phase 3 已通过并完成；`phase3-evidence-index.json` 已同步为最终状态，`NEXT_GOAL.md` 只接力 Phase 4。在 Phase 3 关闭时，Phase 4 尚未启动，该轮未创建 `05-验收报告.md`；整体 Goal 仍在 Phase 4 完成前保持 `in_progress`。

## Phase 4 启动后更正注记（2026-08-31）

本节是 Phase 4 对后续发现的记录，不倒写 Phase 3 当时已验收的 commit/candidate/FDA/probe/API/UI 证据，也不表示 Phase 3 已覆盖新候选。

- Phase 4 静态终审新发现一项 P1：shipped `FULL_DISK_ACCESS.md` 保留 npm paired installer/legacy `HarvisRuntime.app` 现行权威，而 `resolveServiceManagerPath` 仍会回退 legacy executable；两者与 Phase 3 已验证的 fixed-home helper 及双 LaunchAgent 运行事实不一致。
- 源码级 remediation 已落盘：guide 明确 HarvisBar/receipt-bound bundled runtime/`~/.harvis/bin/harvis`/wrapper 角色，并将 ad-hoc 替换锁定为 `continuityClaim=false`；resolver 顺序改为 executable wrapper → fixed-home helper → wrapper failure path，不再探测 legacy App，对应 source targeted tests 已完成。
- 上述 source-only 修复不等于 installed candidate 已更新。Phase 4 必须另行证明 source/bundle/installed guide 逐字节一致且无 npm/legacy executable authority，resolver targeted tests 通过，两个 LaunchAgent `ProgramArguments[0]` 均为 fixed-home helper；获得用户对当次隐私操作的明确确认后，仅对 HarvisBar 执行 FDA off→on，并重跑 full permission probe、`/health`、`/bar/status`、`/task-progress`、`/permission-probe` 及真实界面 fresh AX。
- 这些当前候选门禁未全部通过前，Phase 4 保持 `in-progress`，P1 不得记为关闭，不得生成通过的总验收或关闭整体 Goal。
