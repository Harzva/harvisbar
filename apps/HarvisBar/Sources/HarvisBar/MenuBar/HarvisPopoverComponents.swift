import AppKit
import Foundation
import SwiftUI

extension HarvisPopoverView {
    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(8)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
    }

    func compactPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.text)
            content()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line.opacity(0.86)))
    }

    func compactSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
    }

    func compactMetric(_ title: String, _ value: Int?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text("\(value ?? 0)")
                .font(.caption.bold())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(theme.surfaceAlt.opacity(0.80))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.65)))
    }

    func inlineMetric(_ title: String, _ value: Int?) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundColor(theme.muted)
            Text("\(value ?? 0)")
                .font(.caption2.bold())
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.surfaceAlt.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.56)))
    }

    func messageBox(title: String, message: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(color)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(8)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.35)))
    }
}
