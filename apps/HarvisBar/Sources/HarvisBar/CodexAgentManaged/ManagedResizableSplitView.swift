import AppKit
import SwiftUI

/// A small, reusable split view for the managed workspace.
///
/// The parent owns `length` (usually through `@AppStorage`). This view only
/// changes it for an explicit drag, an accessibility adjustment, or the
/// divider's double-click reset. A window resize clamps the value used for
/// rendering and leaves the saved value untouched, so a temporarily narrow
/// window does not destroy the user's preferred layout.
struct ManagedResizableSplitView<Leading: View, Trailing: View>: View {
    let axis: Axis
    let fixedPane: ManagedSplitFixedPane
    @Binding var length: Double
    let defaultLength: Double
    let minimumLeading: CGFloat
    let minimumTrailing: CGFloat
    let theme: HarvisTheme
    let label: String
    let identifier: String

    private let leading: () -> Leading
    private let trailing: () -> Trailing

    @State private var dragStartLength: Double?

    private let dividerThickness = ManagedSplitGeometry.defaultDividerThickness
    private let adjustmentStep: Double = 16

    init(
        axis: Axis,
        fixedPane: ManagedSplitFixedPane,
        length: Binding<Double>,
        defaultLength: Double,
        minimumLeading: CGFloat,
        minimumTrailing: CGFloat,
        theme: HarvisTheme,
        label: String,
        identifier: String,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.axis = axis
        self.fixedPane = fixedPane
        self._length = length
        self.defaultLength = defaultLength
        self.minimumLeading = minimumLeading
        self.minimumTrailing = minimumTrailing
        self.theme = theme
        self.label = label
        self.identifier = identifier
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        GeometryReader { geometry in
            let availableExtent = ManagedSplitGeometry.availableExtent(
                for: axis,
                in: geometry.size
            )
            let panes = ManagedSplitGeometry.paneLengths(
                requestedLength: length,
                defaultLength: defaultLength,
                availableExtent: availableExtent,
                minimumLeading: minimumLeading,
                minimumTrailing: minimumTrailing,
                fixedPane: fixedPane,
                dividerThickness: dividerThickness
            )

            splitLayout(
                leadingLength: panes.leading,
                trailingLength: panes.trailing,
                availableExtent: availableExtent
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .onChange(of: axis) { _ in dragStartLength = nil }
    }

    private func splitLayout(
        leadingLength: CGFloat,
        trailingLength: CGFloat,
        availableExtent: CGFloat
    ) -> some View {
        let layout: AnyLayout
        if axis == .horizontal {
            layout = AnyLayout(HStackLayout(spacing: 0))
        } else {
            layout = AnyLayout(VStackLayout(spacing: 0))
        }

        return layout {
            leadingPane(length: leadingLength)
            dividerHandle(availableExtent: availableExtent)
            trailingPane(length: trailingLength)
        }
    }

    private func leadingPane(length: CGFloat) -> some View {
        leading()
            .frame(
                width: axis == .horizontal ? length : nil,
                height: axis == .vertical ? length : nil
            )
            .clipped()
    }

    private func trailingPane(length: CGFloat) -> some View {
        trailing()
            .frame(
                width: axis == .horizontal ? length : nil,
                height: axis == .vertical ? length : nil
            )
            .clipped()
    }

    private func dividerHandle(availableExtent: CGFloat) -> some View {
        let visual = ZStack {
            Rectangle()
                .fill(theme.line)
                .frame(
                    width: axis == .horizontal ? 1 : nil,
                    height: axis == .vertical ? 1 : nil
                )
            RoundedRectangle(cornerRadius: 1.5)
                .fill(theme.muted.opacity(0.9))
                .frame(
                    width: axis == .horizontal ? 3 : 22,
                    height: axis == .horizontal ? 22 : 3
                )
        }

        let target: AnyView
        if axis == .horizontal {
            target = AnyView(
                visual.frame(width: dividerThickness)
                    .frame(maxHeight: .infinity)
            )
        } else {
            target = AnyView(
                visual.frame(height: dividerThickness)
                    .frame(maxWidth: .infinity)
            )
        }

        return target
            .contentShape(Rectangle())
            .managedResizeCursor(axis: axis)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityLengthValue(availableExtent: availableExtent))
            .accessibilityHint("拖动调整；双击恢复默认大小")
            .accessibilityIdentifier(identifier + ".divider")
            .accessibilityAdjustableAction { direction in
                adjustLength(
                    by: direction == .increment ? adjustmentStep : -adjustmentStep,
                    availableExtent: availableExtent
                )
            }
            .onTapGesture(count: 2) {
                restoreDefault(availableExtent: availableExtent)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartLength == nil {
                            dragStartLength = visibleLength(availableExtent: availableExtent)
                        }
                        guard let dragStartLength else { return }
                        let translation = axis == .horizontal
                            ? Double(value.translation.width)
                            : Double(value.translation.height)
                        let direction = fixedPane == .leading ? 1.0 : -1.0
                        setLength(
                            dragStartLength + (translation * direction),
                            availableExtent: availableExtent
                        )
                    }
                    .onEnded { _ in
                        dragStartLength = nil
                    }
            )
    }

    private var dragBaseLength: Double {
        if length.isFinite {
            return length
        }
        return defaultLength.isFinite ? defaultLength : 0
    }

    private func setLength(_ candidate: Double, availableExtent: CGFloat) {
        guard availableExtent.isFinite, availableExtent > 0 else { return }
        length = Double(
            ManagedSplitGeometry.clampedLength(
                requestedLength: candidate,
                defaultLength: defaultLength,
                availableExtent: availableExtent,
                minimumLeading: minimumLeading,
                minimumTrailing: minimumTrailing,
                fixedPane: fixedPane,
                dividerThickness: dividerThickness
            )
        )
    }

    private func adjustLength(
        by delta: Double,
        availableExtent: CGFloat
    ) {
        setLength(visibleLength(availableExtent: availableExtent) + delta, availableExtent: availableExtent)
    }

    private func restoreDefault(availableExtent: CGFloat) {
        length = defaultLength.isFinite ? max(0, defaultLength) : 0
    }

    private func visibleLength(availableExtent: CGFloat) -> Double {
        Double(ManagedSplitGeometry.clampedLength(
            requestedLength: dragBaseLength,
            defaultLength: defaultLength,
            availableExtent: availableExtent,
            minimumLeading: minimumLeading,
            minimumTrailing: minimumTrailing,
            fixedPane: fixedPane,
            dividerThickness: dividerThickness
        ))
    }

    private func accessibilityLengthValue(availableExtent: CGFloat) -> String {
        let panes = ManagedSplitGeometry.paneLengths(
            requestedLength: length,
            defaultLength: defaultLength,
            availableExtent: availableExtent,
            minimumLeading: minimumLeading,
            minimumTrailing: minimumTrailing,
            fixedPane: fixedPane,
            dividerThickness: dividerThickness
        )
        let value = fixedPane == .leading ? panes.leading : panes.trailing
        return "\(Int(value.rounded())) 点"
    }
}

private struct ManagedResizeCursorModifier: ViewModifier {
    let axis: Axis
    @State private var cursorIsActive = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                updateCursor(isHovering: isHovering)
            }
            .onDisappear {
                if cursorIsActive {
                    NSCursor.pop()
                    cursorIsActive = false
                }
            }
            .onChange(of: axis) { _ in
                if cursorIsActive {
                    NSCursor.pop()
                    cursor.push()
                }
            }
    }

    private func updateCursor(isHovering: Bool) {
        if isHovering, !cursorIsActive {
            cursor.push()
            cursorIsActive = true
        } else if !isHovering, cursorIsActive {
            NSCursor.pop()
            cursorIsActive = false
        }
    }

    private var cursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }
}

private extension View {
    func managedResizeCursor(axis: Axis) -> some View {
        modifier(ManagedResizeCursorModifier(axis: axis))
    }
}
