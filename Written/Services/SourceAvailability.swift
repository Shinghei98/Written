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

        // **Offered alongside Apple Calendar rather than instead of it.** This
        // used to be hidden where the phone already had a Google account, on
        // the argument that EventKit delivers those events anyway and the API
        // would collect each one twice.
        //
        // That was the wrong shape for this app. Every modality here reads
        // several apps as one — Apple Music beside Spotify, and now two
        // calendars — and harmonising them is the product rather than an
        // accident to be avoided. The duplication is real and is handled where
        // it matters: `ListeningHighlights.personalEvents` reads both sources
        // as one diary and dedupes on title and start, so a person sees each
        // event once and the derived counts are not doubled. The raw rows keep
        // both, because the ontology stage should see everything that was
        // found.

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
