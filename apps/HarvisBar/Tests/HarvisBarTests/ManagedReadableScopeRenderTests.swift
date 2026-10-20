import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

/// Opt-in native renders for the project supervision scope at the narrow and
/// wide widths where the large readable text setting needs to remain legible.
/// Set HARVIS_READABLE_SCOPE_PREVIEW to a writable output directory; ordinary
/// test runs skip bitmap generation.
@MainActor
final class ManagedReadableScopeRenderTests: XCTestCase {
    func testRenderReadableScopeAt380And660WhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment[
            "HARVIS_READABLE_SCOPE_PREVIEW"
        ] else {
            return
        }

        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fixture = try scopeFixture()
        let scope = try XCTUnwrap(
            ManagedProjectSupervisionScope(
                project: fixture.project,
                snapshot: fixture.snapshot,
                threads: fixture.inventory
            )
        )

        // The child project is present in the complete provider inventory, but
        // exact project snapshot projection excludes it from this roster.
        XCTAssertEqual(scope.entries.count, 2)
        XCTAssertFalse(
            scope.entries.contains { $0.target.sourceID == "child-project" }
        )
        XCTAssertEqual(scope.approvalCandidateCount, 1)
        XCTAssertEqual(scope.observationCount, 1)

        let sizes: [(String, CGSize)] = [
            ("scope-readable-380", CGSize(width: 380, height: 760)),
            ("scope-readable-660", CGSize(width: 660, height: 760)),
        ]
        for (name, size) in sizes {
            let view = ManagedProjectSupervisionScopeView(
                project: fixture.project,
                managementSnapshot: fixture.snapshot,
                managementThreads: fixture.inventory,
                managementScope: scope,
                theme: .paper
            )
            let data = try renderPNG(
                AnyView(
                    view
                        .environment(\.harvisTextSize, .large)
                        .frame(
                            width: size.width,
                            height: size.height,
                            alignment: .topLeading
                        )
                ),
                size: size
            )
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private struct ScopeFixture {
        let project: ManagedChatProjectIdentity
        let snapshot: ConversationManagementSnapshotV1
        let inventory: [ManagedChatThread]
    }

    private func scopeFixture() throws -> ScopeFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "harvis-readable-scope-\(UUID().uuidString)",
                isDirectory: true
            )
        let child = root.appendingPathComponent("child-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let project = ManagedChatProjectIdentity(
            id: "path::\(root.path)",
            canonicalPath: root.path,
            displayPath: root.path,
            label: "Readable scope fixture",
            resolution: .resolved
        )
        let inventory = [
            fixtureThread(
                provider: .codex,
                scope: "codex::fixture",
                id: "codex-main",
                title: "Codex 主会话",
                cwd: root.path
            ),
            fixtureThread(
                provider: .dsh,
                scope: "dsh::fixture::web",
                id: "dsh-observer",
                title: "DSH 观察会话",
                cwd: root.path
            ),
            fixtureThread(
                provider: .codex,
                scope: "codex::fixture",
                id: "child-project",
                title: "Child project task",
                cwd: child.path
            ),
        ]
        let snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: project,
            threads: inventory,
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return ScopeFixture(
            project: project,
            snapshot: snapshot,
            inventory: inventory
        )
    }

    private func fixtureThread(
        provider: ManagedChatProvider,
        scope: String,
        id: String,
        title: String,
        cwd: String
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: scope,
            sourceID: id,
            title: title,
            titleSource: "fixture",
            hasMeaningfulTitle: true,
            createdAt: 1_800_000_000,
            updatedAt: 1_800_000_060,
            tokensUsed: 120,
            model: "fixture",
            cwd: cwd,
            archived: false,
            running: false,
            sourceStatus: "idle",
            threadSource: "fixture",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: id,
            isSubagent: false,
            isSidechat: false,
            activity: .init(main: 0, subagent: 0, sidechat: nil),
            trustProjection: .init(state: .idle, reason: "render fixture")
        )
    }

    private func renderPNG(_ view: AnyView, size: CGSize) throws -> Data {
        let rect = NSRect(origin: .zero, size: size)
        let hostingView = NSHostingView(rootView: view)
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
        return try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
    }
}
