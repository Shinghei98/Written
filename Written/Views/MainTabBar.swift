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

    /// The symbol name, for the two tabs that have one.
    ///
    /// Wish and Distill are drawn instead — see `image(size:)`. SF Symbols has
    /// no message-in-a-bottle and no potted plant on the version this project
    /// ships to, and `sailboat` and `tree` were each standing in for a thing
    /// they were not.
    var icon: String {
        switch self {
        case .explore:   return "book"
        case .wish:      return "sailboat"
        case .chat:      return "paperplane"
        case .distill:   return "tree"
        case .dashboard: return "square.grid.2x2"
        }
    }

    /// What the bar actually draws.
    ///
    /// The two hand-drawn ones are stroked at the same weight as the symbols
    /// beside them, so a row of five reads as one set rather than as three
    /// icons and two illustrations.
    @ViewBuilder
    func image(size: CGFloat) -> some View {
        switch self {
        case .wish:
            BottleIcon()
                .stroke(style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        case .distill:
            PottedPlantIcon()
                .stroke(style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        default:
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
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

    /// The gap under the bar, which `AppShell` applies. Exposed so the
    /// clearance below is derived from it rather than guessed alongside it.
    static let bottomInset: CGFloat = 6

    private static let barHeight: CGFloat = 58

    /// What a page should keep clear at its bottom edge.
    ///
    /// The bar's actual footprint, not a round number near it. At a hardcoded 86
    /// it reserved 22 points more than the bar occupies, which on the garden was
    /// 22 points of empty parchment the connected rows could have had. Derived,
    /// it cannot drift from the thing it is clearing.
    static var overlayHeight: CGFloat { barHeight + bottomInset }
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
                        tab.image(size: Self.iconSize)
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


/// A bottle with a note in it — the Wish tab.
///
/// Drawn rather than named: SF Symbols has no message-in-a-bottle, and
/// `sailboat` was standing in for a boat rather than for what the tab is about.
/// Laid out in a unit square and scaled, so it holds its proportions at any
/// size the bar might use.
struct BottleIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()

        // The cork, sitting proud of the neck.
        path.move(to: p(0.42, 0.09))
        path.addLine(to: p(0.58, 0.09))
        path.addLine(to: p(0.58, 0.17))
        path.addLine(to: p(0.42, 0.17))
        path.closeSubpath()

        // Neck, shoulders, body. The shoulders are where a bottle stops being a
        // tube, so they get the curve and everything else stays straight.
        path.move(to: p(0.44, 0.17))
        path.addLine(to: p(0.44, 0.33))
        path.addQuadCurve(to: p(0.27, 0.53), control: p(0.27, 0.38))
        path.addLine(to: p(0.27, 0.85))
        path.addQuadCurve(to: p(0.36, 0.94), control: p(0.27, 0.94))
        path.addLine(to: p(0.64, 0.94))
        path.addQuadCurve(to: p(0.73, 0.85), control: p(0.73, 0.94))
        path.addLine(to: p(0.73, 0.53))
        path.addQuadCurve(to: p(0.56, 0.33), control: p(0.73, 0.38))
        path.addLine(to: p(0.56, 0.17))
        path.closeSubpath()

        // The note, rolled up inside. Two short strokes rather than a scroll:
        // at this size anything more becomes a smudge.
        path.move(to: p(0.38, 0.68))
        path.addLine(to: p(0.62, 0.68))
        path.move(to: p(0.38, 0.79))
        path.addLine(to: p(0.56, 0.79))

        return path
    }
}

/// A seedling in a pot — the Distill tab.
///
/// `tree` was the old symbol and it was wrong twice over: the plant on that
/// screen is a seedling rather than a tree, and it is grown in a pot by the
/// person looking at it.
struct PottedPlantIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()

        // The pot: a trapezoid narrowing toward the base, with its rim drawn
        // across rather than as a separate lip — one stroke reads cleaner at
        // twenty-one points than two parallel ones.
        path.move(to: p(0.22, 0.60))
        path.addLine(to: p(0.78, 0.60))
        path.addLine(to: p(0.68, 0.95))
        path.addLine(to: p(0.32, 0.95))
        path.closeSubpath()
        path.move(to: p(0.25, 0.70))
        path.addLine(to: p(0.75, 0.70))

        // The stem, and a leaf either side at different heights — level leaves
        // read as a symbol of a plant, staggered ones as a plant.
        path.move(to: p(0.50, 0.60))
        path.addLine(to: p(0.50, 0.22))

        path.move(to: p(0.50, 0.34))
        path.addQuadCurve(to: p(0.24, 0.30), control: p(0.34, 0.16))
        path.addQuadCurve(to: p(0.50, 0.34), control: p(0.31, 0.40))

        path.move(to: p(0.50, 0.46))
        path.addQuadCurve(to: p(0.76, 0.43), control: p(0.67, 0.29))
        path.addQuadCurve(to: p(0.50, 0.46), control: p(0.68, 0.52))

        return path
    }
}
