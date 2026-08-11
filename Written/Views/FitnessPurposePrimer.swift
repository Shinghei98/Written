import SwiftUI

/// What activity data is for, asked before iOS asks whether it may be read.
///
/// **Two different questions, and only one of them is Apple's.** HealthKit's
/// sheet asks for *access*; this asks what the data may be *used for*, which is
/// a separate answer with its own version string —
/// `FitnessPurposeGrantService.consentVersion` — recorded server-side. The
/// v0.3.1 contract gates HealthKit transfer on that grant, and the vault
/// refuses a HealthKit row without one.
///
/// **It must come before HealthKit's sheet, never beside it.** That sheet is a
/// remote view hosted by `com.apple.HealthPrivacyService`, and it gives up
/// rather than reporting a refusal if anything else owns the screen — which is
/// why every permission this app asks for near it is sequenced through
/// `.sheet(item:onDismiss:)` rather than a guessed delay. `NotificationPrimer`
/// is the same shape for the same reason.
///
/// **Declining costs nothing.** Health still connects, still distils, still
/// draws its card; the only thing withheld is the encrypted copy leaving the
/// device. A primer that broke the feature by being declined would be a
/// permission dialog wearing a friendlier hat.
struct FitnessPurposePrimer: View {
    let onAgree: () -> Void
    let onDecline: () -> Void

    var body: some View {
        BiographicsSheet(
            title: "Your activity, for you",
            subtitle: "Written keeps it encrypted and uses it to describe you to yourself.",
            dim: 0.42,
            confirmTitle: "Agree",
            onConfirm: onAgree,
            onCancel: onDecline
        ) {
            VStack(alignment: .leading, spacing: 14) {
                line("figure.walk", "When you move, and how often")
                line("lock.fill", "Encrypted before it leaves your phone")
                // **The refusals are the point of the sheet.** A consent screen
                // that only lists benefits is asking for agreement to something
                // unstated; these three are what the grant's four booleans are
                // set to false for, and they stay false until somebody is asked
                // a new question.
                line("xmark.circle", "Never used to match you with anyone")
                line("xmark.circle", "Never written into your bio or openers")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.badgeGold)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
