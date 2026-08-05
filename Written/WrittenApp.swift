import SwiftUI

@main
struct WrittenApp: App {
    /// Only here because `didRegisterForRemoteNotificationsWithDeviceToken` has
    /// no SwiftUI equivalent — see `PushDelegate`. It takes over nothing else.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

    init() {
        BrandFont.register()
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            // At the root and in an alert, for the reason the podcast probe
            // learned: hung off a screen's `onAppear` it may never fire, and
            // reported through a self-dismissing banner it may never be read —
            // and both look exactly like a survey that found nothing.
            RootView().modifier(MediaSurveyAlert())
#else
            RootView()
#endif
        }
    }
}

#if DEBUG
/// Runs `MediaFieldSurvey` once on launch and holds the outcome on screen.
private struct MediaSurveyAlert: ViewModifier {
    @State private var outcome: String?

    func body(content: Content) -> some View {
        content
            .task {
                guard DebugLaunch.surveyTarget == "media",
                      DebugLaunch.firesOnce("survey") else { return }
                outcome = await MediaFieldSurvey.run()
            }
            .alert(
                "Media survey",
                isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
            ) {
                Button("OK", role: .cancel) { outcome = nil }
            } message: {
                Text(outcome ?? "")
            }
    }
}
#endif


/// Decides which of the screens the app is on: sign-in, the onboarding steps,
/// or the garden.
///
/// **Create account and both sign-in routes now make a real account.** This note
/// used to say the phone flow verified nothing — it accepted any six digits and
/// sent no message — and that stayed true long enough for testers to sign up
/// with it, reach the photo page with no session, and be told "You're not signed
/// in". Phone goes through Supabase's Twilio Verify provider now and returns the
/// same session Apple does.
///
/// **Google is the one that still does not**, and it says so rather than
/// pretending: it used to set `route = .home` outright, which is the same lie in
/// a shorter form. Supabase can do Google properly — a provider and an OAuth
/// client — and until that exists the button reports itself unfinished.
struct RootView: View {
    /// The one screen showing, rather than four booleans that could disagree.
    ///
    /// Name and photos are cases here, not covers presented over `SignInView`,
    /// because a cover has to draw whatever is underneath it. Someone resuming
    /// on the photo page would get the sign-in screen behind it — which is the
    /// flash this routing exists to remove.
    enum Route {
        case signIn, name, communication, photos, home
    }

    /// Seeded synchronously, so the first frame is already the right screen.
    ///
    /// Starting at `.signIn` and correcting after the token refresh was the
    /// two-to-four-second flash. Starting at `.home` whenever a session existed
    /// fixed the flash but skipped the rest of onboarding for anyone who had
    /// force-quit part way through it — they landed in the garden and were never
    /// asked their name again.
    @State private var route = RootView.initialRoute()
    /// The six photographs, owned here because they outlive the page that
    /// collects them: onboarding fills them and the dashboard corrects them
    /// afterwards, and the two screens live either side of the shell.
    ///
    /// They still go nowhere durable — see the photos gap in CLAUDE.md — so
    /// this is where they exist until something uploads them.
    @State private var photos: [PickedMedia?] = Array(repeating: nil, count: 6)
    @State private var isEnteringPhone = false
    @State private var signInError: String?

    private static func initialRoute() -> Route {
#if DEBUG
        switch DebugLaunch.forcedRoute {
        case "name": return .name
        case "communication": return .communication
        case "photos": return .photos
        case "home": return .home
        case "signIn": return .signIn
        default: break
        }
#endif
        switch SupabaseAuth.restoredStep {
        case .name: return .name
        case .communication: return .communication
        case .photos: return .photos
        // Both land on the shell. What differs is what the shell *shows* —
        // `exploring` keeps the tab bar away and leaves the garden its arrow.
        case .exploring, .done: return .home
        case nil: return .signIn
        }
    }

    var body: some View {
#if DEBUG
        // `-stages all` swaps the whole app for the contact sheet; see `DebugLaunch`.
        if DebugLaunch.showsAllStages {
            StageSheet()
        } else {
            flow.task { await restoreSession() }
        }
#else
        flow.task { await restoreSession() }
#endif
    }

    private func restoreSession() async {
        guard !hasRestored else { return }
        hasRestored = true
        guard SupabaseAuth.hasStoredSession else { return }

        let outcome = await SupabaseAuth.shared.restoreSession()

        // The server has the last word — **but only when it speaks.** The
        // synchronous guess above assumed a stored token still works; a refusal
        // corrects it, and silence must not. Sending somebody to sign in because
        // their phone is in airplane mode throws away a working session and
        // everything scoped to it, for a fact nobody established.
        switch outcome {
        case .unreachable:
            return
        case .rejected:
            route = .signIn
        case .restored:
            route = Self.route(for: SupabaseAuth.shared.onboardingStep)
        }
    }

    private static func route(for step: SupabaseAuth.OnboardingStep) -> Route {
        switch step {
        case .name: return .name
        case .communication: return .communication
        case .photos: return .photos
        case .exploring, .done: return .home
        }
    }

    /// Picks up a stored session before deciding which screen to show, so a
    /// returning user doesn't sign in twice — the same promise the OAuth sources
    /// make with their Keychain refresh tokens.
    ///
    /// Guarded so it runs once: `body` is re-evaluated on every state change,
    /// and a task keyed to nothing would re-fire on each.
    @State private var hasRestored = false

    private var flow: some View {
        Group {
            switch route {
            case .home:
                AppShell(photos: $photos, onSignOut: {
                    // **Before the session is dropped**, matching the rule the
                    // account-scoped stores follow: afterwards `AccountScope`
                    // resolves to `local` and clears the wrong things. This
                    // array is not one of those stores, but one ordering is
                    // easier to keep right than two.
                    //
                    // Nothing cleared it, and `@State` outlives a route change —
                    // so signing in as somebody else in the same launch showed
                    // them the previous account's photographs, which the
                    // hydration pass could never correct because it only fills
                    // slots that are empty.
                    photos = Array(repeating: nil, count: 6)
                    SupabaseAuth.shared.signOut()
                    route = .signIn
                })

            // Full screens in their own right. Both are reached two ways —
            // forwards from sign-up, and by resuming a session that stopped here.
            case .name:
                NameEntryView { first, last in
                    Task {
                        // Signed in either way. A name that fails to save is
                        // worth a complaint, not a locked door — the account is
                        // real and the profile row already exists.
                        try? await SupabaseAuth.shared.saveName(first: first, last: last)
                        route = .communication
                    }
                }

            case .communication:
                // Saved here rather than in the view, because storing the answer
                // is what marks the step done — `needsCommunicationStyle` reads
                // the store. Doing it anywhere else would let someone arrive at
                // the photo page and be asked their boundaries again next launch.
                //
                // Local and instant, like `setEducation`: these are `user`
                // records with no column behind them, so nothing here waits on a
                // network that onboarding has no business depending on. They
                // reach Postgres when the shell materialises them.
                CommunicationStyleView(initial: CommunicationStyleStore.saved ?? .unset) { style in
                    CommunicationStyleStore.save(style)
                    // Asked, not assumed. Someone reaching this page from
                    // sign-up goes on to the photos; someone who onboarded
                    // before this page existed has already seen them, and
                    // sending them there again would be a step backwards for
                    // answering a new question. `onboardingStep` knows which,
                    // and the save above is what moves it on.
                    route = Self.route(for: SupabaseAuth.shared.onboardingStep)
                }

            case .photos:
                PhotoEntryView(
                    onContinue: { picked in
                        // **Queued, not uploaded.** This page used to send them
                        // and persist nothing, so onboarding on a bad connection
                        // lost somebody's photographs without a word — the one
                        // place a first-time user is most likely to meet that.
                        // They go to `PendingPhotoStore` instead, and `AppShell`
                        // sends them the moment it appears, retrying at every
                        // launch until they land.
                        //
                        // **The staging is awaited and the route is not.** It is
                        // a JPEG encode and a file write, not a network round
                        // trip — fast enough not to feel like a hang, and the
                        // alternative is a race it would lose about half the
                        // time: `AppShell` reads the queue as it mounts, so a
                        // route change that outran the writing would find it
                        // empty and leave the photographs sitting until the next
                        // launch.
                        //
                        // **The card is not published here**, though it carries
                        // the paths. `publishDiscoveryCard` needs interests and
                        // a view model, neither of which exists yet — somebody
                        // on this page has connected nothing. It rides the first
                        // sync instead, which reads the paths back from the
                        // server precisely so the two need not be simultaneous.
                        Task {
                            await PhotoService.shared.stage(picked)
                            route = .home
                            // After the route, because it is a network call and
                            // nothing on the next screen waits for it.
                            await SupabaseAuth.shared.markPhotoStepSeen()
                        }
                    },
                    // Declining still counts as having been asked.
                    onSkip: {
                        Task { await SupabaseAuth.shared.markPhotoStepSeen() }
                        route = .home
                    },
                    media: $photos
                )

            case .signIn:
                signIn
            }
        }
        .animation(.easeInOut(duration: 0.2), value: route)
    }

    /// **One way in, and it is the only one that ever created an account.**
    ///
    /// This used to offer four routes. Three of them — "Create account", "Sign
    /// in with Phone Number" and "Sign in with Google" — authenticated nobody:
    /// the first two pushed `PhoneNumberView`, whose completion set
    /// `route = .photos` with no call to anything, and Google set `route =
    /// .home` outright. The phone screens were finished and never wired up,
    /// because Twilio was rejected on cost.
    ///
    /// What that did to a tester who took the biggest button on the screen:
    /// no session, so the photo page answered "You're not signed in"; no
    /// `route(for:)`, so the name and communication style steps were skipped;
    /// no `auth.users` row, so nothing they did could be saved and nobody could
    /// find them in Explore. The account was gone by the next launch, because
    /// `initialRoute()` reads the Keychain and nothing had been written to it.
    ///
    /// `NavigationStack` stays even with nothing to push: sign-in is still a
    /// forward step and `PhoneNumberView` goes back in here the day phone auth
    /// is bought rather than faked.
    private var signIn: some View {
        NavigationStack {
            SignInView(
                onCreateAccount: { isEnteringPhone = true },
                onSignIn: { method in
                    switch method {
                    case .phone:
                        isEnteringPhone = true
                    case .google:
                        // Real since the Google provider went in — it was
                        // `route = .home`, no account and no session, which is
                        // the same lie the phone flow told.
                        Task {
                            do {
                                try await SupabaseAuth.shared.signInWithGoogle()
                                route = Self.route(for: SupabaseAuth.shared.onboardingStep)
                            } catch OAuthPKCEService.OAuthError.cancelled {
                                // Closing the browser sheet is not a failure,
                                // the same way backing out of Apple's is not.
                            } catch {
                                signInError = error.localizedDescription
                            }
                        }
                    case .apple:
                        Task {
                            do {
                                try await SupabaseAuth.shared.signInWithApple()
                                // Apple gives a name on the first sign-in only,
                                // and lets the user withhold it — so a brand-new
                                // account often arrives with nothing to call
                                // them. Ask rather than carry an anonymous
                                // profile.
                                //
                                // Three separate questions, each off its own
                                // fact. Chaining photos to the name step meant an
                                // account that arrived already named — which is
                                // what Apple does on a first sign-in — skipped
                                // straight past the photo page forever. The same
                                // branch runs on relaunch, from the cached step.
                                route = Self.route(for: SupabaseAuth.shared.onboardingStep)
                            } catch SupabaseAuth.AuthError.cancelled {
                                // Backing out of Apple's sheet is not a failure.
                            } catch {
                                signInError = error.localizedDescription
                            }
                        }
                    }
                }
            )
            .alert("Couldn't sign in", isPresented: .constant(signInError != nil)) {
                Button("OK") { signInError = nil }
            } message: {
                Text(signInError ?? "")
            }
            .navigationDestination(isPresented: $isEnteringPhone) {
                PhoneNumberView(
                    onClose: { isEnteringPhone = false },
                    // **Routed from the step, never hardcoded.** This was
                    // `route = .photos`, which is what skipped the name and
                    // communication style pages for everyone who signed up by
                    // phone — and, because the flow had no session either, sent
                    // them to a photo page that could only answer "You're not
                    // signed in". `verifyOTP` has loaded the profile by the time
                    // this fires, so `onboardingStep` knows where they are.
                    onSignedIn: {
                        isEnteringPhone = false
                        route = Self.route(for: SupabaseAuth.shared.onboardingStep)
                    }
                )
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}
