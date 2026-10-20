import SwiftUI

enum HarvisHoverNotePlacement {
    case belowTrailing
    case aboveLeading
    case aboveCenter
    case aboveTrailing

    var alignment: Alignment {
        switch self {
        case .belowTrailing, .aboveTrailing:
            return .topTrailing
        case .aboveLeading:
            return .topLeading
        case .aboveCenter:
            return .top
        }
    }

    var verticalOffset: CGFloat {
        switch self {
        case .belowTrailing:
            return 36
        case .aboveLeading, .aboveCenter, .aboveTrailing:
            return -38
        }
    }
}

private struct HarvisHoverNoteModifier: ViewModifier {
    let text: String
    let placement: HarvisHoverNotePlacement
    @State private var isPointerInside = false
    @State private var isPresented = false
    @State private var hoverSequence = 0

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isPointerInside = hovering
                hoverSequence += 1
                let sequence = hoverSequence
                if hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        guard isPointerInside, hoverSequence == sequence else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            isPresented = true
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isPresented = false
                    }
                }
            }
            .overlay(alignment: placement.alignment) {
                if isPresented {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                        .offset(y: placement.verticalOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(isPresented ? 1000 : 0)
    }
}

extension View {
    func harvisHoverNote(
        _ text: String,
        placement: HarvisHoverNotePlacement = .belowTrailing
    ) -> some View {
        modifier(HarvisHoverNoteModifier(text: text, placement: placement))
    }
}
