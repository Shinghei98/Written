import SwiftUI

/// The Chat tab: who likes you, and who you are talking to.
///
/// Two lists on one screen, and the order is the argument. The admirers banner is
/// pinned because it is the thing that arrived while you were away — a count that
/// scrolled off the top would be a notification you could miss by reading. The
/// conversations underneath are what you came for once you have seen it.
///
/// Layout follows `DashboardView`: content inset by the header's height and
/// sliding *under* it, rather than a `safeAreaInset`, which would take layout
/// height and is the regression `MainTabBar` documents four times over.
struct ChatView: View {
    /// Only for the ban list — unmatching somebody is the same kind of act as
    /// striking an artist off, and travels the same way.
    @ObservedObject var viewModel: DistillViewModel

    /// Whether this tab is the one on screen. `AppShell` keeps every tab mounted,
    /// so `.task` fires once at launch and never again — this is what makes
    /// arriving at the tab reload it.
    var isVisible = false

    /// Raised while a conversation is pushed, so `AppShell` can take the tab bar
    /// away — it draws over every page, and the compose field is at the bottom of
    /// this one.
    @Binding var hidesTabBar: Bool

    @StateObject private var model = ChatModel()

    @State private var isShowingAdmirers = false
    /// The pushed thread. Two pieces of state rather than one, because
    /// `navigationDestination(item:)` is iOS 17 and this app targets 16 — the
    /// `isPresented` form is what the rest of the project uses.
    @State private var openThread: ChatService.Conversation?
    @State private var isShowingThread = false

    /// Which row is swiped open. One at a time, so the list never has two sets
    /// of red buttons showing.
    @State private var openRowID: String?
    /// The person a confirm alert or the report sheet is about.
    @State private var pendingUnmatch: ChatService.Conversation?
    @State private var pendingReport: ChatService.Conversation?
    @State private var isReporting = false

    /// Where a tapped notification wants to go. `AppShell` brings the tab here;
    /// this opens the page within it.
    @ObservedObject private var notifications = NotificationRouter.shared

    /// Says so when a tapped notification could not be honoured.
    ///
    /// **Only on failure.** It reported every route while the tap handling was
    /// being built — which is how the real cause was found in one attempt after
    /// three wrong guesses, since a cold-launch tap *is* the launch and no
    /// console can be attached to watch it — and then had to be quietened,
    /// because a banner on every successful tap reads to a tester as an error.
    ///
    /// What survives is the case worth saying out loud: somebody tapped and did
    /// not arrive. That looks exactly like the tap having missed, and nothing
    /// else in the app would ever mention it.
    @State private var routeTrail: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                GardenPalette.parchment.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        // **`hasLoaded`, not just `isEmpty`.** The list is empty
                        // for the first moment of every visit, so keying the
                        // empty state on emptiness alone made a working chat
                        // announce "No conversations yet" and then replace it —
                        // which is what read as the chat disappearing. Nothing
                        // is drawn until there is something true to say.
                        if visibleConversations.isEmpty {
                            if model.hasLoaded { empty }
                        } else {
                            ForEach(visibleConversations) { conversation in
                                SwipeableConversationRow(
                                    conversation: conversation,
                                    openRowID: $openRowID,
                                    onTap: {
                                        openThread = conversation
                                        isShowingThread = true
                                    },
                                    onUnmatch: { pendingUnmatch = conversation },
                                    onReport: {
                                        pendingReport = conversation
                                        isReporting = true
                                    }
                                )
                            }
                        }
                    }
                    .padding(.top, headerHeight)
                    .padding(.bottom, MainTabBar.overlayHeight + 12)
                }

                header
                    .background(GardenPalette.parchment)
            }
            // Same defect as `DiscoveryView` had: the reason was recorded and
            // then drawn only where an empty list would have been, so a refused
            // load on an account *with* conversations said nothing at all.
            .statusBanner(BuildKind.showsDiagnostics && routeTrail != nil
                          ? routeTrail : model.failure)
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $isShowingAdmirers) {
                AdmirersView(
                    model: model,
                    onOpened: { conversation in
                        // Back out of the admirers list first, then push the
                        // thread. Pushing from underneath a page being popped
                        // leaves the stack with two destinations mid-animation and
                        // the second one arrives without its transition.
                        isShowingAdmirers = false
                        openThread = conversation
                        isShowingThread = true
                    }
                )
                .navigationBarHidden(true)
            }
            .navigationDestination(isPresented: $isShowingThread) {
                if let openThread {
                    ConversationView(conversation: openThread)
                        .navigationBarHidden(true)
                }
            }
            // **Confirmed, unlike Report.** Nothing in this schema is ever
            // deleted, so there is no undo to offer, and a swipe is easy to
            // start by accident on a list you scroll. Report confirms by way of
            // its own sheet — a form you have to write in and submit is not
            // something a stray thumb completes.
            .alert(
                "Unmatch \(pendingUnmatch?.partnerName ?? "them")?",
                isPresented: Binding(
                    get: { pendingUnmatch != nil },
                    set: { if !$0 { pendingUnmatch = nil } }
                ),
                presenting: pendingUnmatch
            ) { person in
                Button("Cancel", role: .cancel) { pendingUnmatch = nil }
                Button("Unmatch", role: .destructive) {
                    viewModel.banPerson(person.partnerID)
                    pendingUnmatch = nil
                }
            } message: { person in
                Text("\(person.partnerName) will be gone from Explore and from your chats. This can't be undone.")
            }
            .overlay {
                if isReporting, let person = pendingReport {
                    ReportSheet(
                        name: person.partnerName,
                        onSend: { text in
                            let id = person.partnerID
                            let name = person.partnerName
                            // **Blocked here, not on the server's answer.** The
                            // report is worth retrying; getting away from
                            // somebody is not something to make conditional on
                            // a network. If the insert fails the block still
                            // stands and the banner says the words did not
                            // arrive.
                            viewModel.banPerson(id)
                            isReporting = false
                            pendingReport = nil
                            Task {
                                let landed = await ChatService.shared.report(id, named: name, body: text)
                                guard !landed else { return }
                                await model.reportFailed(
                                    await ChatService.shared.lastError
                                        ?? "That report didn't send. They're still blocked."
                                )
                            }
                        },
                        onCancel: {
                            isReporting = false
                            pendingReport = nil
                        }
                    )
                }
            }
        }
        .preferredColorScheme(.light)
        .onChange(of: notifications.pending) { _ in openForNotification() }
        .task(id: isVisible) {
            guard isVisible else { return }
            await model.load()
            // **After the load, not before it.** A tap that launched the app
            // arrives while this list is still empty, so a conversation looked
            // up any earlier is never found. Running it here and again on
            // change covers both a cold launch and a tap while the app is open.
            openForNotification()
#if DEBUG
            // `-chat admirers` / `-chat thread`; see `DebugLaunch`. After the load,
            // so the pushed page has something in it.
            // `-memo` needs the thread open too, and says so itself rather than
            // making the caller remember to pass `-chat thread` alongside it.
            let target = DebugLaunch.chatTarget ?? (DebugLaunch.memoState != nil ? "thread" : nil)
            guard let target, DebugLaunch.firesOnce("chat") else { return }
            try? await Task.sleep(for: .seconds(DebugLaunch.chatPushDelay))
            switch target {
            case "admirers": isShowingAdmirers = true
            // `typing` opens the same page as `thread`; the difference is inside
            // `ConversationView`, which reads the flag itself.
            case "swiped":
                openRowID = model.conversations.first?.id
            case "report":
                pendingReport = model.conversations.first
                isReporting = pendingReport != nil
            case "thread", "typing":
                openThread = model.conversations.first
                isShowingThread = openThread != nil
            default: break
            }
#endif
        }
        // In `onChange` rather than derived in `body`: writing to a binding while a
        // view is being evaluated is what "Modifying state during view update"
        // means, and it is undefined behaviour rather than a warning to ignore.
        .onChange(of: isShowingThread) { isOpen in
            hidesTabBar = isOpen
            // On the way back, the last message and any reply that arrived while
            // the thread was open both belong in the list behind it.
            guard !isOpen else { return }
            Task { await model.load() }
        }
    }

    /// Conversations minus anybody blocked.
    ///
    /// Filtered on the way to the screen rather than out of `ChatModel`, because
    /// the server goes on returning the thread — the block is one-sided and only
    /// this device knows about it. Removing them from the model would mean
    /// re-filtering after every four-second poll and after every restore; doing
    /// it here means the ban list is the only thing that has to be right.
    /// Opens whichever page a tapped notification asked for.
    ///
    /// **Only when this tab is on screen**, because every tab stays mounted:
    /// without the guard, a tap would push a thread onto a navigation stack
    /// nobody is looking at, and it would be waiting there the next time
    /// somebody opened Chat.
    ///
    /// **A conversation that is not in the list yet is waited for, not given up
    /// on.** This is the whole difficulty, and `hasLoaded` is the wrong thing to
    /// test: it means *a load finished*, not *a load succeeded*. On a cold
    /// launch the tap arrives while `restoreSession` is still in flight,
    /// `ChatService.conversations()` answers `[]` for the refused request, and
    /// `hasLoaded` flips true regardless — so reading it as "the list is
    /// complete and your thread is not in it" dropped the destination and left
    /// somebody on an empty chat list. Which is exactly what it did.
    ///
    /// So it reloads and tries again, a few times, a second apart. `.task` fires
    /// only when `isVisible` changes, so nothing else would ever retry. Bounded
    /// because a thread really can be absent — unmatched, or belonging to
    /// another account — and the chat list is a reasonable place to leave
    /// somebody in that case.
    private func openForNotification(attempt: Int = 0) {
        guard isVisible, let destination = notifications.pending else {
            return
        }

        switch destination {
        case .chatList:
            break
        case .admirers:
            isShowingAdmirers = true
        case .conversation(let id):
            guard let thread = model.conversations.first(where: { $0.id == id }) else {
                guard attempt < 4 else {
                    // **Silent on success, and only here.** A trail drawn on
                    // every tap is noise a tester reads as an error — and this
                    // one shipped that way for exactly one round. What is worth
                    // saying is the case where somebody tapped a notification
                    // and did not arrive: it looks like the tap having missed,
                    // and nothing else in the app would ever mention it.
                    if BuildKind.showsDiagnostics {
                        routeTrail = "Couldn't open that conversation"
                            + " (\(model.conversations.count) loaded"
                            + (model.failure.map { ", \($0)" } ?? "") + ")"
                    }
                    notifications.pending = nil
                    return
                }
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await model.load()
                    openForNotification(attempt: attempt + 1)
                }
                return
            }
            // Admirers first, for the reason `AdmirersView.onOpened` gives:
            // pushing from underneath a page being popped leaves the stack with
            // two destinations mid-animation.
            isShowingAdmirers = false
            openThread = thread
            isShowingThread = true
        }
        notifications.pending = nil
    }

    private var visibleConversations: [ChatService.Conversation] {
        let blocked = viewModel.bans.keys(.person)
        guard !blocked.isEmpty else { return model.conversations }
        return model.conversations.filter { !blocked.contains($0.partnerID.lowercased()) }
    }

    /// The pinned block's height, a constant rather than a measurement.
    ///
    /// The content is inset by it, so measuring it would mean the list re-laying
    /// out every time the admirers row appeared or emptied — the same reason
    /// `DashboardView.expandedHeaderHeight` is a number.
    ///
    /// **Measured, though, not guessed.** Both numbers were 15pt smaller when
    /// the title was `BrandFont.title(34)`; taking it to 46 to match the garden
    /// moved the divider from y=532 to y=577 on a 3x screen, which is where the
    /// 15 comes from. Re-measure the same way if the title's size changes again
    /// — a constant that is only *nearly* right hides the first conversation
    /// under the header, and does it silently.
    private var headerHeight: CGFloat { model.admirers.isEmpty ? 89 : 147 }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat")
                // The same face *and* size as "Grow your profile" on the garden.
                // The top-level titles were set in three different type sizes
                // before — and in two different type systems, so one scaled with
                // Dynamic Type and the others did not. This is the size the
                // plant page uses, which is the one a reader arrives from.
                //
                // `headerHeight` below is measured against this. Changing it
                // without changing that number puts the first conversation under
                // the title.
                .font(BrandFont.title(46))
                .foregroundStyle(GardenPalette.ink)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

            if !model.admirers.isEmpty {
                Button { isShowingAdmirers = true } label: {
                    AdmirersBanner(admirers: model.admirers)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
            }

            Divider().opacity(0.35)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "paperplane")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(GardenPalette.gold)
            Text("No conversations yet")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)
            Text("When you and somebody both say yes, this is where it happens.")
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 44)
        .padding(.top, 60)
    }
}

// MARK: - The banner

/// "12 admirers" and up to five faces.
///
/// Capped at five with a "+" after, per the design. The cap is on what is *drawn*
/// — the count above it is the real number, so a sixth admirer is visible as a
/// number even though their face is not.
struct AdmirersBanner: View {
    let admirers: [LikeService.Admirer]

    private static let shown = 5
    private static let avatar: CGFloat = 38
    /// How much each face hides of the one before it. Enough to read as a group
    /// rather than a list, not enough to hide an initial.
    private static let overlap: CGFloat = 11

    var body: some View {
        HStack(spacing: 12) {
            Text("\(admirers.count) \(admirers.count == 1 ? "admirer" : "admirers")")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)

            HStack(spacing: -Self.overlap) {
                ForEach(Array(admirers.prefix(Self.shown).enumerated()), id: \.element.id) { index, admirer in
                    ProfilePhotoView(ref: admirer.photoRef, initial: admirer.name)
                        .frame(width: Self.avatar, height: Self.avatar)
                        .clipShape(Circle())
                        // A parchment ring, not a white one: these sit on the page
                        // rather than on a card, and white would outline each face
                        // against the background it is meant to be on.
                        .overlay { Circle().strokeBorder(GardenPalette.parchment, lineWidth: 2) }
                        // Explicit, and inverted against the stacking order a
                        // plain `HStack` gives. `admirers` is newest first, and
                        // later siblings draw on top — so without this the newest
                        // admirer is the one buried under the other four.
                        .zIndex(Double(Self.shown - index))
                }
            }

            if admirers.count > Self.shown {
                Text("+")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GardenPalette.gold)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GardenPalette.muted)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(admirers.count) admirers")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - A conversation row

/// A chat row you can swipe left to unmatch or report.
///
/// **Hand-rolled, because this list is a `LazyVStack` and not a `List`.**
/// `.swipeActions` is a `List` modifier and nothing else, and converting the
/// list would mean giving up the pinned admirers banner and the inset the
/// header depends on for a gesture.
///
/// The two buttons sit *beside* the row inside one `HStack` and travel with it,
/// rather than being fixed to the screen's trailing edge. That ordering is the
/// requirement rather than an implementation detail: anchored to the edge, the
/// rightmost button is uncovered first, which would reveal Report before
/// Unmatch. Carried along by the row, Unmatch clears the edge first and Report
/// follows it.
struct SwipeableConversationRow: View {

    let conversation: ChatService.Conversation
    /// Which row is open, shared across the list so only one ever is.
    @Binding var openRowID: String?
    var onTap: () -> Void
    var onUnmatch: () -> Void
    var onReport: () -> Void

    @State private var drag: CGFloat = 0

    private let actionWidth: CGFloat = 92
    private var revealed: CGFloat { actionWidth * 2 }
    private var isOpen: Bool { openRowID == conversation.id }
    /// Where the row sits: the drag while a finger is down, the open position
    /// otherwise. Clamped so it cannot be pulled past the buttons or to the
    /// right of home — there is nothing on that side.
    private var offset: CGFloat { min(0, max(-revealed, isOpen ? -revealed + drag : drag)) }

    var body: some View {
        HStack(spacing: 0) {
            // **Not a `Button`.** A button claims the touch, and a gesture on an
            // ancestor is resolved *after* a child's own — so wrapping the row
            // in one is what stopped the swipe registering at all. A tap gesture
            // on plain content competes with the drag on equal terms, and the
            // 15pt minimum below is what separates them.
            ConversationRow(conversation: conversation)
                .frame(width: rowWidth)
                .contentShape(Rectangle())
                .onTapGesture { isOpen ? close() : onTap() }

            action("Unmatch", fill: GardenPalette.badgeGold, ink: GardenPalette.ink) {
                close(); onUnmatch()
            }
            action("Report", fill: Self.reportRed, ink: .white) {
                close(); onReport()
            }
        }
        .offset(x: offset)
        // **A fixed width with a leading alignment, and both halves matter.**
        // The HStack is `rowWidth + 2 * actionWidth` wide, and a child wider
        // than its frame is *centred* by default — which drew the buttons on
        // screen with no swipe at all and pushed every name half off the left
        // edge. Pinned leading, the overflow is where it belongs: off the
        // trailing edge, waiting.
        .frame(width: rowWidth, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        // **`simultaneousGesture`, and it is the whole reason this works inside a
        // `ScrollView`.** An exclusive `.gesture` has to win the touch outright,
        // and the scroll view's pan is what it would have to win it from — so
        // either the list stops scrolling or the rows stop swiping, and which one
        // you get is not yours to choose.
        //
        // Running alongside it costs nothing here because **this scroll view has
        // one axis**. A vertical drag scrolls and is discarded below; a
        // horizontal one the scroll view ignores entirely, and only this reads
        // it. The two gestures never want the same drag.
        .simultaneousGesture(
            // **`.global`, as `GrowProfileView.revealDrag` documents.** A drag
            // measured in the local space of a view the drag is moving changes
            // the frame it is measured against, which changes the translation,
            // which moves the view again — on device that reads as the row
            // shaking under the finger.
            //
            // 15pt rather than 12: the same threshold has to be far enough that
            // a tap on the row is not read as a one-pixel swipe, since the tap
            // gesture above is now a peer rather than a button.
            DragGesture(minimumDistance: 15, coordinateSpace: .global)
                .onChanged { value in
                    // Horizontal only. Without this the list cannot be scrolled
                    // without rows sliding open under the thumb.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    drag = value.translation.width
                    if openRowID != nil, openRowID != conversation.id { openRowID = nil }
                }
                .onEnded { value in
                    // Where the finger was going, not where it stopped, so a
                    // flick and a slow drag settle the same way.
                    let projected = (isOpen ? -revealed : 0) + value.predictedEndTranslation.width
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        openRowID = projected < -revealed / 2 ? conversation.id : nil
                        drag = 0
                    }
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isOpen)
    }

    /// The row keeps the full width so the buttons start off screen.
    private var rowWidth: CGFloat { UIScreen.main.bounds.width }

    private static let reportRed = Color(red: 0.78, green: 0.24, blue: 0.20)

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { openRowID = nil }
    }

    private func action(
        _ title: String, fill: Color, ink: Color, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .background(fill)
        }
        .buttonStyle(.plain)
        // Unreachable until the row is open, or a tap near the edge of a closed
        // row would unmatch somebody.
        .allowsHitTesting(isOpen)
    }
}

struct ConversationRow: View {
    let conversation: ChatService.Conversation

    /// Whatever was said last, by either of you.
    ///
    /// Three states, and the middle one is why this stopped being one line of
    /// text. `last_message` is written by the trigger from the message body, and
    /// **a photo sent without a caption has an empty body** — so an image landed
    /// here as an empty string and the row simply looked blank.
    ///
    /// Empty-but-present is therefore read as "an attachment with nothing
    /// written on it". It is an inference rather than a fact the schema
    /// records — the conversation summary carries no attachment column — but it
    /// cannot be confused with the no-messages case, which is `nil`, and a photo
    /// *with* a caption correctly shows the caption.
    @ViewBuilder
    private var lastLine: some View {
        if let text = conversation.lastMessage {
            if conversation.lastMessageKind == "audio" {
                // The body of a voice memo *is* its duration, so the summary
                // already carries the number — it only needed saying what it is.
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                    Text("Voice message (\(VoiceBubble.compact(text)))")
                        .font(.system(size: 14))
                }
                .foregroundStyle(GardenPalette.muted)
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // **`video` used to draw here as "Photo".** The branch above
                // tests `audio` and everything else fell through to a camera,
                // so a clip sent without a caption named itself wrong — visible
                // only to somebody who sent one, which is why it lasted. The
                // kind is on the summary already; it just was not being asked.
                HStack(spacing: 4) {
                    Image(systemName: conversation.lastMessageKind == "video"
                          ? "video.fill" : "camera.fill")
                        .font(.system(size: 11))
                    Text(conversation.lastMessageKind == "video" ? "Video" : "Photo")
                        .font(.system(size: 14))
                }
                .foregroundStyle(GardenPalette.muted)
            } else {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.muted)
                    .lineLimit(1)
            }
        } else {
            // An accepted like with nothing written in it yet is the common case
            // on this screen, so it says so rather than showing a blank second
            // line that reads as a failed load.
            Text("Say something")
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.gold)
                .lineLimit(1)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // `ProfilePhotoView`, not `PortraitView`: the latter only ever
            // draws the generated placeholder, so everybody with a real
            // photograph appeared as an abstract one.
            ProfilePhotoView(ref: conversation.photoRef, initial: conversation.partnerName)
                .frame(width: 54, height: 54)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.partnerName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)

                lastLine
            }

            Spacer(minLength: 0)

            if let at = conversation.lastMessageAt {
                Text(RelativeTime.short(since: at))
                    .font(.system(size: 12))
                    .foregroundStyle(GardenPalette.muted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Model

/// Holds both lists, so the banner and the rows cannot disagree about what has
/// been answered — accepting a like moves somebody from one to the other and both
/// come from here.
@MainActor
final class ChatModel: ObservableObject {
    /// Seeded from the device's own copy, so the first frame already has the
    /// conversations on it. The network then reconciles into a list that is
    /// already on screen rather than filling an empty one — which is the whole
    /// point, and what makes the four-second poll stop being visible.
    @Published private(set) var conversations: [ChatService.Conversation] = ChatStore.conversations()

    @Published private(set) var admirers: [LikeService.Admirer] = []
    @Published private(set) var failure: String?

    /// Whether a load has finished at least once this session.
    ///
    /// Starts true when the cache had something in it: there is content on
    /// screen, so nothing is pending from the reader's point of view even though
    /// a fetch is in flight.
    @Published private(set) var hasLoaded: Bool = !ChatStore.conversations().isEmpty
    /// Which admirer is mid-answer, so their two buttons can be disabled without
    /// freezing the rest of the list.
    @Published private(set) var answering: String?

    /// Says a report did not reach us. Through the same banner every other
    /// failure on this screen uses, because it is one — and because the block
    /// *did* happen, so silence here would read as the whole action failing.
    func reportFailed(_ message: String) {
        failure = message
    }

    func load() async {
#if DEBUG
        // `-chat sample`; see `DebugLaunch`. Returns before any query, so this
        // works with the migration unapplied and nobody signed in.
        if DebugLaunch.showsSampleChat {
            admirers = Self.sampleAdmirers
            conversations = Self.sampleConversations
            hasLoaded = true
            return
        }
#endif
        // Independent queries, so they go together — the same reason
        // `DiscoveryModel.load` fans out.
        async let admirersTask = LikeService.shared.admirers()
        async let conversationsTask = ChatService.shared.conversations()
        admirers = await admirersTask
        let fetched = await conversationsTask

        // A failed fetch must not wipe what is on screen. `conversations()`
        // returns `[]` for a refused or offline request exactly as it does for
        // an account with no threads, so assigning it blindly would empty a chat
        // because the network hiccupped — the flash this whole change exists to
        // remove, arriving by a different door.
        // Bound before the test, not inside it: `||` takes an autoclosure, and
        // an `await` cannot live in one.
        let chatFailed = await ChatService.shared.lastError != nil
        if !fetched.isEmpty || !chatFailed {
            conversations = fetched
            ChatStore.save(fetched)
        }
        hasLoaded = true

        // Bound separately: `await a ?? b` does not mean "await a, then await b if
        // it was nil" — the whole expression is one suspension and both actors are
        // hit regardless, which reads as a bug the first time somebody profiles it.
        let likeFailure = await LikeService.shared.lastError
        let chatFailure = await ChatService.shared.lastError
        failure = likeFailure ?? chatFailure

        // **Asked here, on somebody's first admirer, and nowhere else.** iOS
        // lets an app ask once ever — a refusal is undoable only in Settings,
        // which nobody visits — so *when* decides whether notifications work for
        // that person at all. Someone has just been liked; being told sooner
        // next time obviously pays, and there is a face on screen making it
        // concrete. Asked at launch it is a question about nothing.
        //
        // And deliberately far from the Health sheet: this project lost a week
        // to two prompts colliding, because HealthKit hosts a remote view and
        // cannot present over anything else. Chat is not where sources are
        // connected.
        if !admirers.isEmpty || !conversations.isEmpty {
            await PushService.shared.askIfNeeded()
        }
    }

    /// Accepts and opens the thread, or declines and drops the row.
    ///
    /// The row leaves the list either way and before either round trip finishes:
    /// a button that stays put after being tapped invites a second tap, and the
    /// second one would answer a like that has already been answered.
    func respond(to admirer: LikeService.Admirer, accept: Bool) async -> ChatService.Conversation? {
        answering = admirer.id
        defer { answering = nil }

        let answered = await LikeService.shared.respond(to: admirer.id, accept: accept)
        guard answered else {
            failure = await LikeService.shared.lastError
            return nil
        }
        admirers.removeAll { $0.id == admirer.id }

        guard accept else { return nil }

        let conversation = await ChatService.shared.open(
            with: admirer.id,
            partnerName: admirer.name,
            partnerPhotoSeed: admirer.photoSeed
        )
        guard let conversation else {
            // The like is accepted and the thread is not. Saying so matters: the
            // admirer has left the list, so with no message this looks like the
            // accept itself vanished.
            failure = await ChatService.shared.lastError
            return nil
        }
        if !conversations.contains(where: { $0.id == conversation.id }) {
            conversations.insert(conversation, at: 0)
        }
        return conversation
    }
}

#if DEBUG
extension ChatModel {
    /// Seven, so the banner has to draw five and a "+", and spread across the
    /// units `RelativeTime` switches between.
    static let sampleAdmirers: [LikeService.Admirer] = {
        // Annotated, because the literal alone sends the type-checker off for long
        // enough that the compiler gives up on the expression outright.
        let people: [(name: String, secondsAgo: TimeInterval)] = [
            ("Mei", 720),
            ("Tobias", 10_800),
            ("Yuki", 32_400),
            ("Priya", 172_800),
            ("Lena", 950_400),
            ("Amara", 3_888_000),
            ("Jonah", 34_560_000),
        ]
        return people.map { person in
            LikeService.Admirer(
                id: "sample-\(person.name)",
                name: person.name,
                photoSeed: PortraitSeed.stable(for: person.name),
                likedAt: Date().addingTimeInterval(-person.secondsAgo)
            )
        }
    }()

    /// One of them deliberately has no message: an accepted like nobody has
    /// written in yet is the common case on this screen, and it is the row most
    /// likely to look broken.
    static let sampleConversations: [ChatService.Conversation] = [
        ChatService.Conversation(
            id: "sample-1",
            partnerID: "sample-Ines",
            partnerName: "Inés",
            partnerPhotoSeed: PortraitSeed.stable(for: "Inés"),
            lastMessage: nil,
            lastMessageAt: nil
        ),
        ChatService.Conversation(
            id: "sample-2",
            partnerID: "sample-Ravi",
            partnerName: "Ravi",
            partnerPhotoSeed: PortraitSeed.stable(for: "Ravi"),
            lastMessage: "the Dice listing said doors at eight but it's actually nine",
            lastMessageAt: Date().addingTimeInterval(-40 * 60)
        ),
        // Empty rather than nil: a photo with no caption, which is what the
        // trigger writes and the case that used to render a blank line.
        ChatService.Conversation(
            id: "sample-photo",
            partnerID: "sample-Nadia",
            partnerName: "Nadia",
            partnerPhotoSeed: PortraitSeed.stable(for: "Nadia"),
            lastMessage: "",
            lastMessageAt: Date().addingTimeInterval(-9 * 60)
        ),
        ChatService.Conversation(
            id: "sample-3",
            partnerID: "sample-Soo",
            partnerName: "Soo-ah",
            partnerPhotoSeed: PortraitSeed.stable(for: "Soo-ah"),
            lastMessage: "ok but you cannot claim to like Ravel and then say that",
            lastMessageAt: Date().addingTimeInterval(-3 * 86400)
        ),
        // A thread whose last word was spoken, so the microphone row can be
        // seen without recording anything.
        ChatService.Conversation(
            id: "sample-5",
            partnerID: "sample-tomas",
            partnerName: "Tomás",
            partnerPhotoSeed: PortraitSeed.stable(for: "Tomás"),
            lastMessage: "00:07",
            lastMessageAt: Date().addingTimeInterval(-25 * 60),
            lastMessageKind: "audio"
        ),
    ]
}
#endif
