import SwiftUI

/// Which sign-in methods reach this account, and the switches that change that.
///
/// **A phone number is the account; these are ways back into it.** Connecting
/// Apple or Google here is what makes those buttons work on the sign-in screen
/// — until then they refuse, by design, because an unlinked identity would
/// otherwise quietly become a second account for the same person.
///
/// State is read from the server rather than remembered here. A link made on
/// another phone is invisible to anything this one wrote down, and a toggle
/// that disagrees with the account is worse than no toggle at all.
struct ConnectedAccountsRows: View {

    @ObservedObject private var links = IdentityLinkService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(name: "Google", icon: "g.circle", provider: "google")

            Rectangle()
                .fill(GardenPalette.unreadBand)
                .frame(height: 1)

            row(name: "Apple", icon: "apple.logo", provider: "apple")

            Text("Connect an account to sign in with it next time. Your phone number is still what identifies you, and it can't be disconnected.")
                .font(.system(size: 13))
                .foregroundStyle(GardenPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            // **Said out loud rather than swallowed.** The commonest failure
            // here is not a bug but a project setting — manual linking off in
            // the Supabase dashboard — and a toggle that springs back with no
            // explanation is the defect this codebase has paid for repeatedly.
            if let error = links.lastError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.72, green: 0.18, blue: 0.16))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .task { await links.refresh() }
    }

    private func row(name: String, icon: String, provider: String) -> some View {
        let isLinked = links.linked.contains(provider)

        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(isLinked ? GardenPalette.gold : GardenPalette.muted.opacity(0.5))
                .frame(width: 24)

            Text(name)
                .font(.system(size: 16))
                .foregroundStyle(GardenPalette.ink)

            Spacer(minLength: 8)

            if links.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(GardenPalette.muted)
            } else {
                Toggle("", isOn: Binding(
                    get: { isLinked },
                    set: { wanted in
                        Task {
                            if wanted {
                                await links.link(provider: provider)
                            } else {
                                await links.unlink(provider: provider)
                            }
                        }
                    }
                ))
                .labelsHidden()
                .tint(GardenPalette.gold)
            }
        }
        .padding(.vertical, 12)
    }
}
