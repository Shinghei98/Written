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
                        if model.conversations.isEmpty {
                            if model.hasLoaded { empty }
                        } else {
                            ForEach(model.conversations) { conversation in
                                Button {
                                    openThread = conversation
                                    isShowingThread = true
                                } label: {
                                    ConversationRow(conversation: conversation)
                                }
                                .buttonStyle(.plain)
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
            .statusBanner(model.failure)
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
        }
        .preferredColorScheme(.light)
        .task(id: isVisible) {
            guard isVisible else { return }
            await model.load()
#if DEBUG
            // `-chat admirers` / `-chat thread`; see `DebugLaunch`. After the load,
            // so the pushed page has something in it.
            guard let target = DebugLaunch.chatTarget, DebugLaunch.firesOnce("chat") else { return }
            try? await Task.sleep(for: .seconds(DebugLaunch.chatPushDelay))
            switch target {
            case "admirers": isShowingAdmirers = true
            // `typing` opens the same page as `thread`; the difference is inside
            // `ConversationView`, which reads the flag itself.
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

    /// The pinned block's height, a constant rather than a measurement.
    ///
    /// The content is inset by it, so measuring it would mean the list re-laying
    /// out every time the admirers row appeared or emptied — the same reason
    /// `DashboardView.expandedHeaderHeight` is a number.
    private var headerHeight: CGFloat { model.admirers.isEmpty ? 74 : 132 }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat")
                // The same *face* as "Memories" on the dashboard, at this
                // screen's own size. The two top-level titles were set in
                // different type — `.system` here against `BrandFont` there —
                // which also meant one scaled with Dynamic Type and the other
                // did not. Only the typeface changes; 34 stays 34.
                .font(BrandFont.title(34))
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
                    PortraitView(seed: admirer.photoSeed, initial: admirer.name)
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
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11))
                    Text("Photo")
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
            PortraitView(seed: conversation.partnerPhotoSeed, initial: conversation.partnerName)
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
    ]
}
#endif
