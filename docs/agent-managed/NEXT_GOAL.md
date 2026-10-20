# 下一步 Goal

## Goal Objective

完成 Harvis Agent 会话管理解耦 Phase 2：在现有 HarvisBar target 内建立 Provider 小端口、Registry 与 Codex/DSH/WorkBuddy 共享契约，保持 Phase 0/1 行为和只读边界，完成验证并回写计划后停止，不进入 Phase 3。

## 可复制提示词

```text
使用 $dev-standard-workflow。

@docs/agent-managed/01-需求分析.md
@docs/agent-managed/02-架构设计.md
@docs/agent-managed/03-开发计划.md
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/AgentProviderID.swift
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/ManagedConversationAddress.swift
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/ManagedConversation.swift
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/AgentIdentity.swift
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/ConversationTrustState.swift
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/ConversationCapabilities.swift
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/ManagedConversationProject.swift
@apps/HarvisBar/Sources/HarvisBar/AgentManaged/Core/ManagedConversationGovernance.swift
@apps/HarvisBar/Sources/HarvisBar/Models/ManagedChatCoreCompatibility.swift
@apps/HarvisBar/Sources/HarvisBar/Models/CodexManagedChatAdapter.swift
@apps/HarvisBar/Sources/HarvisBar/Models/DshManagedChatAdapter.swift
@apps/HarvisBar/Sources/HarvisBar/Models/WorkBuddyManagedChatAdapter.swift
@apps/HarvisBar/Sources/HarvisBar/Models/CodexTaskDeliveryModels.swift
@apps/HarvisBar/Tests/HarvisBarTests/AgentManagedPhase0IdentityCapabilityTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/AgentManagedPhase0PersistenceCharacterizationTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/AgentManagedPhase0DeliverySafetyCharacterizationTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/AgentManagedCoreTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/AgentManagedCoreDependencyTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/ManagedChatProviderTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/DshManagedChatAdapterTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/CodexTaskDeliveryCoordinatorTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/CodexConversationHandoffCoordinatorTests.swift
@apps/HarvisBar/Tests/HarvisBarTests/CodexApprovalResponseTests.swift

进入 Developer Mode · Phase 2（Provider Boundary）。

先完整阅读上述文档、Phase 0/1 tests、Core、兼容桥和三个现有 Adapter，
记录 git status，确认目标文件没有其他写入者，并使用本 Goal 独立 Swift scratch path。

严格执行开发计划第 6 节，只允许：

- 定义小而分离的 discovery、surface open、exact open、input read、dispatch、
  steering、interrupt、approval、archive、fork、handoff、Insight、Planning ports；
- 新增 Provider Registry 与 `AgentManaged/Providers/{Codex,DSH,WorkBuddy}` Adapter；
- 以现有 Adapter 输出和 Phase 0/1 fixture 为 oracle 建立共享 Provider contract suite；
- 为 source batch/freshness/error、唯一 Provider ID、完整 address、generation 和
  authority revision 建立 fail-closed 契约。

每个 allowed decision 都必须有匹配的已注册 port、完整 direct/parent/explicit target
和当前 verified authority revision；缺任一项必须 denied。`.compatibility` revision
只能表达当前兼容事实，不能成为执行授权。保留用户决策 A：Codex transient 的
legacy exact/read/insight 现状只作 characterization，本 Goal 不收紧生产行为；
transient send denied 继续是安全不变量。

DSH/WorkBuddy 仅允许已证明的 discovery 与 provider surface，exact/input/Insight
和所有写动作保持 denied。不得把 CX Agent/Profile/Skill（包括 cxspark、cxglm）、
Harness、Model 或 Runtime Preset 注册为 Provider，除非另有独立地址、authority、
发现接口与生命周期契约。

不建立 Coordinator，不接管生产刷新，不修改 Runtime/UI/窗口或生产持久化，
不创建 SwiftPM target，不新增 DSH/WorkBuddy 写能力，不改变 queue/handoff/approval
状态机语义，不调用真实 surface/deep link，不发送真实 Agent 任务，不读取或输出凭据、
私有聊天正文和原始日志，不自动提交、安装或发布。

运行 Phase 0/1 + shared Provider contract 定向测试、Core 递归依赖门、全量 Swift test
与 Release build，只报告真实结果。回写 docs/agent-managed/03-开发计划.md 的
Phase 2 checkbox、真实结果、风险和设计偏差。若源码事实要求改变 Provider/Authority
分层或扩大生产权限，写入设计偏差表并停止请求决策，不擅自修改架构。

Phase 2 验收通过后停止，不进入 Phase 3。

迭代收尾契约：

在结束当前 Goal 前，必须执行以下步骤：

1. 根据磁盘中的开发文档、checkbox、源码和真实测试结果判断当前阶段状态，
   不得只依据对话中的完成声明。

2. 回写 docs/agent-managed/03-开发计划.md：

   - 当前阶段 checkbox；
   - 真实测试与构建结果；
   - 风险和设计偏差；
   - 完成、失败或阻塞状态。

3. 按以下规则计算下一 Goal：

   - 当前阶段验收通过：进入首个未完成 Phase；
   - 验证失败：继续当前 Phase，只修复验证问题；
   - 外部条件阻塞：继续当前 Phase，只解除阻塞；
   - 所有 Phase 完成：进入总验收；
   - 总验收仍有待修改项：继续总验收修复，只处理验收报告列出的待修改项并引用 `05-验收报告.md`；
   - 总验收通过：生成“复核并关闭 Goal”，不虚构新阶段。

4. 原子覆盖 docs/agent-managed/NEXT_GOAL.md。该文件必须包含：

   - 下一 Goal Objective；
   - 完整可复制提示词；
   - 实际存在的 @文档和相关测试路径；
   - Developer Mode、允许范围、明确不做、验证要求和停止门；
   - 本段完整“迭代收尾契约”，确保下一 Goal 还能继续生成下一棒。

5. 最终答复中的“下一步 Goal / 可复制提示词”必须与
   docs/agent-managed/NEXT_GOAL.md 完全一致。

6. 只生成下一 Goal 接力文件；不得在当前 Goal 中执行下一 Phase，
   不得自动创建新 Goal、提交、安装或发布。
```
