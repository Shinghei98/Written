import Foundation

/// One branch of the profile tree: a facet of the user's digital footprint.
///
/// `rawValue` is the invasiveness order, lowest first — asking what someone
/// listens to is the smallest thing we can ask for, so music is case zero.
///
/// **It is no longer the unlock order, and the two must not be confused.**
/// `allCases` is given explicitly below and the raw values stay where they are,
/// because `TreeSkeleton` derives each branch's attachment height from
/// `rawValue`. Anything asking "in what order does the user meet these?" reads
/// `allCases`; only the drawing reads `rawValue`. `TreeState.connectedModalities`
/// got this wrong for one build and sent music to the top of the stack the
/// moment it was connected.
///
/// Four, against an illustration with four stages — bare soil plus one per
/// connected modality — so the fourth does not grow the plant again. It lights
/// the badge on the bough instead, the shoot that was already drawn with a bud
/// at its tip and had no app behind it. A modality with no distiller behind it
/// yet is still declared here — the user should be able to see what is coming —
/// and `isAvailable` is what says whether it can actually be connected.
enum Modality: Int, CaseIterable, Identifiable, Hashable {
    case music
    case media
    case lifestyle
    case plans

    var id: Int { rawValue }

    /// **The unlock sequence, and it is deliberately not the declaration order.**
    ///
    /// `allCases` is what every part of the app reads as "the order these are
    /// connected in" — `TreeState.nextModality`, `shootModality`, the preview
    /// stepper — so giving it explicitly moves the sequence in one place.
    ///
    /// The declaration order and the raw values stay where they are, and that is
    /// the point rather than laziness. `TreeSkeleton` derives a branch's
    /// attachment height from `modality.rawValue`, so renumbering the cases would
    /// move the branches — and the plant is supposed to look exactly as it did.
    /// Reordering the *sequence* changes which badge stands for what; reordering
    /// the *cases* would change the drawing.
    static let allCases: [Modality] = [.plans, .media, .music, .lifestyle]

    /// The modalities actually put in front of somebody, in order.
    ///
    /// **`allCases` is still every modality, and that is the point of having
    /// two.** A branch that has been connected must keep resolving — its
    /// records need an owner (`owning(source:)`), its metrics need a slot
    /// (`TreeMetrics`), and the branch it already grew has to keep drawing.
    /// What `offered` decides is narrower: what gets asked for next.
    ///
    /// Anything answering "what am I offered, and in what order?" reads this;
    /// anything answering "what modalities exist?" reads `allCases`. Confusing
    /// them is how a hidden modality either reappears as a prompt or takes a
    /// connected user's branch away.
    static let offered: [Modality] = allCases.filter(\.isOffered)

    /// Whether this modality can be offered at all.
    ///
    /// **Everything is offered, and the hook is kept for the shape of the
    /// problem rather than for a current user.** Archiving normally happens in
    /// `sources` below — take a source out and it is never drawn, never
    /// connected, never distilled. That is the wrong lever when *every* source
    /// in a modality is gone, because the branch survives as a prompt for
    /// something with nothing behind it, and this is where that is answered.
    ///
    /// Media was archived here for build 25 and un-archived on 2026-08-07. The
    /// argument for hiding it was that YouTube's removal left Apple Podcasts
    /// alone standing for a whole branch; the argument against, which won, is
    /// that Podcasts is a live source and a branch with one source is still a
    /// branch. **Note what it costs**: the unresolved question on Podcasts is
    /// whether Apple auto-downloads episodes of followed shows, and if it does
    /// not, this branch is empty for nearly everybody who taps it.
    ///
    /// A hidden modality's shoot is drawn either way — it always had a bud at
    /// its tip and no app behind it — so hiding one takes the badge and leaves
    /// the stem, which reads as the drawing breaking rather than as growth
    /// being withheld.
    var isOffered: Bool { true }

    /// `DistilledRecord.source` values that feed this branch. Empty means the
    /// modality is declared for the shape of the tree but has no distiller yet.
    /// Whether a refused permission for this source is fixed in the Health app
    /// rather than in Settings.
    ///
    /// Health is the one permission not reachable from Written's own Settings
    /// page — it lives under Privacy & Security, or in Health under Profile ›
    /// Apps. Every other source's switch is on the app's page.
    var opensHealthApp: Bool { sources.contains("health") }

    /// Which sources each modality offers.
    ///
    /// **This array is the archive switch, and that is deliberate.** A source
    /// missing here is never drawn in `SourcePickerSheet`, never connected,
    /// never distilled and never synced — so taking one out is one line, and
    /// putting it back is one line, while its distiller, its OAuth provider and
    /// every read path that understands its rows stay compiled and correct.
    /// Deleting those instead would make restoring the source a rewrite.
    ///
    /// **`grep -rn "ARCHIVED-"` finds everything held back for the App Store
    /// build.** Two sources are, and for unrelated reasons:
    ///
    /// - **Spotify** — its Developer Terms forbid storing Spotify Content in a
    ///   third-party database, so it is the one source whose rows could never
    ///   be restored to a new device, and it cannot leave development mode
    ///   anyway (five testers; extended quota needs 250,000 monthly actives).
    ///   It was here for the data-collection beta only.
    /// - **YouTube** — needs Google OAuth verification and a quota extension,
    ///   which are weeks of review this build is not waiting for. Nothing about
    ///   the integration is wrong; see `CLAUDE.md` for the compliance work,
    ///   which stands and is what makes it liftable in one line.
    ///
    /// **The share sheet and the embedded player are not affected.** Those use
    /// public URLs and the IFrame player, never the Data API and never OAuth,
    /// so they need no verification and stay exactly as they are.
    var sources: [String] {
        switch self {
        // Order matters: this array drives the rows in `SourcePickerSheet` and
        // the marks in the "Connected to …" bars.
        //
        // Apple Music first: it is the one the product depends on, and the
        // picker draws these in order.
        // ARCHIVED-SPOTIFY — **lifted for the data-collection prototype.**
        // Spotify is offered alongside Apple Music so test users' listening can
        // be inspected together, and comes out again before the real launch.
        //
        // **It took two edits, not one**, and the second is the one to
        // remember when this is archived again: `AppShell` ran
        // `purgeArchivedSources()` on every launch, which deleted Spotify rows
        // locally *and* called `deleteSource` on the server. With the source
        // live that wiped the rows the moment they were distilled. That task is
        // suspended; restoring the archive means restoring it too.
        case .music: return ["apple_music", "spotify"]
        // ARCHIVED-YOUTUBE — `"youtube"` removed for the App Store build.
        //
        // **Lift it again to record Google's OAuth verification video**, which
        // has to show the consent screen and the data being used, and put it
        // straight back: the consent screen is in Testing, so anybody not on
        // the 100-account allowlist gets a 403 after a *successful* login,
        // which reads as the app being broken rather than as a source being
        // unavailable.
        //
        // Apple Podcasts is the **second source not in `written_api.xlsx`**,
        // after Apple Calendar — a podcast is hours of attention given to one
        // show over weeks, which is a stronger claim about a person than a
        // follow costs.
        case .media: return ["apple_podcasts", "youtube"]
        // Not in `written_api.xlsx` — the first source that isn't. A calendar
        // is where a bought ticket lands by itself: Eventbrite, Ticketmaster
        // and Dice all write the booking straight in, so an event someone paid
        // to attend arrives without them doing anything. See `CalendarDistiller`.
        // ARCHIVED-GOOGLE-CALENDAR — `"google_calendar"` removed for the App
        // Store build, for exactly the reason YouTube is: the consent screen is
        // in Testing, which allowlists 100 users, so a reviewer's Google account
        // is not on it and a *successful* login is followed by a 403. That is
        // worse than an absent row — it reads as the app being broken rather
        // than as a source being unavailable.
        //
        // **Nothing has to be swept behind it**, unlike Spotify: nobody has ever
        // connected this source, so there are no rows in Postgres owed to
        // anyone. And `disconnectAll()` still calls `googleCalendarOAuth.revoke()`,
        // which stays correct whether or not anybody can reach the source —
        // a grant that cannot be made is one the revocation simply never finds.
        //
        // `GoogleCalendarDistiller`, `OAuthProvider.googleCalendar`,
        // `AppConfig.googleCalendarScope` and the `google_calendar` case in
        // `GrowProfileView` all stay compiled and correct. Back in one line the
        // day verification lands.
        //
        // **Apple Calendar first, and Google Calendar sat behind it.** A Google
        // account added in iOS Settings already delivers its events through
        // EventKit, so for most people the second row would collect the same
        // dinner twice. It was here for the people whose calendar the device
        // cannot see at all.
        case .plans: return ["apple_calendar", "google_calendar"]
        case .lifestyle: return ["health"]
        }
    }

    var label: String {
        switch self {
        case .music: return "Music"
        case .media: return "Media"
        case .lifestyle: return "Lifestyle"
        // The case stays `.plans` and the label says "Events". Renaming the case
        // would touch every switch over `Modality` and every persisted raw value
        // for a word nobody sees — `label` is the only thing a user reads.
        case .plans: return "Events"
        }
    }

    var systemImage: String {
        switch self {
        case .music: return "music.note"
        case .media: return "play.rectangle"
        case .lifestyle: return "heart"
        case .plans: return "calendar"
        }
    }

    /// False for modalities that exist in the metaphor but can't be connected
    /// yet. They are still offered — the bar appears in its turn — with the
    /// button disabled, rather than the flow simply ending.
    var isAvailable: Bool { !sources.isEmpty }

    /// Human-readable list of the apps behind this branch, for the prompt card.
    var sourceLabels: [String] {
        sources.map(Modality.displayName(forSource:))
    }

    /// Sources whose *records* belong to this branch, which is not the same
    /// question as which sources a person can connect.
    ///
    /// `sources` drives the picker: one row each, one tap each. `music_library`
    /// has no row — it rides the Apple Music connect, because MusicKit and
    /// MediaPlayer share the "Media & Apple Music" grant and offering the device
    /// library as a separate button would be a second tap for a permission
    /// already given. But its rows are still music, and everything that asks
    /// "is this a music record" — the artist ban, the ranking, the fixtures —
    /// has to say yes.
    ///
    /// Splitting the two is what stops a striking-off from missing half the
    /// library: `applyingBans` read `sources` and would have left a banned
    /// artist's locally-held songs untouched.
    var recordSources: [String] {
        switch self {
        case .music: return sources + ["music_library"]
        default: return sources
        }
    }

    /// Which branch a source feeds. `nil` for a source no modality claims.
    static func owning(source: String) -> Modality? {
        allCases.first { $0.recordSources.contains(source) }
    }

    static func displayName(forSource source: String) -> String {
        switch source {
        case "youtube": return "YouTube"
        case "apple_music": return "Apple Music"
        case "apple_podcasts": return "Apple Podcasts"
        case "spotify": return "Spotify"
        case "health": return "Apple Health"
        case "apple_calendar": return "Apple Calendar"
        case "google_calendar": return "Google Calendar"
        default: return source
        }
    }

    /// The mark shown for a connected app, once its modality's bar says so.
    static func icon(forSource source: String) -> String {
        switch source {
        case "youtube": return "play.rectangle.fill"
        case "apple_music": return "music.note"
        case "apple_podcasts": return "mic.fill"
        case "spotify": return "waveform"
        case "health": return "heart.fill"
        case "apple_calendar": return "calendar"
        case "google_calendar": return "calendar.badge.clock"
        default: return "app"
        }
    }
}
