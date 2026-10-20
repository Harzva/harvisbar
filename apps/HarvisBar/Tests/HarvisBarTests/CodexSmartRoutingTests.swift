import AppKit
import XCTest
@testable import HarvisBar

final class CodexSmartRoutingTests: XCTestCase {
    func testIdleTaskStartsAndExternalTaskQueues() {
        XCTAssertEqual(
            CodexSmartRouter.decide(
                externalRunning: false,
                ownership: nil,
                activeTurnID: nil,
                connectionID: nil
            ),
            .start
        )
        XCTAssertEqual(
            CodexSmartRouter.decide(
                externalRunning: true,
                ownership: .external(turnID: "external"),
                activeTurnID: "external",
                connectionID: UUID()
            ),
            .queue
        )
    }

    func testSteerRequiresExactManagerTurnAndConnectionLifecycle() {
        let ownerConnection = UUID()
        let ownership = CodexTurnOwnership.manager(
            turnID: "turn-1",
            connectionID: ownerConnection
        )
        XCTAssertEqual(
            CodexSmartRouter.decide(
                externalRunning: true,
                ownership: ownership,
                activeTurnID: "turn-1",
                connectionID: ownerConnection
            ),
            .steer(turnID: "turn-1")
        )
        XCTAssertNotEqual(
            CodexSmartRouter.decide(
                externalRunning: true,
                ownership: ownership,
                activeTurnID: "turn-1",
                connectionID: UUID()
            ),
            .steer(turnID: "turn-1")
        )
        XCTAssertNotEqual(
            CodexSmartRouter.decide(
                externalRunning: true,
                ownership: ownership,
                activeTurnID: "turn-2",
                connectionID: ownerConnection
            ),
            .steer(turnID: "turn-1")
        )
    }

    func testIdleGateRequiresTwoObservationsAndFinalRecheck() {
        var gate = CodexIdleDispatchGate()
        gate.observe(successfulIdle: true)
        XCTAssertFalse(gate.permitsDispatch(finalSuccessfulIdle: true))
        gate.observe(successfulIdle: true)
        XCTAssertTrue(gate.permitsDispatch(finalSuccessfulIdle: true))
        XCTAssertFalse(gate.permitsDispatch(finalSuccessfulIdle: false))
        gate.observe(successfulIdle: false)
        XCTAssertEqual(gate.consecutiveIdleObservations, 0)
    }

    func testComposerEnterAndShiftEnterPolicy() {
        XCTAssertEqual(
            CodexComposerKeyAction.action(
                keyCode: 36,
                shiftPressed: false,
                hasMarkedText: false
            ),
            .send
        )
        XCTAssertEqual(
            CodexComposerKeyAction.action(
                keyCode: 36,
                shiftPressed: true,
                hasMarkedText: false
            ),
            .newline
        )
        XCTAssertEqual(
            CodexComposerKeyAction.action(
                keyCode: 36,
                shiftPressed: false,
                hasMarkedText: true
            ),
            .forwardToInputSystem
        )
    }

    func testComposerVisibilityDisabledAlwaysHides() {
        XCTAssertFalse(
            CodexComposerVisibilityPolicy.shouldShow(
                isEnabled: false,
                selectedTags: [],
                threadTags: ["remote"]
            )
        )
    }

    func testComposerVisibilityEmptySelectionShowsEveryCard() {
        XCTAssertTrue(
            CodexComposerVisibilityPolicy.shouldShow(
                isEnabled: true,
                selectedTags: [],
                threadTags: []
            )
        )
    }

    func testComposerVisibilityUsesCaseInsensitiveORTagMatching() {
        XCTAssertTrue(
            CodexComposerVisibilityPolicy.shouldShow(
                isEnabled: true,
                selectedTags: ["urgent", "REMOTE"],
                threadTags: ["Remote", "review"]
            )
        )
        XCTAssertTrue(
            CodexComposerVisibilityPolicy.shouldShow(
                isEnabled: true,
                selectedTags: ["URGENT", "remote"],
                threadTags: ["urgent"]
            )
        )
    }

    func testComposerVisibilityHidesWhenNoSelectedTagMatches() {
        XCTAssertFalse(
            CodexComposerVisibilityPolicy.shouldShow(
                isEnabled: true,
                selectedTags: ["urgent", "remote"],
                threadTags: ["review", "local"]
            )
        )
    }

    func testCardInputCanBeOpenedWhileBulkInputsAndTagScopeHideIt() {
        XCTAssertTrue(CodexComposerVisibilityPolicy.shouldShow(
            isEnabled: false, selectedTags: ["urgent"], threadTags: ["review"],
            cardOverride: true
        ))
        XCTAssertTrue(CodexComposerVisibilityPolicy.shouldShow(
            isEnabled: true, selectedTags: ["urgent"], threadTags: ["review"],
            cardOverride: true
        ))
        XCTAssertFalse(CodexComposerVisibilityPolicy.shouldShow(
            isEnabled: true, selectedTags: [], threadTags: [], cardOverride: false
        ))
    }

    func testComposerSelectedTagJSONIsStableAndRoundTrips() {
        let tags: Set<String> = ["zeta", "Alpha", "beta"]
        let encoded = CodexComposerVisibilityPolicy.encodeSelectedTags(tags)

        XCTAssertEqual(encoded, #"["Alpha","beta","zeta"]"#)
        XCTAssertEqual(
            CodexComposerVisibilityPolicy.selectedTags(from: encoded),
            tags
        )
    }

    func testComposerSelectedTagJSONTreatsMalformedDataAsEmpty() {
        XCTAssertEqual(
            CodexComposerVisibilityPolicy.selectedTags(from: "not-json"),
            []
        )
        XCTAssertEqual(
            CodexComposerVisibilityPolicy.selectedTags(
                from: #"{"tag":"remote"}"#
            ),
            []
        )
        XCTAssertEqual(
            CodexComposerVisibilityPolicy.selectedTags(
                from: #"["remote",1]"#
            ),
            []
        )
    }

    func testWorkbenchDefaultsAndMinimums() {
        XCTAssertEqual(CodexWorkbenchWindowSize.compactDefault.width, 920)
        XCTAssertEqual(CodexWorkbenchWindowSize.expandedDefault.height, 820)
        XCTAssertEqual(
            CodexWorkbenchWindowSize(width: 1, height: 1)
                .clamped(for: .expanded),
            CodexWorkbenchWindowSize(width: 980, height: 560)
        )
    }

    func testLegacyOversizedCompactPreferenceMigratesToCompactDefault() {
        let suiteName = "CodexWorkbenchSizePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            2_048.0,
            forKey: CodexChatWorkbenchDefaults.compactWidthKey
        )
        defaults.set(
            1_120.0,
            forKey: CodexChatWorkbenchDefaults.compactHeightKey
        )

        let restoration = CodexChatWorkbenchSizePolicy.restore(
            mode: .compact,
            defaults: defaults
        )

        XCTAssertTrue(restoration.migratedLegacyCompactSize)
        XCTAssertEqual(restoration.size, .compactDefault)
        XCTAssertLessThan(restoration.size.width, 2_048)
        XCTAssertEqual(
            defaults.double(forKey: CodexChatWorkbenchDefaults.compactWidthKey),
            CodexWorkbenchWindowSize.compactDefault.width
        )
        XCTAssertEqual(
            defaults.double(forKey: CodexChatWorkbenchDefaults.compactHeightKey),
            CodexWorkbenchWindowSize.compactDefault.height
        )
    }

    func testExpandedSizedCompactPreferenceMigratesToCompactDefault() {
        let restoration = CodexChatWorkbenchSizePolicy.restore(
            mode: .compact,
            storedWidth: CodexWorkbenchWindowSize.expandedDefault.width,
            storedHeight: CodexWorkbenchWindowSize.expandedDefault.height
        )

        XCTAssertTrue(restoration.migratedLegacyCompactSize)
        XCTAssertEqual(restoration.size, .compactDefault)
    }

    func testReasonableCompactUserResizeIsPreserved() {
        let restoration = CodexChatWorkbenchSizePolicy.restore(
            mode: .compact,
            storedWidth: 1_080,
            storedHeight: 860
        )

        XCTAssertFalse(restoration.migratedLegacyCompactSize)
        XCTAssertEqual(
            restoration.size,
            CodexWorkbenchWindowSize(width: 1_080, height: 860)
        )
    }

    @MainActor
    func testWindowFrameSizeRoundTripsThroughContentRectConversion() {
        let requested = NSSize(width: 920, height: 780)
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]
        let contentRect = CodexChatWorkbenchSizePolicy.contentRect(
            forWindowFrameSize: requested,
            styleMask: styleMask
        )
        let roundTripped = NSWindow.frameRect(
            forContentRect: contentRect,
            styleMask: styleMask
        ).size

        XCTAssertEqual(roundTripped.width, requested.width, accuracy: 0.01)
        XCTAssertEqual(roundTripped.height, requested.height, accuracy: 0.01)
    }

    func testExpandedFrameIsClampedToTargetDisplayVisibleFrame() {
        let original = NSRect(x: 2_400, y: 100, width: 920, height: 780)
        let visible = NSRect(x: 1_920, y: 24, width: 1_100, height: 760)
        let resized = CodexChatWorkbenchSizePolicy.resizedFrame(
            original,
            toWindowFrameSize: .expandedDefault,
            within: visible
        )

        XCTAssertEqual(resized.size, visible.size)
        XCTAssertTrue(visible.contains(resized))
    }

    func testSerialBatchPromptValidationAndCardPermissions() {
        XCTAssertEqual(
            CodexSerialBatchPolicy.normalizedPrompt(
                "  continue  ",
                repeatCount: 20
            ),
            "continue"
        )
        XCTAssertNil(
            CodexSerialBatchPolicy.normalizedPrompt(
                "   ",
                repeatCount: 20
            )
        )
        XCTAssertNil(
            CodexSerialBatchPolicy.normalizedPrompt(
                "continue",
                repeatCount: 1
            )
        )
        XCTAssertNil(
            CodexSerialBatchPolicy.normalizedPrompt(
                "continue",
                repeatCount: 21
            )
        )
        XCTAssertEqual(CodexSerialBatchPolicy.defaultRepeatCount, 20)
        XCTAssertTrue(CodexTaskCardType.main.canDispatchThroughCodex)
        XCTAssertTrue(CodexTaskCardType.persistedSubagent.canDispatchThroughCodex)
        XCTAssertTrue(CodexTaskCardType.sidechatParent.canDispatchThroughCodex)
        XCTAssertFalse(CodexTaskCardType.transientSidechat.canDispatchThroughCodex)
        XCTAssertFalse(CodexTaskCardType.dsh.canDispatchThroughCodex)
        XCTAssertFalse(CodexTaskCardType.workBuddy.canDispatchThroughCodex)
    }

    func testSerialBatchAdvancesOnlyAfterExactCompletedPredecessor() {
        var items = makeSerialBatchItems(states: [.waiting, .waiting, .waiting])
        XCTAssertEqual(
            CodexSerialBatchPolicy.predecessorDecision(
                for: items[0],
                in: items
            ),
            .ready
        )
        guard case .waiting = CodexSerialBatchPolicy.predecessorDecision(
            for: items[1],
            in: items
        ) else {
            return XCTFail("A pending predecessor must hold the next step")
        }

        items[0].state = .completed
        XCTAssertEqual(
            CodexSerialBatchPolicy.predecessorDecision(
                for: items[1],
                in: items
            ),
            .ready
        )

        for terminalState in [
            CodexDeliveryState.failed,
            .deliveryUnknown,
            .cancelled,
        ] {
            items[0].state = terminalState
            guard case .stop = CodexSerialBatchPolicy.predecessorDecision(
                for: items[1],
                in: items
            ) else {
                return XCTFail("\(terminalState) must stop the remaining batch")
            }
        }
    }

    private func makeSerialBatchItems(
        states: [CodexDeliveryState]
    ) -> [CodexTaskQueueItem] {
        let batchID = UUID()
        return states.enumerated().map { ordinal, state in
            CodexTaskQueueItem(
                command: CodexTaskCommand(
                    homeID: "home-a",
                    homePath: "/tmp/home-a",
                    threadID: "thread-a",
                    sourceThreadID: "thread-a",
                    cardType: .main,
                    text: "continue",
                    strategy: .serialBatch,
                    batch: CodexTaskBatchPosition(
                        batchID: batchID,
                        ordinal: ordinal,
                        count: states.count
                    )
                ),
                state: state
            )
        }
    }
}
