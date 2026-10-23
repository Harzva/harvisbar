import Foundation
import XCTest
@testable import HarvisBar

/// Opt-in acceptance against explicitly supplied, existing local logins. The
/// project and stores are isolated, while execution uses the production stack.
@MainActor
final class HarvisGroupLiveAcceptanceTests: XCTestCase {
    func testEmptyAccountHandoffThenRestartStartsOnlyExplicitTurn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HARVIS_GROUP_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Real-account acceptance is opt-in")
        }
        let homesData = try XCTUnwrap(environment["HARVIS_GROUP_LIVE_HOMES"]?.data(using: .utf8))
        let homes = try JSONDecoder().decode([String].self, from: homesData)
        guard homes.count >= 3 else { throw AcceptanceFailure("Supply three authorized Codex homes") }
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["HARVIS_GROUP_LIVE_OUTPUT"]), isDirectory: true)
        let project = URL(fileURLWithPath: try XCTUnwrap(environment["HARVIS_GROUP_LIVE_PROJECT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let marker = "HANDOFF_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        var runtime = makeRuntime(root)
        var coordinator = runtime.1
        do {
            await coordinator.activate()
            await runtime.0.activate(probeExecutablePath: "unused-native-probe")
            await coordinator.recover()
            let createdGroup = await coordinator.createGroup(title: "空交接重启真实验收", projectPath: project.path)
            let groupID = try XCTUnwrap(createdGroup)
            let createdMember = await coordinator.addMember(groupID: groupID, name: "接力者",
                role: "按群请求简短回复。", homePath: homes[2])
            let memberID = try XCTUnwrap(createdMember)
            await coordinator.send(groupID: groupID, text: "@接力者 请记住并原样复述口令 \(marker)，不要调用工具。")
            _ = try await waitForReply(coordinator, groupID, memberID, containing: String(marker))
            let original = try binding(coordinator, groupID, memberID)
            await coordinator.handoff(groupID: groupID, memberID: memberID, targetHomePath: homes[0])
            let empty = try binding(coordinator, groupID, memberID)
            guard empty.lineage == "context-handoff", empty.accountIdentity != original.accountIdentity else {
                throw AcceptanceFailure(coordinator.lastError ?? "Cross-account handoff did not create an empty destination")
            }
            coordinator.deactivate()
            await runtime.0.deactivate()
            runtime = makeRuntime(root)
            coordinator = runtime.1
            await coordinator.activate()
            await runtime.0.activate(probeExecutablePath: "unused-native-probe")
            await coordinator.recover()
            XCTAssertEqual(coordinator.group(groupID)?.dispatches.count, 1, "Restart must never submit a turn")
            await coordinator.send(groupID: groupID, text: "@接力者 依据共享群记录复述刚才保存的完整口令，一行即可，不要调用工具。")
            _ = try await waitForReply(coordinator, groupID, memberID, containing: String(marker))
            let restored = try binding(coordinator, groupID, memberID)
            XCTAssertEqual(restored.accountIdentity, empty.accountIdentity)
            XCTAssertEqual(restored.lineage, "context-handoff")
            XCTAssertEqual(restored.predecessorThreadID, original.threadID)
            XCTAssertEqual(coordinator.group(groupID)?.dispatches.count, 2)
            let originalHistory = try await CodexGroupAdapter(pool: runtime.0.pool).turns(original)
            XCTAssertEqual(originalHistory["data"]?.arrayValue?.count, 1, "Source native conversation stays untouched")
            let receipt: [String: Any] = ["status": "passed", "scenario": "empty-account-handoff-restart-explicit-turn",
                "sourceThread": original.threadID, "emptyDestinationThread": empty.threadID,
                "resumedDestinationThread": restored.threadID, "dispatchCount": 2]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
            coordinator.deactivate()
            await runtime.0.deactivate()
        } catch {
            let receipt: [String: Any] = ["status": "failed", "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
            coordinator.deactivate()
            await runtime.0.deactivate()
            throw error
        }
    }

    func testThreeAccountsSharedProjectResumeForkAndHandoff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HARVIS_GROUP_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Real-account acceptance is opt-in")
        }
        let homesData = try XCTUnwrap(environment["HARVIS_GROUP_LIVE_HOMES"]?.data(using: .utf8))
        let homes = try JSONDecoder().decode([String].self, from: homesData)
        guard homes.count >= 3 else { throw AcceptanceFailure("Supply three authorized Codex homes") }
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["HARVIS_GROUP_LIVE_OUTPUT"]), isDirectory: true)
        let project = URL(fileURLWithPath: try XCTUnwrap(environment["HARVIS_GROUP_LIVE_PROJECT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let marker = "HARVIS_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        try String(marker).write(to: project.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        var evidence: [[String: Any]] = []
        var runtime = makeRuntime(root)
        var coordinator = runtime.1
        let began = Date()

        func record(_ name: String, _ details: [String: Any] = [:]) throws {
            evidence.append(["scenario": name, "elapsedSeconds": Date().timeIntervalSince(began), "evidence": details])
            let value: [String: Any] = ["status": "running", "scenarios": evidence, "project": project.path]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
            print("LIVE ACCEPTANCE: \(name)")
        }

        do {
            await runtime.0.activate(probeExecutablePath: "unused-native-probe")
            await coordinator.activate()
            let createdGroup = await coordinator.createGroup(title: "三账号真实验收", projectPath: project.path)
            let groupID = try XCTUnwrap(createdGroup)
            let createdWriter = await coordinator.addMember(groupID: groupID, name: "实现者", role: "按指定项目完成小任务，用简短中文回复。", homePath: homes[0])
            let writer = try XCTUnwrap(createdWriter)
            let createdPeer = await coordinator.addMember(groupID: groupID, name: "同账号伙伴", role: "独立讨论成员，按群请求阅读证据。", homePath: homes[0])
            let peer = try XCTUnwrap(createdPeer)
            let createdReviewer = await coordinator.addMember(groupID: groupID, name: "审查者", role: "只读核对项目文件，引用已共享群消息。", homePath: homes[1])
            let reviewer = try XCTUnwrap(createdReviewer)
            let createdObserver = await coordinator.addMember(groupID: groupID, name: "观察者", role: "阅读共享结论并简短确认。", homePath: homes[2])
            let observer = try XCTUnwrap(createdObserver)

            await coordinator.send(groupID: groupID, text: "@实现者 请只读 shared.txt，并用一行回复其中的完整口令。")
            _ = try await waitForReply(coordinator, groupID, writer, containing: String(marker))
            let writerOriginal = try binding(coordinator, groupID, writer)
            try record("first-account-native-read", ["threadID": writerOriginal.threadID])

            await coordinator.send(groupID: groupID, text: "@同账号伙伴 根据群记录，复述实现者刚读出的完整口令；不要修改任何文件。")
            _ = try await waitForReply(coordinator, groupID, peer, containing: String(marker))
            let peerBinding = try binding(coordinator, groupID, peer)
            XCTAssertNotEqual(writerOriginal.threadID, peerBinding.threadID)
            let count = await runtime.0.pool.connectionCount()
            XCTAssertEqual(count, 1, "Members of one profile must reuse one app-server")
            try record("same-account-two-independent-members", ["firstThread": writerOriginal.threadID, "secondThread": peerBinding.threadID, "connectionCount": count])

            await coordinator.send(groupID: groupID, text: "@审查者 请引用实现者在群里提供的口令，并只读 shared.txt 核对，回复该完整口令及是否一致。")
            _ = try await waitForReply(coordinator, groupID, reviewer, containing: String(marker))
            XCTAssertNotEqual(try binding(coordinator, groupID, reviewer).accountIdentity, writerOriginal.accountIdentity)
            try record("cross-account-shared-evidence")

            await coordinator.send(groupID: groupID,
                text: "@实现者 在共享项目中创建 implementation.txt，唯一内容为 \(marker)_EDITED 加换行。仅修改这个文件，完成后简短确认。",
                permission: .workspaceWrite)
            _ = try await waitForReply(coordinator, groupID, writer)
            let written = try String(contentsOf: project.appendingPathComponent("implementation.txt"), encoding: .utf8)
            XCTAssertEqual(written.trimmingCharacters(in: .whitespacesAndNewlines), "\(marker)_EDITED")
            await coordinator.send(groupID: groupID, text: "@审查者 只读 implementation.txt，报告文件完整内容并判断是否与实现者刚才的任务一致。不要写任何文件。")
            _ = try await waitForReply(coordinator, groupID, reviewer, containing: "\(marker)_EDITED")
            try record("writer-edits-reviewer-inspects-same-project", ["content": written, "writerPermission": try binding(coordinator, groupID, writer).permission.rawValue,
                "reviewerPermission": try binding(coordinator, groupID, reviewer).permission.rawValue])

            let beforeRestart = try binding(coordinator, groupID, reviewer)
            coordinator.deactivate()
            await runtime.0.deactivate()
            runtime = makeRuntime(root)
            coordinator = runtime.1
            await runtime.0.activate(probeExecutablePath: "unused-native-probe")
            await coordinator.activate()
            XCTAssertEqual(try binding(coordinator, groupID, reviewer).threadID, beforeRestart.threadID)
            await coordinator.send(groupID: groupID, text: "@审查者 继续前面的核对，请再次给出实现者已经写入 implementation.txt 的完整内容，一行即可。")
            _ = try await waitForReply(coordinator, groupID, reviewer, containing: "\(marker)_EDITED")
            XCTAssertEqual(try binding(coordinator, groupID, reviewer).threadID, beforeRestart.threadID)
            try record("restart-resumes-original-native-thread", ["threadID": beforeRestart.threadID])

            let originalPage = try await coordinator.readHistory(groupID: groupID, memberID: reviewer)
            let originalTurns = originalPage["data"]?.arrayValue?.count ?? 0
            await coordinator.forkMember(groupID: groupID, memberID: reviewer)
            let fork = try binding(coordinator, groupID, reviewer)
            XCTAssertNotEqual(fork.threadID, beforeRestart.threadID)
            XCTAssertEqual(fork.lineage, "native-fork")
            XCTAssertEqual(fork.predecessorThreadID, beforeRestart.threadID)
            await coordinator.send(groupID: groupID, text: "@审查者 这是新分支，请按继承的上下文复述项目口令，一行即可。")
            _ = try await waitForReply(coordinator, groupID, reviewer, containing: String(marker))
            let oldHistory = try await CodexGroupAdapter(pool: runtime.0.pool).turns(beforeRestart)
            XCTAssertEqual(oldHistory["data"]?.arrayValue?.count ?? 0, originalTurns)
            try record("native-fork-preserves-original", ["sourceThread": beforeRestart.threadID, "forkThread": fork.threadID, "sourceTurnCount": originalTurns])

            await coordinator.handoff(groupID: groupID, memberID: reviewer, targetHomePath: homes[0])
            let handoff = try binding(coordinator, groupID, reviewer)
            XCTAssertNotEqual(handoff.accountIdentity, fork.accountIdentity)
            XCTAssertNotEqual(handoff.threadID, fork.threadID)
            XCTAssertEqual(handoff.lineage, "context-handoff")
            await coordinator.send(groupID: groupID, text: "@审查者 继续已共享的群任务，指出 implementation.txt 应有的完整内容，并说明这是依据共享群记录的交接。只读，一至两行。")
            _ = try await waitForReply(coordinator, groupID, reviewer, containing: "\(marker)_EDITED")
            try record("explicit-account-handoff-preserves-member-and-shared-context", ["memberID": reviewer.uuidString, "sourceThread": fork.threadID, "destinationThread": handoff.threadID])

            let unavailableHome = root.appendingPathComponent("unavailable-home", isDirectory: true)
            try FileManager.default.createDirectory(at: unavailableHome, withIntermediateDirectories: true)
            let createdUnavailable = await coordinator.addMember(groupID: groupID, name: "离线成员", role: "验证账号不可用时的隔离。", homePath: unavailableHome.path)
            let unavailable = try XCTUnwrap(createdUnavailable)
            await coordinator.send(groupID: groupID, text: "@观察者 @离线成员 从群记录中确认本次协作的原始口令，原样输出完整口令即可，不需要工具。")
            _ = try await waitForReply(coordinator, groupID, observer, containing: String(marker))
            try record("third-account-shared-discussion", ["threadID": try binding(coordinator, groupID, observer).threadID])
            XCTAssertEqual(coordinator.group(groupID)?.dispatches.last(where: { $0.memberID == unavailable })?.state, .failed)
            try record("unavailable-member-does-not-block-other-account")

            let final = try XCTUnwrap(coordinator.group(groupID))
            XCTAssertTrue(final.dispatches.allSatisfy { $0.memberID == unavailable ? $0.state == .failed : ($0.state == .completed && $0.nativeReplyVerified) })
            XCTAssertEqual(final.dispatches.count, 10)
            let receipt: [String: Any] = ["status": "passed", "scenarios": evidence, "groupID": groupID.uuidString,
                "dispatchCount": final.dispatches.count, "messageCount": final.messages.count, "project": project.path]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
            coordinator.deactivate()
            await runtime.0.deactivate()
        } catch {
            let receipt: [String: Any] = ["status": "failed", "error": error.localizedDescription, "scenarios": evidence, "project": project.path]
            try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
            coordinator.deactivate()
            await runtime.0.deactivate()
            throw error
        }
    }

    private func makeRuntime(_ root: URL) -> (CodexTaskDeliveryCoordinator, HarvisGroupCoordinator) {
        let pool = CodexAppServerPool(executableURL: CodexExecutableLocator.resolve(), environmentPolicy: .chatGPTProfile)
        let delivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: root.appendingPathComponent("delivery.json")),
            pool: pool, handoffStore: CodexConversationHandoffStore(storeURL: root.appendingPathComponent("legacy-handoffs.json")),
            activityProbe: CodexGroupNativeActivityProbe(pool: pool), monitorIntervalNanoseconds: 500_000_000)
        return (delivery, HarvisGroupCoordinator(delivery: delivery, store: HarvisGroupStore(url: root.appendingPathComponent("groups.json"))))
    }

    private func binding(_ coordinator: HarvisGroupCoordinator, _ groupID: UUID, _ memberID: UUID) throws -> HarvisGroupBinding {
        try XCTUnwrap(coordinator.group(groupID)?.members.first { $0.id == memberID }?.binding)
    }

    private func waitForReply(_ coordinator: HarvisGroupCoordinator, _ groupID: UUID, _ memberID: UUID, containing text: String? = nil) async throws -> String {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            guard let group = coordinator.group(groupID), let dispatch = group.dispatches.last(where: { $0.memberID == memberID }) else {
                throw AcceptanceFailure(coordinator.lastError ?? "No durable dispatch was created")
            }
            if dispatch.state == .failed || dispatch.state == .deliveryUnknown {
                throw AcceptanceFailure("\(dispatch.state): \(dispatch.lastError ?? coordinator.lastError ?? "unknown")")
            }
            if dispatch.state == .completed && dispatch.nativeReplyVerified {
                let reply = group.messages.first { $0.id == dispatch.responseMessageID }?.text ?? ""
                guard !reply.isEmpty, text.map(reply.contains) ?? true else {
                    throw AcceptanceFailure("Native completed reply did not contain required evidence: \(reply.prefix(1000))")
                }
                return reply
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let state = coordinator.group(groupID)?.dispatches.last(where: { $0.memberID == memberID })
        throw AcceptanceFailure("Native dispatch timed out: \(String(describing: state?.state)); \(state?.lastError ?? coordinator.lastError ?? "no detail")")
    }
}

private struct AcceptanceFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
