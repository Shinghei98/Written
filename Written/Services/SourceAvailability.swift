import Foundation
import HealthKit

/// Whether a source can actually be connected on the device in hand.
///
/// The distinction that matters here, and the reason this isn't simply "is the
/// app installed": **a source needn't have its app.** YouTube authenticates
/// through OAuth in a browser sheet, so it works for someone who only ever
/// watches on a desktop, and it works in the simulator — which is exactly why
/// `CLAUDE.md` says it is the one you *can* test there. Hiding it for a missing
/// app would refuse a connection that would have succeeded.
///
/// What genuinely depends on the device is the two Apple frameworks: HealthKit
/// has no data on an iPad, and MusicKit cannot mint a developer token in the
/// simulator. Those are the ones worth hiding, because offering them would be
/// offering a button that cannot work.
enum SourceAvailability {

    static func isAvailable(_ source: String) -> Bool {
        switch source {
        case "health":
            // The framework's own answer, not a guess about an app icon. Note
            // this is `true` on iPad too since iPadOS 17 put the Health app
            // there — the check is about a Health *database* existing, which is
            // the thing the distiller needs, not about hardware.
            return HKHealthStore.isHealthDataAvailable()

        case "apple_music":
            // MusicKit mints its developer token from the signing identity, and
            // an ad-hoc-signed simulator build has none — the distiller fails
            // with "Failed to request developer token" every time. Offering it
            // there is offering a button that is known to fail.
            #if targetEnvironment(simulator)
            return false
            #else
            return true
            #endif

        case "google_calendar":
            // **Hidden where the phone already has the account.** A Google
            // account added in iOS Settings delivers its events through
            // EventKit as `caldav`, so `apple_calendar` already collects them —
            // and connecting this as well would put every dinner in the
            // database twice, under a different `item_id` and a different
            // `source`, which `append_source_records` dedupes within a source
            // and would not catch.
            //
            // So this is not a device capability like the two above; it is a
            // *redundancy* test, and it belongs here for the same reason they
            // do: the picker should not offer a row that cannot help.
            //
            // It is a drawing rather than a rule, which is why
            // `DistillViewModel.distillGoogleCalendar` guards it too —
            // somebody who adds the account to their phone after connecting
            // here would otherwise start collecting everything twice.
            return !CalendarDistiller.hasGoogleAccountOnDevice()

        default:
            // OAuth sources. The browser is the requirement, and every device
            // has one.
            return true
        }
    }

    /// The sources of a modality that this device can actually offer, in the
    /// modality's own order. Empty is a real answer and the picker says so.
    static func sources(for modality: Modality) -> [String] {
        modality.sources.filter(isAvailable)
    }
}
