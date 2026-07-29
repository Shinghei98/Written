import SwiftUI

/// Where the app is, and how to go somewhere else.
///
/// Five tabs, in the order they sit on the bar. Explore, Distill and Dashboard
/// are built; Wish and Chat are named here rather than added later so the bar's
/// geometry and the blob's travel are right from the start — a bar that grows
/// from three icons to five moves every one of them.
enum MainTab: Int, CaseIterable, Identifiable {
    case explore
    case wish
    case chat
    case distill
    case dashboard

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
        case .distill:   return "tree"
        case .dashboard: return "square.grid.2x2"
        }
    }

    var label: String {
        switch self {
        case .explore:  return "Explore"
        case .wish:     return "Wish"
        case .chat:     return "Chat"
        case .distill:   return "Your garden"
        case .dashboard: return "Dashboard"
        }
    }
}

/// The floating bar: a near-transparent pill, five icons, and a blob behind the
/// one you are on that can be tapped to or slid to.
///
/// **It overlays; it never insets.** The garden below it is measured against
/// `promptsReserve`, and anything that consumes layout height at the bottom of
/// the screen changes that measurement and moves the plant — a regression this
/// project has paid for three times. Callers place it in an overlay and add
/// `overlayHeight` of padding to their own content instead.
struct MainTabBar: View {
    @Binding var selection: MainTab
    /// Hidden while another gesture owns the bottom of the screen.
    var isHidden = false

    /// What a page should keep clear at its bottom edge.
    static let overlayHeight: CGFloat = 86

    private static let barHeight: CGFloat = 58
    private static let iconSize: CGFloat = 21

    /// Where the blob is while a finger is on it, in slots. Nil between
    /// gestures, when the selection alone decides.
    @State private var dragSlot: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let slot = geometry.size.width / CGFloat(MainTab.allCases.count)
            let at = dragSlot ?? CGFloat(selection.rawValue)

            ZStack(alignment: .leading) {
                // Barely there. The garden is the screen's subject and the bar
                // is chrome over it, so it tints what is behind rather than
                // covering it — a solid pill cut the plant off at the ankles.
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(GardenPalette.ink.opacity(0.18)))
                    .overlay(Capsule().strokeBorder(GardenPalette.ink.opacity(0.10), lineWidth: 0.5))

                Capsule()
                    .fill(GardenPalette.ink.opacity(0.20))
                    .frame(width: slot * 0.86, height: Self.barHeight - 12)
                    .offset(x: slot * at + slot * 0.07)

                HStack(spacing: 0) {
                    ForEach(MainTab.allCases) { tab in
                        Image(systemName: tab.icon)
                            .font(.system(size: Self.iconSize, weight: .regular))
                            .foregroundColor(
                                tab == selection ? GardenPalette.ink : GardenPalette.ink.opacity(0.42)
                            )
                            .frame(width: slot, height: Self.barHeight)
                            .accessibilityLabel(tab.label)
                    }
                }
                // Nothing inside the bar takes touches. The icons were `Button`s
                // and each filled its whole slot, so every drag that began on
                // one — which is every drag anybody would make — went to the
                // button and the blob could not be slid at all.
                .allowsHitTesting(false)
            }
            .frame(height: Self.barHeight)
            .contentShape(Capsule())
            // One gesture for both. A tap is a drag that went nowhere, so
            // separating them means deciding which fires first; measuring the
            // distance at the end decides it after the fact instead.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let raw = value.location.x / slot - 0.5
                        dragSlot = min(CGFloat(MainTab.allCases.count - 1), max(0, raw))
                    }
                    .onEnded { value in
                        // Where the finger is, tap or slide alike — a tap is
                        // just a slide that went nowhere, and both mean "this
                        // slot". No need to tell them apart.
                        let index = min(MainTab.allCases.count - 1,
                                        max(0, Int(value.location.x / slot)))
                        dragSlot = nil
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            selection = MainTab(rawValue: index) ?? selection
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
