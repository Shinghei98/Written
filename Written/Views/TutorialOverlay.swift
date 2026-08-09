import SwiftUI

/// The coach marks that run once, during onboarding, over the garden and the
/// dashboard.
///
/// **A dimmed screen with holes in it, and one sentence.** Everything except the
/// thing being pointed at is greyed; the thing itself keeps its own colour, so
/// the instruction has an object rather than a direction.
///
/// **It gates.** A step ends when the control it points at is *used* — the first
/// source connected, the picker opened, the entry long-pressed — and a tap
/// anywhere else does nothing at all. So the lit area stays live and everything
/// around it is inert, which is the opposite of the first version: that one
/// advanced on any tap, and somebody could read all six marks in six taps
/// without doing a single thing they described.
///
/// **Nothing here can strand somebody**, which is the risk a gate introduces
/// and the failure this project has paid for in other forms — an inert control,
/// a button that authenticated nobody. The lit control is always the real one,
/// never a copy, and it always does what it would have done with no tutorial
/// running; and a step whose target is not on screen draws nothing at all —
/// neither a dim nor a sentence — because a mark with no hole in it is a grey
/// page somebody cannot get out of. That last one was a claim in this comment
/// before it was true of the code: the blockers were empty, so taps passed
/// through, while the dim went on covering everything.
///
/// **Only during onboarding, and only once.** `isOnboarding` is the real gate:
/// it is false for everybody past the sequence, and the sequence runs once
/// because `Route` says so. `TutorialProgress` is the second line, so a person
/// who leaves the garden and comes back does not start again.
enum Tutorial {

    /// What a step points at. Views name themselves with `.tutorialTarget(_:)`
    /// and the overlay looks them up — a frame cannot be passed down from a
    /// parent that has not laid its children out yet.
    enum Target: String, Hashable {
        /// The card at the foot of the garden: "Ready to grow?" and its button.
        case promptCard
        /// The badge on the plant for the branch already connected. **This is
        /// "the icon"** in step two's sentence: `BadgeTap` calls `connect`, so
        /// it is a control and not decoration.
        case connectedBadge
        /// The row naming that branch, under the plant. "The button" — its
        /// `onTap` opens the same picker the badge does.
        case connectedBar

        /// **A circle for the badge, a rounded rectangle for everything else.**
        ///
        /// The badge is a circle inside square bounds, so a rounded rectangle
        /// lights its four corners as well — parchment around a coin. Every
        /// other target is a row or a card, which is a rectangle and is lit as
        /// one.
        ///
        /// Nothing here depends on the badge being frozen: its layout frame is
        /// the diameter whether it is bobbing or not, since the bob is an
        /// `.offset` and offsets do not move layout. The freeze matters because
        /// a moving badge leaves this window, not because it changes its size.
        var isRound: Bool { self == .connectedBadge }
    }

    /// The sequence, in order. Each case carries its own sentence, because copy
    /// that lives beside the thing it describes is copy that gets changed with
    /// it.
    enum Step: Int, CaseIterable, Comparable {
        case firstConnection
        case updateConnection
        case moreConnections

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        var text: String {
            switch self {
            case .firstConnection:  return "Click here to make your first connection."
            case .updateConnection: return "Tap the icon or the button to update your connection."
            case .moreConnections:  return "More connections help us learn more about you."
            }
        }

        /// What stays in colour.
        ///
        /// **`updateConnection` lights the connected bar alone**, not the prompt
        /// card beside it. "Update your connection" means the branch already
        /// made — the Events bar and the calendar mark on it — while the card
        /// underneath is offering Music, which is a *new* connection and the
        /// subject of the step after this one. Lighting both said "either of
        /// these" about two things that do opposite jobs.
        ///
        /// **Two targets, because the sentence names two things and they are
        /// in different places.** "The icon" is the badge on the plant and "the
        /// button" is the bar beneath it; both call `connect` for that branch,
        /// and lighting only the bar left somebody reading about an icon that
        /// was greyed out.
        var targets: [Target] {
            switch self {
            case .firstConnection:  return [.promptCard]
            case .updateConnection: return [.connectedBadge, .connectedBar]
            case .moreConnections:  return [.promptCard]
            }
        }


    }

    /// How far somebody got. Account-scoped, so signing into a second account on
    /// one phone starts fresh — the same rule every other local store here
    /// follows, and the reason `AccountScope` exists.
    ///
    /// **`UserDefaults` and no column, deliberately.** `0034` added columns for
    /// the onboarding facts because a reinstall re-ran onboarding without them,
    /// and that reasoning does not reach this: the tutorial only draws while
    /// `isOnboarding`, so on a restored account it cannot appear whatever this
    /// says. This exists to stop a repeat *within* a session, not across
    /// devices.
    enum Progress {
        private static var key: String { AccountScope.key("written-tutorial-step") }

        /// The last step somebody finished, or nil if they have seen none.
        static var completed: Step? {
            get {
                guard let raw = UserDefaults.standard.object(forKey: key) as? Int else { return nil }
                return Step(rawValue: raw)
            }
            set {
                guard let newValue else {
                    UserDefaults.standard.removeObject(forKey: key)
                    return
                }
                UserDefaults.standard.set(newValue.rawValue, forKey: key)
            }
        }

        /// True once this step has been shown and dismissed.
        static func hasSeen(_ step: Step) -> Bool {
            guard let completed else { return false }
            return completed >= step
        }

        static func complete(_ step: Step) {
            guard !hasSeen(step) else { return }
            completed = step
        }

        /// Signing out clears it with everything else — see `signOutLocalState`.
        static func clear() {
            completed = nil
            UserDefaults.standard.removeObject(forKey: memoriesKey)
        }

        // MARK: - The Memories tutorial

        /// Its own flag rather than a case in `Step`, because it is not a step:
        /// the garden's marks point at controls on a page somebody is using,
        /// and this is four pages of its own that run start to finish.
        private static var memoriesKey: String { AccountScope.key("written-tutorial-memories") }

        static var hasSeenMemories: Bool {
            UserDefaults.standard.bool(forKey: memoriesKey)
        }

        /// Recorded when somebody reaches the end, not when it opens. Closing
        /// the app halfway through should bring it back — it is four taps, and
        /// the alternative is a tutorial somebody never sees the point of.
        static func completeMemories() {
            UserDefaults.standard.set(true, forKey: memoriesKey)
        }
    }
}

// MARK: - Naming a target

/// Where the targets report their frames.
///
/// **An anchor rather than a rect**, because a rect is only meaningful in a
/// coordinate space and a child does not know the overlay's. `Anchor<CGRect>`
/// is resolved by whoever reads it, against their own geometry, which is
/// exactly the arrangement `DiscoveryCard` and `MessageBubble` use
/// `containerWidth` for by hand.
struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [Tutorial.Target: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [Tutorial.Target: Anchor<CGRect>],
        nextValue: () -> [Tutorial.Target: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Name this view so a tutorial step can point at it.
    ///
    /// Costs nothing when no tutorial is running: a preference is collected
    /// whether or not anybody reads it, and nothing else changes about the view.
    ///
    /// **Takes an optional so a `ForEach` can name one row and not the rest**,
    /// which is what the connected-sources bar needs — the step means the icon
    /// somebody just made, not the row it sits in.
    @ViewBuilder
    func tutorialTarget(_ target: Tutorial.Target?) -> some View {
        if let target {
            anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [target: $0] }
        } else {
            self
        }
    }
}

// MARK: - The overlay

/// The dim, the holes, and the bands that make everything but the lit control
/// inert.
struct TutorialOverlay: View {
    let step: Tutorial.Step
    let anchors: [Tutorial.Target: Anchor<CGRect>]
    let geometry: GeometryProxy
    let advance: () -> Void

    /// Dark enough that the lit thing is obviously the subject, light enough
    /// that the rest of the page is still legible — somebody has to be able to
    /// see what they are being pointed *away* from to understand the pointing.
    private static let dim: Double = 0.55

    /// The lit area is grown a little so the thing inside it is not touching
    /// the edge of its own hole.
    ///
    /// **Two figures, because 8 points means something different around a card
    /// than around a badge.** On a card it is a hairline of clearance. On a
    /// 48-point badge it is a third again of its width — a circle visibly
    /// larger than the thing in it, with a ring of parchment between, which
    /// reads as the mark having missed. Round targets take 3, which is enough
    /// to keep the badge's own gold ring off the edge and nothing more.
    private static let padding: CGFloat = 8
    private static let roundPadding: CGFloat = 3
    private static let cornerRadius: CGFloat = 16

    /// Each lit area, with the shape and the clearance its target asked for.
    private var holes: [(rect: CGRect, isRound: Bool)] {
        step.targets.compactMap { target in
            guard let anchor = anchors[target] else { return nil }
            let grow = target.isRound ? Self.roundPadding : Self.padding
            let rect = geometry[anchor].insetBy(dx: -grow, dy: -grow)
            return (rect, target.isRound)
        }
    }

    @ViewBuilder
    var body: some View {
        // **Nothing to light, nothing drawn.** A target that is off screen has
        // no anchor, so `holes` comes back empty — and an empty mask is a
        // *solid* dim, which is a grey page with no hole in it and no way to
        // reach whatever would end the step. Scroll the Memories marks' section
        // off the top and that is exactly what happened.
        //
        // The guarantee this buys is worth more than the case that prompted it:
        // a mark can only ever darken a screen that contains its subject. When
        // the target scrolls back, the mark comes back with it, which is right
        // — an instruction belongs beside the thing it describes.
        if holes.isEmpty {
            Color.clear
        } else {
            marked
        }
    }

    private var marked: some View {
        ZStack {
            // **The dim is one shape with holes punched in it**, not four
            // rectangles arranged around the subject. Four rectangles have to be
            // recomputed for every shape of hole and leave hairlines where they
            // meet; a mask does not.
            // **No `ignoresSafeArea` here, and that is the whole of why the
            // holes line up.** It expands the view's own frame, so the mask's
            // coordinate space stops being the one `geometry[anchor]` resolves
            // into — and every hole is punched out by the top inset, about 60
            // points above the thing it is meant to be lighting. The reader
            // ignores the safe area instead, in `tutorial(_:advance:)`, so the
            // rects and the mask share one space.
            Rectangle()
                .fill(Color.black.opacity(Self.dim))
                .mask {
                    ZStack {
                        Rectangle().fill(.white)
                        ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                            Group {
                                if hole.isRound {
                                    // **The shorter side, so it is a circle and
                                    // not an ellipse.** The badge's bounds are
                                    // square, so the two agree — but taking the
                                    // larger side would turn any rounding error
                                    // into a hole wider than the badge, and this
                                    // way an error can only ever make it tighter.
                                    Circle().fill(.black)
                                        .frame(width: min(hole.rect.width, hole.rect.height),
                                               height: min(hole.rect.width, hole.rect.height))
                                } else {
                                    RoundedRectangle(cornerRadius: Self.cornerRadius,
                                                     style: .continuous)
                                        .fill(.black)
                                        .frame(width: hole.rect.width, height: hole.rect.height)
                                }
                            }
                            .position(x: hole.rect.midX, y: hole.rect.midY)
                            // Punches through rather than painting over.
                            .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }
                // **The drawn dim never takes a touch.** Hit testing is done by
                // the blockers below, which leave the lit area alone — a mask
                // changes what is painted, not what is tappable, so without this
                // the dim would swallow the very control it is pointing at.
                .allowsHitTesting(false)

            // **Four bands around the lit area, and nothing over it.** The step
            // only completes when the real control is used, so the control has
            // to be reachable — and everything else has to not be, or somebody
            // wanders off mid-tutorial into a screen with a dimmed page and no
            // way back to the instruction.
            //
            // Bands rather than a shape with a hole in it: `contentShape` tests
            // a path with the non-zero rule, so a subtracted rectangle is not a
            // hole to it. Four rectangles are exact for one target, and for the
            // step that lights two they surround the union — which leaves the
            // gap between them tappable, and that gap is inside the same card.

            ForEach(Array(blockers.enumerated()), id: \.offset) { _, band in
                Color.clear
                    .frame(width: band.width, height: band.height)
                    // **Before `position`, and that ordering is the whole
                    // bug.** `position` reports the *parent's* bounds as the
                    // view's layout size, so a `contentShape` applied after it
                    // claims the entire screen — every band swallowed every
                    // tap, including the one over the lit button, and the
                    // tutorial could not be got past at all. Shaped first, then
                    // placed.
                    .contentShape(Rectangle())
                    // Absorbed, not forwarded. A tap outside the lit control is
                    // somebody trying the wrong thing, and the honest answer is
                    // that nothing happens.
                    .onTapGesture {}
                    .position(x: band.midX, y: band.midY)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.text)
        .accessibilityAddTraits(.isStaticText)
    }

    /// The screen minus the lit area, as four rectangles.
    ///
    /// Empty when nothing has been laid out yet, which is deliberate: a step
    /// whose target has no frame must not cover the screen in a blocker with no
    /// hole in it, because that is a page nobody can use and no instruction to
    /// explain why.
    private var blockers: [CGRect] {
        let lit = holes
        guard !lit.isEmpty else { return [] }

        // **Subtracted one hole at a time, not bounded by their union.**
        //
        // The union is only right when there is one lit thing. Step two lights
        // two — the badge beside the plant and the bar at the foot of the page
        // — and the union of those is most of the screen, so bands around it
        // would have left the whole middle live, including the card offering
        // Music that the step exists to keep dim.
        //
        // Splitting each remaining rectangle around each hole is exact for any
        // number of holes, and for one hole it produces the same four bands as
        // before.
        var rects = [CGRect(origin: .zero, size: geometry.size)]
        for hole in lit {
            // The rectangle either way. Hit testing a circle would leave the
            // corners of its bounding box inert, which is four small dead
            // zones on the one control the step wants pressed.
            rects = rects.flatMap { $0.subtracting(hole.rect) }
        }
        return rects.filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}

extension View {
    /// Host the tutorial over this screen.
    ///
    /// Reads the anchors its children published, so it goes on the container
    /// rather than on any one card. `overlayPreferenceValue` is what makes the
    /// order work: the children lay out, publish their bounds, and only then is
    /// the overlay built with real frames — a `GeometryReader` wrapped round the
    /// outside would have to guess.
    @ViewBuilder
    func tutorial(_ step: Tutorial.Step?, advance: @escaping () -> Void) -> some View {
        overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let step {
                    TutorialOverlay(
                        step: step,
                        anchors: anchors,
                        geometry: geometry,
                        advance: advance
                    )
                }
            }
            // **On the reader, not on the dim.** The overlay has to cover the
            // status bar and the home indicator, and this is the only place it
            // can be said without moving the coordinate space the holes are
            // measured in — see the note beside the mask.
            .ignoresSafeArea()
            // A step whose target has not been laid out yet would otherwise
            // dim the screen with no hole in it, which reads as the app having
            // frozen rather than as an instruction.
            .opacity(step == nil ? 0 : 1)
            .animation(.easeInOut(duration: 0.22), value: step)
        }
        // **The sentence is a second layer, and it has to be.** It belongs
        // inside the safe area, and the layer below deliberately ignores the
        // safe area so the mask shares a coordinate space with the anchors —
        // a reader that ignores it reports its insets as zero, which drew the
        // first version of this text underneath the Dynamic Island.
        //
        // `allowsHitTesting(false)` so a tap on the words still reaches the dim
        // beneath and advances: "anywhere" cannot have a hole in it where the
        // instruction is.
        .overlay(alignment: .top) {
            if let step {
                Text(step.text)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    // **No panel behind it.** The sentence belongs to the
                    // dimmed page rather than to a control sitting on top of
                    // it, and a filled box reads as a thing to dismiss. The
                    // shadow is what keeps it legible wherever the top of the
                    // screen happens to be.
                    .shadow(color: .black.opacity(0.65), radius: 10, y: 2)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}

extension CGRect {
    /// This rectangle with `hole` taken out of it, as up to four pieces.
    ///
    /// Used by the tutorial's blockers, which have to be everything the screen
    /// is *except* the lit controls. Returns `[self]` when the two do not
    /// overlap, so subtracting a hole that is somewhere else costs nothing.
    func subtracting(_ hole: CGRect) -> [CGRect] {
        guard intersects(hole) else { return [self] }
        let cut = intersection(hole)
        var pieces: [CGRect] = []
        if cut.minY > minY {
            pieces.append(CGRect(x: minX, y: minY, width: width, height: cut.minY - minY))
        }
        if cut.maxY < maxY {
            pieces.append(CGRect(x: minX, y: cut.maxY, width: width, height: maxY - cut.maxY))
        }
        if cut.minX > minX {
            pieces.append(CGRect(x: minX, y: cut.minY, width: cut.minX - minX, height: cut.height))
        }
        if cut.maxX < maxX {
            pieces.append(CGRect(x: cut.maxX, y: cut.minY, width: maxX - cut.maxX, height: cut.height))
        }
        return pieces
    }
}

extension View {

}
