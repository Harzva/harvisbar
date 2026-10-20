import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedConversationInsightPresentationTests: XCTestCase {
    func testDynamicInputLabelsRenderValuesInsteadOfLiteralInterpolation() {
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputCountLabel(
                loaded: 4,
                total: 9,
                truncated: true
            ),
            "已读取 4/9 条；其余已安全截断。"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputCountLabel(
                loaded: 3,
                total: 3,
                truncated: false
            ),
            "共 3 条用户输入"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.analyzedInputCountLabel(
                analyzed: 2,
                total: 5
            ),
            "2/5"
        )
        XCTAssertFalse(
            ManagedConversationInsightPresentation.providerReadOnlyLabel("DSH")
                .contains("\\(")
        )
    }

    func testProjectAndRelevanceLabelsPreserveAccessibilityValues() {
        XCTAssertEqual(
            ManagedConversationInsightPresentation.recommendedProjectLabel("Brand"),
            "推荐归属：Brand"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.confirmRecommendationLabel("Brand"),
            "确认推荐项目 Brand"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.projectSelectionLabel(
                "Brand",
                isCurrent: true
            ),
            "当前管理项目：Brand"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.projectSelectionLabel(
                "Research",
                isCurrent: false
            ),
            "选择项目 Research"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.confidenceLabel(0.73),
            "置信度 73%"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.relevanceAccessibilityLabel(
                score: 38,
                isStale: true
            ),
            "项目相关性 38，数据陈旧"
        )
    }

    func testInputRowsHaveStableSequenceLabelsAndIdentifiers() {
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputSequenceLabel(7),
            "#7"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputToggleLabel(
                sequence: 7,
                isExpanded: false
            ),
            "展开第 7 条用户输入"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputToggleLabel(
                sequence: 7,
                isExpanded: true
            ),
            "收起第 7 条用户输入"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputIdentifier("turn-7"),
            "managed-conversation-input-turn-7"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputSourceLabel(.human),
            "用户输入"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputSourceLabel(.unknown),
            "用户角色 · 来源未证实"
        )
        XCTAssertEqual(
            ManagedConversationInsightPresentation.inputSourceLabel(.manager),
            "Manager 指令 · 已排除"
        )
    }
}
