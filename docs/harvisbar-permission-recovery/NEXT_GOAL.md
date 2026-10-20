# NEXT GOAL

HarvisBar 权限恢复 Phase 1 已闭环。下一目标切换到独立工作树 `dsh-codex-index` 的 Stage 2，不在本 hotfix branch 混入 Index 代码。

## Stage 2 启动门禁

1. 读取 Index 项目的 `NEXT_GOAL.md` 与 docs/01–04，锁定 Stage 2 的首个未完成任务和 ownership。
2. 保持远程发布冻结：不创建 remote、不 push、不打 tag。
3. 先验证 Stage 1 当前测试、typecheck、lint、build/preflight 基线，再开始 Stage 2。
4. Stage 2 必须遵循固定 native 双别名、manifest SHA、public-safe preflight 与 Host/Client 零越权契约。
5. 每个小阶段先实现、再做定向测试和独立复核；不得使用真实用户会话或未隔离的 memory store 作为 fixture。

HarvisBar 后续非阻断优化单独排期：大型工作区 full bar 的 5 秒预算性能，以及窄宽度 warning 的完整可访问性表达。
