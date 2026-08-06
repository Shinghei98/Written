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

    @State private var preferences = DatingPreferencesStore.saved ?? DatingPreferences()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                GardenPalette.parchment.ignoresSafeArea()

                ScrollView {
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
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, Self.bannerHeight + 8)
                    .padding(.bottom, 48)
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
