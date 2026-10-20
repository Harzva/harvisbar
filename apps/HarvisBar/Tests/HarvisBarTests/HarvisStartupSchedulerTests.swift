import XCTest
@testable import HarvisBar

@MainActor
final class HarvisStartupSchedulerTests: XCTestCase {
    func testManagedChatDiscoveryDoesNotWaitForSlowSystemRefresh() async {
        let systemStarted = expectation(description: "system refresh started")
        let managedChatsDiscovered = expectation(description: "managed chats discovered")

        let tasks = HarvisStartupScheduler.launch(
            recoverDelivery: {},
            discoverManagedChats: {
                managedChatsDiscovered.fulfill()
            },
            refreshSystem: {
                systemStarted.fulfill()
                try? await Task.sleep(for: .seconds(30))
            }
        )
        defer { tasks.cancel() }

        await fulfillment(
            of: [systemStarted, managedChatsDiscovered],
            timeout: 1,
            enforceOrder: false
        )
        XCTAssertFalse(tasks.managedChatDiscovery.isCancelled)
    }

    func testManagedChatDiscoveryDoesNotWaitForDeliveryRecovery() async {
        let deliveryStarted = expectation(description: "delivery recovery started")
        let managedChatsDiscovered = expectation(description: "managed chats discovered")

        let tasks = HarvisStartupScheduler.launch(
            recoverDelivery: {
                deliveryStarted.fulfill()
                try? await Task.sleep(for: .seconds(30))
            },
            discoverManagedChats: {
                managedChatsDiscovered.fulfill()
            },
            refreshSystem: {}
        )
        defer { tasks.cancel() }

        await fulfillment(
            of: [deliveryStarted, managedChatsDiscovered],
            timeout: 1,
            enforceOrder: false
        )
        XCTAssertFalse(tasks.managedChatDiscovery.isCancelled)
    }
}
