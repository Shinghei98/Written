import SwiftUI

/// Where the app is, and how to go somewhere else.
///
/// Five tabs, in the order they sit on the bar. Only Explore and Distill are
/// built; the other three are named here rather than added later so the bar's
/// geometry, the blob's travel and the drag arithmetic are right from the
/// start — a bar that grows from three icons to five moves every one of them.
enum MainTab: Int, CaseIterable, Identifiable {
    case explore
    case wish
    case chat
    case distill
    case settings

    var id: Int { rawValue }

    /// SF Symbols, with one compromise.
    ///
    /// **There is no ship-in-a-bottle symbol.** `sailboat` stands in for Wish
    /// until there is custom artwork; it is the only icon here that is not the
    /// thing it means, and it should be replaced rather than grown used to.
    var icon: String {
        switch self {
        case .explore:  return "book"
        case .wish:     return "sailboat"
        case .chat:     return "paperplane"
        case .distill:  return "tree"
        case .settings: return "gearshape"
        }
    }

    var label: String {
        switch self {
        case .explore:  return "Explore"
        case .wish:     return "Wish"
        case .chat:     return "Chat"
        case .distill:  return "Your garden"
        case .settings: return "Settings"
        }
    }
}

/// The floating bar: a dark pill, five icons, and a lighter blob behind the one
/// you are on.
///
/// **It overlays; it never insets.** The garden below it is measured against
/// `promptsReserve`, and anything that consumes layout height at the bottom of
/// the screen changes that measurement and moves the plant — a regression this
/// project has paid for three times. Callers place it in an overlay and add
/// `overlayHeight` of padding to their own content instead.
struct MainTabBar: View {
    @Binding var selection: MainTab
    /// Hidden while another gesture owns the bottom of the screen. The garden's
    /// pull-up starts exactly where this sits, and two things reacting to one
    /// drag is worse than one of them being briefly absent.
    var isHidden = false

    /// What a page should keep clear at its bottom edge.
    static let overlayHeight: CGFloat = 86

    private static let barHeight: CGFloat = 58
    private static let iconSize: CGFloat = 21

    @State private var dragBlob: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let slot = geometry.size.width / CGFloat(MainTab.allCases.count)

            ZStack(alignment: .leading) {
                Capsule().fill(GardenPalette.ink)

                // The blob, positioned by the selection and nudged by a drag in
                // progress so it follows the finger rather than jumping when the
                // finger lets go.
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: slot * 0.86, height: Self.barHeight - 12)
                    .offset(x: slot * CGFloat(selection.rawValue) + slot * 0.07 + dragBlob)

                HStack(spacing: 0) {
                    ForEach(MainTab.allCases) { tab in
                        Button {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                selection = tab
                            }
                        } label: {
                            Image(systemName: tab.icon)
                                .font(.system(size: Self.iconSize, weight: .regular))
                                .foregroundColor(
                                    tab == selection ? .white : .white.opacity(0.55)
                                )
                                .frame(width: slot, height: Self.barHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.label)
                    }
                }
            }
            .frame(height: Self.barHeight)
            .gesture(
                // Dragging the blob itself. Global space, for the same reason
                // the garden's pull-up needs it: a gesture whose own view moves
                // in response to it measures its translation against a moving
                // frame and oscillates.
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        let limit = slot * CGFloat(MainTab.allCases.count - 1)
                        let origin = slot * CGFloat(selection.rawValue)
                        dragBlob = min(limit - origin, max(-origin, value.translation.width))
                    }
                    .onEnded { _ in
                        let landed = (slot * CGFloat(selection.rawValue) + dragBlob + slot / 2) / slot
                        let clamped = min(MainTab.allCases.count - 1, max(0, Int(landed)))
                        dragBlob = 0
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            selection = MainTab(rawValue: clamped) ?? selection
                        }
                    }
            )
        }
        .frame(height: Self.barHeight)
        .padding(.horizontal, 22)
        .opacity(isHidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .allowsHitTesting(!isHidden)
    }
}
