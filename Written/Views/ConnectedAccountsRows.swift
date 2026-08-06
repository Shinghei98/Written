import SwiftUI

/// Which sign-in methods reach this account.
///
/// **This row reports; it does not yet link.** Identity linking is a known gap
/// with a decision attached rather than a missing function: three sign-in
/// methods already mean one person can hold three accounts, which for a dating
/// app is a duplicate in the pool. Wiring a toggle that merges two accounts
/// before that is decided would be the most destructive control in the app.
///
/// So each provider shows whether it is the method this session was opened
/// with, and says plainly that adding a second is not available yet. **A row
/// that explains itself is not a placeholder** — the failure the settings work
/// is meant to remove is a control that looks live and does nothing, and this
/// one neither looks live nor pretends.
struct ConnectedAccountsRows: View {

    @ObservedObject private var auth = SupabaseAuth.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(
                name: "Google",
                icon: "g.circle",
                isConnected: auth.signInProvider == .google
            )

            Rectangle()
                .fill(GardenPalette.unreadBand)
                .frame(height: 1)

            row(
                name: "Apple",
                icon: "apple.logo",
                isConnected: auth.signInProvider == .apple
            )

            Text("You signed in with one of these. Connecting a second one to the same account is coming; until then, signing in with a different method creates a separate account.")
                .font(.system(size: 13))
                .foregroundStyle(GardenPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private func row(name: String, icon: String, isConnected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(isConnected ? GardenPalette.gold : GardenPalette.muted.opacity(0.5))
                .frame(width: 24)

            Text(name)
                .font(.system(size: 16))
                .foregroundStyle(GardenPalette.ink)

            Spacer(minLength: 8)

            Text(isConnected ? "Connected" : "Not connected")
                .font(.system(size: 14))
                .foregroundStyle(isConnected ? GardenPalette.gold : GardenPalette.muted)
        }
        .padding(.vertical, 12)
    }
}
