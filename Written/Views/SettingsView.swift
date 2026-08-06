import SwiftUI

/// Everything about the account that is not the profile itself.
///
/// **Reached from a cog on the Memories header and nowhere else**, and only
/// after onboarding — the same rule that hides sign-out and delete while
/// somebody is still building an account. A settings page during onboarding is
/// a fifth exit from a sequence whose whole point is that it has one.
///
/// Rises from the bottom as a `fullScreenCover` and pushes its sub-pages in
/// from the right, which is the arrangement iOS users read as "a place I went
/// into and can come back out of". The cross closes the whole thing rather than
/// popping one level: from three pages deep, tapping it returns to Memories.
struct SettingsView: View {

    @ObservedObject var viewModel: DistillViewModel
    let onClose: () -> Void
    /// Passed through from `AppShell` rather than reimplemented. That chain
    /// flushes staged photographs and forgets the push token *before* the
    /// session is dropped, and both would be lost by a second sign-out written
    /// here — the same reason `GrowProfileView` deliberately has none.
    let onSignOut: () -> Void

    @State private var preferences = DatingPreferencesStore.saved ?? DatingPreferences()
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                GardenPalette.parchment.ignoresSafeArea()

                ScrollView {
                    ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        profileSection
                        divider
                        preferencesSection
                        divider
                        safetySection
                        divider
                        accountsSection
                        divider
                        legalSection
                        divider
                        accountSection
                            .id("account")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, Self.bannerHeight + 8)
                    .padding(.bottom, 48)
#if DEBUG
                    // `-settings bottom` → open already scrolled to Sign out
                    // and Delete account. Same reason the dashboard has
                    // `-scroll`: those rows are below the fold on every phone
                    // and `simctl` cannot drag, so they are otherwise
                    // unscreenshottable. Asked more than once because the
                    // cover is still presenting when this first fires.
                    .onAppear {
                        guard DebugLaunch.scrollsSettingsToBottom,
                              DebugLaunch.firesOnce("settings-scroll") else { return }
                        Task {
                            for delay in [0.4, 1.2, 2.0] {
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                proxy.scrollTo("account", anchor: .bottom)
                            }
                        }
                    }
#endif
                    }
                }

                banner
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // Written the moment anything changes rather than on a Save button:
        // the sub-pages have their own Save, and the toggles on this page have
        // nothing to confirm. A settings screen that loses a switch because
        // somebody swiped away is the kind of bug nobody reports.
        .onChange(of: preferences) { _ in
            DatingPreferencesStore.save(preferences)
            viewModel.syncDatingPreferences(preferences)
        }
    }

    private static let bannerHeight: CGFloat = 56

    /// Title left, cross right. No back arrow — this is the root.
    private var banner: some View {
        HStack {
            Text("Settings")
                .font(BrandFont.title(28))
                .foregroundStyle(GardenPalette.ink)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GardenPalette.muted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close settings")
        }
        .padding(.horizontal, 20)
        .frame(height: Self.bannerHeight)
        .background(GardenPalette.parchment)
    }

    /// A rule rather than a gap, so the sections read as a list rather than as
    /// five cards. `unreadBand` is the palette's existing hairline — barely a
    /// shade against parchment, which is what a separator should be.
    private var divider: some View {
        Rectangle()
            .fill(GardenPalette.unreadBand)
            .frame(height: 1)
            .padding(.vertical, 18)
    }

    // MARK: - Sections

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("PROFILE")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pause")
                        .font(.system(size: 16))
                        .foregroundStyle(GardenPalette.ink)
                    Spacer()
                    Toggle("", isOn: $preferences.isPaused)
                        .labelsHidden()
                        .tint(GardenPalette.gold)
                }
                Text("Pausing prevents your profile from being shown to new users. However, your invitations sent remain valid, and you can still chat with your current matches.")
                    .font(.system(size: 13))
                    .foregroundStyle(GardenPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("DATING PREFERENCES")

            NavigationLink {
                GenderPreferenceView(selection: $preferences.gender)
            } label: {
                row("Gender preference", value: preferences.gender.label)
            }

            NavigationLink {
                MatchingRadiusView(miles: $preferences.radiusMiles)
            } label: {
                row("Matching radius", value: "\(preferences.radiusMiles) mi")
            }

            NavigationLink {
                AgeRangeView(minAge: $preferences.minAge, maxAge: $preferences.maxAge)
            } label: {
                row("Age range", value: "\(preferences.minAge)–\(preferences.maxAge)")
            }
        }
    }

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("SAFETY")

            NavigationLink {
                BlockListView(viewModel: viewModel)
            } label: {
                row("Block list", subtitle: "Block anyone who you do not wish to see your profile.")
            }

            NavigationLink {
                WordFilterView(viewModel: viewModel)
            } label: {
                row("Word filter", subtitle: "Block incoming invites with comments containing these words.")
            }
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("CONNECTED ACCOUNTS")
            ConnectedAccountsRows()
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("LEGAL")

            // **Contact information is not optional here.** Guideline 1.2
            // requires an app with user-generated content to publish a way to
            // reach the people who make it, alongside filtering, reporting and
            // blocking — and this app had all three of those and no address
            // anywhere in it. The website carried one; a reviewer looking in
            // the app would not have found it.
            link("Contact support", to: "mailto:hello@written-stl.com")
            link("Help and safety", to: "https://written-stl.com/en-us/support/")
            link("Privacy policy", to: "https://written-stl.com/en-us/privacy/")
            link("Terms of service", to: "https://written-stl.com/en-us/terms/")
            link("Licenses", to: "https://github.com/Shinghei98/Written")

            Button {
                // The same export the garden offers, reached from where
                // somebody actually looks for it. `AppShell` already hosts the
                // `.fileExporter` bound to `isExporterPresented`, so this only
                // has to prepare the document and raise the flag.
                viewModel.prepareExport()
            } label: {
                row("Download my data", value: nil, showsChevron: false, trailingIcon: "arrow.down.circle")
            }
        }
    }

    /// **No label, and that is the point.** Every other section here names a
    /// group of settings; these two are not settings at all, they are things
    /// that happen to the account. Centring them rather than using the leading
    /// `row(...)` treatment says the same thing a second way — a row with a
    /// chevron is somewhere to go, and these are not.
    private var accountSection: some View {
        VStack(spacing: 0) {
            Button("Sign out") { isConfirmingSignOut = true }
                .font(.system(size: 16))
                .foregroundStyle(GardenPalette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .confirmationDialog(
                    "Sign out?",
                    isPresented: $isConfirmingSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign out", role: .destructive) { signOut() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // Signing out does not disconnect anything: the
                    // connections, the ban list and the snapshot are stored per
                    // account, so they are still there on the way back in.
                    Text("Your connections stay as they are.")
                }

            Button {
                isConfirmingDelete = true
            } label: {
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(GardenPalette.muted)
                } else {
                    Text("Delete account")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(red: 0.72, green: 0.18, blue: 0.16))
                }
            }
            .disabled(isDeleting)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .confirmationDialog(
                "Delete your account?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your profile, your distillation and everything connected to it are erased. This can't be undone.")
            }
            .alert("Couldn't delete your account", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    /// **The cover comes down before the session does.** This page is a
    /// `fullScreenCover` over the dashboard, and signing out swaps the whole
    /// route underneath it — leaving a settings page floating over the sign-in
    /// screen it was never meant to cover.
    private func signOut() {
        onClose()
        onSignOut()
    }

    private func delete() {
        isDeleting = true
        Task {
            // Local first, and while still signed in: `AccountScope` reads the
            // stored user id to know which files and Keychain items belong to
            // this account, and after the session goes it would resolve to
            // `local` and clear the wrong ones.
            viewModel.deleteAccountLocalState()
            do {
                try await SupabaseAuth.shared.deleteAccount()
            } catch {
                // The server call throws only after the data itself is gone, so
                // this reports what survived rather than cancelling anything.
                deleteError = error.localizedDescription
            }
            isDeleting = false
            onClose()
            onSignOut()
        }
    }

    // MARK: - Pieces

    /// The same treatment as "PHOTOS" and "BIOGRAPHICS" on the Memories page,
    /// deliberately: this screen is a continuation of that one and should not
    /// introduce a second way of labelling a group.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(GardenPalette.muted)
            .padding(.bottom, 12)
    }

    private func row(
        _ title: String,
        value: String? = nil,
        subtitle: String? = nil,
        showsChevron: Bool = true,
        trailingIcon: String? = nil
    ) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(GardenPalette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.muted)
            }
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.gold)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GardenPalette.muted.opacity(0.6))
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func link(_ title: String, to urlString: String) -> some View {
        Button {
            guard let url = URL(string: urlString) else { return }
            UIApplication.shared.open(url)
        } label: {
            row(title)
        }
    }
}
