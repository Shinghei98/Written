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

/// Sign-in is the entry point. "Create account" and "Sign in with Phone Number"
/// both lead to the phone step; the other providers drop straight into the
/// distillation screen until real accounts exist.
struct RootView: View {
    @State private var isSignedIn = true
    @State private var isEnteringPhone = false

    var body: some View {
#if DEBUG
        // `-stages all` swaps the whole app for the contact sheet; see `DebugLaunch`.
        if DebugLaunch.showsAllStages {
            StageSheet()
        } else {
            flow
        }
#else
        flow
#endif
    }

    @ViewBuilder
    private var flow: some View {
        if isSignedIn {
            HomeView()
        } else {
            // Pushed rather than presented: sign-up is a forward step in a flow,
            // so it slides in from the trailing edge and can be swiped back,
            // instead of rising from the bottom like a modal.
            NavigationStack {
                SignInView(
                    onCreateAccount: { isEnteringPhone = true },
                    onSignIn: { method in
                        switch method {
                        case .phone: isEnteringPhone = true
                        case .apple, .google: isSignedIn = true
                        }
                    }
                )
                .navigationDestination(isPresented: $isEnteringPhone) {
                    PhoneNumberView(
                        onClose: { isEnteringPhone = false },
                        // The name is collected but has nowhere to go yet: there
                        // is no profile store. It gets sent from here once there is.
                        onSignedUp: { _, _, _ in
                            isEnteringPhone = false
                            isSignedIn = true
                        }
                    )
                    .navigationBarBackButtonHidden(true)
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }
}
