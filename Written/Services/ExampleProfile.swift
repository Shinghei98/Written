import Foundation

/// The person the user is shown as an example of who they'll meet.
///
/// Synthetic — there is nobody to match with yet — but the *caption* is not:
/// every line is assembled from records already on the device, so what the
/// screen demonstrates is the actual mechanism rather than a mockup of it. The
/// two lines come from two different `Ontology` domains on purpose; see
/// `interestLine`.
struct ExampleProfile: Equatable {

    /// One example person: a handle and the photographs of them.
    ///
    /// Bundle filenames rather than asset-catalog names — these are loose
    /// resources under `Written/Resources/Assets/`, so `Image("name")` will not
    /// find them and `ExampleProfileCard` loads them by URL instead.
    struct PhotoSet: Equatable {
        let handle: String
        /// Two, shown as a carousel. Instagram posts carry several and one
        /// photograph of a stranger reads as a stock image; a second reads as
        /// somebody's account.
        let assets: [String]
        let fileExtension: String
    }

    static let femmeSet = PhotoSet(
        handle: "ella_w",
        assets: ["example_femme_1", "example_femme_2"],
        fileExtension: "png"
    )

    static let mascSet = PhotoSet(
        handle: "noah_r",
        assets: ["example_masc_1", "example_masc_2"],
        fileExtension: "png"
    )

    /// Which set to show, from what the user answered on "Who are you
    /// interested in?".
    ///
    /// **Masculine only when that is the whole answer.** Somebody interested in
    /// men *and* women is shown the feminine set rather than a second
    /// arbitrating rule, and somebody who has answered nothing gets it too —
    /// the screen has to draw a person either way, and defaulting to the branch
    /// that also covers "no answer yet" is one rule instead of three.
    static func photos(for interests: Set<DatingPreferences.Gender>) -> PhotoSet {
        interests == [.male] ? mascSet : femmeSet
    }

    let handle: String
    /// The photographs, in the order the carousel shows them.
    let photoAssets: [String]
    let photoExtension: String
    /// `nil` when the user's own age is unknown. The card drops the field
    /// rather than inventing a number — a made-up age on a screen that is
    /// otherwise all real data would undermine the point of it.
    let age: Int?
    let place: String?
    let musicLine: String?
    let interestLine: String?
    /// The song line 1 is about, kept so the view model knows what to look the
    /// chorus up for. Not shown anywhere itself.
    let song: MusicHighlights.Song?

    /// Shown when neither line could be built, so the card is never blank.
    static let genericLine = "Somewhere near you, with taste worth arguing about."

    /// What the caption actually renders: the lines that exist, or the generic
    /// one when none do.
    var captionLines: [String] {
        let lines = [musicLine, interestLine].compactMap { $0 }
        return lines.isEmpty ? [Self.genericLine] : lines
    }

    /// Built synchronously, so the card can render the moment the records land.
    ///
    /// `fetchedHook` is the chorus `LyricsService` found, once it has — the
    /// screen is drawn first from what is already on the device and improved
    /// when the network answers, rather than waiting on it. See
    /// `DistillViewModel.resolveHook()`.
    static func make(
        identity: IdentitySummary,
        records: [DistilledRecord],
        interests: Set<DatingPreferences.Gender>,
        fetchedHook: String? = nil
    ) -> ExampleProfile {
        let song = MusicHighlights.topSong(in: records)
        let set = photos(for: interests)
        return ExampleProfile(
            handle: set.handle,
            photoAssets: set.assets,
            photoExtension: set.fileExtension,
            age: age(for: identity),
            place: identity.place,
            musicLine: musicLine(for: song, fetchedHook: fetchedHook),
            interestLine: interestLine(in: records),
            song: song
        )
    }

    // MARK: - The person

    /// Two years either side of the user: younger if they are male, older
    /// otherwise.
    ///
    /// "Otherwise" carries every answer that isn't male — female, non-binary,
    /// unset — rather than branching three ways, which was a deliberate call:
    /// the offset is a demo flourish, and inventing a third rule for non-binary
    /// users would be making a statement with it that nobody asked for.
    private static func age(for identity: IdentitySummary) -> Int? {
        guard let age = identity.age else { return nil }
        return identity.sex?.lowercased() == "male" ? age - 2 : age + 2
    }

    // MARK: - The caption

    /// Their top song, as the song's own hook plus a line offering it.
    ///
    /// Reads like an Instagram caption because that is what it is standing in
    /// for — the hook is quoted the way someone quotes a song they have had
    /// stuck in their head, and the second half is the offer.
    ///
    /// Three sources, in descending order of how likely they are to be right:
    ///
    /// 1. **The fetched chorus**, computed from the song's real lyrics.
    /// 2. **The bundled table**, which is now the offline seed rather than the
    ///    whole mechanism. It is what makes the first paint and airplane mode
    ///    work, and it covers the songs before any network call returns.
    /// 3. **Naming the song**, which still says the true thing — this is what
    ///    they have on — without pretending to quote it.
    private static func musicLine(for song: MusicHighlights.Song?, fetchedHook: String?) -> String? {
        guard let song else { return nil }
        let artist = song.displayArtist

        if let hook = fetchedHook ?? SongHooks.hook(artist: song.artist, title: song.title) {
            // The `~♪` is doing the work quotation marks would, without the
            // stiffness: it marks the words as sung rather than said, which is
            // how someone writes a lyric into a caption.
            return "\(hook)~♪ I hope you also enjoy \(artist)"
        }
        return "On repeat: \(song.title). I hope you also enjoy \(artist)"
    }

    /// How many recorded sessions a sport needs before the profile offers to do
    /// it with someone. One logged tennis match is not a thing you play.
    static let minimumSessionsForSport = 2

    /// How much evidence a domain needs before the profile claims it as an
    /// interest, in likes' worth. Same reasoning as the sport threshold: one
    /// liked stand-up clip is a thing that happened, not a thing someone is
    /// into, and a caption built on it describes a stranger rather than the
    /// reader.
    static let minimumEvidenceForInterest = 3.0

    /// How many liked videos to weigh. Deep enough that the tally reflects the
    /// library rather than the last handful of likes, capped so a large export
    /// doesn't turn a caption into a scan of thousands of rows.
    private static let likesConsidered = 200

    /// Something about them that **isn't** music.
    ///
    /// This is the two-ontology rule, and it is the whole idea of the screen: a
    /// profile whose two lines are both about music has said one thing twice.
    /// So the second line comes from a different ontology than the first, and it
    /// is *earned* — every candidate below can come back empty, and an empty
    /// second line is a correct outcome.
    ///
    /// Candidates, in order of how much they actually claim:
    ///
    /// 1. **A sport they play**, from Health's recorded workouts. The strongest
    ///    thing on the list: a first-party record of something they did with
    ///    their body, repeatedly, and "play tennis together" is an offer a
    ///    stranger can accept. Gated on `minimumSessionsForSport`.
    /// 2. **Something they watch a lot of**, from liked videos — see
    ///    `watchedInterest`, which weighs domains rather than taking the first
    ///    one it can name.
    private static func interestLine(in records: [DistilledRecord]) -> String? {
        if let sport = LifestyleHighlights.topSports(in: records)
            .first(where: { $0.sessions >= minimumSessionsForSport }) {
            return Ontology.line(for: .playedSport, subject: sport.name)
        }

        guard let watched = watchedInterest(in: records) else { return nil }
        return Ontology.line(for: watched.domain, subject: watched.subject)
    }

    /// The domain the person watches *most* of, not the first one we can put a
    /// name to.
    ///
    /// Two things had to be got right here, and both were wrong once.
    ///
    /// **What counts.** Walking liked videos in order and taking the first that
    /// classified meant a single stray clip decided a whole line of the bio —
    /// and since YouTube returns likes newest first, that was a ranking by
    /// *recency of one tap*. So everything is classified and tallied, and the
    /// best-supported domain wins, provided it clears
    /// `minimumEvidenceForInterest`. If none do there is no second line, which
    /// is a correct outcome and not a hole to fill.
    ///
    /// **Where to look.** Likes alone are the wrong half of YouTube. On a real
    /// distillation the likes were 470 rows of almost nothing but music, while
    /// the *subscriptions* held fourteen bioinformatics and statistics channels
    /// — the same person's other whole self, in the half the code wasn't
    /// reading. Subscriptions also weigh more than likes, by the multiplier
    /// `MediaHighlights` already uses for exactly this judgement: subscribing is
    /// a standing commitment, liking is one tap.
    private static func watchedInterest(in records: [DistilledRecord]) -> (domain: Ontology.Domain, subject: String)? {
        var scores: [Ontology.Domain: Double] = [:]
        /// Which channel within a domain carries it, so the line names one they
        /// actually follow rather than whichever came first.
        var subjects: [Ontology.Domain: [String: Double]] = [:]
        /// A title to fall back on for `.film`, where the film is the offer and
        /// the channel is just where it was posted.
        var titles: [Ontology.Domain: String] = [:]

        func credit(_ domain: Ontology.Domain, channel: String, weight: Double) {
            scores[domain, default: 0] += weight
            if !channel.isEmpty { subjects[domain, default: [:]][channel, default: 0] += weight }
        }

        // **YouTube's own labels, never our term list.** Both loops below used
        // to call `Ontology.classify`, which matches a title and channel name
        // against terms we wrote — that is *"infer or estimate the content
        // category/type of a video or channel"*, which YouTube's compliance
        // guide lists as a don't for developers without the derived-metrics
        // amendment. The category is available from the API, so it is read.
        //
        // The cost is real and accepted: YouTube leaves plenty of channels
        // untagged, so fewer items are placed than before. Fewer lines, none of
        // them guessed.
        //
        // These were `classify`'s only two callers, so it now has none — see the
        // note on it. The music line never went through it; it comes from
        // `musicLine(for:)` and Apple Music's own genres.
        for video in MediaHighlights.topLikedVideos(in: records, limit: likesConsidered) {
            guard let domain = Ontology.domain(
                youTubeTopics: video.topics,
                creatorTags: video.creatorTags,
                categoryID: video.categoryID
            ), domain != .music else { continue }

            credit(domain, channel: video.channel, weight: 1)
            if titles[domain] == nil { titles[domain] = video.title }
        }

        for channel in MediaHighlights.subscribedChannels(in: records) {
            guard let domain = Ontology.domain(
                youTubeTopics: channel.topics, categoryID: nil
            ), domain != .music else { continue }

            credit(domain, channel: channel.name, weight: MediaHighlights.subscribedMultiplier)
        }

        // Ties break on the domain's own name, and below on the channel's, so
        // the same library can't produce a different caption between launches —
        // a bio that changes on its own reads as a bug.
        let ranked = scores
            .filter { $0.value >= minimumEvidenceForInterest }
            .sorted { left, right in
                left.value == right.value ? left.key.rawValue < right.key.rawValue : left.value > right.value
            }
        guard let best = ranked.first else { return nil }

        let topChannel = (subjects[best.key] ?? [:])
            .sorted { left, right in
                left.value == right.value ? left.key < right.key : left.value > right.value
            }
            .first?.key

        // A film is named by its title; everything else by the channel, which
        // says more about the interest than any one video of theirs does.
        let subject = best.key == .film
            ? (titles[best.key] ?? topChannel ?? "")
            : (topChannel ?? titles[best.key] ?? "")
        guard !subject.isEmpty else { return nil }

        return (best.key, subject)
    }
}
