#if DEBUG
import Foundation
import MediaPlayer
import os

/// Does Apple Podcasts put anything in the media library?
///
/// **A throwaway, and it should be deleted the moment it has answered.** It
/// exists because the question decides whether podcasts can ever be a one-tap
/// source: `MPMediaQuery.podcasts()` is the exact analogue of what
/// `AppleMusicDistiller` does for songs, needs only the
/// `NSAppleMusicUsageDescription` already declared, and would be permanent and
/// frictionless if it worked. The belief is that it returns nothing — the
/// Podcasts app stopped writing to the media library around iOS 11 and keeps its
/// own container — but that belief is recollection, and recollection has been
/// wrong repeatedly in this project.
///
/// **A zero here has two confounds and the songs count only rules out one.**
///
///     podcasts > 0             ->  open. This becomes a real distiller.
///     podcasts = 0, songs = 0  ->  nothing learned. Unauthorized, or a library
///                                  with nothing in it at all.
///     podcasts = 0, songs > 0  ->  the library is readable — and still nothing
///                                  is learned unless the Podcasts app actually
///                                  holds something.
///
/// That third line was originally written as "closed", which is how a phone
/// whose Podcasts app had never been opened came to be recorded in CLAUDE.md as
/// proof that the framework does not expose podcasts. Songs come from the Music
/// library; podcasts would come from a different provider into the same one, so
/// one says nothing about the other. **Zero is a finding only when something
/// ought to have been found.**
///
/// So before running this: in Apple Podcasts, follow a show and **download an
/// episode**. The download is the part that matters — when Podcasts did populate
/// the media library it was downloaded episodes that appeared, not
/// subscriptions, so a test without one cannot tell "not exposed" from "nothing
/// local". Playing a minute of it also gives `playCount`, `lastPlayedDate` and
/// `bookmarkTime` something to report.
///
/// Run with `-probe podcasts` on the launch line, on a **device**. The
/// simulator's media library is empty and can only ever produce the second line.
enum PodcastProbe {

    private static let log = Logger(subsystem: "com.written.datingapp", category: "podcast-probe")

    /// Runs the query and returns a one-line summary for the on-screen banner.
    /// Everything else goes to the log, which survives the banner's dismissal.
    static func run() async -> String {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }

        guard status == .authorized else {
            let line = "media library not authorized (\(status.rawValue))"
            log.error("probe: \(line, privacy: .public)")
            return "Podcast probe: \(line)"
        }

        // The control. Without it a zero is unreadable.
        let songs = MPMediaQuery.songs().items?.count ?? 0

        let query = MPMediaQuery.podcasts()
        let items = query.items ?? []
        let shows = query.collections?.count ?? 0

        log.notice("probe: songs=\(songs, privacy: .public) podcastItems=\(items.count, privacy: .public) podcastCollections=\(shows, privacy: .public)")

        // Whatever came back, described in full — if this ever returns rows the
        // next question is immediately "which fields are populated?", and a
        // second device round trip to find out would be a wasted day.
        for item in items.prefix(10) {
            log.notice("""
                probe item: show=\(item.podcastTitle ?? "nil", privacy: .public) \
                episode=\(item.title ?? "nil", privacy: .public) \
                released=\(item.releaseDate?.description ?? "nil", privacy: .public) \
                duration=\(Int(item.playbackDuration), privacy: .public) \
                plays=\(item.playCount, privacy: .public) \
                lastPlayed=\(item.lastPlayedDate?.description ?? "nil", privacy: .public) \
                bookmark=\(Int(item.bookmarkTime), privacy: .public)
                """)
        }

        let verdict: String
        if !items.isEmpty {
            verdict = "OPEN — podcasts are in the media library"
        } else if songs == 0 {
            verdict = "inconclusive — library reads empty, try a phone with music"
        } else {
            // **This branch used to announce a closure, and it was wrong.** It
            // said "library readable, no podcasts in it", was run on a phone
            // whose Podcasts app had never been opened, and the conclusion was
            // written into CLAUDE.md as measured fact.
            //
            // The songs count rules out one confound — an unreadable or
            // unauthorized library — and says nothing about the other, because
            // songs arrive from the Music library and podcasts would arrive from
            // a different provider into the same one. Zero is only a *finding*
            // once there is something that ought to have been found.
            //
            // So it states its own precondition rather than a result. A probe
            // that can only be read correctly by somebody who remembers the
            // caveat is a probe that will be misread.
            verdict = "no podcast rows — CONCLUSIVE ONLY IF this phone has a "
                + "followed show with a DOWNLOADED episode. Otherwise this "
                + "means nothing; go and download one, then run again."
        }

        let line = "songs \(songs), podcast items \(items.count), shows \(shows) — \(verdict)"
        log.notice("probe verdict: \(line, privacy: .public)")
        return "Podcast probe: \(line)"
    }
}
#endif
