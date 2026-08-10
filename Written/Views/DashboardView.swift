import SwiftUI
import UIKit

/// Where the garden leads: what the distillation actually found.
///
/// Laid out like the iOS Weather app, which is the reference for this screen —
/// a big bold title, two thin summary rows under it, then titled cards, each
/// labelled with a small icon beside its name. The palette stays Written's own
/// parchment and ink; only the structure is borrowed.
///
/// Everything here is read off `DistilledRecord`s already on the device. The
/// dating side of the product has no data behind it yet and is not mocked up.
struct DashboardView: View {
    @ObservedObject var viewModel: DistillViewModel

    /// Observed, not read statically. The name lives on the auth object rather
    /// than in the distillation, and a static `SupabaseAuth.shared.firstName`
    /// renders once and never again — so correcting it would have left the row
    /// showing the old name until the screen was rebuilt.
    @ObservedObject private var auth = SupabaseAuth.shared

    /// The six profile photographs. Bound from `RootView`, which owns them —
    /// the page that collects them runs before this screen exists.
    @Binding var photos: [PickedMedia?]
    var onBack: () -> Void = {}
    /// "Confirm" — `HomeView` slides this screen away to the profile previews.
    var onConfirm: () -> Void = {}
    /// Drops the session and everything this device remembers about the account.
    var onSignOut: () -> Void = {}

    /// Which half of the app this is, which decides what the page offers as a
    /// way *out* of it.
    ///
    /// Onboarding: no signing out and no deleting the account. Someone half way
    /// through setting up has not seen what any of it is for yet, and offering
    /// to destroy it beside the button that carries on is an invitation to end
    /// the thing by accident. Both stay reachable afterwards, where the account
    /// is a thing that exists rather than one being made.
    ///
    /// Regular use: no "Garden". The tab bar is the way back to it, and a second
    /// route in the corner is chrome for something already handled — during
    /// onboarding there is no bar, so it is the only way back and it stays.
    var isOnboarding = false
    /// Whether this tab is the one being looked at.
    ///
    /// Only used to send the page back to the top on returning to it —
    /// `DashboardTab` already tracks this for the location fix, so it is
    /// passed down rather than worked out again.
    var isVisible = true

    @State private var isShowingSettings = false
    @State private var isShowingBookmarks = false
    /// The four-page Memories tutorial, shown once.
    @State private var isShowingMemoriesTutorial = false

    /// How far the content has scrolled, negative as it rises. Drives the
    /// header's collapse.
    @State private var scrollOffset: CGFloat = 0

    /// Which single entry is wobbling, if any — keyed by kind and id so an
    /// artist and a channel of the same name can't both light up.
    ///
    /// One at a time, not the whole page: the press names the thing to edit,
    /// and arming its neighbours would put a delete button next to entries the
    /// user never pointed at.
    @State private var editingEntry: String?

    /// Which biographics row is being corrected, if any.
    @State private var editor: BiographicsEditor?

    /// Which "what did we miss" sheet is open, by the kind it asks about —
    /// "artist", "podcast". Nil is closed.
    @State private var favouriteKind: String?
    @State private var favouriteText = ""
    @FocusState private var isFavouriteFocused: Bool


    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                  VStack(spacing: 0) {
                    // **Above the header padding, deliberately.** Anchoring to
                    // the first section instead would scroll that section's top
                    // to the viewport's top — which is the *collapsed* position,
                    // with the photographs tucked under the pinned header. This
                    // sits before the padding, so "top" means offset zero.
                    Color.clear.frame(height: 0).id("top")

                    VStack(spacing: 14) {
                        photosSection
                            .id("photos")
                        identitySection
                        // Straight after the biographics, because it is one:
                        // the sliders say how to approach this person, which
                        // belongs beside their age and where they are rather
                        // than down among what their phone observed about them.
                        communicationSection
                            .id("communication")
                        // **One card per domain, not one per source.** Five
                        // cards named MUSIC / MEDIA / PODCASTS / EVENTS /
                        // LIFESTYLE were a picture of the plumbing; these are
                        // what the ontology concluded, with their owner standing
                        // over them. See `Ontology.terms`.
                        domainSections
                        // The readings, which are not terms — a chronotype has
                        // no entry behind it to agree with.
                        lifestyleSection
                            .id("lifestyle")
                        // **Onboarding only**, like the "Garden" button in the
                        // header and for the same reason. Confirm means "I am
                        // done building this, show me who I will see" — it is a
                        // step in a line that has one way forward. In regular
                        // use there is nothing to confirm: the page is a record
                        // you visit, the profile preview it led to is reachable
                        // from the tab bar, and a button that finishes something
                        // already finished is chrome.
                        // **Nothing follows it in regular use.** Sign out,
                        // Delete account and Disconnect all are all in
                        // Settings: they are account actions rather than
                        // things about this page, and the cog is where
                        // somebody looks for them.
                        //
                        // The YouTube pair went with them, replaced by
                        // *Disconnect all*, which does what they did and more.
                        // The Developer Policies' 7-day deadlines for a
                        // deletion request and an in-client revocation are
                        // still met — they require the user to have a way, not
                        // a per-source one.
                        if isOnboarding {
                            confirmButton
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    // Clear of the pinned header at its tallest; the content
                    // slides *under* it from there, as in the reference.
                    .padding(.top, Self.expandedHeaderHeight)
                    // **And clear of the tab bar at the bottom.** The bar
                    // overlays and never insets — that rule is why the garden's
                    // plant stays where it is — so every page that scrolls has
                    // to keep `MainTabBar.overlayHeight` free at its own
                    // bottom edge. Chat, Explore and the admirers list all do;
                    // Memories was the one that did not, and its last section
                    // sat under the bar.
                    //
                    // Derived rather than a round number near it: hardcoding 86
                    // once reserved 22 points more than the bar occupies, which
                    // on the garden was empty parchment the connected rows
                    // could have had.
                    //
                    // Not added during onboarding, where there is no bar — the
                    // whole point of that half of the app is that it has one way
                    // forward and no tabs to reach.
                    .padding(.bottom, isOnboarding ? 36 : 36 + MainTabBar.overlayHeight)
                  }
                }
                // How far the content has travelled, which is what the header
                // collapses against.
                .trackingScrollOffset { scrollOffset = $0 }
                // **Back to the top every time this tab is returned to.**
                // `AppShell` keeps all four tabs mounted, so a scroll position
                // survives leaving and coming back — somebody who scrolled to
                // their podcasts, went to Chat and returned found the page
                // where they left it rather than where it starts, and the
                // header collapsed with no obvious way to see the title again.
                //
                // Not animated: it is not a movement anybody watched happen,
                // and animating it would draw the eye to a scroll the user did
                // not perform.
                //
                // **Outside `#if DEBUG`, which is where it spent its whole
                // life.** It sat between two `-scroll` and `-bio` helpers
                // inside that block, so it worked every time it was tested —
                // from Xcode, in Debug — and shipped in no archive at all. A
                // conditional that compiles out a *feature* along with the
                // scaffolding around it is invisible until somebody installs a
                // Release build, which is exactly how it was found.
                .onChange(of: isVisible) { visible in
                    guard visible else { return }
                    proxy.scrollTo("top", anchor: .top)
                }
#if DEBUG
                // `-bio education`; see `DebugLaunch`. The rows only open to a
                // tap, which `simctl` cannot send.
                .onAppear {
                    guard let target = DebugLaunch.biographicsTarget,
                          DebugLaunch.firesOnce("bio") else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        switch target {
                        case "name": withAnimation { editor = .name }
                        case "birthday": withAnimation { editor = .birthday }
                        case "gender": withAnimation { editor = .gender }
                        case "place": withAnimation { editor = .place }
                        case "education": withAnimation { editor = .education }
                        case "occupation": withAnimation { editor = .occupation }
                        default: break
                        }
                    }
                }
                // `-edit 1`; see `DebugLaunch`.
                .onAppear {
                    if let target = DebugLaunch.editTarget, DebugLaunch.firesOnce("edit") {
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            // Stands in for the long press `simctl` cannot send.
                            let armed: String?
                            switch target {
                            // **Terms are uniform now**, so there is one way to
                            // arm a removal rather than one per source. `-edit
                            // sport` still names a domain because that is the
                            // one whose rows come from Health and look
                            // different; everything else takes the second term
                            // of the first card, which is the row the remove
                            // mark points at.
                            case "sport":
                                armed = viewModel.domainTerms
                                    .first { $0.domain == .playedSport }?
                                    .terms.first?.id
                            case "birthday":
                                withAnimation { editor = .birthday }
                                return
                            case "gender":
                                withAnimation { editor = .gender }
                                return
                            case "place":
                                withAnimation { editor = .place }
                                return
                            default:
                                armed = viewModel.domainTerms.first?
                                    .terms.dropFirst().first?.id
                            }
                            guard let armed else { return }
                            withAnimation(.easeOut(duration: 0.18)) { editingEntry = armed }
                        }
                    }
                }
                // `-scroll media`; see `DebugLaunch`.
                .onAppear {
                    guard let target = DebugLaunch.scrollTarget, DebugLaunch.firesOnce("scroll") else { return }
                    Task {
                        // This view is built with `HomeView`, long before the
                        // garden slides away, so it appears while the dashboard
                        // is still off screen. A single scroll is a race the
                        // screenshot loses about half the time — whether it is
                        // too early or too late depends on the run. Scrolling is
                        // idempotent, so ask a few times across the window
                        // instead of guessing one moment.
                        for delay in [0.4, 1.6, 2.6, 3.6] {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
#endif
            }

            // Over the scrolling content, on its own parchment: without it the
            // title slides under the status bar and the only way back goes with it.
            VStack(spacing: 0) {
                topBar
                header
            }
            .background(GardenPalette.parchment)
        }
        // A tap anywhere puts the armed entry away — the page is the "outside"
        // of whichever row is wobbling. Simultaneous rather than exclusive so
        // it doesn't swallow the cross: that button still fires, and its own
        // handler clears the same state.
        .simultaneousGesture(
            TapGesture().onEnded {
                guard editingEntry != nil else { return }
                withAnimation(.easeOut(duration: 0.18)) { editingEntry = nil }
            }
        )
        .overlay { biographicsSheet }
        .overlay { favouriteSheet }
        // Full screen rather than a sheet: settings is a place, not a decision,
        // and the sub-pages need a navigation stack of their own. The cross
        // inside dismisses the whole cover from any depth.
        .fullScreenCover(isPresented: $isShowingSettings) {
            SettingsView(
                viewModel: viewModel,
                onClose: { isShowingSettings = false },
                onSignOut: onSignOut
            )
        }
        // A cover rather than a tab, matching Settings. Bookmarks is somewhere
        // you go and come back from, not a fifth place to be — and the tab bar
        // has no room for it without demoting something that is.
        .fullScreenCover(isPresented: $isShowingBookmarks) {
            BookmarksView(
                viewModel: viewModel,
                onClose: { isShowingBookmarks = false }
            )
        }
        // **Four pages the first time somebody reaches Memories.**
        //
        // A cover rather than marks over the page itself: what it teaches is
        // three gestures, and a demonstration can perform a gesture where a
        // mark can only wait for one. It also cannot be wrong about what
        // somebody has connected, because it shows a fixture — the page behind
        // it may be empty on a phone that has distilled one calendar.
        //
        // Presented on `isVisible` rather than `onAppear`: during onboarding
        // `HomeView` builds this page under the garden from the first frame, so
        // `onAppear` fires long before anybody has pulled it up. That mistake
        // cost the coach marks their whole existence — they started against an
        // empty page and were never asked again.
        .fullScreenCover(isPresented: $isShowingMemoriesTutorial) {
            MemoriesTutorialView {
                Tutorial.Progress.completeMemories()
                isShowingMemoriesTutorial = false
            }
        }
        .onChange(of: isVisible) { visible in
            guard visible, isOnboarding, !Tutorial.Progress.hasSeenMemories else { return }
            isShowingMemoriesTutorial = true
        }
#if DEBUG
        .onAppear {
            if DebugLaunch.opensMemoriesTutorial, DebugLaunch.firesOnce("memories-tutorial") {
                isShowingMemoriesTutorial = true
            }
        }
#endif
#if DEBUG
        .onAppear {
            // `-settings 1`, and once only: `firesOnce` is what stops the page
            // reopening every time this view reappears behind it.
            if DebugLaunch.opensSettings, !isOnboarding, DebugLaunch.firesOnce("settings") {
                isShowingSettings = true
            }
        }
#endif
        // The one-time Memories tutorial, over the whole page. Started rather
        // than on a tab change, because during onboarding this page is reached
        // by the pull-up and there is no tab to change.
        // **Not `.onAppear`, which is the whole reason this never ran.** During
        // onboarding `HomeView` builds this page underneath the garden from the
        // first frame, so `onAppear` fires long before anything is distilled —
        // `events` is empty, the guard refuses, and nothing ever asks again. It
        // now starts when the Events card comes into view, which is also when
        // somebody is actually looking at the thing the marks describe.
        .preferredColorScheme(.light)
        // **The location fix is asked for by `DashboardTab`, not here.** This
        // was a `.task` on this view, and `AppShell` mounts every tab at launch
        // — so the district row's permission alert appeared over the *garden*,
        // seconds into a first run, from a screen the user had never opened.
        //
        // Which is worse than merely startling. A system alert owns the screen
        // while it is up, and HealthKit draws its own sheet by launching another
        // process and hosting a view from it: asked to present underneath this
        // one, it cannot, and gives up with "Authorization session timed out" —
        // no sheet, no refusal, nothing to react to. Connecting Apple Health as
        // a first-time user failed for exactly this reason.
        //
        // See `DashboardTab.isVisible`, which is the flag that already knows
        // whether this screen is the one being looked at.
    }

    /// Signs off on what was collected. The editing above is the reason this
    /// exists: having been given the chance to strike things off, the user says
    /// when the picture is right.
    private var confirmButton: some View {
        // Styled as the garden's "Dashboard" button is: the two are the same
        // kind of thing — the way on from a screen you have finished with — and
        // they should look it.
        Button(action: onConfirm) {
            Text("Confirm")
        }
        .buttonStyle(
            PressShrinkButtonStyle(
                fill: GardenPalette.card,
                foreground: GardenPalette.ink,
                border: GardenPalette.gold.opacity(0.35),
                expands: false,
                font: .system(size: 16, weight: .semibold),
                horizontalPadding: 26,
                minHeight: 48
            )
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: - Collapse

    /// What the content is inset by: the header at full height — 44 for the back
    /// bar, ~56 for the title, 76 for the summary, and the gaps. Fixed rather
    /// than measured, so the content never re-lays-out as the header shrinks;
    /// it simply slides underneath, which is what the reference does.
    private static let expandedHeaderHeight: CGFloat = 206

    /// How far the summary has to travel to be fully collapsed. Short enough
    /// that a flick finishes it, long enough not to snap.
    private static let collapseDistance: CGFloat = 90

    /// 0 at rest, 1 fully collapsed. Rubber-band overscroll reads negative and
    /// clamps to 0 rather than growing the header past its full size.
    private var collapse: CGFloat {
        min(max(scrollOffset / Self.collapseDistance, 0), 1)
    }

    // MARK: - Editing one entry

    private func key(artist: MusicHighlights.Artist) -> String { "artist:\(artist.id)" }
    private func key(channel: MediaHighlights.Channel) -> String { "channel:\(channel.id)" }
    private func key(sport: LifestyleHighlights.Sport) -> String { "sport:\(sport.id)" }
    private func key(show: ListeningHighlights.Show) -> String { "show:\(show.id)" }

    /// Strike the entry off and put the page back to rest — the thing that was
    /// wobbling no longer exists, so leaving edit mode armed would hand its
    /// cross to whichever entry moved up into that place.
    private func remove(_ ban: () -> Void) {
        ban()
        withAnimation(.easeOut(duration: 0.18)) { editingEntry = nil }
    }

    // MARK: - Header

    /// The way back, pinned. The page arrived by sliding up, so dragging it back
    /// down is the gesture people reach for first — the button is for everyone
    /// who doesn't.
    private var topBar: some View {
        HStack {
            // Onboarding only. In regular use the tab bar is the way back to
            // the garden, and a second route in the corner is chrome for
            // something already handled.
            if isOnboarding {
                Button(action: onBack) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Garden")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(GardenPalette.muted)
                    // A 44pt-tall target, not just the glyphs.
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the garden")
            }

            Spacer(minLength: 0)

            // The way out of editing. Tapping the page would be ambiguous here
            // — the entries themselves are the only thing to tap — so it is a
            // control, as the home screen's own Done is.
            if editingEntry != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { editingEntry = nil }
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GardenPalette.gold)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        // Its own height, not its contents'. Everything in this row is
        // conditional — the Garden button only during onboarding, Done only
        // while editing — so with both away the row collapsed to nothing and
        // took the title up 44 points with it. The bar reserves the space it
        // has always occupied whether or not anything is standing in it.
        //
        // Nothing below moves either way: the scrolling content is padded by
        // `expandedHeaderHeight`, a constant, so the biographics sit where they
        // always did.
        .frame(height: 44)
        .padding(.horizontal, 4)
        .background(GardenPalette.parchment)
        // Onboarding only, and for the same reason the button is: pulling down
        // to go back needs somewhere to go back *to*, and in regular use the
        // garden is a tab rather than a layer underneath.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { drag in
                    guard isOnboarding else { return }
                    if drag.translation.height > 40 { onBack() }
                }
        )
    }

    /// Bookmarks and Settings, overlaid on the title's trailing edge.
    ///
    /// **Its own property rather than inline in the overlay**, and that is not
    /// only tidiness: two buttons inside an `if` inside an `.overlay` on a
    /// modified `Text`, in a view this size, is where the type checker stops
    /// being able to infer the body in reasonable time. Extracting it gives the
    /// compiler a named return type to work against.
    ///
    /// Hidden during onboarding, with sign-out and delete: a settings page
    /// there is a fifth exit from a sequence whose whole point is that it has
    /// one. Bookmarks is hidden for that reason and a second — nothing is saved
    /// yet, so it could only ever be an empty room.
    ///
    /// **Does not fade with the collapse.** It used to, on the reasoning that it
    /// would otherwise sit over the summary line — but the header is pinned and
    /// the content scrolls under it, so these hold their place at every collapse
    /// value and nothing is behind them. What fading actually did was take the
    /// only route to Settings away from anybody who had scrolled, which is most
    /// people by the time they want it.
    @ViewBuilder
    private var headerControls: some View {
        if !isOnboarding {
            HStack(spacing: 0) {
                // **Inboard of the cog, and the order is not arbitrary.**
                // Settings is the last thing on every bar in every app; anything
                // added beside it goes inboard, or the one control people find
                // by muscle memory moves.
                Button { isShowingBookmarks = true } label: {
                    Image(systemName: "bookmark")
                        .font(.system(size: 18))
                        .foregroundStyle(GardenPalette.muted)
                        .frame(width: 40, height: 44)
                }
                .accessibilityLabel("Bookmarks")

                Button { isShowingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19))
                        .foregroundStyle(GardenPalette.muted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    /// Title, then the apps this profile was distilled from, then when.
    ///
    /// The title holds its size and place at any scroll position — as
    /// "Cupertino" does in the reference — and only the summary beneath it
    /// collapses: the big icon row and the date fold into one small line. The
    /// header shrinks but never leaves, so there is always something naming the
    /// screen.
    ///
    /// `headerControls` is an *overlay* on the title rather than a row beside
    /// it. "Memories" is centred and has to stay centred — putting the two in an
    /// `HStack` moves the title left by half the controls' width, which is
    /// visible against the collapsed header's own centring and would need a
    /// matching spacer on the other side to undo.
    private var header: some View {
        VStack(spacing: 14) {
            Text("Memories")
                .font(BrandFont.title(44))
                .foregroundStyle(GardenPalette.ink)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) { headerControls }

            // Cross-faded rather than re-laid-out: interpolating one stack's
            // spacing and icon size fights the layout system every frame, and
            // the two states want different arrangements anyway.
            ZStack {
                expandedSummary.opacity(Double(1 - min(collapse * 1.6, 1)))
                collapsedSummary.opacity(Double(max(collapse * 1.6 - 0.6, 0)))
            }
            .frame(height: 76 - 52 * collapse)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
    }

    private var expandedSummary: some View {
        VStack(spacing: 14) {
            if !connectedSources.isEmpty {
                HStack(spacing: 12) {
                    ForEach(connectedSources, id: \.self) { source in
                        AppMark(source: source, diameter: 42)
                            .accessibilityLabel(Modality.displayName(forSource: source))
                    }
                }
            }

            Text(lastReadLine)
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.muted.opacity(0.75))
        }
    }

    /// The same two facts on one line, the way the reference folds a
    /// temperature and a condition together.
    private var collapsedSummary: some View {
        HStack(spacing: 8) {
            ForEach(connectedSources, id: \.self) { source in
                AppMark(source: source, diameter: 20)
                    .accessibilityLabel(Modality.displayName(forSource: source))
            }

            if !connectedSources.isEmpty {
                Text("|").foregroundStyle(GardenPalette.muted.opacity(0.5))
            }

            Text(lastReadLine)
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted.opacity(0.75))
        }
    }

    private var connectedSources: [String] {
        Modality.allCases.flatMap { viewModel.connectedSources(for: $0) }
    }

    private var lastReadLine: String {
        guard let last = viewModel.lastCollectedAt else { return "Nothing distilled yet" }
        return "Last read: \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    // MARK: - Photos

    /// The six profile photographs, editable here the same way they were
    /// collected.
    ///
    /// The grid is `PhotoGrid`, the same view the photo page uses rather than a
    /// second one that looks like it — so picking, framing, the video branch and
    /// the 4:5 slot ratio all behave identically, and a change to any of them
    /// lands in both places at once.
    ///
    /// Three across rather than two: this is a card on a page of cards, not a
    /// page of its own, and at two the slots were taller than everything around
    /// them. The prompts are dropped for the same reason — by the time someone
    /// is on this screen the grid needs no explaining, and six lines of
    /// instruction would be the loudest thing on the page.
    private var photosSection: some View {
        card {
            cardLabel("PHOTOS", icon: "photo.on.rectangle")
            Divider().overlay(GardenPalette.ink.opacity(0.08))

            // **Recorded here, sent on the way out.** Onboarding waits for
            // Continue; this page has no such button, so the departure is the
            // button — see `AppShell`, which flushes on leaving the tab, on the
            // app going away, and before signing out. Staging rather than
            // sending means swapping a picture three times costs one upload.
            PhotoGrid(
                media: $photos,
                columns: 3,
                cornerRadius: 16,
                onEdit: { position, media in
                    viewModel.stagePhoto(media, at: position)
                }
            )
            .padding(.top, 12)
        }
    }


    // MARK: - Identity

    /// Age, sex and district — the three facts a profile leads with, and the
    /// only ones here the user didn't have to connect an app for.
    ///
    /// Slim rows, no charts: these are single values, and giving them a bar
    /// each would imply a comparison that doesn't exist.
    @ViewBuilder
    private var identitySection: some View {
        let identity = viewModel.identity
        // Always drawn, including when all three are unknown.
        //
        // It used to hide itself on an empty identity, and every row hid itself
        // individually too — which made these three facts unreachable for the
        // people most likely to need them. Health only carries a date of birth
        // and a sex if the user filled them in years ago, location is a separate
        // permission again, and the editors that let someone simply *type* the
        // answers could only be opened by tapping a row that existed only once
        // an answer was already there. Empty meant permanently empty.
        card {
            cardLabel("BIOGRAPHICS", icon: "person")
            Divider().overlay(GardenPalette.ink.opacity(0.08))

            VStack(spacing: 0) {
                // A button rather than `onTapGesture`: the page carries a
                // simultaneous tap recogniser for dismissing entry edits, and a
                // bare tap gesture has to compete with it. A button's hit
                // handling doesn't.
                Button { withAnimation(.easeOut(duration: 0.18)) { editor = .name } } label: {
                    identityRow(
                        icon: "person.text.rectangle",
                        text: auth.firstName ?? "Add your name",
                        isPlaceholder: auth.firstName == nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                identityDivider

                Button { withAnimation(.easeOut(duration: 0.18)) { editor = .birthday } } label: {
                    identityRow(
                        icon: "birthday.cake",
                        text: identity.age.map { "\($0)" } ?? "Add your age",
                        isPlaceholder: identity.age == nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                identityDivider

                Button { withAnimation(.easeOut(duration: 0.18)) { editor = .gender } } label: {
                    identityRow(
                        icon: identity.sex.map(Self.symbol(forSex:)) ?? "person.fill",
                        text: identity.sex ?? "Add your gender",
                        isPlaceholder: identity.sex == nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                identityDivider

                Button { withAnimation(.easeOut(duration: 0.18)) { editor = .place } } label: {
                    identityRow(
                        icon: "mappin.and.ellipse",
                        text: identity.place ?? "Set your location",
                        isPlaceholder: identity.place == nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                identityDivider

                Button { withAnimation(.easeOut(duration: 0.18)) { editor = .education } } label: {
                    identityRow(
                        icon: "graduationcap.fill",
                        text: identity.education ?? "Add where you studied",
                        isPlaceholder: identity.education == nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                identityDivider

                Button { withAnimation(.easeOut(duration: 0.18)) { editor = .occupation } } label: {
                    identityRow(
                        icon: "briefcase.fill",
                        text: identity.occupation ?? "Add your occupation",
                        isPlaceholder: identity.occupation == nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                identityDivider

                // Last of the rows, because it is the only one somebody writes
                // rather than answers — and the only one that goes nowhere
                // except a match's dynamic profile.
                Button { withAnimation(.easeOut(duration: 0.18)) { editor = .bio } } label: {
                    identityRow(
                        icon: "quote.bubble.fill",
                        text: identity.bio ?? "Add your bio",
                        isPlaceholder: identity.bio == nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
    }

    /// "What did we miss?" — the one place a person adds something their phone
    /// could not observe.
    ///
    /// Built on `BiographicsSheet` like every other sheet here, so it inherits
    /// the dimmed backdrop, the tap-outside-to-cancel and the confirm button's
    /// disabled state rather than reproducing them. `ReportSheet` does the same.
    @ViewBuilder
    private var favouriteSheet: some View {
        if let kind = favouriteKind {
            BiographicsSheet(
                // **Per kind, because "your favorite event" is not a
                // question.** A favourite artist is a standing preference; an
                // event is a thing that happened on a date, and asking somebody
                // to nominate their favourite one gets a different answer from
                // asking what the calendar missed — which is what this sheet is
                // for everywhere else too.
                // **One question now, because `kind` is a domain.** With the
                // cards named after domains the favourite phrasing breaks
                // everywhere ("your favorite Science?"), and the missed phrasing
                // was always the truer one: this sheet exists for what a phone
                // could not observe.
                title: "What did we miss?",
                subtitle: Ontology.Domain(rawValue: kind)
                    .map { "Anything in \($0.label.lowercased()) we didn't find." }
                    ?? "Tell us what we missed.",
                // Nothing to save is nothing to do — the same rule the report
                // sheet applies to an empty account of what happened.
                confirmEnabled: !favouriteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                confirmTitle: "Save",
                onConfirm: {
                    viewModel.addFavourite(kind: kind, favouriteText)
                    favouriteText = ""
                    withAnimation(.easeOut(duration: 0.18)) { favouriteKind = nil }
                },
                onCancel: {
                    // Discarded rather than kept: reopening the sheet to find
                    // somebody else's half-typed answer in it would be worse
                    // than typing it again.
                    favouriteText = ""
                    withAnimation(.easeOut(duration: 0.18)) { favouriteKind = nil }
                    // Cancelling counts. The mark asked somebody to look at the
                    // sheet, not to fill it in — a person who decides nothing
                    // was missed has done the step.
                }
            ) {
                // **The same field as the school and occupation sheets**, down
                // to the corner radius. It was a bare `TextField` on parchment,
                // so there was nothing to say where the writing went — the
                // caret sat in open space and the sheet read as a message
                // rather than a form. Two sheets that ask the same kind of
                // question should not answer it in two different shapes.
                TextField(kind.capitalized, text: $favouriteText)
                    .font(BrandFont.body(17))
                    .foregroundStyle(GardenPalette.ink)
                    .multilineTextAlignment(.center)
                    // Proper nouns more often than not — "Charli XCX",
                    // "Radiolab" — the same reasoning those sheets use.
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFavouriteFocused)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    .background(GardenPalette.parchment, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
                    }
            }
            .onAppear { isFavouriteFocused = true }
            .transition(.opacity)
        }
    }

    /// Whichever row is being corrected. Closing always goes through here, so
    /// the number pad can't be left holding first responder and eating the next
    /// tap on the page — which looks exactly like a row that stopped working.
    @ViewBuilder
    private var biographicsSheet: some View {
        switch editor {
        case .name:
            NameSheet(
                current: auth.firstName,
                onSave: { name in
                    // The sheet closes either way, and `upsertProfile` sets
                    // `firstName` only *after* the server accepts — so the row
                    // never shows a name that did not save.
                    //
                    // It used to swallow the throw with `try?`, which made a
                    // refused write indistinguishable from a dead button: the
                    // sheet closed and the row stayed on "Add your name". The
                    // error carries the status and PostgREST's own message, so
                    // it is reported through the same channel as the rows that
                    // own a column.
                    Task {
                        do {
                            try await auth.saveName(first: name, last: nil)
                            viewModel.saveError = nil
                        } catch {
                            viewModel.saveError =
                                "Couldn't save that — \(error.localizedDescription)"
                        }
                    }
                    closeEditor()
                },
                onCancel: closeEditor
            )
        case .birthday:
            BirthdaySheet(
                onSave: { month, day, year in
                    guard viewModel.setBirthday(month: month, day: day, year: year) else { return false }
                    closeEditor()
                    return true
                },
                onCancel: closeEditor
            )
        case .gender:
            GenderSheet(
                current: viewModel.identity.sex,
                onSave: { gender in
                    viewModel.setGender(gender)
                    closeEditor()
                },
                onCancel: closeEditor
            )
        case .place:
            PlaceSheet(
                initialCoordinate: nil,
                onLocate: { await viewModel.currentCoordinate() },
                onSave: { coordinate in
                    Task { await viewModel.setPlace(at: coordinate) }
                    closeEditor()
                },
                onCancel: closeEditor
            )
        case .education:
            FreeTextSheet(
                title: "Where did you study?",
                subtitle: "List every school that you have attended.",
                placeholder: "Schools",
                current: viewModel.identity.education,
                allowsMultipleLines: true,
                onSave: { schools in
                    viewModel.setEducation(schools)
                    closeEditor()
                },
                onCancel: closeEditor
            )
        case .occupation:
            FreeTextSheet(
                title: "What is your current occupation?",
                subtitle: "Put student if you are a student.",
                placeholder: "Occupation",
                current: viewModel.identity.occupation,
                onSave: { occupation in
                    viewModel.setOccupation(occupation)
                    closeEditor()
                },
                onCancel: closeEditor
            )
        case .bio:
            FreeTextSheet(
                title: "Attach a short bio for your matches",
                subtitle: "Limited to 30 letters.",
                placeholder: "Bio",
                current: viewModel.identity.bio,
                characterLimit: DistillViewModel.maximumBioLength,
                onSave: { bio in
                    viewModel.setBio(bio)
                    closeEditor()
                },
                onCancel: closeEditor
            )
        case nil:
            EmptyView()
        }
    }

    private func closeEditor() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        withAnimation(.easeOut(duration: 0.18)) { editor = nil }
    }

    private var identityDivider: some View {
        Divider().overlay(GardenPalette.ink.opacity(0.06))
    }

    /// One biographics line. `isPlaceholder` is the empty state — an invitation
    /// to add the value rather than the value itself, drawn lighter and with a
    /// chevron so it reads as somewhere to go.
    private func identityRow(icon: String, text: String, isPlaceholder: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(isPlaceholder ? GardenPalette.gold.opacity(0.5) : GardenPalette.gold)
                .frame(width: 24)

            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(isPlaceholder ? GardenPalette.muted : GardenPalette.ink)

            Spacer(minLength: 0)

            if isPlaceholder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GardenPalette.muted.opacity(0.6))
            }
        }
        .padding(.vertical, 9)
    }

    /// The first name the system actually has an image for.
    ///
    /// Asked rather than assumed: `mars` and `venus` are the obvious choice and
    /// this runtime has neither — 9,000-odd symbols and no gender marks — so the
    /// row rendered with a blank where the icon should be. `figure.stand.dress`
    /// is iOS 18, which this project can't require. Resolving at runtime beats
    /// a version table that has to be right about every OS the app meets.
    /// The card header's small mark, matching the large one beside it.
    ///
    /// Resolved at runtime with a fallback, the same way `symbol(forSex:)` is:
    /// a name absent on the running OS draws nothing at all, silently, which is
    /// how the "no apps available" state once shipped with a hole in it.
    private static func symbol(for phase: LifestyleHighlights.Phase) -> String {
        let candidates: [String]
        switch phase {
        case .dawn: candidates = ["sunrise", "sun.horizon"]
        case .morning: candidates = ["sun.max"]
        case .lateMorning: candidates = ["cloud.sun", "sun.haze"]
        case .night: candidates = ["moon"]
        }
        return candidates.first { UIImage(systemName: $0) != nil } ?? "clock"
    }

    private static func symbol(forSex sex: String) -> String {
        // Only the two the glyphs actually depict get a gendered figure. Drawing
        // "figure.stand" beside "Non-binary" or "Prefer not to say" would be the
        // icon contradicting the word next to it, so those take the neutral one.
        let candidates: [String]
        switch sex.lowercased() {
        case "female": candidates = ["figure.stand.dress", "figure.dress.line.vertical.figure"]
        case "male": candidates = ["figure.stand"]
        default: candidates = []
        }
        return candidates.first { UIImage(systemName: $0) != nil } ?? "person.fill"
    }

    // MARK: - The ontology, one card per domain

    /// What was found about somebody, grouped by what it says rather than by
    /// where it came from.
    ///
    /// **The page is a confirmation, not a report.** Every term here is the
    /// source's own string — an artist, a composer, a channel, a show, an event
    /// — placed under a domain by `Ontology.terms`. Leaving one alone is
    /// agreement; striking it off goes through the same `BanList` the entry rows
    /// always used, so it stops counting toward the mix, the discovery card and
    /// the icebreaker rather than merely disappearing from view.
    ///
    /// **This is the first screen that makes `classify`'s mistakes visible**,
    /// and that cuts both ways: it matches substrings, so "art" inside
    /// "Bartholomew" files a podcast under Art. Tolerable in a percentage, plain
    /// as day under a heading — which is the point of letting somebody remove it
    /// and the risk of showing it at all. Coverage against a real library has
    /// never been measured; this is what will measure it.
    @ViewBuilder
    private var domainSections: some View {
        ForEach(viewModel.domainTerms) { group in
            card {
                cardLabel(group.domain.label.uppercased(), icon: group.domain.systemImage)
                Divider().overlay(GardenPalette.ink.opacity(0.08))

                entryStack {
                    ForEach(Array(group.terms.enumerated()), id: \.element.id) { index, term in
                        if index > 0 { Divider().overlay(GardenPalette.ink.opacity(0.06)) }
                        termRow(term, peak: group.terms.first?.weight ?? 0)
                            .removable(editing: editingEntry == term.id, index: index) {
                                remove { viewModel.banTerm(term) }
                            }
                            .editableOnLongPress($editingEntry, key: term.id)
                    }
                    // What no phone could observe — the same rows the source
                    // cards gave their own additions, keyed by domain now.
                    ForEach(viewModel.favourites(kind: group.domain.rawValue), id: \.self) { name in
                        Divider().overlay(GardenPalette.ink.opacity(0.06))
                        ownRow(name)
                    }
                }

                Divider().overlay(GardenPalette.ink.opacity(0.08))
                addYourOwn(kind: group.domain.rawValue)
            }
            // `-scroll music`, `-scroll science`. The old anchors were named
            // after sources and those sections no longer exist.
            .id(group.domain.rawValue)
        }
    }

    /// One term: its picture where the source gave one, its name, and a bar
    /// saying how much of this domain it accounts for.
    ///
    /// **The peak is the domain's own top term, not a global maximum.** A bar
    /// says "less than that one" and nothing else out loud, so comparing a
    /// podcast against somebody's most-played artist would draw every domain but
    /// music as empty.
    private func termRow(_ term: Ontology.Term, peak: Int) -> some View {
        HStack(spacing: 12) {
            ArtworkTile(name: term.text, url: term.artworkURL, side: 40, corner: 8)

            Text(term.text)
                .font(.system(size: 16))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            ShareBar(fraction: peak > 0 ? Double(term.weight) / Double(peak) : 0)
                .frame(width: 96, height: 8)
        }
        .padding(.vertical, 9)
        // The count never reaches the screen, so it has to be in the label —
        // the bar carries it visually and says nothing to a screen reader.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(term.text), \(term.weight)")
    }

    // MARK: - Music

    /// The card's own horizontal padding, named because one thing now has to
    /// cancel it: the flirt dial divides *the card* into thirds, so it has to
    /// know the card's outer width rather than its content width.
    static let cardInset: CGFloat = 18

    /// How tall a stack of entries may get before it scrolls inside the card.
    ///
    /// The cards used to show six of everything and stop. Showing all of it
    /// makes some cards hundreds of rows long, which turns the page into a
    /// scroll through one person's music library — so the list scrolls within
    /// its own bounds and the page keeps its shape.
    ///
    /// Roughly five rows: enough that it plainly *is* a list and plainly has
    /// more in it, which is what makes somebody try to scroll it.
    private static let stackHeight: CGFloat = 232

    /// The scrolling half of a card: every entry, bounded.
    ///
    /// **Nested inside the page's own scroll view, which is a real cost.** Two
    /// vertical scrollers in the same gesture space means a drag that starts
    /// here does not move the page, and a fast flick can be caught by the wrong
    /// one. It is accepted because the alternative is worse: a card holding
    /// every artist somebody has ever played would be several screens tall, and
    /// the biographics below it unreachable.
    ///
    /// The placeholder is deliberately **not** in here — see `addYourOwn`. It
    /// belongs to the card, not to the list, and a row that scrolls away is a
    /// row nobody finds.
    @ViewBuilder
    private func entryStack<Content: View>(@ViewBuilder rows: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0, content: rows)
                // **Room for the remove badge, which hangs outside its row.**
                // `removable` puts the cross at the row's top-trailing corner
                // and then offsets it (8, -8) further out, so it reads as
                // attached to the entry rather than sitting inside it — and a
                // `ScrollView` clips to its bounds, so those 8 points were being
                // cut off. About half the circle survived on the trailing edge,
                // and the *first* row's badge lost its top the same way.
                //
                // Reserved here rather than by pulling the badge inward,
                // because the overhang is the design: a cross tucked inside the
                // row reads as part of the entry instead of as something
                // attached to it, which is the springboard idiom this borrows.
                //
                // Always, not only while editing — reserving it on entry to
                // edit mode would shift every row sideways at the moment the
                // badges appear.
                .padding(.top, RemoveBadge.overhang + 2)
                .padding(.trailing, RemoveBadge.overhang + 4)
        }
        .frame(maxHeight: Self.stackHeight)
        // Only when there is something to scroll. A short list inside a bouncing
        // scroller reads as broken — it springs under a finger that meant to
        // move the page.
        .modifier(NoIdleBounce())
    }

    /// The circle-and-cross under a stack: "we missed one, tell us".
    ///
    /// Pinned below the scrolling rows rather than at the end of them, because
    /// the end of a list of two hundred artists is somewhere nobody goes. It is
    /// the one control in these cards that adds rather than removes, and it is
    /// the only way anything a phone cannot observe gets into a profile.
    private func addYourOwn(kind: String) -> some View {
        Button {
            favouriteKind = kind
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(GardenPalette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a favourite \(kind)")
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, Self.cardInset)
            .padding(.vertical, 14)
            .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
            }
    }

    // MARK: - Media

    // MARK: - Podcasts, audiobooks, events

    private func key(event: ListeningHighlights.Event) -> String { "event-\(event.id)" }

    /// A row the person typed in rather than one their phone observed. Marked,
    /// because the two are different kinds of evidence and a card that blurred
    /// them would be claiming more than it knows.
    private func ownRow(_ name: String) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 16))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("you added")
                .font(.system(size: 11))
                .foregroundStyle(GardenPalette.muted)
        }
        .padding(.vertical, 9)
    }

    // MARK: - Lifestyle

    /// Three blocks: when the day starts, its shape, and what they do with it.
    ///
    /// The first two are half-width and share a row, as the reference pairs
    /// FEELS LIKE with UV INDEX — two small readings side by side say more than
    /// one wide one, and the sports list is the only part that needs the width.
    @ViewBuilder
    private var lifestyleSection: some View {
        let hasChronotype = viewModel.chronotype != nil
        let hasSteps = viewModel.averageDailySteps != nil && !viewModel.hourlyActivity.isEmpty

        // **The sports block has gone and the readings have not**, which is the
        // line between this section and the domain cards above. A sport is a
        // named thing somebody can confirm or strike off, so it is a term and
        // lives under SPORT. A chronotype is a *reading* — there is no entry
        // behind "You start at 06:40" to agree with — and neither is a step
        // average, so both would simply have been deleted along with the card.
        if hasChronotype || hasSteps {
            HStack(spacing: 14) {
                if hasChronotype { circadianCard }
                if hasSteps { stepsCard }
            }
            // Both halves stretch to the taller one, so their bottoms line up
            // the way the reference's pairs do.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The two onboarding sliders, paired the way circadian and steps are.
    ///
    /// Side by side because they answer one question between them — how this
    /// person wants to be talked to — and separating them would read as two
    /// unrelated facts. Both or neither: they are set together in one screen, so
    /// a row with one empty half would mean a bug rather than a gap.
    @ViewBuilder
    private var communicationSection: some View {
        if let flirt = viewModel.identity.flirtLevel,
           let response = viewModel.identity.responseTime {
            HStack(spacing: 14) {
                flirtCard(flirt)
                responseCard(response)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func flirtCard(_ level: FlirtLevel) -> some View {
        card {
            cardLabel("FLIRT LEVEL") { OverlappingHearts() }

            FlirtGauge(fraction: level.fraction, word: level.word)
                // **Out to the card's edges**, cancelling the padding every
                // other card keeps. The dial and its two captions are placed on
                // thirds of the card, so they have to measure the card — given
                // the content width instead they would land 6pt in from where
                // they belong, and the legs with them.
                .padding(.horizontal, -Self.cardInset)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func responseCard(_ time: ResponseTime) -> some View {
        card {
            cardLabel("RESPONSE TIME", icon: "metronome")

            Text(time.rawValue)
                .font(BrandFont.title(30))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(1)
                // "Prestissimo" is nearly twice "Largo", and the card is half a
                // phone wide. It shrinks rather than truncating: a clipped tempo
                // marking is unreadable, a small one is merely small.
                .minimumScaleFactor(0.5)

            Spacer(minLength: 10)

            Text(time.note)
                .font(.system(size: 12))
                .foregroundStyle(GardenPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var circadianCard: some View {
        if let chronotype = viewModel.chronotype {
            card {
                cardLabel("CIRCADIAN", icon: Self.symbol(for: chronotype.phase))

                VStack(spacing: 10) {
                    ChronotypeMark(phase: chronotype.phase)
                        .frame(width: 66, height: 66)

                    VStack(spacing: 2) {
                        Text(chronotype.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(GardenPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        // The spread matters as much as the middle: up at 07:00
                        // give or take ten minutes is a different life from
                        // averaging 07:00 across 05:00 and 09:00.
                        Text("~\(chronotype.wakeTime) ±\(spread(chronotype.spreadMinutes))")
                            .font(.system(size: 12))
                            .foregroundStyle(GardenPalette.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var stepsCard: some View {
        if let steps = viewModel.averageDailySteps {
            card {
                cardLabel("STEPS", icon: "figure.walk")

                Text(steps.formatted(.number))
                    .font(BrandFont.title(30))
                    .foregroundStyle(GardenPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("a day")
                    .font(.system(size: 12))
                    .foregroundStyle(GardenPalette.muted)

                Spacer(minLength: 10)

                StepCurve(shares: viewModel.hourlyActivity)
                    .frame(height: 52)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func spread(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// The card's own name, small and quiet above the rule — "DAILY FORECAST"
    /// in the reference.
    private func cardLabel(_ text: String, icon: String) -> some View {
        cardLabel(text) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
        }
    }

    /// The same label with a drawn glyph, for the ones SF Symbols hasn't got.
    ///
    /// The third such case in this app, after the message-in-a-bottle and the
    /// potted plant on the tab bar — and the same judgement: `heart.fill` alone
    /// is a *like*, which this row is not.
    private func cardLabel<Icon: View>(
        _ text: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 6) {
            icon()
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.8)
        }
        .foregroundStyle(GardenPalette.muted)
        .padding(.bottom, 12)
    }

    private var genres: [MusicHighlights.Genre] { viewModel.musicGenres }

    /// What the music is made of, as one bar rather than six. Unheaded: the
    /// card's own MUSIC label sits directly above it.
    private var genreBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let widths = segmentWidths(in: geometry.size.width)
                HStack(spacing: 0) {
                    ForEach(Array(genres.enumerated()), id: \.element.id) { index, genre in
                        Rectangle()
                            .fill(Self.genreTone(index))
                            .frame(width: widths[index])
                    }
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())

            // Two columns: six entries on one line truncate on a phone.
            legend
        }
    }

    private var legend: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(genres.enumerated()), id: \.element.id) { index, genre in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.genreTone(index))
                        .frame(width: 8, height: 8)

                    Text(genre.name)
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.softInk)
                        .lineLimit(1)

                    Text(percent(genre.fraction))
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)
                }
            }
        }
    }

    /// Each segment gets a floor of 6pt so a 2% genre is still a mark, and the
    /// rest of the bar is shared out by share. Handing every segment
    /// `width × fraction` and a `minWidth` instead would push the total past the
    /// bar's own width once a few small genres hit the floor.
    private func segmentWidths(in total: CGFloat) -> [CGFloat] {
        let floor: CGFloat = 6
        let floors = floor * CGFloat(genres.count)
        guard total > floors else {
            return genres.map { _ in total / CGFloat(max(1, genres.count)) }
        }
        let flexible = total - floors
        return genres.map { floor + flexible * CGFloat($0.fraction) }
    }

    /// One gold, stepped down in weight — not six hues. The card is parchment
    /// and ink with album art in the middle of it, and a rainbow here would take
    /// the eye off the covers.
    private static func genreTone(_ index: Int) -> Color {
        GardenPalette.gold.opacity(max(0.18, 1 - Double(index) * 0.16))
    }

    private func percent(_ fraction: Double) -> String {
        let value = Int((fraction * 100).rounded())
        return "\(max(1, value))%"
    }

}

private extension View {
    /// Reports how far a `ScrollView` has scrolled: 0 at rest, growing as the
    /// content rises.
    ///
    /// The old `GeometryReader` + `PreferenceKey` trick is what this replaces —
    /// measured against this SDK it never delivered a value at all, not even a
    /// constant, so the header simply never collapsed. Below iOS 18 the header
    /// stays at full height, which is the honest degradation: it is the summary
    /// that shrinks, and a screen that never shrinks it is merely roomier.
    @ViewBuilder
    func trackingScrollOffset(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                onChange(offset)
            }
        } else {
            self
        }
    }
}

/// The home-screen wobble, for anything that can be struck off.
///
/// Internal rather than private: the photo slots use it too, in both the
/// onboarding grid and this page's. One wobble, one cross, one long-press
/// duration — a second implementation would drift from this one on the first
/// tweak to either.
///
/// Each row is given a slightly different period and start phase. Sharing one
/// makes a list move as a single rigid sheet, which reads as a glitch rather
/// than as "these are loose now".
struct Jiggle: ViewModifier {
    let active: Bool
    let index: Int

    @State private var angle: Double = 0

    private var period: Double { 0.13 + Double(index % 3) * 0.012 }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onChange(of: active) { isActive in
                if isActive {
                    angle = -1.1
                    withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
                        angle = 1.1
                    }
                } else {
                    // Not animated back: a `repeatForever` animation has to be
                    // replaced, and easing to zero here leaves it running under
                    // the new one.
                    withAnimation(.linear(duration: 0.01)) { angle = 0 }
                }
            }
    }
}

/// The remove badge — a cross in a circle at the corner, as the old springboard
/// had it.
struct RemoveBadge: View {
    /// How far the badge hangs past the corner it is pinned to.
    ///
    /// **Two places have to agree about this number**, which is why it is one
    /// number: `removable` offsets the badge by it, and `entryStack` reserves
    /// that much padding so the enclosing `ScrollView` does not clip the
    /// overhang off. They disagreed, and about half the circle was cut away on
    /// the trailing edge of every row.
    static let overhang: CGFloat = 8

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(GardenPalette.card)
                .frame(width: 22, height: 22)
                .background(GardenPalette.ink.opacity(0.75), in: Circle())
                .overlay { Circle().strokeBorder(GardenPalette.card, lineWidth: 1.5) }
                // The circle is small; the tap target shouldn't be.
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove")
    }
}

extension View {
    /// Long press to make *this* entry editable. Pressing another entry hands
    /// the cross over rather than adding a second one.
    func editableOnLongPress(
        _ editing: Binding<String?>,
        key: String,
        onPress: @escaping () -> Void = {}
    ) -> some View {
        onLongPressGesture(minimumDuration: 0.45) {
            onPress()
            withAnimation(.easeOut(duration: 0.18)) {
                editing.wrappedValue = editing.wrappedValue == key ? nil : key
            }
        }
    }

    /// Wobble, and offer a cross at the top-right, while the dashboard is being
    /// edited.
    func removable(editing: Bool, index: Int, remove: @escaping () -> Void) -> some View {
        modifier(Jiggle(active: editing, index: index))
            // The whole row is the target, not just the artwork and glyphs.
            // Without this the gaps between a tile, a name and a bar are holes
            // the press falls through, and the entry only responds if you happen
            // to land on the album.
            //
            // Applied before the badge is overlaid, so the cross keeps its own
            // hit area — it hangs half outside this shape.
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if editing {
                    RemoveBadge(action: remove)
                        // Half off the corner, so it reads as attached to the
                        // entry rather than sitting inside it. `entryStack`
                        // reserves exactly this much padding so the enclosing
                        // `ScrollView` does not clip the overhang — the two
                        // numbers are the same number and must stay so.
                        .offset(x: RemoveBadge.overhang, y: -RemoveBadge.overhang)
                        // Drawn over the rows below it, not under them. Without
                        // this the badge for one row can slide beneath the next
                        // row's artwork, which is the same half-hidden cross by
                        // a different route.
                        .zIndex(1)
                        .transition(.scale.combined(with: .opacity))
                }
            }
    }
}

/// The sun for someone whose day starts early, the moon for someone whose
/// doesn't.
///
/// Drawn rather than an SF Symbol: the rest of this app is hand-made vector ink
/// on parchment, and a filled system glyph beside it reads as a control borrowed
/// from somewhere else.
/// One mark per chronotype band, tracing the sun's position when this person
/// gets up: below the horizon, up, high and soft, or not up at all.
///
/// Four silhouettes rather than four shades of the same one — at 66pt the only
/// difference a glance registers is outline, so the sun and the hazy sun are
/// distinguished by the cloud, not by ray length.
private struct ChronotypeMark: View {
    let phase: LifestyleHighlights.Phase

    private let gold = GardenPalette.gold.opacity(0.9)

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                switch phase {
                case .dawn: dawn(side: side, centre: centre)
                case .morning: sun(side: side, centre: centre, radius: 0.26, rays: true)
                case .lateMorning: hazy(side: side, centre: centre)
                case .night: crescent(side: side, centre: centre)
                }
            }
        }
    }

    /// A half disc on the horizon with rays only above it — the sun arriving.
    private func dawn(side: CGFloat, centre: CGPoint) -> some View {
        let horizon = centre.y + side * 0.20
        return ZStack {
            // Rays fan across the top half only; a full ring would read as the
            // midday sun sitting oddly low.
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(gold.opacity(0.85))
                    .frame(width: side * 0.05, height: side * 0.13)
                    .offset(y: -side * 0.33)
                    .rotationEffect(.degrees(-90 + Double(index) * 45))
                    .position(x: centre.x, y: horizon)
            }

            Circle()
                .fill(gold)
                .frame(width: side * 0.46, height: side * 0.46)
                .position(x: centre.x, y: horizon)
                // Clipped to what sits above the horizon line.
                .clipped(to: CGRect(x: 0, y: 0, width: side * 2, height: horizon))

            Capsule()
                .fill(gold)
                .frame(width: side * 0.78, height: side * 0.055)
                .position(x: centre.x, y: horizon)
        }
    }

    private func sun(side: CGFloat, centre: CGPoint, radius: CGFloat, rays: Bool) -> some View {
        ZStack {
            Circle()
                .fill(gold)
                .frame(width: side * radius * 2, height: side * radius * 2)
                .position(centre)

            if rays {
                // Eight rays, at the compass points.
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(gold.opacity(0.85))
                        .frame(width: side * 0.055, height: side * 0.16)
                        .offset(y: -side * 0.38)
                        .rotationEffect(.degrees(Double(index) * 45))
                        .position(centre)
                }
            }
        }
    }

    /// Sun behind a cloud — up, but a softer start than the full sun.
    ///
    /// The sun sits clear of the cloud's top edge with its own short rays. An
    /// earlier version tucked it almost entirely behind a wide cloud, and at
    /// 66pt the two merged into one lump with no readable silhouette.
    private func hazy(side: CGFloat, centre: CGPoint) -> some View {
        ZStack {
            let sunCentre = CGPoint(x: centre.x + side * 0.16, y: centre.y - side * 0.22)

            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(gold.opacity(0.8))
                    .frame(width: side * 0.042, height: side * 0.10)
                    .offset(y: -side * 0.235)
                    .rotationEffect(.degrees(-90 + Double(index) * 45))
                    .position(sunCentre)
            }

            Circle()
                .fill(gold)
                .frame(width: side * 0.30, height: side * 0.30)
                .position(sunCentre)

            // Three discs and a bar, unioned by overlap into one cloud. Narrower
            // than the mark so the sun stays visible over its shoulder.
            ZStack {
                Circle().frame(width: side * 0.26, height: side * 0.26)
                    .offset(x: -side * 0.13, y: 0)
                Circle().frame(width: side * 0.32, height: side * 0.32)
                    .offset(x: side * 0.03, y: -side * 0.04)
                Circle().frame(width: side * 0.22, height: side * 0.22)
                    .offset(x: side * 0.16, y: side * 0.01)
                Capsule().frame(width: side * 0.54, height: side * 0.19)
                    .offset(y: side * 0.07)
            }
            // Opaque first, then faded as one shape. Tinting each disc at 90%
            // and letting them overlap doubles the alpha where they meet, and
            // the cloud shows its own seams.
            .foregroundStyle(GardenPalette.gold)
            .compositingGroup()
            .opacity(0.9)
            .position(x: centre.x - side * 0.06, y: centre.y + side * 0.17)
        }
    }

    /// A disc with a second disc punched out of it.
    ///
    /// `.destinationOut` rather than an even-odd fill. Even-odd removes the
    /// *overlap*, which is right for the bite but also fills the part of the
    /// biting disc that hangs outside the main one — so the moon came with a
    /// stray arc off its right side. Punching a hole removes only what the
    /// second disc covers, wherever it happens to lie.
    private func crescent(side: CGFloat, centre: CGPoint) -> some View {
        ZStack {
            Circle()
                .fill(gold)
                .frame(width: side * 0.72, height: side * 0.72)
                .position(centre)

            Circle()
                .fill(.black)
                .frame(width: side * 0.62, height: side * 0.62)
                .position(x: centre.x + side * 0.20, y: centre.y - side * 0.09)
                .blendMode(.destinationOut)
        }
        // Without this the punch would cut through the card behind it too.
        .compositingGroup()
    }
}

private extension View {
    /// Clip to an explicit rect in the parent's coordinate space.
    func clipped(to rect: CGRect) -> some View {
        clipShape(Rectangle().path(in: rect))
    }
}

/// The day's activity as one continuous line over a horizon, after the arc on
/// the reference's sunset card — midnight at the left, 23:00 at the right.
private struct StepCurve: View {
    /// 24 values, 0…1, each hour's share of steps against the busiest hour.
    let shares: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let peak = shares.enumerated().max { $0.element < $1.element }?.offset

            ZStack {
                // The zero line the curve rises from. The reference's horizon
                // sits mid-card because a sun crosses it; steps have no
                // below-ground, so a baseline at zero is the honest analogue —
                // mid-height here would just be a rule the curve ignores.
                Rectangle()
                    .fill(GardenPalette.ink.opacity(0.10))
                    .frame(height: 1)
                    .offset(y: size.height / 2 - 5)

                CurvePath(shares: shares)
                    .stroke(
                        GardenPalette.gold,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                CurvePath(shares: shares)
                    .fill(
                        LinearGradient(
                            colors: [GardenPalette.gold.opacity(0.16), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if let peak, shares.indices.contains(peak) {
                    Circle()
                        .fill(GardenPalette.gold)
                        .frame(width: 7, height: 7)
                        .position(CurvePath.point(at: peak, of: shares, in: size))
                }
            }
        }
    }
}

/// The curve itself, smoothed so a day reads as one movement rather than 24
/// joined segments. Control points are placed halfway between neighbours —
/// enough to round the corners without the overshoot a spline would give on a
/// spiky hour.
private struct CurvePath: Shape {
    let shares: [Double]

    static func point(at hour: Int, of shares: [Double], in size: CGSize) -> CGPoint {
        let step = size.width / CGFloat(max(shares.count - 1, 1))
        // A little headroom top and bottom so the peak's dot isn't clipped.
        let usable = size.height - 10
        return CGPoint(
            x: CGFloat(hour) * step,
            y: size.height - 5 - CGFloat(shares[hour]) * usable
        )
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard shares.count > 1 else { return path }

        let points = shares.indices.map { Self.point(at: $0, of: shares, in: rect.size) }
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midX = (previous.x + current.x) / 2
            path.addCurve(
                to: current,
                control1: CGPoint(x: midX, y: previous.y),
                control2: CGPoint(x: midX, y: current.y)
            )
        }
        return path
    }
}

/// A count as a length rather than a number — songs for an artist, liked
/// videos for a channel.
///
/// Grown from the right edge leftward, so the bars share a baseline down the
/// right of the card and the eye compares their left ends. Anchored on the left
/// instead they would start at a different x on every row — the name beside them
/// is a different width each time — and the comparison would be unreadable.
private struct ShareBar: View {
    /// 0…1 against the longest bar on the card.
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(GardenPalette.gold)
                // A floor, so the smallest count is still a mark rather than
                // nothing at all.
                .frame(width: max(4, geometry.size.width * min(max(fraction, 0), 1)))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// An album cover, or the artist's initial when there isn't one.
///
/// There is no cover for records distilled before the distillers started
/// keeping image URLs, and none while the image is still loading, so the
/// monogram is the resting state rather than an error case.
private struct ArtworkTile: View {
    let name: String
    let url: URL?
    var side: CGFloat = 44
    var corner: CGFloat = 8

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var monogram: some View {
        ZStack {
            GardenPalette.gold.opacity(0.14)
            Text(String(name.prefix(1)))
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(GardenPalette.gold)
        }
    }
}

#Preview {
    DashboardView(viewModel: DistillViewModel(), photos: .constant(Array(repeating: nil, count: 6)))
}


