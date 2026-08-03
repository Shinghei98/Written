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
/// **The songs count is the whole point of the design, not a curiosity.** A
/// query that returns zero podcasts is indistinguishable from a library that
/// cannot be read at all, which is the same trap HealthKit set — a declined read
/// and an empty database give the identical answer. So this asks for songs too:
///
///     songs > 0, podcasts = 0  ->  the library is readable and Podcasts is
///                                  genuinely not in it. Avenue closed.
///     songs = 0, podcasts = 0  ->  proves nothing. Authorization, or an empty
///                                  library. Run it on a phone with music on it.
///     podcasts > 0             ->  the avenue is open, and this becomes a real
///                                  distiller.
///
/// Run with `-probe podcasts` on the launch line, on a **device** — the
/// simulator's media library is empty, so it can only ever produce the
/// second, useless answer.
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
        if items.isEmpty && songs == 0 {
            verdict = "inconclusive — library empty, try a phone with music"
        } else if items.isEmpty {
            verdict = "closed — library readable, no podcasts in it"
        } else {
            verdict = "OPEN — podcasts are in the media library"
        }

        let line = "songs \(songs), podcast items \(items.count), shows \(shows) — \(verdict)"
        log.notice("probe verdict: \(line, privacy: .public)")
        return "Podcast probe: \(line)"
    }
}
#endif
