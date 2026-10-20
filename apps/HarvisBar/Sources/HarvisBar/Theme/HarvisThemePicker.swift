import SwiftUI

/// A compact native menu for switching semantic Harvis themes.
///
/// The picker deliberately binds to the persisted raw ID used by
/// `HarvisRuntimeModel`, so it can be placed in any toolbar or header without
/// introducing a second selection state.
struct HarvisThemePicker: View {
    @Binding private var selection: String

    let theme: HarvisTheme
    let label: String

    init(
        selection: Binding<String>,
        theme: HarvisTheme,
        label: String = "主题"
    ) {
        self._selection = selection
        self.theme = theme
        self.label = label
    }

    private var selectedTheme: HarvisTheme {
        HarvisTheme(rawValue: selection) ?? theme
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(HarvisTheme.allCases) { item in
                HStack(spacing: 7) {
                    Circle()
                        .fill(item.accent)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(item.title)
                }
                .tag(item.rawValue)
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selectedTheme.accent)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(label)
                    .harvisFont(.system(size: 12))
            }
        }
        .pickerStyle(.menu)
        .harvisFont(.system(size: 12))
        .fixedSize()
        .foregroundColor(theme.text)
        .tint(theme.accent)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(selectedTheme.title))
        .accessibilityIdentifier("harvis.theme-picker")
        .help("选择界面主题")
    }
}
