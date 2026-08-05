import SwiftUI

/// The app once onboarding is behind you: five tabs and a bar that floats over
/// all of them.
///
/// Every tab stays mounted. A `switch` would be less code and would tear the
/// garden down on every trip to Explore — replaying the plant's whole growth on
/// the way back and losing the animation state its badges and stem are pinned
/// to, which is the same reason `HomeView` keeps the garden alive under the
/// dashboard rather than swapping it out.
struct AppShell: View {
    /// Bound from `RootView`, which owns them: the photo page runs before this
    /// view exists, so the array cannot belong to the view model it feeds.
    @Binding var photos: [PickedMedia?]

    var onSignOut: () -> Void = {}

    /// One distillation, every tab. Owned here rather than by a tab, because the
    /// garden and the dashboard are now siblings — they used to be layers of one
    /// screen, which is what let that screen own it.
    @StateObject private var viewModel = DistillViewModel()

    /// Distill, not Explore. Someone arriving here has just finished growing
    /// their plant, and the first thing they should see is the thing they made.
    /// Reaching Explore is a deliberate move — the button on the profile
    /// preview, or the bar.
    @State private var tab: MainTab = .distill

    /// Which half of the app this is.
    ///
    /// Onboarding is a line, not a place you navigate: sign in, name, photos,
    /// grow the plant, meet the first person. A tab bar during it would offer
    /// four exits from a sequence whose whole point is that it has one. So the
    /// bar is absent until "Explore" is tapped, and the garden keeps the arrow
    /// and the pull-up that were its own way onward.
    ///
    /// Read once into state rather than observed: the answer only changes at the
    /// single moment `finishOnboarding` runs, and it decides the whole shape of
    /// the screen, so it should not be able to shift under a redraw.
    @State private var isOnboarding = SupabaseAuth.shared.onboardingStep != .done

    /// Where a tapped notification wants to go. Observed rather than owned —
    /// `PushDelegate` writes to it from outside the view tree entirely.
    @ObservedObject private var notifications = NotificationRouter.shared

    /// Whether the notification primer is on screen. See `NotificationPrimer`.
    @State private var isPrimingNotifications = false

    var body: some View {
        ZStack(alignment: .bottom) {
            GardenPalette.parchment.ignoresSafeArea()

            page(.explore) { DiscoveryView(viewModel: viewModel) }
            page(.wish) { ComingSoonView(tab: .wish, note: "A bottle you can put something in, and someone else can find.") }
            page(.chat) {
                ChatView(viewModel: viewModel, isVisible: tab == .chat, hidesTabBar: $isThreadOpen)
            }
            // **Before the garden, not after it.** The pull-up during onboarding
            // slides the garden off to reveal this underneath, and a ZStack
            // draws later children on top — so in the old order making the
            // dashboard visible mid-drag would have covered the very page being
            // pulled. Z-order between these two matters only while both are on
            // screen, which is only during that drag.
            page(.dashboard) {
                DashboardTab(
                    viewModel: viewModel,
                    photos: $photos,
                    onBack: { withAnimation(.easeInOut(duration: 0.35)) { tab = .distill } },
                    onExplore: finishOnboarding,
                    // Flushed first, while the token is still good: signing
                    // out drops the session and clears local state, so a staged
                    // photograph would go with nothing left to retry from.
                    onSignOut: {
                        Task {
                            await viewModel.flushPhotos()
                            // Withdrawn here for the same reason and in the same
                            // window: the row is deleted through RLS, so it needs
                            // the session that is about to be dropped. Left
                            // behind, the next like for this account arrives on a
                            // phone somebody else has since signed into.
                            if let token = PushDelegate.currentToken {
                                await PushService.shared.forget(token: token)
                            }
                            onSignOut()
                        }
                    },
                    isVisible: tab == .dashboard,
                    isOnboarding: isOnboarding
                )
            }
            page(.distill) {
                GrowProfileView(
                    viewModel: viewModel,
                    isOnboarding: isOnboarding,
                    isVisible: tab == .distill,
                    // Only ever used during onboarding — `canReveal` is false
                    // afterwards, so these are never called in regular use.
                    onRevealDrag: {
                        isRevealing = true
                        gardenLift = -$0
                    },
                    onRevealEnd: { committed in
                        guard committed else {
                            isRevealing = false
                            withAnimation(.easeInOut(duration: 0.4)) { gardenLift = 0 }
                            return
                        }
                        // Stays true through the commit animation below. It is
                        // cleared where the lift is, because for that third of a
                        // second the garden is deliberately displaced — and a
                        // background-and-return in that window would otherwise
                        // look like an abandoned drag and undo a pull that had
                        // already succeeded.
                        // Carry it all the way off, rather than dropping it back
                        // to zero as this used to. That was invisible while the
                        // dashboard only appeared at the end — but now that it
                        // is there from the first millimetre of the drag, a
                        // garden returning to its place would read as the pull
                        // having failed, at the exact moment it succeeded.
                        withAnimation(.easeInOut(duration: 0.34)) {
                            gardenLift = -revealTravel
                        }
                        // Then swap, once it has left. Both changes land in one
                        // tick and neither can be seen: the garden is already
                        // off-screen when it is hidden, and the offset it
                        // returns to is the offset of a hidden view.
                        //
                        // **`gardenLift` is zero at rest, always.** Leaving it
                        // parked off-screen would be one fewer moving part here
                        // and a trap everywhere else — every future route out of
                        // the dashboard would have to remember to reset it, and
                        // the one that forgot would show an empty garden tab.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                            tab = .dashboard
                            gardenLift = 0
                            isRevealing = false
                        }
                    }
                )
                .offset(y: gardenLift)
            }

            if !isOnboarding {
                MainTabBar(selection: $tab, isHidden: isThreadOpen)
                    .padding(.bottom, MainTabBar.bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Measured, not guessed, and in a `background` so it costs no layout
        // height — the one rule the bottom of this screen cannot bend, since
        // `promptsReserve` is what the plant is positioned against. A constant
        // tall enough for a Pro Max would leave an SE's garden gone long before
        // the animation ended; one sized for an SE would strand a Pro Max's
        // partway off. The slack covers the safe areas the ZStack excludes.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        revealTravel = proxy.size.height + 120
#if DEBUG
                        // `-reveal 0.5` on the launch line; see `DebugLaunch`.
                        if let fraction = DebugLaunch.revealFraction, isOnboarding {
                            gardenLift = -proxy.size.height * CGFloat(fraction)
                        }
#endif
                    }
                    .onChange(of: proxy.size.height) { revealTravel = $0 + 120 }
            }
        )
        // The onboarding sliders reach the record system here, because this is
        // the first moment a view model exists to put them in — they are
        // answered two screens before this view is built. Idempotent, and
        // `restoreFromServer` calls it again once the server's version lands.
        .task { viewModel.adoptStoredCommunicationStyle() }
        // **The grid starts empty on every launch**, because `photos` is state
        // on `RootView` and nothing ever read the account's own back. So the
        // pictures were in the bucket, on the discovery card, and absent from
        // the one screen their owner goes to look at them.
        //
        // Empty slots only, and never one with an edit waiting. Two races
        // otherwise: onboarding's freshly-picked array would be overwritten by
        // the server's copy of the same photographs, and one removed while its
        // download was in flight would come back.
        .task {
            // **Unsent work first.** A photograph staged and then lost to a
            // crash or a kill is the user's latest intent, so it goes back into
            // the grid before the server's older answer does — otherwise it
            // comes back missing, gets silently re-uploaded by the retry below,
            // and reappears, which reads as the app losing it and finding it.
            for (position, data) in viewModel.restorePendingPhotos() {
                guard let image = UIImage(data: data) else { continue }
                photos[position] = PickedMedia(
                    url: URL(fileURLWithPath: ""),
                    thumbnail: image,
                    isVideo: false,
                    cropRect: PickedMedia.fullFrame
                )
            }

            for slot in await PhotoService.shared.slots() {
                guard photos[slot.position] == nil,
                      !viewModel.hasPendingPhoto(at: slot.position),
                      let image = await ProfilePhotoCache.shared.image(at: slot.path)
                else { continue }
                // The same shape `PhotoGrid.load` builds for a photograph: the
                // thumbnail *is* the picture, so the url is unused.
                photos[slot.position] = PickedMedia(
                    url: URL(fileURLWithPath: ""),
                    thumbnail: image,
                    isVideo: false,
                    cropRect: PickedMedia.fullFrame
                )
            }

            // **Silent on an ordinary launch, not on the one after
            // onboarding.** A refusal about a photograph chosen in some earlier
            // session explains nothing the user can act on, and announcing it
            // every cold launch while offline is noise. But arriving here from
            // the photo page, these are pictures chosen seconds ago — that is
            // something they just did, and it is worth telling them it did not
            // land. The next departure they perform says so either way.
            await viewModel.flushPhotos(announcing: isOnboarding)

            // Nothing is *asked* here — see `registerIfAlreadyAllowed`. Somebody
            // who granted months ago is reachable only if every launch says
            // where they are, because a token can change without the app ever
            // being told.
            await PushService.shared.registerIfAlreadyAllowed()

            // A tap that launched the app arrives before this view exists, so
            // the destination is already waiting by the time we get here. Later
            // taps come through `onChange` below.
            openTabForNotification()

#if DEBUG
            // `-push ask`; see `DebugLaunch`. After the line above, so a device
            // that has already granted re-registers either way, and the ask only
            // does something on one that has not.
            if DebugLaunch.asksForPush, DebugLaunch.firesOnce("push") {
                try? await Task.sleep(nanoseconds: UInt64(DebugLaunch.pushDelay * 1_000_000_000))
                await PushService.shared.askIfNeeded()
            }
#endif
        }
        // One placement for every tab, rather than five that can disagree — the
        // same argument `isOnboarding` makes for owning the bar here.
        //
        // An overlay, so it costs no layout height and the garden underneath
        // does not move when it appears. `safeAreaInset` reads more naturally
        // and is precisely the modifier that would break `promptsReserve`.
        //
        // Offline first when both apply: "you're offline" explains the refusal
        // that follows it, and a PostgREST message underneath would only be the
        // same fact in worse words.
        // Over every tab, not inside one: it is raised by a tab *change*, so a
        // sheet owned by the arriving page would be racing its own appearance.
        .overlay {
            if isPrimingNotifications {
                NotificationPrimer(
                    onAllow: {
                        isPrimingNotifications = false
                        Task { await PushService.shared.askIfNeeded() }
                    },
                    onDismiss: {
                        isPrimingNotifications = false
                        Task { await PushService.shared.declinePrimer() }
                    }
                )
            }
        }
        .onChange(of: notifications.pending) { _ in openTabForNotification() }
        .onChange(of: tab) { moved in askForNotificationsIfDue(arrivingAt: moved) }
        .statusBanner(
            reachability.isOnline ? viewModel.saveError : "You're offline. Changes won't save.",
            isWarning: true
        )
        // **The guard for a drag that never ended** — see `gardenLift`. Becoming
        // active means nothing is touching the glass, so a lift still sitting
        // here belongs to a gesture that died rather than to one in progress.
        // Without an animation: this corrects a state that should never have
        // persisted, and sliding it back would perform an exit the user never
        // asked for and did not see begin.
        .onChange(of: scenePhase) { phase in
            // **`.inactive` as well as `.background`, and `.inactive` is the one
            // that matters.** Raising the app switcher makes the app inactive
            // *before* the swipe kills it, so this is what gives a force-quit
            // any chance at all; by `.background` it is usually too late. Firing
            // for a notification banner or Control Centre simply saves early.
            //
            // A crash or an instant kill can still lose a staged edit. That is
            // the accepted cost of batching rather than an oversight.
            //
            // The background assertion that keeps this alive is taken inside
            // `flushPhotos`, around the work rather than around the call — see
            // the note there. Held here, it protected a call that had already
            // been turned away by the re-entrancy guard.
            if phase != .active {
                Task { await viewModel.flushPhotos() }
            }

            guard phase == .active, !isRevealing, gardenLift != 0 else { return }
            gardenLift = 0
        }
        // The same invariant from the other side. Any route that lands on a tab
        // arrives with the garden in its place — so a future exit from the
        // dashboard cannot inherit a lift, which is the trap the commit path
        // already avoids by returning to zero rather than parking off-screen.
        .onChange(of: tab) { _ in
            // **Leaving Memories is the save.** Every exit changes `tab` — the
            // bar, the dashboard's back button, and the profile preview's
            // Explore button — so one place catches all of them. It fires on
            // arrival too, which costs nothing: only the dashboard can stage an
            // edit, so nothing is ever pending on the way in.
            Task { await viewModel.flushPhotos() }

            guard !isRevealing, gardenLift != 0 else { return }
            gardenLift = 0
        }
        // A refusal is a moment, not a state — unlike being offline, which ends
        // when it ends. Left up, it would still be there long after the row it
        // referred to had scrolled away.
        .onChange(of: viewModel.saveError) { message in
            guard message != nil else { return }
            Task {
                // Something just failed, which is the one moment worth spending
                // a request to find out whether the connection is real — the
                // path monitor calls a joined-but-dead network "satisfied", so
                // without this the offline banner stays hidden in exactly the
                // situation it was built for.
                await reachability.verify()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard viewModel.saveError == message else { return }
                viewModel.saveError = nil
            }
        }
#if DEBUG
        // `-tab explore` on the launch line; see `DebugLaunch`.
        .onAppear {
            guard let name = DebugLaunch.forcedTab, DebugLaunch.firesOnce("tab") else { return }
            switch name {
            case "explore":  tab = .explore
            case "wish":     tab = .wish
            case "chat":     tab = .chat
            case "dashboard": tab = .dashboard
            default:         break
            }
        }
#endif
    }

    /// How far the garden has been pulled up, during onboarding only. The
    /// dashboard is a sibling tab rather than a layer beneath, so this is the
    /// garden moving rather than a reveal of anything.
    ///
    /// **Zero at rest is an invariant, and nothing was enforcing it.**
    /// `onRevealDrag` writes this straight from `onChanged`, and `onRevealEnd`
    /// puts it back — but `DragGesture.onEnded` is not guaranteed to fire. Swipe
    /// up to the Home screen mid-pull, take a call, or let the bars' scroll
    /// gesture win (they are deliberately simultaneous), and the drag dies with
    /// no end. This is `@State`, so it survives backgrounding, and the app
    /// reopens with the whole page still displaced: the title under the status
    /// bar, the dashboard showing beneath. Reported as "when I open the app it
    /// often shows up as half-scrolled", which is exactly what a partial drag
    /// looks like.
    ///
    /// SwiftUI offers no `onCancelled`, so `scenePhase` is the guard — see
    /// `body`. Becoming active means no finger is on the glass, so resetting
    /// then can never interrupt a real drag.
    @State private var gardenLift: CGFloat = 0

    /// Set while a reveal drag is actually in progress, so the guard above can
    /// tell a live gesture from an abandoned one.
    @State private var isRevealing = false

    @Environment(\.scenePhase) private var scenePhase

    /// How far the garden must travel to be entirely gone. Set from the shell's
    /// own height; the initial value only stands for the frame before that
    /// arrives, and is generous rather than accurate on purpose — too far is
    /// invisible here, too short leaves a strip of the garden hanging.
    @State private var revealTravel: CGFloat = 1200

    /// Whether a conversation is covering the Chat tab.
    ///
    /// The bar draws *over* every page, so a thread's compose field would sit
    /// underneath it — and a bar offering four ways out of a conversation is the
    /// same mistake as a bar during onboarding, one level down. `MainTabBar.isHidden`
    /// already exists for "another gesture owns the bottom of the screen"; this is
    /// the second thing that does. Owned here rather than by `ChatView` for the
    /// reason `isOnboarding` is: the thing that hides the bar and the bar itself
    /// must not be able to disagree.
    @State private var isThreadOpen = false

    @ObservedObject private var reachability = Reachability.shared

    /// "Explore" on the profile preview: the one moment onboarding ends.
    ///
    /// Asks for notification permission on arriving at Explore or Chat.
    ///
    /// **It used to be asked on somebody's first admirer, and that was the
    /// wrong moment by exactly one event.** The question was put *after* the
    /// like or message that would have used it, so the first one anybody
    /// received could never notify them — reported as being asked only when the
    /// first message arrived, which is the feature working as built. Reaching
    /// Explore is the end of onboarding and the first moment somebody is
    /// discoverable, so it is the last point before a like is possible.
    ///
    /// **Keyed on the tab moving, not on a `.task`.** Every tab is mounted at
    /// once, so any `.task` here fires during start-up for everybody — which is
    /// the shape that stopped HealthKit's sheet drawing at all. A tab change is
    /// a deliberate move by somebody already looking at the app, and neither
    /// Explore nor Chat is where a source gets connected.
    ///
    /// One site rather than two: `PushService.askIfNeeded` handles asking once
    /// per launch and never re-asking somebody who has answered.
    ///
    /// **No `isOnboarding` guard, deliberately.** Neither tab is reachable
    /// during onboarding — there is no bar, and `finishOnboarding` is the only
    /// route to `.explore` — so the flag would add nothing except a race with
    /// itself: it and `tab` are set in the same transaction, and testing both
    /// makes the correct behaviour depend on which SwiftUI applies first.
    private func askForNotificationsIfDue(arrivingAt destination: MainTab) {
        guard destination == .explore || destination == .chat else { return }
        Task {
            // **The primer first, and iOS only for somebody who said yes.** The
            // system dialog is the one attempt this app will ever have, and
            // spending it cold means one distracted tap on "Don't Allow" ends
            // notifications for that account permanently.
            //
            // Anybody who has already answered iOS — either way — skips both:
            // a yes needs nothing, and a no is a decision this app does not
            // re-open with a sheet of its own.
            guard await PushService.shared.shouldPrime(),
                  await !PushService.shared.wasPrimerDeclinedRecently()
            else { return }
            // **After the transition, not during it.** `finishOnboarding`
            // animates for 0.45s, and a sheet arriving mid-slide covers the
            // discovery feed at the exact moment somebody tapped to see it.
            // This lets the page land first and then asks.
            try? await Task.sleep(for: .milliseconds(900))
            isPrimingNotifications = true
        }
    }

    /// Moves to Chat when a notification was tapped.
    ///
    /// **Only the tab.** Which admirer or which thread is `ChatView`'s to open,
    /// because it owns that navigation state and — more to the point — it may
    /// not have loaded the conversation yet. The router keeps the destination
    /// until somebody consumes it, so the two halves need no ordering between
    /// them.
    ///
    /// **Not during onboarding.** That is a line rather than a place you
    /// navigate: there is no tab bar, so switching would strand somebody on a
    /// page with no way back to the step they were on. Nobody has matches at
    /// that point either, so the destination is left pending and honoured the
    /// moment the shell becomes a tab bar.
    private func openTabForNotification() {
        guard notifications.pending != nil, !isOnboarding else { return }
        withAnimation(.easeInOut(duration: 0.25)) { tab = .chat }
    }

    /// The bar arrives and the garden gives up its arrow together, which is why
    /// both read the same flag rather than each deciding for itself.
    private func finishOnboarding() {
        SupabaseAuth.shared.markExplored()
        withAnimation(.easeInOut(duration: 0.45)) {
            isOnboarding = false
            tab = .explore
        }
    }

    /// Mounted always, shown when selected. `opacity` rather than `isHidden`
    /// because a hidden view still lays out, which is what keeps a tab's
    /// geometry stable while you are not looking at it.
    @ViewBuilder
    private func page<Content: View>(
        _ which: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Under `-solo 1` the other four tabs are not built at all. The three
        // modifiers below are what normally hides them, and XCUITest honours
        // none of them — see `DebugLaunch.auditsOneTabAtATime`. This changes
        // nothing outside an audit run: in Release the flag compiles to `false`.
        if isAuditingOneTab && tab != which {
            EmptyView()
        } else {
            content()
                .opacity(isDrawn(which) ? 1 : 0)
                // Still the selected tab, not merely the drawn one. Mid-pull the
                // dashboard is visible but must not take a tap, or a finger
                // travelling up the screen could press a row it is only sliding
                // past — and the garden is the page the gesture belongs to.
                .allowsHitTesting(tab == which)
                .accessibilityHidden(tab != which)
        }
    }

    /// Whether this page has to be on screen this frame, which is not the same
    /// as whether it is the selected tab.
    ///
    /// For one moment it isn't: during onboarding the garden is pulled up off
    /// the dashboard, so both are visible while `tab` still says `.distill`.
    /// Keying visibility on the selected tab alone is what made that pull reveal
    /// bare parchment — the dashboard did not appear until the gesture committed
    /// and flipped the tab, which is precisely when the reveal was already over.
    ///
    /// The same shape of bug as `DashboardTab` hiding the profile preview until
    /// its slide began: a layer needed *during* a transition, gated on a flag
    /// that only moves at the end of it.
    private func isDrawn(_ which: MainTab) -> Bool {
        if tab == which { return true }
        return gardenLift != 0 && (which == .dashboard || which == .distill)
    }

    /// Constant-folded away outside DEBUG, so the branch above costs a release
    /// build nothing.
    private var isAuditingOneTab: Bool {
#if DEBUG
        DebugLaunch.auditsOneTabAtATime
#else
        false
#endif
    }
}

/// A tab that exists on the bar before it exists as a screen.
///
/// Deliberately not a blank page: the bar has five icons from the first build so
/// its geometry never shifts, and an icon that leads nowhere with no explanation
/// reads as a bug rather than as something unfinished.
struct ComingSoonView: View {
    let tab: MainTab
    let note: String

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: tab.icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(GardenPalette.gold)
                Text(tab.label)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.muted)
                    .multilineTextAlignment(.center)
                Text("Not built yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GardenPalette.gold)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .overlay { Capsule().strokeBorder(GardenPalette.gold.opacity(0.35), lineWidth: 1) }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 44)
            .padding(.bottom, MainTabBar.overlayHeight)
        }
        .preferredColorScheme(.light)
    }
}
