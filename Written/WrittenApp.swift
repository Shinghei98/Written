import SwiftUI

@main
struct WrittenApp: App {
    init() {
        BrandFont.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Decides which of the four screens the app is on: sign-in, the two onboarding
/// steps, or the garden.
///
/// Note the phone flow does not yet *verify* anything — `VerificationCodeView`
/// accepts any six digits and no text message is sent, because phone
/// verification is waiting on a backend. The TestFlight notes have to say so.
/// Sign in with Apple is the only route that proves anything.
struct RootView: View {
    /// The one screen showing, rather than four booleans that could disagree.
    ///
    /// Name and photos are cases here, not covers presented over `SignInView`,
    /// because a cover has to draw whatever is underneath it. Someone resuming
    /// on the photo page would get the sign-in screen behind it — which is the
    /// flash this routing exists to remove.
    enum Route {
        case signIn, name, photos, home
    }

    /// Seeded synchronously, so the first frame is already the right screen.
    ///
    /// Starting at `.signIn` and correcting after the token refresh was the
    /// two-to-four-second flash. Starting at `.home` whenever a session existed
    /// fixed the flash but skipped the rest of onboarding for anyone who had
    /// force-quit part way through it — they landed in the garden and were never
    /// asked their name again.
    @State private var route = RootView.initialRoute()
    @State private var isEnteringPhone = false
    @State private var signInError: String?

    private static func initialRoute() -> Route {
#if DEBUG
        switch DebugLaunch.forcedRoute {
        case "name": return .name
        case "photos": return .photos
        case "home": return .home
        case "signIn": return .signIn
        default: break
        }
#endif
        switch SupabaseAuth.restoredStep {
        case .name: return .name
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

        await SupabaseAuth.shared.restoreSession()
        // The server has the last word. The synchronous guess above assumed a
        // stored token still works and that the cached step is current; if the
        // token has been revoked they go back to sign-in, and if the profile
        // moved on elsewhere the route catches up here.
        guard SupabaseAuth.shared.isSignedIn else {
            route = .signIn
            return
        }
        route = Self.route(for: SupabaseAuth.shared.onboardingStep)
    }

    private static func route(for step: SupabaseAuth.OnboardingStep) -> Route {
        switch step {
        case .name: return .name
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
                AppShell(onSignOut: {
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
                        route = .photos
                    }
                }

            case .photos:
                PhotoEntryView(
                    onContinue: { _ in
                        // The bytes go no further than this screen yet, the same
                        // way names did before there was a profile table.
                        // Uploading needs a Supabase Storage bucket.
                        Task { await SupabaseAuth.shared.markPhotoStepSeen() }
                        route = .home
                    },
                    // Declining still counts as having been asked.
                    onSkip: {
                        Task { await SupabaseAuth.shared.markPhotoStepSeen() }
                        route = .home
                    }
                )

            case .signIn:
                signIn
            }
        }
        .animation(.easeInOut(duration: 0.2), value: route)
    }

    private var signIn: some View {
        // Pushed rather than presented: sign-up is a forward step in a flow,
        // so it slides in from the trailing edge and can be swiped back,
        // instead of rising from the bottom like a modal.
        NavigationStack {
            SignInView(
                onCreateAccount: { isEnteringPhone = true },
                onSignIn: { method in
                    switch method {
                    case .phone: isEnteringPhone = true
                    case .apple:
                        // The first sign-in that actually proves anything.
                        // Everything else here still sets a boolean.
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
                    case .google: route = .home
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
                    // The name is collected but has nowhere to go yet: there
                    // is no profile store. It gets sent from here once there is.
                    onSignedUp: { _, _, _ in
                        isEnteringPhone = false
                        route = .photos
                    }
                )
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}
