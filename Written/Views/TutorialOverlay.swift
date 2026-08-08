import SwiftUI

/// The coach marks that run once, during onboarding, over the garden and the
/// dashboard.
///
/// **A dimmed screen with holes in it, and one sentence.** Everything except the
/// thing being pointed at is greyed; the thing itself keeps its own colour, so
/// the instruction has an object rather than a direction. Tapping anywhere
/// advances — anywhere, with no exceptions, because a coach mark that only
/// responds to one part of the screen is a coach mark somebody gets stuck on.
///
/// **It points, it does not gate.** The dim never swallows a control it is not
/// pointing at, because it is dismissed by the same tap that would have reached
/// one. Nothing here can strand a person mid-onboarding, which is the failure
/// this project has already paid for in other forms — an inert control, a
/// button that authenticated nobody, a card interrogating the wrong modality.
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
        /// The first icon in the row of connected sources.
        case connectedIcon
        /// The whole music card on the dashboard, artwork through to the bars.
        case musicCard
        /// One row inside it — the one the "long press to remove" mark points at.
        case secondEntry
        /// The circle-and-cross that adds something the phone could not see.
        case addPlaceholder
    }

    /// The sequence, in order. Each case carries its own sentence, because copy
    /// that lives beside the thing it describes is copy that gets changed with
    /// it.
    enum Step: Int, CaseIterable, Comparable {
        case firstConnection
        case updateConnection
        case moreConnections
        case reviewMusic
        case removeEntry
        case addMissing

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        var text: String {
            switch self {
            case .firstConnection:  return "Click here to make your first connection."
            case .updateConnection: return "Tap the icon or the button to update your connection."
            case .moreConnections:  return "More connections help us learn more about you."
            case .reviewMusic:      return "Review what we found! Scroll to see the entire list."
            case .removeEntry:      return "Long press on entry to remove."
            case .addMissing:       return "Tap here to add what we missed!"
            }
        }

        /// What stays in colour. More than one for the step that says "the icon
        /// **or** the button" — a sentence naming two things has to show both.
        var targets: [Target] {
            switch self {
            case .firstConnection:  return [.promptCard]
            case .updateConnection: return [.connectedIcon, .promptCard]
            case .moreConnections:  return [.promptCard]
            case .reviewMusic:      return [.musicCard]
            case .removeEntry:      return [.secondEntry]
            case .addMissing:       return [.addPlaceholder]
            }
        }

        /// Which screen it belongs to, so the garden does not draw a dashboard
        /// step behind a page that is not on screen.
        var isGarden: Bool { self <= .moreConnections }
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
        static func clear() { completed = nil }
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

/// The dim, the holes, the sentence, and the tap that advances.
struct TutorialOverlay: View {
    let step: Tutorial.Step
    let anchors: [Tutorial.Target: Anchor<CGRect>]
    let geometry: GeometryProxy
    let advance: () -> Void

    /// Dark enough that the lit thing is obviously the subject, light enough
    /// that the rest of the page is still legible — somebody has to be able to
    /// see what they are being pointed *away* from to understand the pointing.
    private static let dim: Double = 0.55

    /// The lit rectangle is grown a little so the thing inside it is not
    /// touching the edge of its own hole.
    private static let padding: CGFloat = 8
    private static let cornerRadius: CGFloat = 16

    private var holes: [CGRect] {
        step.targets.compactMap { anchors[$0] }.map { anchor in
            geometry[anchor].insetBy(dx: -Self.padding, dy: -Self.padding)
        }
    }

    var body: some View {
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
                            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                                .fill(.black)
                                .frame(width: hole.width, height: hole.height)
                                .position(x: hole.midX, y: hole.midY)
                                // Punches through rather than painting over.
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }
        // **Anywhere, with no exceptions.** The whole overlay takes the tap,
        // including over the lit hole: a person pointed at a button will press
        // the button, and that press has to do something rather than fall into
        // the gap between the mark and the control.
        .contentShape(Rectangle())
        .onTapGesture(perform: advance)
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.text)
        .accessibilityHint("Tap anywhere to continue")
        .accessibilityAddTraits(.isButton)
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
                    // **A ground of its own, not just a shadow.** The sentence
                    // lands wherever the screen's top happens to be — over the
                    // "Grow your profile" title on the garden, over the pinned
                    // header on the dashboard — and white-on-dim is legible
                    // against parchment but not against everything. Its own
                    // panel makes the contrast a property of the mark rather
                    // than of the page underneath it.
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}
