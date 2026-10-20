import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class CodexDesktopCoordinatorTests: XCTestCase {
    func testExistingAccountReceivesLinkWithoutLaunchingAnotherInstance() async throws {
        let host = DesktopHostFixture()
        host.live = [.init(pid: 11, homePath: "/codex-test-accounts/other"), .init(pid: 22, homePath: "/codex-test-accounts/target")]
        let coordinator = CodexDesktopCoordinator(host: host)
        let receipt = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "thread-1")
        XCTAssertEqual(receipt.pid, 22)
        XCTAssertTrue(receipt.reused)
        XCTAssertFalse(receipt.requestedNewWindow)
        XCTAssertEqual(host.launchCount, 0)
        XCTAssertEqual(host.links, [.init(pid: 22, url: "codex://threads/thread-1", newWindow: false)])
        XCTAssertEqual(host.activated, [22])
    }

    func testDifferentAccountIsNeverReusedAndColdOpenCreatesOnlyOneWindow() async throws {
        let host = DesktopHostFixture()
        host.live = [.init(pid: 11, homePath: "/codex-test-accounts/other")]
        let coordinator = CodexDesktopCoordinator(host: host)
        let receipt = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "thread-1", newWindow: true)
        XCTAssertEqual(host.launchCount, 1)
        XCTAssertEqual(receipt.pid, 42)
        XCTAssertFalse(receipt.reused)
        XCTAssertTrue(receipt.requestedNewWindow)
        XCTAssertEqual(host.links.first?.pid, 42)
        XCTAssertEqual(host.links.first?.newWindow, false, "The first app window already exists; don't create a second one")
    }

    func testExplicitNewWindowUsesExistingAccountProcess() async throws {
        let host = DesktopHostFixture()
        host.live = [.init(pid: 22, homePath: "/codex-test-accounts/target")]
        let coordinator = CodexDesktopCoordinator(host: host)
        let receipt = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "thread-1", newWindow: true)
        XCTAssertEqual(host.launchCount, 0)
        XCTAssertTrue(receipt.requestedNewWindow)
        XCTAssertEqual(host.links.first?.pid, 22)
        XCTAssertEqual(host.links.first?.newWindow, true)
    }

    func testAccountLaunchButtonOnlyActivatesAnExistingInstance() async throws {
        let host = DesktopHostFixture()
        host.live = [.init(pid: 22, homePath: "/codex-test-accounts/target")]
        let coordinator = CodexDesktopCoordinator(host: host)
        _ = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account")
        XCTAssertEqual(host.launchCount, 0)
        XCTAssertTrue(host.links.isEmpty)
        XCTAssertEqual(host.activated, [22])
    }

    func testConcurrentCardsShareOneAccountLaunch() async throws {
        let host = DesktopHostFixture()
        host.suspendLaunch = true
        let coordinator = CodexDesktopCoordinator(host: host)
        let first = Task { try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "first") }
        let second = Task { try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "second") }
        for _ in 0..<100 where host.resumeLaunch == nil { await Task.yield() }
        XCTAssertNotNil(host.resumeLaunch)
        host.resumeLaunch?.resume()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(host.launchCount, 1)
        XCTAssertEqual(Set(host.links.map(\.pid)), [42])
        XCTAssertEqual(Set(host.links.map(\.url)), ["codex://threads/first", "codex://threads/second"])
        XCTAssertTrue(host.links.allSatisfy { !$0.newWindow })
    }

    func testConcurrentExplicitWindowsShareOneLaunchButRequestSeparateWindows() async throws {
        let host = DesktopHostFixture()
        host.suspendLaunch = true
        let coordinator = CodexDesktopCoordinator(host: host)
        let first = Task {
            try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "first", newWindow: true)
        }
        for _ in 0..<100 where host.resumeLaunch == nil { await Task.yield() }
        let second = Task {
            try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "second", newWindow: true)
        }
        for _ in 0..<100 where host.instanceReadCount < 2 { await Task.yield() }
        XCTAssertEqual(host.instanceReadCount, 2, "Both requests must observe the cold account before launch completes")
        host.resumeLaunch?.resume()
        let receipts = try await [first.value, second.value]
        XCTAssertEqual(host.launchCount, 1)
        XCTAssertEqual(host.links.first(where: { $0.url == "codex://threads/first" })?.newWindow, false)
        XCTAssertEqual(host.links.first(where: { $0.url == "codex://threads/second" })?.newWindow, true)
        XCTAssertEqual(receipts.map(\.reused), [false, true])
        XCTAssertTrue(receipts.allSatisfy(\.requestedNewWindow))
    }

    func testDuplicateExplicitWindowRequestsCoalesceToOneDelivery() async throws {
        let host = DesktopHostFixture()
        host.suspendLaunch = true
        let coordinator = CodexDesktopCoordinator(host: host)
        let first = Task {
            try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "same", newWindow: true)
        }
        for _ in 0..<100 where host.resumeLaunch == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "same", newWindow: true)
        }
        for _ in 0..<100 where !secondStarted { await Task.yield() }
        XCTAssertTrue(secondStarted)
        host.resumeLaunch?.resume()
        let firstReceipt = try await first.value
        let secondReceipt = try await second.value
        XCTAssertEqual(firstReceipt, secondReceipt)
        XCTAssertEqual(host.launchCount, 1)
        XCTAssertEqual(host.links, [.init(pid: 42, url: "codex://threads/same", newWindow: false)])
        XCTAssertEqual(host.activated, [42])
    }

    func testActivationFailureDoesNotReturnAReceiptAndCanBeRetried() async throws {
        for threadID: String? in [nil, "thread-1"] {
            let host = DesktopHostFixture()
            host.live = [.init(pid: 22, homePath: "/codex-test-accounts/target")]
            host.activationSucceeds = false
            let coordinator = CodexDesktopCoordinator(host: host)
            do {
                _ = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: threadID)
                XCTFail("Failed activation must not be reported as a completed open")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("切换到前台"))
            }
            host.activationSucceeds = true
            let receipt = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: threadID)
            XCTAssertEqual(receipt.pid, 22)
            XCTAssertEqual(host.launchCount, 0)
            XCTAssertEqual(host.activated, [22, 22])
        }
    }

    func testUnverifiedIdentityAfterLaunchNeverReceivesTheThread() async throws {
        let host = DesktopHostFixture()
        host.invalidateLaunchedIdentity = true
        let coordinator = CodexDesktopCoordinator(host: host)
        do {
            _ = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "thread-1")
            XCTFail("Unverified identity must stop routing")
        } catch {
            XCTAssertTrue(host.links.isEmpty)
            XCTAssertTrue(host.activated.isEmpty)
        }
    }

    func testInvalidThreadDoesNotLaunchAndReservedCharactersCannotChangeRoute() async throws {
        let host = DesktopHostFixture()
        let coordinator = CodexDesktopCoordinator(host: host)
        do {
            _ = try await coordinator.open(homePath: "/codex-test-accounts/target", homeID: "account", threadID: "")
            XCTFail("Empty thread must be rejected")
        } catch { XCTAssertEqual(host.launchCount, 0) }
        let url = try CodexDesktopCoordinator.threadURL("a/b?c#d%")
        XCTAssertEqual(url.absoluteString, "codex://threads/a%2Fb%3Fc%23d%25")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
    }

    func testDshLinkSelectsExactSessionAndRejectsAmbiguousInstance() {
        let endpoint = DshRuntimeEndpoint(homeID: "home", profile: "web", port: 3080)
        let url = ManagedChatOpenTarget.dshSessionURL(sessionID: "a/b?c#d%", sourceScope: endpoint.sourceScope, endpoints: [endpoint])
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:3080/#/session/a%2Fb%3Fc%23d%25")
        XCTAssertNil(ManagedChatOpenTarget.dshSessionURL(sessionID: "session", sourceScope: "other", endpoints: [endpoint]))
        XCTAssertNil(ManagedChatOpenTarget.dshSessionURL(sessionID: "session", sourceScope: endpoint.sourceScope, endpoints: [endpoint,
            .init(homeID: "home", profile: "web", port: 3081)]))
        XCTAssertNil(ManagedChatOpenTarget.dshSessionURL(sessionID: "", sourceScope: endpoint.sourceScope, endpoints: [endpoint]))
    }
}

@MainActor
private final class DesktopHostFixture: CodexDesktopHosting {
    struct Link: Equatable { let pid: Int32; let url: String; let newWindow: Bool }
    var live: [CodexDesktopInstance] = []
    var launchCount = 0
    var links: [Link] = []
    var activated: [Int32] = []
    var suspendLaunch = false
    var activationSucceeds = true
    var instanceReadCount = 0
    var invalidateLaunchedIdentity = false
    var resumeLaunch: CheckedContinuation<Void, Never>?
    func instances() -> [CodexDesktopInstance] {
        instanceReadCount += 1
        return live
    }
    func launch(homePath: String, homeID: String) async throws -> CodexDesktopInstance {
        launchCount += 1
        if suspendLaunch { await withCheckedContinuation { resumeLaunch = $0 } }
        let instance = CodexDesktopInstance(pid: 42, homePath: homePath)
        live.append(.init(pid: 42, homePath: invalidateLaunchedIdentity ? nil : homePath))
        return instance
    }
    func activate(pid: Int32) -> Bool {
        activated.append(pid)
        return activationSucceeds
    }
    func openThread(_ url: URL, pid: Int32, newWindow: Bool) async throws { links.append(.init(pid: pid, url: url.absoluteString, newWindow: newWindow)) }
}
