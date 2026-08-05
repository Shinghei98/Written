import PhotosUI
import SwiftUI

/// One chatroom.
///
/// **It polls, and only while it is on screen.** `.task` is cancelled the moment
/// this view goes away, which is what keeps the app's "nothing polls, nothing runs
/// in the background" property true everywhere except a conversation somebody is
/// looking at. Supabase Realtime would be instant and would mean hand-rolling
/// Phoenix's protocol — `phx_join`, a heartbeat, reconnection, `postgres_changes`
/// decoding — over `URLSessionWebSocketTask`, in a project with no package
/// dependencies at all. Push covers the case that actually matters, which is a
/// message arriving while the app is shut.
///
/// The layout follows the reference: a floating translucent banner the chat
/// scrolls *underneath*, tail-less bubbles with a generous corner radius, and a
/// compose bar whose trailing controls change with what you have typed.
struct ConversationView: View {
    let conversation: ChatService.Conversation

    /// The cache is read here rather than in `.task`, and that is the difference
    /// between a thread that opens and one that appears. A `.task` runs after the
    /// first frame, so seeding there would still draw one empty screen.
    init(conversation: ChatService.Conversation) {
        self.conversation = conversation
        _messages = State(initialValue: ChatStore.messages(in: conversation.id))
    }

    @Environment(\.dismiss) private var dismiss

    /// Seeded from disk in `init`, so the thread is already on screen before any
    /// query runs. This is the local-first half: the network reconciles what is
    /// showing rather than being what produces it.
    @State private var messages: [ChatService.Message]
    @State private var draft = ""
    @State private var myID: String?
    @State private var isSending = false
    @State private var failure: String?

    /// The recorder, and whether its sheet is up.
    ///
    /// Two pieces rather than one, because they end at different moments: the
    /// finger comes off the microphone and the recording stops, but the sheet
    /// stays for as long as it takes to decide whether to keep the take.
    @StateObject private var memo = VoiceMemo()
    @State private var isMemoOpen = false
    /// Whether the take running now began at the composer's microphone.
    ///
    /// The sheet draws a different row for a held take than for a tapped one —
    /// see `VoiceMemoBanner.isHeld` — and only this view knows which gesture
    /// started it.
    @State private var isMemoHeld = false

    /// Whether the other person is typing right now.
    ///
    /// **Nothing sets this yet, and that is a gap rather than an oversight.**
    /// Typing is presence, and presence needs a live channel — the thing the
    /// header comment above explains this app deliberately does not have. Polling
    /// cannot carry it: by the time a four-second poll reported "typing", they
    /// would have stopped. The indicator is built and correct so that wiring a
    /// channel later is a one-line change rather than a design exercise, and
    /// `-chat typing` drives it in DEBUG so the animation can be seen.
    @State private var isPartnerTyping = false

    /// The attachment flow: the picker, what came back, and the upload.
    ///
    /// `pending` holds a chosen file that has not been sent yet, so the compose
    /// bar can show it and let somebody add a caption or change their mind —
    /// choosing a photo is not the same act as sending one.
    @State private var isPickingMedia = false
    @State private var picked: PhotosPickerItem?
    @State private var pending: PickedMedia?
    @State private var isAttaching = false

    /// Paging back through history. `false` once a page comes back short, which
    /// is how the end of a thread announces itself — there is no count to ask
    /// for, and asking for one per open would be a query nobody reads.
    @State private var hasMoreHistory = true
    @State private var isLoadingOlder = false

    /// How often the thread re-reads itself. Slow enough not to be a load on a
    /// screen somebody may leave open, fast enough that a reply does not feel
    /// stuck — and only ever while visible.
    private static let pollInterval: Duration = .seconds(4)

    var body: some View {
        ZStack(alignment: .top) {
            ChatBackground()

            thread
                // **A tap anywhere in the thread puts the keyboard away.**
                //
                // `contentShape` first, because without it only the bubbles are
                // hit-testable and the gaps between them — most of the screen in
                // a short conversation — would swallow the tap. The whole
                // message area is the target, which is the point.
                //
                // `simultaneousGesture`, not `onTapGesture`: an attachment is
                // tappable and a plain tap gesture here would eat it. This runs
                // alongside whatever the tap was also for, and a drag is
                // untouched, so scrolling still works.
                //
                // Attached to `thread` rather than to the `ZStack` so it covers
                // exactly the right region on its own — the banner is drawn
                // above and keeps its own taps, and the composer sits outside in
                // a `safeAreaInset`.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    // **Anywhere outside the sheet closes it and gives the
                    // keyboard back**, which is the same tap that dismisses the
                    // keyboard when no memo is open. One gesture, two meanings,
                    // decided by what is currently covering the composer.
                    if isMemoOpen { closeMemo() } else { dismissKeyboard() }
                })

            // Last in the stack, so the chat passes beneath it.
            banner
        }
        // **The composer stays mounted and the sheet is layered over it.**
        //
        // Swapping one for the other is the obvious arrangement and it broke the
        // whole gesture: the microphone button carries the `DragGesture`, and
        // replacing the composer *destroys that button the instant recording
        // starts*. A destroyed recogniser never delivers `.onEnded`, so lifting
        // the finger did nothing at all and the take ran on to its sixty-second
        // cap. The touch is already being tracked by the time the sheet appears,
        // so as long as the view still exists the release arrives.
        //
        // It is also what the reference shows. The gold disc in the sheet's
        // corner sits exactly where the microphone is, because the finger has
        // never left the microphone.
        .safeAreaInset(edge: .bottom) {
            ZStack(alignment: .bottom) {
                composer

                if isMemoOpen {
                    VoiceMemoBanner(
                        memo: memo,
                        isHeld: isMemoHeld,
                        onStartTapped: {
                            isMemoHeld = false
                            Task { await memo.startRecording() }
                        },
                        onStopTapped: { memo.stopRecording() },
                        onRetry: { memo.discard() },
                        onSend: {
                            // Sendable mid-take, which the reference allows: the
                            // arrow is on screen while a tapped recording runs.
                            // Stop first, or the file would be uploaded while
                            // still being written to.
                            if memo.isRecording { memo.stopRecording() }
                            sendMemo()
                        },
                        // The composer draws this too, and is invisible behind
                        // this sheet — so a failed voice send had nowhere to be
                        // read. See `VoiceMemoBanner.failure`.
                        failure: failure
                    )
                    .transition(.move(edge: .bottom))
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isMemoOpen)
        .photosPicker(
            isPresented: $isPickingMedia,
            selection: $picked,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: picked) { item in
            guard let item else { return }
            // Cleared straight away, or choosing the same photograph twice in a
            // row is a no-op the binding never reports — `PhotoGrid` documents
            // the same trap.
            picked = nil
            isAttaching = true
            Task {
                // The loader lives in `PhotoGrid` and is shared rather than
                // copied: the video path has traps in it that are already
                // written down there once.
                pending = await PhotoGrid.load(item)
                isAttaching = false
                if pending == nil { failure = "That file couldn't be opened." }
            }
        }
        .preferredColorScheme(.light)
        .task {
            // **`currentUserID()`, not the raw property.** `userID` is a cache
            // filled in by the token exchange, so on a cold launch — which is
            // exactly what a tapped notification is — it is nil until
            // `restoreSession` has been round the network. It decides both which
            // side each bubble is drawn on and which messages count as unread,
            // so an empty one draws the whole thread as theirs. The same defect
            // was cleared out of `ChatService` and `LikeService` this morning
            // and this call was missed.
            myID = await SupabaseAuth.shared.currentUserID()
#if DEBUG
            isPartnerTyping = DebugLaunch.showsTypingIndicator
            // Without this the sample thread draws entirely as *their* messages.
            // `MessageBubble` asks whether a sender matches `myID`, and nobody is
            // signed in during a debug launch, so every comparison against nil
            // failed and one side of the conversation quietly vanished — with
            // both sides grey, which is exactly what a broken side looks like.
            if DebugLaunch.showsSampleChat, myID == nil { myID = Self.sampleMe }
            // `-memo review|empty|holding`; see `DebugLaunch.memoState`.
            if let state = DebugLaunch.memoState {
                memo.seedForPreview(state)
                isMemoHeld = state == "holding"
                isMemoOpen = true
            }
#endif
            await reload()
            // **Before `markRead`, which is what destroys the evidence.**
            captureUnread()
            // **Positions the thread exactly once, whatever the load found.**
            // `onChange(of: messages.count)` was the only trigger, and a thread
            // opened before is seeded from `ChatStore` in the initialiser — so a
            // reload returning the same number of messages changed no count,
            // fired nothing, and left the page sitting at the top of the
            // conversation. Every thread with nothing new in it opened at its
            // beginning.
            hasLoadedOnce = true
            await markRead()
            // Cancelled with the view. A `while true` here would be a leak; this
            // one ends when the page does.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }
                await reload()
                // **Every pass, not only the first.** A message arriving while
                // somebody is looking at the thread has been read by definition,
                // and leaving it unread would put a badge on the icon of an app
                // they are holding open.
                await markRead()
            }
        }
    }

    /// Marks their messages read, then redraws the icon badge.
    ///
    /// Both, in that order: the count is read back from the server rather than
    /// decremented locally, so the number cannot drift away from the truth
    /// across two devices or a failed write.
    private func markRead() async {
        await ChatService.shared.markRead(in: conversation.id)
        await PushService.shared.refreshBadge()
    }

    /// Puts the keyboard away without owning the focus.
    ///
    /// The composer's field manages its own first responder — there is no
    /// `FocusState` here to set to `nil` — so this asks whoever holds it to give
    /// it up, the same way `DashboardView.closeEditor` does for the biographics
    /// sheets. Sending to `nil` walks the responder chain, which is what lets a
    /// view that does not know about the field dismiss it.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - The thread

    private var thread: some View {
        // Outside the `ScrollView`, so the width is the viewport's and not the
        // scrolling content's — the two differ, and measuring the wrong one
        // gives bubbles sized against something that can change as you scroll.
        GeometryReader { geometry in
            threadContent(width: geometry.size.width - 32)
        }
    }

    private func threadContent(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Measured off the reference rather than chosen: its bubbles sit
                // **4.7pt apart inside a run** and **13.3pt apart across a
                // change of speaker**, both repeating consistently down the
                // thread. This is the first of the two; `startsRun` adds the
                // rest below.
                //
                // The earlier pair — 2 and 14 — had the between-speaker gap
                // about right and the within-run one less than half what it
                // should be, which read as cramped rather than grouped.
                // **`pinnedViews: [.sectionHeaders]` is the sticky behaviour.**
                //
                // One section per calendar day, and SwiftUI keeps the current
                // day's pill at the top of the viewport until the next one
                // pushes it off — which is what WhatsApp does and what a
                // hand-rolled overlay would have to reimplement badly, by
                // tracking scroll offsets against message frames.
                LazyVStack(spacing: 5, pinnedViews: [.sectionHeaders]) {
                    // Reaching the oldest message on screen asks for the page
                    // before it. Safe here for the reason `DiscoveryView`'s
                    // `onAppear` paging is: a `LazyVStack` builds only what is
                    // near the viewport, so this fires when somebody actually
                    // scrolls back rather than all at once on open.
                    if let oldest = messages.first, hasMoreHistory {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { loadOlder(before: oldest.sentAt) }
                    }

                    ForEach(Self.days(in: messages)) { day in
                        Section {
                            ForEach(Array(day.messages.enumerated()), id: \.element.id) { index, message in
                                // **Inside the section, above the message.**
                                // That is what puts it *under* the date pill
                                // when the boundary falls on a new day, with no
                                // special case: the pill is the section header,
                                // so anything at the top of the section's
                                // content is beneath it. Mid-day it simply sits
                                // between two bubbles.
                                if unreadMark?.firstID == message.id {
                                    unreadBand
                                        .id(Self.unreadAnchor)
                                }
                                let previous = index > 0 ? day.messages[index - 1] : nil
                                // **A photo ends the run.** The rule was "same
                                // sender as the message before", which is right
                                // until the message before is an attachment —
                                // those draw no bubble and carry no tail, so the
                                // text under a photo looked like the *middle* of
                                // a run and lost its tail while plainly
                                // beginning one. Anything that did not draw a
                                // tailed bubble has to break the group.
                                //
                                // A new day breaks it too, and falls out for
                                // free: `previous` is nil at the top of a
                                // section, so the first message after a
                                // separator always starts a run.
                                let startsRun = previous == nil
                                    || previous?.senderID != message.senderID
                                    || previous?.attachmentPath != nil

                                MessageBubble(
                                    message: message,
                                    isMine: message.senderID == myID,
                                    containerWidth: width,
                                    startsRun: startsRun
                                )
                                .id(message.id)
                                // Brings a change of speaker to the measured
                                // 13pt: 5 from the stack plus 8 here. A run
                                // stays at 5. Not on the first of a section —
                                // the separator above it is already the gap.
                                .padding(.top, startsRun && index > 0 ? 8 : 0)
                            }
                        } header: {
                            DayDivider(label: day.label)
                        }
                    }

                    if isPartnerTyping {
                        TypingBubble()
                            .id(Self.typingAnchor)
                            // Arrives and leaves as movement rather than a pop,
                            // since it appears while somebody is watching.
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                // Clear of the banner it scrolls under. The banner is translucent
                // precisely so a message part-way behind it still reads as a
                // message rather than as a clipped edge — but the *first* one
                // should start below it, not under it.
                //
                // Padding alone is no longer enough. A pinned section header
                // sticks to the **scroll view's** top edge, which is behind the
                // banner, so the day pill parked itself under it and could not
                // be read. Content padding does not move that edge; a safe-area
                // inset does.
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            // Where the day pill comes to rest. `Color.clear` rather than the
            // banner itself: the banner is drawn in the `ZStack` above so that
            // the chat passes beneath it, and this only has to reserve the
            // height so the scroll view's top edge lands below it.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: Self.bannerHeight)
            }
            // A child's `minY` in this space is its offset from the *visible*
            // top rather than from the content's, which is what makes "is the
            // band on screen" answerable without tracking scroll offsets.
            // Straight to the end from the cached messages, before the network
            // has answered. Unanimated because this is where the page opens; the
            // load a moment later refines it to the unread band if there is one.
            .onAppear {
                guard let last = messages.last?.id else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .coordinateSpace(name: Self.threadSpace)
            .background(
                GeometryReader { geometry in
                    Color.clear.onAppear { viewportHeight = geometry.size.height }
                }
            )
            .onPreferenceChange(UnreadBandOffset.self) { bandOffset = $0 }
            // The end of the thread is where a conversation is read from, so it
            // opens there rather than at its beginning.
            .onChange(of: messages.count) { _ in scroll(proxy) }
            // The one that always fires. `captureUnread` runs after the first
            // load, so by then any count change has already been and gone — and
            // for a thread with nothing new there was no count change at all.
            .onChange(of: hasLoadedOnce) { _ in scroll(proxy) }
            // The dots push the last message up, so follow them too.
            .onChange(of: isPartnerTyping) { _ in scroll(proxy) }
        }
    }

    private static let typingAnchor = "typing-indicator"
    /// The scroll id of the unread band, so opening can land on it.
    private static let unreadAnchor = "unread-divider"

    /// Where the divider goes, and how many are below it.
    ///
    /// **Captured once, before anything is marked read, and never recomputed.**
    /// Opening a thread marks everything read — that is what clears the badge —
    /// so the boundary exists only in the very first fetch. Recomputing it later
    /// would find nothing and the band would vanish while somebody was reading
    /// towards it, which is the one thing it must not do. It also stays put as
    /// new messages arrive: it marks where you *were*, not where the end is.
    @State private var unreadMark: (firstID: String, count: Int)?
    /// So the snapshot is only ever taken on the first load.
    @State private var hasMarkedUnread = false
    /// So the thread lands on the band once and then behaves normally.
    @State private var hasCentredOnUnread = false
    /// Flipped after the first fetch, purely so something can be observed. The
    /// value means nothing; the transition is the signal.
    @State private var hasLoadedOnce = false

    private static let threadSpace = "thread"
    /// The band's offset from the top of the visible area, or nil when it has
    /// not been built at all.
    @State private var bandOffset: CGFloat?
    @State private var viewportHeight: CGFloat = 0

    /// **A band that was never built reports nothing, and that is the answer
    /// rather than a gap.** `LazyVStack` only builds near the viewport, so a
    /// band far above the end of the thread is simply absent — which is exactly
    /// "the unread did not fit".
    private var isBandOnScreen: Bool {
        guard let bandOffset, viewportHeight > 0 else { return false }
        return bandOffset >= 0 && bandOffset <= viewportHeight
    }

    /// Reads the boundary out of a freshly loaded thread.
    ///
    /// Their messages only: your own are never unread, and `read_at` is null on
    /// everything you have sent until they open it.
    private func captureUnread() {
        guard !hasMarkedUnread else { return }
        hasMarkedUnread = true
        guard let me = myID else { return }
        let theirs = messages.filter { $0.senderID != me && $0.readAt == nil }
        guard let first = theirs.first, theirs.count > 0 else { return }
        unreadMark = (first.id, theirs.count)
    }

    /// The band that separates what you have read from what you have not.
    ///
    /// Edge to edge, because it is a *rule across the thread* rather than an
    /// item in it — a pill would read as another message, and the point is that
    /// it belongs to the list rather than to either side of it.
    private var unreadBand: some View {
        ZStack {
            GardenPalette.unreadBand
            Text(unreadMark.map { "\($0.count) unread message\($0.count == 1 ? "" : "s")" } ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GardenPalette.ink.opacity(0.55))
        }
        .frame(height: 26)
        // Cancels the list's own inset so the band reaches both edges. The
        // bubbles are padded individually, so nothing else has to change.
        .padding(.horizontal, -16)
        .padding(.vertical, 6)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: UnreadBandOffset.self,
                    value: geometry.frame(in: .named(Self.threadSpace)).minY
                )
            }
        )
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        // **The band wins on the first pass, once.** With more unread than fits
        // a screen, landing at the bottom means scrolling back up hunting for
        // where you stopped — so the first thing drawn is the boundary, in the
        // middle of the screen, with the last read message above it and the
        // first unread one below.
        //
        // Only once: after that the thread behaves normally and follows new
        // messages down, or somebody replying would be yanked back to a line
        // they have already passed.
        // **The bottom first, then correct if the band did not survive it.**
        // "Does the unread block fit on a screen" is exactly "is the band still
        // visible once we are at the end", so the question answers itself — no
        // height arithmetic, and no guessing from a message count that a single
        // photograph would falsify.
        //
        // Asking for the band centred outright is what this replaces, and it was
        // wrong across the middle of its range: a scroll view clamps to its end
        // only when the content below the band is under *half* a screen, so
        // anywhere between half and one screen left somebody centred on the
        // boundary with the newest messages below the fold.
        if unreadMark != nil, !hasCentredOnUnread {
            hasCentredOnUnread = true
            proxy.scrollTo(messages.last?.id ?? Self.unreadAnchor, anchor: .bottom)
            // Next runloop, so the layout above has settled and the band has had
            // its chance to report.
            Task { @MainActor in
                await Task.yield()
                guard !isBandOnScreen else { return }
                // Unanimated: this is where the page *opens*, not somewhere it
                // travels to, and a visible slide would read as the thread
                // moving on its own.
                proxy.scrollTo(Self.unreadAnchor, anchor: .center)
            }
            return
        }
        let target = isPartnerTyping ? Self.typingAnchor : messages.last?.id
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    // MARK: - The banner

    /// Tall enough for a 38pt portrait and two lines of text beside it.
    private static let bannerHeight: CGFloat = 64

    /// Back, who you are talking to, and when they were last here. Nothing else.
    ///
    /// Half transparent over the chat, which is the reference's arrangement and
    /// not decoration: a conversation is a continuous thing, and a solid bar
    /// would cut the top off it. `.ultraThinMaterial` rather than an opacity —
    /// a flat translucent fill lets whatever is behind it show through as
    /// muddied colour, where the material blurs first and stays legible over
    /// both a white bubble and a yellow one.
    private var banner: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to conversations")

            // Their real photograph where there is one — see
            // `ChatService.Conversation.photoRef`.
            ProfilePhotoView(ref: conversation.photoRef, initial: conversation.partnerName)
                .frame(width: 38, height: 38)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.partnerName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .lineLimit(1)

                // Typing replaces the timestamp rather than joining it: they are
                // answers to the same question — where is this person — and
                // showing both would say they were last seen an hour ago while
                // they type at you.
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(isPartnerTyping ? GardenPalette.gold : GardenPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.bannerHeight)
        .background(.ultraThinMaterial)
        // Only along the bottom, so the bar reads as a layer over the chat
        // rather than as a box drawn on it.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(GardenPalette.ink.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    private var subtitle: String {
        if isPartnerTyping { return "typing..." }
        guard let seen = lastSeenAt else { return "" }
        return RelativeTime.lastSeen(since: seen)
    }

    /// When the other person was last here, as far as anything can honestly say.
    ///
    /// **Read from their newest message rather than from a column**, because
    /// there is no presence column and inventing one here would mean a migration
    /// this session cannot apply. It is a floor, not a guess: somebody was
    /// certainly present when they sent something, so this only ever *understates*
    /// how recently they were around. `last_message_at` on the conversation would
    /// have been the easier reach and is wrong — it moves when *you* write, so a
    /// thread you just posted in would claim they were seen a second ago.
    private var lastSeenAt: Date? {
        messages.last { $0.senderID != myID }?.sentAt
    }

    // MARK: - The compose bar

    private var composer: some View {
        VStack(spacing: 0) {
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(SignInPalette.error)
                    .padding(.bottom, 6)
            }

            // What you picked, before you send it. Choosing is not sending, so
            // it sits here with a way out — and a caption can still be typed
            // alongside it.
            if let pending {
                HStack(spacing: 10) {
                    Image(uiImage: pending.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            if pending.isVideo {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                            }
                        }

                    Text(pending.isVideo ? "Video ready to send" : "Photo ready to send")
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)

                    Spacer(minLength: 0)

                    Button { self.pending = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(GardenPalette.muted.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove attachment")
                }
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isAttaching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing…")
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.ink)
                    .lineLimit(1...5)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(GardenPalette.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(SignInPalette.fieldBorder, lineWidth: 1) }
                    .submitLabel(.send)
                    .onSubmit(send)

                // The two attachment controls and the send button occupy the same
                // place, and never both. An empty field has nothing to send, and
                // a written one is almost certainly on its way out — so the row
                // offers what you are about to do rather than everything you
                // could do.
                if hasDraft {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            // The same pairing as the bubble it is about to
                            // make: white on sky blue.
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(GardenPalette.bubbleMine, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .accessibilityLabel("Send")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    HStack(spacing: 4) {
                        // **Hold, not tap.** A `Button` reports a press and a
                        // release together as one event, so it cannot say when
                        // the finger went down — which is the only thing this
                        // control needs to know. A zero-distance drag can.
                        //
                        // The sheet opens on the way down, so it is already
                        // there when the first sample arrives; the keyboard goes
                        // at the same moment, because the composer it belongs to
                        // is about to be replaced.
                        composerIcon("mic", label: "Record a voice message")
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        guard !isMemoOpen else { return }
                                        // The first hold ever only asks. The
                                        // prompt takes the touch, so a take
                                        // started behind it would begin after
                                        // the finger had lifted and would have
                                        // no release to end it. Ask now, record
                                        // on the next hold.
                                        guard memo.isPermissionDecided else {
                                            Task { _ = await memo.hasPermission() }
                                            return
                                        }
                                        dismissKeyboard()
                                        // Or the last failure — a photo's,
                                        // perhaps — greets them inside a sheet
                                        // it has nothing to do with.
                                        failure = nil
                                        isMemoOpen = true
                                        isMemoHeld = true
                                        Task { await memo.startRecording() }
                                    }
                                    // Straight to the take the instant the
                                    // finger lifts, which is the whole gesture:
                                    // hold to speak, let go to be done.
                                    .onEnded { _ in memo.stopRecording() }
                            )

                        // Presented from a plain view rather than using a
                        // `PhotosPicker` label directly — the same arrangement
                        // `PhotoGrid` arrived at, and for the same reason: a
                        // `PhotosPicker` *is* a button and its own tap handling
                        // wins over anything wrapped around it.
                        Button { isPickingMedia = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(GardenPalette.muted)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Attach a photo or video")
                    }
                    .transition(.opacity)
                }
            }
            // One animation for the swap, driven off the one fact that causes it.
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hasDraft)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // The same material as the banner, so the photograph runs behind both
        // ends of the screen. A solid bar here would read as the picture having
        // been cut off rather than as a layer over it.
        .background(.ultraThinMaterial)
    }

    /// Drawn, and not yet wired.
    ///
    /// Sending media needs somewhere to put it, and this project's storage
    /// bucket is an open gap — `PhotoEntryView` already picks and frames media
    /// and then drops it. These are in place because the compose bar's shape is
    /// what is being designed here, and because a bar that gained buttons later
    /// would move the field under somebody's thumb.
    private func composerIcon(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(GardenPalette.muted)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    /// Whether the send button is showing. An attachment counts: a photo with no
    /// caption is the ordinary case, and leaving the mic and plus up while one
    /// is queued would offer to attach a second thing this bar cannot carry.
    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending != nil
    }

    // MARK: - Sending

    /// Closes the sheet and throws away whatever was in it.
    ///
    /// Tapping outside is a way *out*, not a way to park a recording — leaving
    /// a take alive behind a closed sheet would mean the next tap on the
    /// microphone found somebody else's audio already loaded.
    private func closeMemo() {
        isMemoOpen = false
        failure = nil
        memo.reset()
    }

    /// The up arrow: upload the take, write the message, close the sheet.
    ///
    /// Nothing optimistic here, unlike a text message. A voice bubble drawn
    /// before its bytes exist would have nothing to play, and a bubble that
    /// cannot be played is worse than a moment's wait — the same reasoning
    /// `send()` gives for photographs.
    private func sendMemo() {
        guard let url = memo.recording, !isSending else { return }
        let seconds = memo.duration
        isSending = true
        memo.stopPlayback()

        Task {
            guard let upload = await MediaService.shared.uploadVoice(at: url, to: conversation.id) else {
                isSending = false
                failure = await MediaService.shared.lastError
                return
            }
            // The bytes are already on this device, so file them against the
            // path they were uploaded to rather than fetching them back to play
            // a recording we made ourselves.
            if let data = try? Data(contentsOf: url) {
                await MediaService.shared.seedCache(data, for: upload.path)
            }
            // The length rides in the body, which is otherwise empty for an
            // attachment. `messages_have_content` allows that — a row needs a
            // body *or* a path — and it saves the reader downloading the file
            // to find out how long it is before deciding to hear it.
            let sent = await ChatService.shared.send(
                VoiceMemoBanner.clock(seconds),
                in: conversation.id,
                attachment: upload
            )
            isSending = false
            guard sent else {
                failure = await ChatService.shared.lastError ?? "That message didn't send."
                return
            }
            isMemoOpen = false
            memo.reset()
            await reload()
        }
    }

    private func send() {
        guard hasDraft, !isSending else { return }
        let body = draft
        let media = pending
        // Cleared before the round trip. Leaving the text in place until the
        // server answers means a slow network looks like a send that did not
        // happen, and invites a second tap.
        draft = ""
        pending = nil
        isSending = true

        // The bubble appears now, not when the server answers. This is what
        // every messaging app does and it is why they feel immediate — the
        // network decides whether it *stays*, not whether it shows.
        //
        // Only for text: a photo has to be uploaded before there is anything to
        // draw, and a bubble promising a picture that is still compressing would
        // be a worse lie than a short wait.
        let localID = "pending-\(UUID().uuidString)"
        if media == nil, let myID {
            messages.append(
                ChatService.Message(
                    id: localID,
                    senderID: myID,
                    body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                    sentAt: Date(),
                    isPending: true
                )
            )
        }

        func withdraw() {
            messages.removeAll { $0.id == localID }
        }

        Task {
            // Upload first: the row carries the path, so a message written
            // before its bytes exist would point at nothing. If the upload
            // fails, nothing is sent at all — a caption arriving without the
            // photo it belonged to is worse than an obvious failure.
            var attachment: MediaService.Upload?
            if let media {
                attachment = await MediaService.shared.upload(media, to: conversation.id)
                guard attachment != nil else {
                    isSending = false
                    withdraw()
                    draft = body
                    pending = media
                    // Shown, unlike a failed like. A photo that silently fails
                    // to send is a message the sender believes they sent.
                    failure = await MediaService.shared.lastError
                    return
                }
                // File the bytes we already have against the path they were just
                // uploaded to, so the sender's own thread never downloads back
                // the picture it has been holding all along. For a video this is
                // the poster frame, which is the only still that exists.
                if let path = attachment?.path,
                   let poster = media.thumbnail.jpegData(compressionQuality: 0.9) {
                    await MediaService.shared.seedCache(poster, for: path)
                }
            }

            let landed = await ChatService.shared.send(
                body, in: conversation.id, attachment: attachment
            )
            isSending = false
            if landed {
                failure = nil
                // The pending bubble is not removed here — `merge` drops it as
                // the real row arrives, so the two never both show and the
                // bubble never blinks out and back in between.
                await reload()
            } else {
                // Put it back rather than losing what they wrote.
                withdraw()
                draft = body
                pending = media
                failure = await ChatService.shared.lastError
            }
        }
    }

    /// Folds a fetched page into what is on screen, rather than replacing it.
    ///
    /// Assigning the fetched array wholesale was the old behaviour and it churns:
    /// every four seconds the list identity changed, which fights the scroll
    /// position of somebody reading back through a thread. It also threw away
    /// anything the fetch did not cover — an optimistic message still in flight,
    /// or an older page already paged in.
    ///
    /// Server rows win, because the server is the source of truth and the device
    /// keeps a cache. A pending message is dropped once its real counterpart
    /// arrives: matched on sender and body rather than id, since the id it was
    /// given locally is not the one the server assigned.
    private func merge(_ fetched: [ChatService.Message]) {
        guard !fetched.isEmpty else { return }

        var byID: [String: ChatService.Message] = [:]
        for message in messages where !message.isPending { byID[message.id] = message }
        for message in fetched { byID[message.id] = message }

        var merged = Array(byID.values)

        let landed = Set(fetched.map { "\($0.senderID)\u{1}\($0.body)" })
        merged += messages.filter { pending in
            pending.isPending && !landed.contains("\(pending.senderID)\u{1}\(pending.body)")
        }

        // **The id breaks ties, and it has to.** `Array.sort` is not stable in
        // Swift, and the rows come out of a dictionary, so two messages sharing
        // a timestamp land in a different order on every pass — which made the
        // unread band appear to wander, since it is anchored to one message id
        // while the messages around it reshuffled underneath it. Every four
        // second poll moved them again.
        //
        // Equal timestamps are rarer in life than in testing — `now()` is the
        // *transaction* time in Postgres, so a batch inserted in one statement
        // shares it exactly — but two messages landing in the same microsecond
        // is a coin this app should not be flipping every poll.
        merged.sort { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) }
        guard merged != messages else { return }
        messages = merged
        // Only what the server confirmed is written down; see `Message.isPending`.
        ChatStore.replace(merged.filter { !$0.isPending }, in: conversation.id)
    }

    /// Fetches the page before the oldest message on screen.
    ///
    /// The scroll position is deliberately not restored afterwards. Inserting
    /// above the viewport keeps it where it was in a `ScrollView`, which is the
    /// behaviour wanted — the reader stays on the message they were reading and
    /// the older ones appear above it.
    private func loadOlder(before: Date) {
        guard !isLoadingOlder, hasMoreHistory else { return }
        isLoadingOlder = true
        Task {
            let older = await ChatService.shared.messages(in: conversation.id, before: before)
            isLoadingOlder = false
            // A short page means the beginning of the thread. An empty one says
            // the same thing and is the common case once you reach it.
            if older.count < ChatService.messagePageSize { hasMoreHistory = false }
            merge(older)
        }
    }

    private func reload() async {
#if DEBUG
        // `-chat sample` and friends. Returns before any query, so the bubbles
        // can be looked at with the migration unapplied and nobody signed in —
        // and, more to the point, with both sides present. A real thread on this
        // developer's account has one participant in it.
        if DebugLaunch.showsSampleChat {
            messages = Self.sampleMessages(mine: myID ?? Self.sampleMe)
            return
        }
#endif
        merge(await ChatService.shared.messages(in: conversation.id))
    }
}

#if DEBUG
extension ConversationView {
    /// Stands in for `SupabaseAuth.userID` when nobody is signed in, so the
    /// sample thread still has a side that is "mine".
    static let sampleMe = "sample-me"

    /// Both sides, short and long, so the bubble's corner radius can be judged
    /// against a two-word reply as well as a wrapped paragraph — a radius that
    /// looks right on a long message turns a short one into a pill.
    ///
    /// It ends on *their* message, which is what makes `lastSeenAt` and the
    /// typing indicator show something.
    static func sampleMessages(mine: String) -> [ChatService.Message] {
        let them = "sample-partner"
        // Spread across four calendar days on purpose, so every branch of
        // `RelativeTime.daySeparator` is on one screen: a date beyond a week, a
        // weekday name, Yesterday and Today. A thread that all happened this
        // afternoon would draw one separator and prove nothing.
        let day: TimeInterval = 86_400
        let script: [(String, String, TimeInterval)] = [
            (them, "did you ever listen to the thing I sent", 9 * day),
            (mine, "not yet. it is 40 minutes long", 9 * day - 900),
            (them, "it is FOUR minutes long", 3 * day),
            (mine, "then I have listened to it", 3 * day - 600),
            (them, "you have not", day),
            (mine, "ok but you cannot claim to like Ravel and then say that", 8_400),
            (mine, "say what", 8_100),
            (them, "that the Bolero is the good one", 7_900),
            (mine, "it IS the good one", 7_700),
            (them, "it's fifteen minutes of one bar getting louder. I have heard louder bars", 7_400),
            (mine, "and yet you have listened to it four times this month, which I know, because this app told me", 5_900),
            (them, "that feels like a violation of something", 5_600),
        ]
        var messages = script.enumerated().map { index, line in
            ChatService.Message(
                id: "sample-\(index)",
                senderID: line.0,
                body: line.1,
                sentAt: Date().addingTimeInterval(-line.2)
            )
        }
        // One of each side, so the voice bubble can be judged in both fills —
        // gold has a much narrower contrast margin than grey and is where a
        // too-faint waveform would show first.
        //
        // The path points at nothing on purpose. `VoiceBubble` asks
        // `MediaService` for the file and draws an empty waveform when it gets
        // nothing, which is the layout question this is here to answer; playing
        // it back needs a real conversation and a real recording.
        for (index, entry) in [(mine, "00:04", 5_200.0), (them, "01:12", 4_800.0)].enumerated() {
            messages.append(
                ChatService.Message(
                    id: "sample-voice-\(index)",
                    senderID: entry.0,
                    body: entry.1,
                    sentAt: Date().addingTimeInterval(-entry.2),
                    attachmentPath: "sample/voice-\(index).m4a",
                    attachmentKind: "audio"
                )
            )
        }
        return messages.sorted { $0.sentAt < $1.sentAt }
    }
}
#endif

extension ConversationView {

    /// One calendar day of the thread.
    struct Day: Identifiable {
        /// The start of the day, which is both the identity and the sort key.
        let id: Date
        let label: String
        let messages: [ChatService.Message]
    }

    /// Splits the thread on calendar-day boundaries, in order.
    ///
    /// Grouped here rather than in `body`. It walks the whole thread, and a
    /// SwiftUI body runs on any state change — an image finishing, a scroll
    /// tick, the four-second poll — which is the same argument
    /// `DistillViewModel` makes for deriving the dashboard once per
    /// distillation instead of once per frame.
    ///
    /// `messages` is already sorted by `sentAt` (see `merge`), so one pass is
    /// enough and nothing has to be re-sorted.
    static func days(in messages: [ChatService.Message]) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for message in messages {
            let start = calendar.startOfDay(for: message.sentAt)
            if let last = days.last, last.id == start {
                days[days.count - 1] = Day(
                    id: last.id, label: last.label, messages: last.messages + [message]
                )
            } else {
                days.append(
                    Day(
                        id: start,
                        label: RelativeTime.daySeparator(for: message.sentAt),
                        messages: [message]
                    )
                )
            }
        }
        return days
    }
}

/// The day label between two messages, and the one that sticks to the top.
///
/// It is a section header, so the same view does both jobs — inline when its
/// day is on screen, pinned while you scroll through it. That is why it is
/// opaque rather than translucent: messages pass *underneath* it, and a
/// material would let a bubble's text ghost through the words.
struct DayDivider: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(GardenPalette.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(GardenPalette.card, in: Capsule())
            .overlay { Capsule().strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1) }
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - The background

/// Plain parchment, the same surface as the rest of the app.
///
/// It was a photograph for a while and is not any more. Worth keeping the
/// measurement that came out of that, because it is the argument for why the
/// bubbles are the colours they are: against the Santorini image, **6.8% of the
/// picture sat within 45 of `bubbleTheirs`** — grey stone, concentrated in the
/// stairs, which is exactly where a long thread scrolls to. Sky blue never
/// collided anywhere.
///
/// On flat parchment neither is in any danger, so the bubbles keep their shadow
/// rather than gaining a border: the shadow was chosen to lift them off a busy
/// picture and it does no harm here, where a hairline outline would only add a
/// line to a screen that does not need one.
struct ChatBackground: View {
    var body: some View {
        GardenPalette.parchment
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

// MARK: - A message

/// A bubble with a tail at the bottom corner on the sender's side.
///
/// **The tail lives inside the frame, not outside it.** The body is inset by
/// `tail` on the tailed side and the tail fills that strip, so the shape never
/// draws beyond its own bounds — a tail added as an overhang would be clipped
/// by any ancestor that bounds its children, and would push the bubble's
/// alignment off by its own width.
///
/// Drawn as two overlapping subpaths rather than one traced outline. Tracing a
/// rounded rectangle *and* a tail as a single continuous path means hand-rolling
/// three of the four corner arcs to join it, which is a lot of arithmetic to get
/// a shape that `addRoundedRect` already knows how to draw. The default
/// non-zero fill rule merges the two cleanly.
struct BubbleShape: Shape {
    var isMine: Bool
    var radius: CGFloat = 15
    var tail: CGFloat = 7
    /// Only the first message of a consecutive run from one sender is tailed —
    /// the rest are plain rounded rectangles. That is the reference's rule, and
    /// it is what stops a burst of four replies looking like four separate
    /// interruptions.
    var hasTail: Bool = true

    func path(in rect: CGRect) -> Path {
        // The contour extends this far past the wall, so the strip is reserved
        // inside the frame and a tailed bubble lines up with an untailed one.
        let reach: CGFloat = 6.2

        let body = CGRect(
            x: isMine ? rect.minX : rect.minX + reach,
            y: rect.minY,
            width: max(0, rect.width - reach),
            height: rect.height
        )
        let r = min(radius, min(body.width, body.height) / 2)

        guard hasTail else {
            var plain = Path()
            plain.addRoundedRect(
                in: body,
                cornerSize: CGSize(width: r, height: r),
                style: .continuous
            )
            return plain
        }

        // A point on the traced contour, given as an offset from the corner the
        // tail grows out of. `isMine` mirrors it horizontally.
        func p(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: isMine ? body.maxX + dx : body.minX - dx, y: body.maxY + dy)
        }

        // Where the contour rejoins the flat part of the bottom edge. Clamped so
        // a very narrow bubble cannot have its tail overrun its other corner.
        let joinX = -min(Self.contourStart, max(0, body.width - r - 2))

        var path = Path()
        // Start where the contour leaves the wall and go the long way round: up
        // the wall, over the top, down the far side, back along the foot.
        path.move(to: p(0, -Self.contourTop))
        path.addLine(to: CGPoint(x: isMine ? body.maxX : body.minX, y: body.minY + r))
        addCorner(&path, to: CGPoint(x: isMine ? body.maxX - r : body.minX + r, y: body.minY),
                  via: CGPoint(x: isMine ? body.maxX : body.minX, y: body.minY))
        path.addLine(to: CGPoint(x: isMine ? body.minX + r : body.maxX - r, y: body.minY))
        addCorner(&path, to: CGPoint(x: isMine ? body.minX : body.maxX, y: body.minY + r),
                  via: CGPoint(x: isMine ? body.minX : body.maxX, y: body.minY))
        path.addLine(to: CGPoint(x: isMine ? body.minX : body.maxX, y: body.maxY - r))
        addCorner(&path, to: CGPoint(x: isMine ? body.minX + r : body.maxX - r, y: body.maxY),
                  via: CGPoint(x: isMine ? body.minX : body.maxX, y: body.maxY))
        path.addLine(to: p(joinX, 0))

        // **The traced contour.** Sampled off a WhatsApp outgoing bubble at 3x —
        // the boundary of its lower-right corner, in points, relative to the
        // wall and the foot — then fitted with Catmull-Rom, which passes through
        // every sample and is C1 continuous by construction.
        //
        // This replaces the corner arc rather than sitting beside it. Every
        // earlier version *appended* a tail to a rounded rectangle, which always
        // leaves a junction to give the game away however the curves are tuned;
        // here the bottom edge, the notch, the tip and the flank are one
        // uninterrupted run of Béziers with no corner and no flat segment
        // between them.
        //
        // Absolute points, deliberately not scaled by `radius`: the reference's
        // own corner is 8.7pt where this app's is 15, and scaling the tail by
        // the larger radius would inflate it by two thirds.
        for c in Self.contour {
            path.addCurve(to: p(c.to.0, c.to.1),
                          control1: p(c.c1.0, c.c1.1),
                          control2: p(c.c2.0, c.c2.1))
        }
        path.closeSubpath()
        return path
    }

    /// The three untailed corners. A quadratic through the corner point is what
    /// `addRoundedRect` draws, and matching it keeps the tailed and untailed
    /// bubbles identical everywhere except the one corner.
    private func addCorner(_ path: inout Path, to end: CGPoint, via corner: CGPoint) {
        path.addQuadCurve(to: end, control: corner)
    }

    /// How far up the wall the contour begins, and how far along the foot it
    /// rejoins — both measured from the reference.
    private static let contourTop: CGFloat = 10
    private static let contourStart: CGFloat = 18

    private struct Segment {
        let to: (CGFloat, CGFloat)
        let c1: (CGFloat, CGFloat)
        let c2: (CGFloat, CGFloat)
    }

    /// Fitted to the traced samples; see `path(in:)`. Travelling from the foot,
    /// through the notch, round the tip, and up the flank to the wall.
    private static let contour: [Segment] = [
        Segment(to: (-16.67, -0.33), c1: (-17.78, -0.06), c2: (-18.22, -0.22)),
        Segment(to: ( -8.67, -0.67), c1: (-15.11, -0.44), c2: (-10.44, -0.44)),
        Segment(to: ( -6.00, -1.67), c1: ( -6.89, -0.89), c2: ( -6.89, -1.28)),
        Segment(to: ( -3.33, -3.00), c1: ( -5.11, -2.06), c2: ( -4.00, -2.94)),
        Segment(to: ( -2.00, -2.00), c1: ( -2.67, -3.06), c2: ( -2.67, -2.33)),
        Segment(to: ( +0.67, -1.00), c1: ( -1.33, -1.67), c2: ( -0.22, -1.28)),
        Segment(to: ( +3.33, -0.33), c1: ( +1.56, -0.72), c2: ( +2.44, -0.39)),
        Segment(to: ( +6.00, -0.67), c1: ( +4.22, -0.28), c2: ( +6.00, -0.17)),
        Segment(to: ( +3.33, -3.33), c1: ( +6.00, -1.17), c2: ( +4.06, -2.44)),
        Segment(to: ( +1.67, -6.00), c1: ( +2.61, -4.22), c2: ( +2.11, -4.89)),
        Segment(to: ( +0.00,-10.00), c1: ( +1.22, -7.11), c2: ( +0.55, -9.33)),
    ]
}

/// One message. Mine on the right in sky blue, theirs on the left in grey, both
/// in white text — told apart by hue rather than by a tail, which is what the
/// reference does and what survives being read at a glance.
struct MessageBubble: View {
    let message: ChatService.Message
    let isMine: Bool
    /// The width of the row this sits in. See the `frame` in `body`.
    var containerWidth: CGFloat = 0
    /// First of a run from this sender. See `BubbleShape.hasTail`.
    var startsRun: Bool = true

    /// How much of the row a bubble may occupy before it wraps. The reference
    /// leaves a clear margin on the far side at every length.
    private static let maxWidthFraction: CGFloat = 0.78

    /// Blank space appended to the message so the clock has somewhere to sit.
    ///
    /// **This is why the time is not laid out beside the text.** An `HStack`
    /// puts the clock in its own *column*, which shortens every line of a long
    /// message by its width — the reference only gives up room on the **last**
    /// line. Padding the string and overlaying the clock into the gap reserves
    /// space exactly where it is needed, and lets it fall to a line of its own
    /// when the last line is already full.
    ///
    /// Figure spaces (U+2007), not ordinary ones: they are the width of a digit
    /// and, unlike a normal space, are not collapsed or trimmed at a line break.
    ///
    /// Seven of them, sized for the **widest** clock rather than a typical one —
    /// `12:34 PM` is a good deal wider than `9:16 PM`, and the gutter is fixed
    /// while the string is not. Six fitted the single-digit hours in the sample
    /// thread and would have started clipping after noon.
    private static let timeGutter = String(repeating: "\u{2007}", count: 7)

    /// Tightened from 20 with the padding. Once a bubble hugs a two-word
    /// message, a 20pt corner on a ~34pt-tall box is most of its height and the
    /// bubble reads as a pill; the reference keeps the corner well inside the
    /// bubble at every length.
    private static let radius: CGFloat = 15

    /// How far the tail reaches out from the body.
    private static let tail: CGFloat = 7

    /// Ink on gold, white on grey — see `GardenPalette.bubbleMineText` for the
    /// contrast measurements that force the difference.
    private var textColour: Color {
        isMine ? GardenPalette.bubbleMineText : GardenPalette.bubbleTheirsText
    }

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 0) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if message.isVoice {
                    // Asked first, because `AttachmentThumbnail` would try to
                    // decode an m4a as an image and draw the broken-file
                    // placeholder. A voice memo is a player, not a picture.
                    VoiceBubble(message: message, isMine: isMine)
                } else if message.attachmentPath != nil {
                    AttachmentThumbnail(message: message)
                }
                // A photo sent without a caption has an empty body, which the
                // `messages_have_content` constraint allows precisely so this
                // case exists. Drawing it would put an empty bubble under the
                // picture.
                //
                // A voice memo carries its length in the body and draws it
                // inside the player, so it must not also get a bubble of its
                // own saying "00:03" underneath.
                if !message.isVoice,
                   !message.body.trimmingCharacters(in: .whitespaces).isEmpty {
                    bubble
                }
            }
            // **An explicit ceiling, not a `Spacer` fight.**
            //
            // A flexible `Spacer` expands to fill and squeezes the content to
            // its compressed width, so long messages broke their lines at about
            // 190 points of an available 350 — narrow columns with half the row
            // empty beside them. `layoutPriority` did not settle it either.
            //
            // Naming the maximum does: the bubble takes what it needs up to this
            // and no more, so short messages still hug and long ones use the
            // width the reference gives them. Same `containerWidth` pattern
            // `DiscoveryCard` uses, and for the same reason — a child cannot ask
            // how wide its parent is.
            .frame(
                maxWidth: containerWidth * Self.maxWidthFraction,
                alignment: isMine ? .trailing : .leading
            )

            if !isMine { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let who = isMine ? "You" : "They"
        if message.attachmentPath != nil, message.body.isEmpty {
            return "\(who) sent a \(message.isVideo ? "video" : "photo")"
        }
        return "\(who) said: \(message.body)"
    }

    private var bubble: some View {
        Group {
            // **The bubble hugs its text, and the time rides the last line.**
            //
            // Both of those were wrong first time round. The text carried
            // `.frame(maxWidth: .infinity)`, which inflated every bubble to the
            // full available width — a two-word reply sat in a bubble three
            // times its size. And the time was stacked underneath, spending a
            // whole line on eleven points of type.
            //
            // `HStack(alignment: .bottom)` gives both: the row is only as wide
            // as it needs to be, so a short message makes a short bubble, and a
            // long one wraps with the time settling at the end of the last line.
            Text(message.body + Self.timeGutter)
                .font(.system(size: 15))
                .foregroundStyle(textColour)
                // Wrap, but never stretch — without this the text would rather
                // grow its own box than break a line.
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottomTrailing) {
                    Text(RelativeTime.clock(message.sentAt))
                        .font(.system(size: 11))
                        // "Grey" against each fill rather than one literal grey:
                        // a mid-grey on their mid-grey bubble would disappear.
                        // This is the bubble's own text colour, stepped back.
                        .foregroundStyle(textColour.opacity(0.55))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                // The strip the tail occupies. Without it the text would run to
                // the frame's edge and the tail would be drawn over the last
                // character of every line.
                .padding(isMine ? .trailing : .leading, Self.tail)
                .background(
                    isMine ? GardenPalette.bubbleMine : GardenPalette.bubbleTheirs,
                    in: BubbleShape(
                        isMine: isMine,
                        radius: Self.radius,
                        tail: Self.tail,
                        hasTail: startsRun
                    )
                )
                // A shadow rather than a border, now that there is a photograph
                // underneath. An outline drawn on a busy background competes
                // with it; a shadow lifts the bubble off whatever it lands on
                // without adding a line of its own.
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                .fixedSize(horizontal: false, vertical: true)
                // Faded while in flight, the way a single tick means "sent, not
                // yet delivered" elsewhere. Subtle on purpose: it should read as
                // *not settled yet*, not as an error.
                .opacity(message.isPending ? 0.55 : 1)
        }
    }
}

/// A photo or video in a bubble.
///
/// **The URL is fetched, not built.** `chat-media` is private, so an object has
/// no permanent address — asking for a signed one *is* the permission check, and
/// it fails for anybody not in the conversation. That is also why this cannot be
/// an `AsyncImage` over a stored link: there is no stored link.
///
/// Signing once per appearance rather than caching the URL: the signature lasts
/// an hour, and a thread left open longer than that would otherwise start
/// showing broken images with no way to tell why.
struct AttachmentThumbnail: View {
    let message: ChatService.Message

    /// Seeded from disk in `init`, so a photo that has been seen once is on the
    /// very first frame. `.task` runs after that frame, which is why the cache
    /// is read here and not there — the same reason `ConversationView` seeds its
    /// messages in `init`.
    @State private var image: UIImage?
    @State private var failed = false

    init(message: ChatService.Message) {
        self.message = message
        _image = State(
            initialValue: message.attachmentPath
                .flatMap { ChatStore.attachment(for: $0) }
                .flatMap(UIImage.init(data:))
        )
    }

    private static let maxWidth: CGFloat = 220
    private static let height: CGFloat = 260

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(GardenPalette.ink.opacity(0.06))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                // A video with no poster frame lands here too, and it is not an
                // error — see the note on `body` below.
                icon(message.isVideo ? "film" : "exclamationmark.triangle")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: Self.maxWidth, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            // A still with a play mark, not a player. One video decoder per
            // visible bubble is what the feed already refuses to do.
            if message.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.3), radius: 4)
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // A photo sent without a caption has no text bubble, so without this
            // it would be the one kind of message with no time on it.
            //
            // White with a shadow rather than a colour from the palette: this
            // sits on a photograph, and there is no fill underneath to pick a
            // readable tone against.
            Text(RelativeTime.clock(message.sentAt))
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 3)
                .padding(8)
        }
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .task {
            guard image == nil, let path = message.attachmentPath else { return }

            // **Videos are not fetched.** The object is an mp4, so downloading it
            // to draw a thumbnail would pull the whole file to show one frame —
            // and it is not an image, so nothing could decode it anyway. The
            // sender sees their own poster frame because it was filed against
            // this path when they sent it; the recipient gets the film mark
            // until poster frames are uploaded alongside the video. That gap is
            // real and is not a failure state.
            guard !message.isVideo else {
                failed = true
                return
            }

            guard let data = await MediaService.shared.data(for: path),
                  let decoded = UIImage(data: data)
            else {
                failed = true
                return
            }
            image = decoded
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .foregroundStyle(GardenPalette.muted)
    }
}

// MARK: - Typing

/// Three dots that rise in sequence, in a bubble shaped like one of theirs.
///
/// The sequence is the whole point: all three moving together reads as a pulse
/// and says "loading", where one after another reads as somebody working through
/// a sentence. That is a phase offset per dot, not three separate animations —
/// one `repeatForever` with a delay of a third of the cycle each.
struct TypingBubble: View {
    @State private var isAnimating = false

    private static let dot: CGFloat = 7
    private static let rise: CGFloat = 5
    /// One full trip for a single dot. The stagger below is a third of it, so the
    /// third dot lands as the first sets off again and the cycle never gaps.
    private static let period: Double = 0.9

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        // Ink, like the text it stands in for: this is one of
                        // their bubbles with the words not written yet. It was
                        // white while their fill was a mid grey; on the faint
                        // grey it would have been three invisible dots.
                        .fill(GardenPalette.bubbleTheirsText.opacity(0.45))
                        .frame(width: Self.dot, height: Self.dot)
                        .offset(y: isAnimating ? -Self.rise : 0)
                        .animation(
                            .easeInOut(duration: Self.period / 2)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * Self.period / 3),
                            value: isAnimating
                        )
                }
            }
            .padding(.horizontal, 14)
            // Taller than the dots need, so they have somewhere to rise into and
            // the bubble does not change size as they move.
            .padding(.vertical, 12)
            // The same shape as one of their messages, tail included — it is
            // standing in for one.
            .padding(.leading, 7)
            .background(
                GardenPalette.bubbleTheirs,
                in: BubbleShape(isMine: false, radius: 15, tail: 7)
            )
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

            Spacer(minLength: 44)
        }
        // Started on appear rather than declared true, or the first frame draws
        // the dots already lifted and the animation begins halfway through.
        .onAppear { isAnimating = true }
        .accessibilityLabel("Typing")
    }
}

/// Where the unread band sits relative to the visible top of the thread.
///
/// Nil when the band is not in the view tree at all — `LazyVStack` builds only
/// near the viewport, so absence is the signal that it is far off screen rather
/// than a measurement that failed.
private struct UnreadBandOffset: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
