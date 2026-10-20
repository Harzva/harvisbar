import AppKit
import SwiftUI

/// Shared vertical measurements for task composers.
///
/// The matrix layout relies on every card reserving the same composer height;
/// keeping the values here avoids each card deciding its own input geometry.
enum CodexTaskComposerLayoutMetrics {
    static let compactInputHeight: CGFloat = 56
    static let matrixInputHeight: CGFloat = 72
    static let controlsHeight: CGFloat = 22
    static let verticalSpacing: CGFloat = 5

    /// The matrix reserves the complete composer slot even when a card is
    /// read-only or its input is hidden by the user's tag policy. This keeps
    /// neighboring cards' input and footer rows on the same horizontal lines.
    static var matrixComposerSlotHeight: CGFloat {
        matrixInputHeight + verticalSpacing + controlsHeight
    }

    static func inputHeight(compact: Bool) -> CGFloat {
        compact ? compactInputHeight : matrixInputHeight
    }

    static func inputHeight(compact: Bool, for textSize: HarvisTextSize?) -> CGFloat {
        scaled(inputHeight(compact: compact), for: textSize)
    }

    static func controlsHeight(for textSize: HarvisTextSize?) -> CGFloat {
        scaled(controlsHeight, for: textSize)
    }

    static func verticalSpacing(for textSize: HarvisTextSize?) -> CGFloat {
        scaled(verticalSpacing, for: textSize)
    }

    static func matrixComposerSlotHeight(for textSize: HarvisTextSize?) -> CGFloat {
        scaled(matrixComposerSlotHeight, for: textSize)
    }

    private static func scaled(_ value: CGFloat, for textSize: HarvisTextSize?) -> CGFloat {
        value * (textSize?.layoutScale ?? 1)
    }
}

/// A non-dispatchable/filtered matrix card still occupies the same composer
/// slot as a dispatchable card. Read-only providers get a small explanation;
/// tag-filtered Codex cards stay visually quiet so hiding inputs remains a
/// useful compactness control.
struct CodexMatrixComposerPlaceholder: View {
    @Environment(\.harvisTextSize) private var harvisTextSize

    let thread: ManagedChatThread
    let theme: HarvisTheme
    let inputPolicyHidden: Bool

    var body: some View {
        Group {
            if inputPolicyHidden {
                Color.clear
            } else {
                HStack(spacing: 6) {
                    Image(systemName: thread.provider == .dsh ? "bubble.left" : "eye")
                        .harvisFont(.caption2)
                    Text(readOnlyLabel)
                        .harvisFont(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundColor(theme.muted)
                .accessibilityLabel(readOnlyLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: CodexTaskComposerLayoutMetrics.matrixComposerSlotHeight(for: harvisTextSize))
        .accessibilityHidden(inputPolicyHidden)
    }

    private var readOnlyLabel: String {
        switch thread.provider {
        case .dsh:
            return thread.isSubagent ? "DSH 子智能体 · 在 DSH 中操作" : "点击标题，在详情中发送消息"
        case .workBuddy:
            return "WorkBuddy 只读观察"
        case .codex:
            return "此会话暂不支持卡片发送"
        }
    }
}

private final class CodexComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch CodexComposerKeyAction.action(
            keyCode: event.keyCode,
            shiftPressed: event.modifierFlags.contains(.shift),
            hasMarkedText: hasMarkedText()
        ) {
        case .send:
            onSubmit?()
        case .newline:
            insertNewline(nil)
        case .forwardToInputSystem:
            super.keyDown(with: event)
        }
    }
}

struct ManagedChatMultilineInput: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    var inputAccessibilityID: String? = nil
    var inputAccessibilityLabel: String? = nil

    @Environment(\.harvisTextSize) private var harvisTextSize

    private var nativeFont: NSFont {
        NSFont.systemFont(ofSize: harvisTextSize?.pointSize(for: 13) ?? 13)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ManagedChatMultilineInput

        init(_ parent: ManagedChatMultilineInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = CodexComposerTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.font = nativeFont
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CodexComposerTextView else {
            return
        }
        textView.onSubmit = onSubmit
        textView.setAccessibilityIdentifier(inputAccessibilityID)
        textView.setAccessibilityLabel(inputAccessibilityLabel)
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        if textView.font?.pointSize != nativeFont.pointSize {
            let selectedRange = textView.selectedRange()
            textView.font = nativeFont
            textView.setSelectedRange(selectedRange)
        }
        if textView.string != text {
            textView.string = text
        }
    }
}

struct CodexTaskComposerView: View {
    @ObservedObject var coordinator: CodexTaskDeliveryCoordinator
    let thread: ManagedChatThread
    let home: CodexHome?
    let homePath: String?
    @Binding var text: String
    @Binding var isSubmitting: Bool
    let theme: HarvisTheme
    var compact = false

    @Environment(\.harvisTextSize) private var harvisTextSize

    @AppStorage(CodexSerialBatchPolicy.repeatCountDefaultsKey)
    private var repeatCount = CodexSerialBatchPolicy.defaultRepeatCount
    @State private var showingRepeatPopover = false

    private var targetThreadID: String? {
        switch thread.dispatchCapability {
        case let .direct(threadID), let .parentOnly(threadID):
            return threadID
        case .unavailable:
            return nil
        }
    }

    private var unavailableReason: String? {
        switch thread.dispatchCapability {
        case .direct, .parentOnly:
            guard home != nil, homePath != nil else {
                return "未选择可用的 Codex 账户。"
            }
            guard thread.sourceScope == home?.id else {
                return "任务来源账户已切换，请刷新后再派发。"
            }
            return nil
        case let .unavailable(reason):
            return reason
        }
    }

    private var actionLabel: String {
        switch thread.dispatchCapability {
        case .parentOnly: return "发送给父任务"
        case .direct: return "发送"
        case .unavailable: return "不可派发"
        }
    }

    private var canSubmit: Bool {
        unavailableReason == nil
            && coordinator.isReady
            && !isSubmitting
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedRepeatCount: Int {
        CodexSerialBatchPolicy.normalizedRepeatCount(repeatCount)
    }

    private var repeatCountBinding: Binding<Int> {
        Binding(
            get: { normalizedRepeatCount },
            set: { repeatCount = CodexSerialBatchPolicy.normalizedRepeatCount($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CodexTaskComposerLayoutMetrics.verticalSpacing(for: harvisTextSize)) {
            if let unavailableReason {
                Label(localizedReason(unavailableReason), systemImage: "eye")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(2)
            } else {
                ZStack(alignment: .topLeading) {
                    ManagedChatMultilineInput(
                        text: $text,
                        isEnabled: coordinator.isReady && !isSubmitting,
                        onSubmit: submit,
                        inputAccessibilityID: "codex-card-input-\(thread.id)",
                        inputAccessibilityLabel: "会话指令 · \(thread.title)"
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .frame(
                        height: CodexTaskComposerLayoutMetrics.inputHeight(compact: compact, for: harvisTextSize),
                        alignment: .topLeading
                    )

                    if text.isEmpty || !coordinator.isReady {
                        Text(composerPlaceholder)
                            .harvisFont(.system(size: 12))
                            .foregroundColor(theme.muted)
                            .padding(.leading, 8)
                            .padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                }
                .background(theme.surfaceAlt.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))

                HStack(spacing: 7) {
                    Text(coordinator.isReady
                        ? "Enter 发送 · Shift+Enter 换行"
                        : "正在恢复持久化任务队列…")
                        .harvisFont(.system(size: 11))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button {
                        showingRepeatPopover.toggle()
                    } label: {
                        Label(
                            "×\(normalizedRepeatCount)",
                            systemImage: "repeat"
                        )
                        .harvisFont(.caption.bold().monospacedDigit())
                        .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .layoutPriority(1)
                    .disabled(!canSubmit)
                    .help("把当前提示词逐 Turn 自动发送")
                    .accessibilityLabel(
                        "设置固定提示词自动发送，当前 \(normalizedRepeatCount) 次"
                    )
                    .popover(isPresented: $showingRepeatPopover) {
                        repeatPromptPopover
                    }
                    Button(actionLabel, action: submit)
                        .harvisFont(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .layoutPriority(1)
                        .tint(theme.accent)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("codex-card-send-\(thread.id)")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(
                    height: CodexTaskComposerLayoutMetrics.controlsHeight(for: harvisTextSize),
                    alignment: .center
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task input for \(thread.title)")
    }

    private var repeatPromptPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("固定提示词自动续发", systemImage: "repeat")
                .harvisFont(.headline)

            Text(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)))
                .harvisFont(.caption.monospaced())
                .lineLimit(5)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Stepper(
                "次数：\(normalizedRepeatCount)",
                value: repeatCountBinding,
                in: CodexSerialBatchPolicy.repeatCountRange
            )
            .harvisFont(.subheadline.monospacedDigit())

            Text("每次都等待上一 Turn 成功完成后再启动新 Turn；不会 steer。失败、取消或交付状态未知时自动停止剩余次数。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button(repeatActionLabel) {
                showingRepeatPopover = false
                submitRepeated()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(!canSubmit)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var repeatActionLabel: String {
        switch thread.dispatchCapability {
        case .parentOnly:
            return "逐回合发送给父任务 ×\(normalizedRepeatCount)"
        case .direct:
            return "逐回合发送 ×\(normalizedRepeatCount)"
        case .unavailable:
            return "不可派发"
        }
    }

    private var composerPlaceholder: String {
        guard coordinator.isReady else {
            return "恢复队列中，完成后可发送…"
        }
        return thread.isSidechat ? "追加到父任务…" : "输入任务或追加指令…"
    }

    private func submit() {
        guard canSubmit,
              let home,
              let homePath,
              thread.sourceScope == home.id,
              let targetThreadID else {
            return
        }
        let submittedText = text
        isSubmitting = true
        Task {
            let commandID = await coordinator.submit(
                homeID: home.id,
                homePath: homePath,
                sourceThreadID: thread.sourceID,
                targetThreadID: targetThreadID,
                cardType: thread.taskCardType,
                text: submittedText
            )
            await MainActor.run {
                if commandID != nil, text == submittedText {
                    text = ""
                }
                isSubmitting = false
            }
        }
    }

    private func submitRepeated() {
        guard canSubmit,
              let home,
              let homePath,
              thread.sourceScope == home.id,
              let targetThreadID else {
            return
        }
        let submittedText = text
        let submittedCount = normalizedRepeatCount
        isSubmitting = true
        Task {
            let batchID = await coordinator.submitRepeated(
                homeID: home.id,
                homePath: homePath,
                sourceThreadID: thread.sourceID,
                targetThreadID: targetThreadID,
                cardType: thread.taskCardType,
                text: submittedText,
                repeatCount: submittedCount
            )
            await MainActor.run {
                if batchID != nil, text == submittedText {
                    text = ""
                }
                isSubmitting = false
            }
        }
    }

    private func localizedReason(_ reason: String) -> String {
        switch thread.taskCardType {
        case .workBuddy:
            return "WorkBuddy 卡片仅观察，不允许直接派发。"
        case .transientSidechat:
            return "瞬时 Sidechat 没有可靠父任务，不能直接派发。"
        default:
            return reason
        }
    }
}
