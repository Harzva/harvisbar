import Foundation
import SwiftUI

/// The pane which keeps the length supplied to `ManagedResizableSplitView`.
///
/// A leading pane keeps the length measured from the leading edge of the
/// split. A trailing pane keeps the same length measured from the trailing
/// edge. The enum is deliberately independent of the orientation so the same
/// preference can be used by horizontal and vertical workbench layouts.
enum ManagedSplitFixedPane: String, CaseIterable, Identifiable {
    case leading
    case trailing

    var id: String { rawValue }
}

/// Shared persistence keys and defaults for the managed workspace shell.
///
/// Owners pass these values to `@AppStorage` at the composition boundary. The
/// resizable split view itself owns only the transient drag state and never
/// writes preferences while a window is being resized.
enum ManagedWorkspaceLayout {
    static let railWidthKey = "harvis.codex.chatManager.railWidth"
    static let workbenchWidthKey = "harvis.codex.chatManager.workbenchWidth"
    static let workbenchHeightKey = "harvis.codex.chatManager.workbenchHeight"
    static let workbenchPlacementKey = "harvis.codex.chatManager.workbenchPlacement"

    static let defaultRailWidth: Double = 224
    static let defaultWorkbenchWidth: Double = 460
    static let defaultWorkbenchHeight: Double = 300
    static let defaultWorkbenchPlacement = ManagedWorkbenchPlacement.automatic
}

/// The two placements supported by the managed workbench.
enum ManagedWorkbenchPlacement: String, CaseIterable, Identifiable {
    case automatic
    case right
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .right: return "右侧"
        case .bottom: return "底部"
        }
    }
}

/// Pure geometry used by the resizable split view and its tests.
///
/// `availableExtent` is the full width or height offered by the parent. The
/// handle thickness is removed before applying pane minimums. When a window
/// is too narrow to satisfy both minimums, the model proportionally allocates
/// the available pane extent from those minimums and still guarantees finite,
/// non-negative lengths.
struct ManagedSplitGeometry {
    /// The total hit target for the divider. It is intentionally large enough
    /// to be usable without making the visible rule look heavy.
    static let defaultDividerThickness: CGFloat = 12

    /// Selects the dimension used by a horizontal or vertical split.
    static func availableExtent(for axis: Axis, in size: CGSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    /// Returns the space available to the two panes after the divider.
    static func paneExtent(
        availableExtent: CGFloat,
        dividerThickness: CGFloat = defaultDividerThickness
    ) -> CGFloat {
        guard availableExtent.isFinite else { return 0 }
        let safeExtent = max(0, availableExtent)
        let safeDivider = finiteNonNegative(dividerThickness)
        return max(0, safeExtent - safeDivider)
    }

    /// Clamps a requested fixed-pane length to the available pane space.
    ///
    /// The non-labelled overload is convenient for call sites where the
    /// requested value is already named `length` in the surrounding view.
    static func clampedLength(
        _ length: Double,
        availableExtent: CGFloat,
        minimumLeading: CGFloat,
        minimumTrailing: CGFloat,
        fixedPane: ManagedSplitFixedPane,
        dividerThickness: CGFloat = defaultDividerThickness
    ) -> CGFloat {
        clampedLength(
            requestedLength: length,
            availableExtent: availableExtent,
            minimumLeading: minimumLeading,
            minimumTrailing: minimumTrailing,
            fixedPane: fixedPane,
            dividerThickness: dividerThickness
        )
    }

    /// Clamps a requested fixed-pane length to the available pane space.
    static func clampedLength(
        length: Double,
        availableExtent: CGFloat,
        minimumLeading: CGFloat,
        minimumTrailing: CGFloat,
        fixedPane: ManagedSplitFixedPane,
        dividerThickness: CGFloat = defaultDividerThickness
    ) -> CGFloat {
        clampedLength(
            requestedLength: length,
            availableExtent: availableExtent,
            minimumLeading: minimumLeading,
            minimumTrailing: minimumTrailing,
            fixedPane: fixedPane,
            dividerThickness: dividerThickness
        )
    }

    /// Clamps a requested fixed-pane length, using a fallback for an invalid
    /// persisted value without writing that fallback back to the preference.
    static func clampedLength(
        requestedLength: Double,
        defaultLength: Double = 0,
        availableExtent: CGFloat,
        minimumLeading: CGFloat,
        minimumTrailing: CGFloat,
        fixedPane: ManagedSplitFixedPane,
        dividerThickness: CGFloat = defaultDividerThickness
    ) -> CGFloat {
        let panes = paneExtent(
            availableExtent: availableExtent,
            dividerThickness: dividerThickness
        )
        guard panes > 0 else { return 0 }

        let leadingMinimum = finiteNonNegative(minimumLeading)
        let trailingMinimum = finiteNonNegative(minimumTrailing)
        let requested = finite(requestedLength)
            ? CGFloat(requestedLength)
            : (finite(defaultLength) ? CGFloat(defaultLength) : 0)
        let safeRequested = requested.isFinite ? requested : 0

        let fixedMinimum: CGFloat
        let otherMinimum: CGFloat
        switch fixedPane {
        case .leading:
            fixedMinimum = leadingMinimum
            otherMinimum = trailingMinimum
        case .trailing:
            fixedMinimum = trailingMinimum
            otherMinimum = leadingMinimum
        }

        // In the usual case both pane minimums fit. This keeps the split
        // stable while a temporary window resize changes the visible value.
        if fixedMinimum + otherMinimum <= panes {
            let lowerBound = min(fixedMinimum, panes)
            let upperBound = max(lowerBound, panes - otherMinimum)
            return min(max(safeRequested, lowerBound), upperBound)
        }

        // A very narrow window cannot satisfy both minimums. Preserve their
        // relative priority while guaranteeing that neither pane receives a
        // negative or non-finite dimension.
        let minimumTotal = fixedMinimum + otherMinimum
        guard minimumTotal > 0, minimumTotal.isFinite else {
            return min(max(safeRequested, 0), panes)
        }
        let proportionalFallback = panes * fixedMinimum / minimumTotal
        return min(max(proportionalFallback, 0), panes)
    }

    /// Computes both visible pane lengths for a full parent extent.
    static func paneLengths(
        requestedLength: Double,
        defaultLength: Double = 0,
        availableExtent: CGFloat,
        minimumLeading: CGFloat,
        minimumTrailing: CGFloat,
        fixedPane: ManagedSplitFixedPane,
        dividerThickness: CGFloat = defaultDividerThickness
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let panes = paneExtent(
            availableExtent: availableExtent,
            dividerThickness: dividerThickness
        )
        let fixedLength = clampedLength(
            requestedLength: requestedLength,
            defaultLength: defaultLength,
            availableExtent: availableExtent,
            minimumLeading: minimumLeading,
            minimumTrailing: minimumTrailing,
            fixedPane: fixedPane,
            dividerThickness: dividerThickness
        )
        switch fixedPane {
        case .leading:
            return (fixedLength, max(0, panes - fixedLength))
        case .trailing:
            return (max(0, panes - fixedLength), fixedLength)
        }
    }

    private static func finite(_ value: Double) -> Bool {
        value.isFinite
    }

    private static func finiteNonNegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}

/// Descriptive alias for callers that want to name the model after the view.
typealias ManagedResizableSplitGeometry = ManagedSplitGeometry
