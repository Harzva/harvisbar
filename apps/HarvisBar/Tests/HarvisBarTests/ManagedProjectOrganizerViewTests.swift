import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedProjectOrganizerViewTests: XCTestCase {
    func testRenderProjectOrganizerStatesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["HARVIS_PROJECT_ORGANIZER_PREVIEW"] else {
            return
        }

        let root = project(
            id: "project::workspace",
            name: "Workspace",
            purpose: "跨项目的示例工作区",
            path: "/Users/example.test/workspace"
        )
        let product = project(
            id: "project::product",
            name: "Product",
            purpose: "整理产品交付",
            parentID: root.id,
            path: "/Users/example.test/workspace/product"
        )
        let empty = project(
            id: "project::empty",
            name: "Empty subproject",
            purpose: "等待会话进入",
            parentID: product.id,
            path: nil
        )

        let rootNodes = [
            matrixNode(root, kind: .folder, childCount: 2, direct: 1, aggregate: 4, participants: 2),
            ManagedProjectPathMatrixNode(
                id: "unclassified::root",
                name: "未分类会话",
                kind: .unclassified,
                path: nil,
                purpose: "尚未绑定到项目",
                childCount: 0,
                sessionCount: 2,
                directSessionCount: 2,
                participantCount: 1,
                healthLabel: "需要确认",
                healthReason: "来源会话没有可用的项目路径。"
            )
        ]
        let rootView = ManagedProjectPathMatrixView(
            nodes: rootNodes,
            breadcrumbs: [ManagedProjectPathMatrixBreadcrumb(id: nil, label: "所有项目")],
            currentLayerID: nil,
            summary: .init(
                currentCount: 2,
                directCount: 0,
                loadedCount: 6,
                loadedTotal: 6,
                sessionCount: 6,
                unresolvedCount: 1,
                note: "当前目录只展示已载入的会话归属。"
            ),
            theme: .glass,
            onNavigate: { _ in },
            onProperties: { _ in },
            onOrganize: {},
            conversationContent: AnyView(conversationCards("所有项目", count: 1))
        )

        let drillNodes = [
            matrixNode(root, kind: .folder, childCount: 2, direct: 1, aggregate: 4, participants: 2),
            matrixNode(product, kind: .project, childCount: 1, direct: 2, aggregate: 3, participants: 2),
            matrixNode(empty, kind: .project, childCount: 0, direct: 0, aggregate: 0, participants: 0)
        ]
        let drillView = ManagedProjectPathMatrixView(
            nodes: drillNodes,
            breadcrumbs: [
                ManagedProjectPathMatrixBreadcrumb(id: nil, label: "所有项目"),
                ManagedProjectPathMatrixBreadcrumb(id: root.id, label: root.name, path: root.path),
            ],
            currentLayerID: root.id,
            summary: .init(
                currentCount: 1,
                directCount: 1,
                loadedCount: 4,
                loadedTotal: 4,
                sessionCount: 4,
                note: "已进入 Workspace 的直属路径。"
            ),
            theme: .glass,
            onNavigate: { _ in },
            onProperties: { _ in },
            onOrganize: {},
            conversationContent: AnyView(conversationCards("Workspace", count: 1))
        )

        let emptyView = ManagedProjectPathMatrixView(
            nodes: [
                matrixNode(root, kind: .folder, childCount: 2, direct: 1, aggregate: 4, participants: 2),
                matrixNode(product, kind: .project, childCount: 1, direct: 2, aggregate: 3, participants: 2),
                matrixNode(empty, kind: .project, childCount: 0, direct: 0, aggregate: 0, participants: 0),
            ],
            breadcrumbs: [
                ManagedProjectPathMatrixBreadcrumb(id: nil, label: "所有项目"),
                ManagedProjectPathMatrixBreadcrumb(id: root.id, label: root.name),
                ManagedProjectPathMatrixBreadcrumb(id: product.id, label: product.name),
                ManagedProjectPathMatrixBreadcrumb(id: empty.id, label: empty.name),
            ],
            currentLayerID: empty.id,
            summary: .init(
                currentCount: 0,
                directCount: 0,
                loadedCount: 0,
                sessionCount: 0,
                note: "这是一个已登记但尚未载入会话的空子项目。"
            ),
            theme: .glass,
            onNavigate: { _ in },
            onProperties: { _ in },
            onOrganize: {}
        )

        let proposal = organizerProposal(existing: product, child: empty)
        let readyView = reviewView(
            proposal: proposal,
            analysis: .init(
                status: .ready,
                coverage: "3 个会话已覆盖",
                feedback: "建议已生成，应用前仍需逐项审核。"
            )
        )
        let appliedView = reviewView(
            proposal: proposal,
            analysis: .init(status: .applied, coverage: "3 个会话已覆盖", feedback: "上次整理已完成。"),
            latestReceipt: receipt(child: empty)
        )

        let outputs: [(String, AnyView, CGSize)] = [
            ("-root", AnyView(rootView), CGSize(width: 760, height: 620)),
            ("-drill-in", AnyView(drillView), CGSize(width: 760, height: 620)),
            ("-empty-subproject", AnyView(emptyView), CGSize(width: 760, height: 500)),
            ("-review-ready", AnyView(readyView), CGSize(width: 720, height: 700)),
            ("-review-applied", AnyView(appliedView), CGSize(width: 720, height: 700)),
        ]

        let base = URL(fileURLWithPath: output).deletingPathExtension().path
        for (suffix, view, size) in outputs {
            let data = try renderPNG(view, size: size)
            try data.write(to: URL(fileURLWithPath: base + suffix + ".png"))
        }
    }

    private func renderPNG(_ view: AnyView, size: CGSize) throws -> Data {
        let rect = NSRect(origin: .zero, size: size)
        let hostingView = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color(hex: 0xF0F2F3))
        )
        hostingView.frame = rect

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.contentView = hostingView
        // Keep the temporary AppKit surface off-screen and out of focus. A
        // real NSHostingView is still needed so ScrollView/AppKit-backed
        // controls render into the bitmap instead of being flattened away by
        // ImageRenderer.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderOut(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func reviewView(
        proposal: ManagedProjectOrganizerProposal,
        analysis: ManagedProjectOrganizerReviewAnalysis,
        latestReceipt: ManagedProjectOrganizationReceipt? = nil
    ) -> ManagedProjectOrganizerReviewView {
        ManagedProjectOrganizerReviewView(
            proposal: .constant(proposal),
            catalog: [
                ManagedProjectRecord(
                    id: "project::existing",
                    name: "Existing project",
                    purpose: "已有项目",
                    path: "/Users/example.test/workspace/existing"
                )
            ],
            analysis: analysis,
            theme: .glass,
            onAnalyze: {},
            onClose: {},
            onCancelAnalysis: {},
            onApply: { _ in },
            onUndo: { _ in },
            latestReceipt: latestReceipt
        )
    }

    private func organizerProposal(
        existing: ManagedProjectRecord,
        child: ManagedProjectRecord
    ) -> ManagedProjectOrganizerProposal {
        let snapshots = [
            conversation("conversation::alpha", title: "整理产品需求", project: existing.identity),
            conversation("conversation::beta", title: "准备上线清单", project: existing.identity),
            conversation("conversation::gamma", title: "未命名会话", project: existing.identity),
        ]
        var create = ManagedProjectOrganizerSuggestion(
            id: "suggestion::create",
            action: .createSubproject,
            conversationIDs: [],
            proposedProject: child,
            reason: "两个会话都围绕独立的上线清单，适合归入新的子项目。",
            evidence: ["“准备上线清单”提到了独立交付范围。"],
            confidence: .strong
        )
        create.isSelected = false
        let assign = ManagedProjectOrganizerSuggestion(
            id: "suggestion::assign",
            action: .assign,
            conversationIDs: [snapshots[2].id],
            targetProjectID: child.id,
            reason: "会话内容与拟建子项目的用途一致。",
            evidence: ["用户输入包含 example.test 上线环境信息。"],
            confidence: .needsReview
        )
        return ManagedProjectOrganizerProposal(
            id: "proposal::example",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            baseStateRevision: 0,
            catalogFingerprint: "fingerprint::example",
            snapshots: snapshots,
            suggestions: [create, assign]
        )
    }

    private func receipt(child: ManagedProjectRecord) -> ManagedProjectOrganizationReceipt {
        ManagedProjectOrganizationReceipt(
            id: "receipt::example",
            proposalFingerprint: "fingerprint::example",
            appliedAt: Date(timeIntervalSince1970: 1_800_000_100),
            appliedRevision: 1,
            assignmentChanges: [
                ManagedProjectOrganizationAssignmentChange(
                    storageKey: "codex::example.test::conversation::gamma",
                    conversationID: "conversation::gamma",
                    before: nil,
                    after: nil
                ),
                ManagedProjectOrganizationAssignmentChange(
                    storageKey: "codex::example.test::conversation::alpha",
                    conversationID: "conversation::alpha",
                    before: nil,
                    after: nil
                ),
            ],
            projectChanges: [
                ManagedProjectOrganizationProjectChange(
                    projectID: child.id,
                    before: nil,
                    after: child
                )
            ]
        )
    }

    private func project(
        id: String,
        name: String,
        purpose: String,
        parentID: String? = nil,
        path: String?
    ) -> ManagedProjectRecord {
        ManagedProjectRecord(
            id: id,
            name: name,
            purpose: purpose,
            parentID: parentID,
            path: path
        )
    }

    private func matrixNode(
        _ project: ManagedProjectRecord,
        kind: ManagedProjectPathMatrixNode.Kind,
        childCount: Int,
        direct: Int,
        aggregate: Int,
        participants: Int
    ) -> ManagedProjectPathMatrixNode {
        ManagedProjectPathMatrixNode(
            id: project.id,
            name: project.name,
            kind: kind,
            path: project.path,
            purpose: project.purpose,
            parentID: project.parentID,
            childCount: childCount,
            sessionCount: aggregate,
            directSessionCount: direct,
            participantCount: participants,
            healthLabel: project.path == nil ? "未关联路径" : "已验证",
            healthReason: project.path == nil ? "该逻辑项目没有绑定路径。" : "示例项目路径已登记。"
        )
    }

    private func conversation(
        _ id: String,
        title: String,
        project: ManagedChatProjectIdentity
    ) -> ManagedProjectOrganizationConversation {
        ManagedProjectOrganizationConversation(
            id: id,
            storageKey: "codex::example.test::\(id)",
            sourceRevision: "sha256:example-\(id)",
            sourceProject: project,
            effectiveProject: project,
            assignment: nil,
            title: title,
            provider: "Codex"
        )
    }

    private func conversationCards(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("当前层直接会话 · \(title)")
                .font(.caption.bold())
                .foregroundColor(.black)
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 7) {
                    Image(systemName: "text.bubble")
                    Text(index == 0 ? "准备上线清单" : "需要确认的项目会话")
                    Spacer()
                    Text("Codex")
                        .font(.caption2)
                }
                .font(.caption2)
                .foregroundColor(.black.opacity(0.72))
                .padding(8)
                .background(Color.white.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
