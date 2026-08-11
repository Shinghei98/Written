import Foundation

/// A first, deliberately small ontology: which corner of someone's interests a
/// thing belongs to.
///
/// This is the stage `CLAUDE.md` describes as consuming the distillation —
/// keywords over an ontology — standing up in its crudest possible form. It is
/// a term table, not an embedding, and it is asked one question: *is this the
/// same kind of thing as that other one?*
///
/// Which is the whole reason it exists. A profile whose two lines are both
/// about music says one thing about a person twice; a profile that pairs a song
/// with a stand-up special, or with a sport they actually play, says two.
/// `ExampleProfile` walks candidates until it finds one from a different domain
/// and drops the rest.
enum Ontology {

    /// The domains we can currently tell apart. Small on purpose: a domain
    /// earns its place by having a sentence worth writing about it and a term
    /// list specific enough not to swallow everything else.
    enum Domain: String, CaseIterable {
        case music
        case comedy
        case film
        case gaming
        case tech
        /// Research, statistics, the exact sciences. Split from `learning`
        /// because they are different offers: someone who watches "how to tie a
        /// tie" and someone subscribed to fourteen bioinformatics channels are
        /// not making the same claim about themselves.
        case science
        case food
        case fitness
        /// Sport *watched* — highlights, a match, the Olympics.
        case spectatorSport
        case learning
        case art
        case travel
        /// Sport *played*, which is a different fact about a person and comes
        /// from a different place: Health's recorded workouts, not anything
        /// they watched. Never returned by `classify`.
        case playedSport

        /// The name a person reads, over the percentage on a dynamic profile.
        ///
        /// `rawValue` is `spectatorSport`, which is a programmer's word.
        var label: String {
            switch self {
            case .music: return "Music"
            case .comedy: return "Comedy"
            case .film: return "Film"
            case .gaming: return "Gaming"
            case .tech: return "Tech"
            case .science: return "Science"
            case .food: return "Food"
            case .fitness: return "Fitness"
            case .spectatorSport: return "Watching sport"
            case .learning: return "Learning"
            case .art: return "Art"
            case .travel: return "Travel"
            case .playedSport: return "Sport"
            }
        }

        /// The glyph on the Memories card, where a modality's icon used to sit.
        ///
        /// SF Symbols throughout, unlike the tab bar's potted plant — every one
        /// of these has an obvious symbol and none of them is a brand.
        var systemImage: String {
            switch self {
            case .music: return "music.note"
            case .comedy: return "theatermasks"
            case .film: return "film"
            case .gaming: return "gamecontroller"
            case .tech: return "desktopcomputer"
            case .science: return "atom"
            case .food: return "fork.knife"
            case .fitness: return "figure.strengthtraining.traditional"
            case .spectatorSport: return "sportscourt"
            case .learning: return "book"
            case .art: return "paintpalette"
            case .travel: return "airplane"
            case .playedSport: return "figure.run"
            }
        }

        /// What to say when two people share this domain but nothing specific
        /// inside it — the fallback caption on a dynamic profile's photographs
        /// once the shared *subjects* have run out.
        ///
        /// Deliberately about a habit rather than a taste. "You both spend
        /// Saturdays outdoors" is true of two people who play different sports;
        /// "you both like sport" reads as a category somebody typed.
        var sharedLine: String {
            switch self {
            case .music: return "You both have this on in the background."
            case .comedy: return "You both need something that makes you laugh."
            case .film: return "You both sit through the credits."
            case .gaming: return "You both lose evenings this way."
            case .tech: return "You both read about this for fun."
            case .science: return "You both go looking for how things work."
            case .food: return "You both take the cooking seriously."
            case .fitness: return "You both keep at it."
            case .spectatorSport: return "You both clear the afternoon for a match."
            case .learning: return "You both keep picking things up."
            case .art: return "You both go and look at things."
            case .travel: return "You both plan the next one early."
            case .playedSport: return "You both spend Saturdays outdoors."
            }
        }
    }

    // MARK: - Classifying something watched

    /// Terms that place a video in a domain, matched case-insensitively against
    /// its title, channel and description prefix.
    ///
    /// Every term here is one somebody would only write on purpose. That rule
    /// cost real entries: `"ep "` matched *keep*, `"ai "` matched *wait*, and
    /// `"single"`, `"album"` and `"audio"` are said about far more than music.
    /// A domain reached by accident is worse than no domain, because the line
    /// it produces still sounds confident.
    ///
    /// Ordering matters: `Domain.allCases` is walked in declaration order and
    /// the first hit wins, so `music` is checked first — it is the domain we
    /// most need to *detect*, in order to rule it out.
    private static let terms: [Domain: [String]] = [
        // The CJK and Hangul terms are not here to grow the music domain. They
        // are here so idol clips are *recognised* as music and skipped: on a
        // real Korean-and-Chinese library, 140 of 200 liked videos matched
        // nothing at all, so the tally that decides the second line was being
        // taken over a set that silently excluded most of what the person
        // watches. A domain that cannot see its own content distorts every
        // other domain's share of the total.
        .music: ["official mv", "music video", "official video", "lyric video", "lyrics",
                 "full album", "live performance", "concert", "vevo", "remix",
                 "acoustic", "unplugged", "official audio", "kpop", "k-pop", "ost",
                 "fancam", "직캠", "무대", "커버", "챌린지", "엔터", "뮤직",
                 "翻譯", "舞台", "现场", "現場", "音樂", "音乐", "歌詞", "歌词"],
        .comedy: ["comedy", "stand-up", "standup", "stand up", "sketch", "parody",
                  "meme", "memes", "roast", "satire", "funny", "humor", "humour",
                  "jokes", "prank", "snl", "improv", "shitpost"],
        .film: ["trailer", "movie", "film", "cinema", "documentary", "anime",
                "netflix", "ending explained", "behind the scenes", "box office"],
        .gaming: ["gameplay", "playthrough", "let's play", "speedrun", "boss fight",
                  "minecraft", "fortnite", "valorant", "league of legends", "elden ring",
                  "zelda", "pokemon", "esports", "gaming", "twitch"],
        .tech: ["programming", "coding", "developer", "software", "startup",
                "machine learning", "llm", "python", "javascript", "swift",
                "linux", "unboxing", "keyboard"],
        // Channel names as much as titles: a subscription carries only a name,
        // and for research channels the name *is* the subject — "Sanbomics",
        // "StatQuest", "Bioinformagician" say what they are about.
        .science: ["bioinformat", "genomic", "sequencing", "rna-seq", "single-cell",
                   "statistic", "statquest", "biostat", "neurosci", "molecular",
                   "biology", "chemistry", "physics", "calculus", "linear algebra",
                   "mathemat", "professor", "phd", "research", "sanbomics",
                   "ritvikmath", "science"],
        .food: ["recipe", "cooking", "baking", "kitchen", "restaurant",
                "street food", "mukbang", "espresso", "taste test"],
        .fitness: ["workout", "gym", "deadlift", "squat", "calisthenics",
                   "yoga", "pilates", "marathon", "mobility"],
        .spectatorSport: ["highlights", "nba", "nfl", "premier league", "world cup",
                          "olympics", "formula 1", "champions league", "ufc"],
        .learning: ["explained", "how to", "tutorial", "lecture", "history of",
                    "deep dive", "veritasium", "essay"],
        .art: ["drawing", "painting", "illustration", "typography", "sketchbook",
               "photography", "lightroom", "architecture", "pottery", "animation"],
        .travel: ["travel", "vlog", "walking tour", "city guide", "hiking",
                  "backpacking", "van life"]
    ]

    /// Which domain a video belongs to, or `nil` when nothing matches.
    ///
    /// `nil` is a real answer and not a failure: a video we cannot place is
    /// better left out of the profile than described with a guess, and the
    /// caller treats it that way.
    ///
    /// **This has no callers, and must never be given YouTube data.** Its two
    /// callers were `ExampleProfile`'s liked-video and subscription loops, and
    /// both now read YouTube's own labels through
    /// `domain(youTubeTopics:categoryID:)` instead. Applying a term list to a
    /// title or channel name is *"infer or estimate the content category/type
    /// of a video or channel"*, which YouTube's compliance guide lists as a
    /// don't for developers who have not been accepted under the
    /// derived-metrics amendment.
    ///
    /// It is kept rather than deleted because the term table is a real asset
    /// and the restriction is YouTube's alone — Apple Music, Podcasts and
    /// Calendar carry no such term, and this is the right tool for them when
    /// the ontology stage reaches them. **Check the source before calling it.**
    static func classify(title: String, channel: String, detail: String) -> Domain? {
        let haystack = "\(title) \(channel) \(detail)".lowercased()
        for domain in Domain.allCases where domain != .playedSport {
            guard let list = terms[domain] else { continue }
            if list.contains(where: haystack.contains) { return domain }
        }
        return nil
    }

    // MARK: - The mix

    /// One domain and the share of somebody's placed items that fell into it.
    struct Weight: Equatable, Hashable {
        let domain: Domain
        /// 0…1 of everything that *could* be placed. See `mix` for why that is
        /// the denominator and not the count of items overall.
        let share: Double

        var percent: Int { Int((share * 100).rounded()) }
    }

    /// One named thing and the share of somebody's listening that fell to it.
    ///
    /// **A subject, not a domain.** `Weight` says "Music, 83%", which is a shape
    /// rather than a fact — anybody can see from the artist names beside it that
    /// this person listens to music. This says "Bach, 22%", which is the thing
    /// the page is actually for: three figures where posts / followers /
    /// following sit, and unlike a follower count there is nothing to inflate.
    struct SubjectWeight: Equatable, Hashable {
        let subject: String
        /// 0…1 of the music counted, not of everything distilled. See `subjects`.
        let share: Double

        var percent: Int { Int((share * 100).rounded()) }
    }

    /// The three named things somebody listens to most, ranked.
    ///
    /// **Music only, and that is a publishing decision rather than a technical
    /// one.** These are written to `discovery_cards`, the one table in this
    /// schema every signed-in user may read, so each entry has to pass the
    /// two-part test: something a sentence can be about, *and* something the
    /// source's terms allow a stranger to see. Apple Music artists clear both
    /// and are already published as `interests`. The others do not, each for its
    /// own reason:
    ///
    /// * **YouTube** is excluded by construction — it takes no parameter here,
    ///   because a channel name is Authorized Data under III.E.3.b and deriving
    ///   a label from one is III.E.4.h.
    /// * **Calendar** titles are the strongest signal this app collects and the
    ///   least publishable — "Outpatient" is a subject a sentence can be about
    ///   and has no business on a card strangers read.
    /// * **Podcast shows** are merely undecided. `publishDiscoveryCard` already
    ///   records that publishing a new category of subject about somebody is its
    ///   own decision; this is not the place to take it quietly.
    /// * **Sports** come from Health, and `health_sports` is derived data that
    ///   has never appeared on a card. The icebreaker names a shared sport to
    ///   somebody already matched, which is a narrower audience than this.
    ///
    /// So the denominator is the music counted here, and a person who listens to
    /// nothing gets an empty row rather than a padded one.
    ///
    /// **The subject is read, not decided.** `AppleMusicDistiller` stamps
    /// `subject=` on every song row — the composer for classical, the performer
    /// otherwise — and this and `seed_icebreaker` both read it. That is the
    /// whole reason the rule is not implemented here: the profile and the
    /// icebreaker have to call the same listening by the same name, and two
    /// implementations of one rule drift.
    static func subjects(records: [DistilledRecord], limit: Int = 3) -> [SubjectWeight] {
        var counts: [String: Int] = [:]

        // **`MusicHighlights.songTypes`, not a literal.** This read
        // `dataType == "song"`, a type `AppleMusicDistiller` has never written —
        // it emits `library_song`, `heavy_rotation`, `playlist_item` and
        // `recently_played` — so this answered `[]` for every real library and
        // the dynamic profile's three figures never drew. Deduplicated for the
        // reason `topArtists` is: one song reaches us as a library row, as
        // recently played and again inside each playlist it sits on, and
        // counting the rows would rank an artist by how many lists they are on.
        for record in MusicHighlights.deduplicatedSongs(in: records) {
            let subject = storedSubject(for: record)
            guard !subject.isEmpty else { continue }
            counts[subject, default: 0] += 1
        }

        let total: Int = counts.values.reduce(0, +)
        guard total > 0 else { return [] }

        // Written as statements rather than one chain: the fluent version was
        // long enough that the type checker gave up on it outright.
        var weights: [SubjectWeight] = []
        for (subject, count) in counts {
            weights.append(SubjectWeight(subject: subject, share: Double(count) / Double(total)))
        }
        // Ties break on the name so the same library always produces the same
        // three figures in the same order — a profile that reshuffled between
        // two viewings would read as unstable.
        weights.sort { a, b in
            a.share == b.share ? a.subject < b.subject : a.share > b.share
        }
        return Array(weights.prefix(limit))
    }

    /// The composer for classical, the performer for everything else.
    ///
    /// **The only implementation of that rule in the project**, called by
    /// `AppleMusicDistiller` when it stamps `subject=` into a row's `extra`.
    /// Nothing downstream repeats it: `subjects` below and `seed_icebreaker` in
    /// SQL both read the stamp and fall back to `creator`. Two implementations
    /// would drift, and the day they drifted the profile would say Bach while
    /// the thread said English Baroque Soloists about the same listening.
    ///
    /// The match is `contains("classical")`, which takes Classical Crossover
    /// and Classical Era and does not take `Klassik`, `Clásica` or 古典音樂,
    /// because Apple Music localises genre names to the storefront. Incomplete
    /// by construction, and the failure is naming the performer — which is what
    /// happened before any of this existed.
    ///
    /// Worth knowing how thin the composer data is: on one real library, 42 of
    /// 481 classical rows carried a `composerName` at all. The rule fires
    /// correctly and is outvoted by the rows that have nothing to fire on.
    static func musicSubject(genres: [String], composer: String?, performer: String) -> String {
        let isClassical = genres.contains { $0.lowercased().contains("classical") }
        let trimmedComposer = composer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isClassical, !trimmedComposer.isEmpty {
            return trimmedComposer
        }
        return performer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stamp, or the performer for rows written before it existed.
    ///
    /// **Not the rule again.** A row distilled before `subject=` was stamped
    /// falls back to `creator`, which is what those rows resolve to in SQL as
    /// well — the two stay in step even while a library is half re-distilled.
    /// One re-distill re-stamps the lot.
    private static func storedSubject(for record: DistilledRecord) -> String {
        if let stamped = record.extraValue("subject")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stamped.isEmpty {
            return stamped
        }
        return record.creator.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Who the recording is *by* — the first credit, and only the first.
    ///
    /// **The counterpart to `storedSubject`, and the reason both are needed.**
    /// For a classical row the subject is the composer and this is the
    /// performer; for everything else they are the same string and the term
    /// they produce collapses. Splitting on `|` because `SpotifyDistiller`
    /// pipe-joins every credit while Apple Music writes one name — so the first
    /// element is the lead performer on both, which is what makes a term
    /// comparable across the two services.
    private static func primaryPerformer(of record: DistilledRecord) -> String {
        record.creator
            .split(separator: "|")
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    /// What somebody is into, ranked, from every source that may be classified.
    ///
    /// **This is the ontology stage being switched on**, and until now it was
    /// not. Exactly one place in the app ever attached a `Domain` to real data —
    /// the music line in `publishDiscoveryCard` — so the enum had thirteen cases
    /// and one of them was used. `classify` had no callers at all.
    ///
    /// **YouTube is not a parameter and must never become one.** Applying a term
    /// list to a title or a channel name is *"infer or estimate the content
    /// category/type of a video or channel"*, which III.E.4.h prohibits outright.
    /// The source is archived, so this is a door being locked before anybody
    /// tries it rather than a live concern —
    /// `domain(youTubeTopics:creatorTags:categoryID:)` stays the only legal
    /// route, and it reads YouTube's own labels instead of guessing.
    ///
    /// **The denominator is placed items, not all items.** Somebody with 300
    /// songs and 4 podcasts is not "98% music" in any sense worth printing — the
    /// question is what their attention is made of, and an item `classify` could
    /// not place is not evidence for anything. Unplaced items are dropped rather
    /// than counted against the total.
    ///
    /// Shares therefore sum to 1 across *all* domains, so the top three usually
    /// will not — which is honest. Normalising the three to 100 would imply the
    /// rest do not exist.
    static func mix(
        musicArtists: [MusicHighlights.Artist],
        podcastShows: [ListeningHighlights.Show],
        events: [ListeningHighlights.Event],
        sports: [LifestyleHighlights.Sport]
    ) -> [Weight] {
        var counts: [Domain: Int] = [:]

        // Weighted by songs rather than one per artist: somebody with forty
        // tracks by one person and one track each by five others is more
        // musical than the headcount suggests.
        for artist in musicArtists {
            counts[.music, default: 0] += max(artist.songs, 1)
        }

        // **Sports bypass `classify` entirely**, and that is by construction
        // rather than convenience — it skips `.playedSport` on every pass,
        // because a term list matched against a title cannot tell watching a
        // sport from playing one. A `health_sports` row is a workout somebody
        // actually did, so it is the one place that distinction is already
        // settled.
        for sport in sports {
            counts[.playedSport, default: 0] += max(sport.sessions, 1)
        }

        for show in podcastShows {
            guard let domain = classify(title: show.name, channel: show.publisher, detail: "") else { continue }
            counts[domain, default: 0] += max(show.episodes, 1)
        }

        // The organizer, not the calendar name: "Gym" as a calendar tells you
        // less than "Eventbrite" as an organizer, and the calendar's name is
        // whatever somebody called it.
        for event in events {
            guard let domain = classify(title: event.name, channel: event.organizer, detail: "") else { continue }
            counts[domain, default: 0] += 1
        }

        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }

        return counts
            .map { Weight(domain: $0.key, share: Double($0.value) / Double(total)) }
            // Ties break on the domain's name so the same library always
            // produces the same three bars in the same order — a profile that
            // reshuffled between two viewings would read as unstable.
            .sorted { a, b in
                a.share == b.share
                    ? a.domain.rawValue < b.domain.rawValue
                    : a.share > b.share
            }
    }

    // MARK: - Terms, grouped by the domain they landed in

    /// One named thing somebody can look at and say yes or no to.
    ///
    /// **The text is always the source's own string** — an artist, a composer, a
    /// channel, a show, an event title. Nothing here is a word this app invented,
    /// which is what keeps the page a reading of somebody's data rather than a
    /// set of labels applied to them.
    struct Term: Identifiable, Hashable {
        /// The kind is part of the identity: an artist and a podcast may share a
        /// name, and two rows with one id is undefined behaviour in `ForEach`.
        var id: String { "\(kind.rawValue):\(text.lowercased())" }
        let text: String
        /// Songs, episodes, occurrences — whatever the source counts in. Only
        /// ever compared against other terms in the same domain.
        let weight: Int
        let artworkURL: URL?
        /// **What striking this off means**, and the reason removal reuses the
        /// existing machinery instead of inventing a parallel one.
        let kind: BanList.Kind
        /// Every string that has to enter the ban list for the underlying rows
        /// to actually stop counting — a name, and an id where one exists.
        /// `banChannel` already adds both, because liked videos identify a
        /// channel by id while subscriptions carry only the title.
        let banValues: [String]
        /// Every source that contributed to this term.
        ///
        /// **A set because terms merge, and the merge was invisible.** `id` is
        /// kind-and-text, so one artist read from Apple Music and again from
        /// Spotify is a single chip — and until this existed the row could not
        /// say so, which left a test user unable to tell a term backed by two
        /// libraries from one backed by a single play.
        ///
        /// It is also what makes striking a term off a judgement rather than a
        /// guess: a Spotify classical row files under the performer because
        /// Spotify returns no composer, and knowing which service a term came
        /// from is the first half of knowing whether it is wrong.
        let sources: Set<String>
    }

    /// One domain and everything that landed in it.
    struct DomainTerms: Identifiable, Hashable {
        var id: String { domain.rawValue }
        let domain: Domain
        let terms: [Term]

        /// What orders the cards on the page. Not `mix`'s share, because `mix`
        /// takes no YouTube parameter and never will — a domain reached only
        /// through YouTube would sort last regardless of how much is in it.
        var weight: Int { terms.reduce(0) { $0 + $1.weight } }
    }

    /// Everything distilled, placed under the domain it belongs to.
    ///
    /// **This is what the Memories page draws.** It used to be five cards named
    /// after the plumbing — MUSIC, MEDIA, PODCASTS, EVENTS, LIFESTYLE — which is
    /// a picture of where data came from rather than of what it says. Grouped by
    /// domain, the page is the ontology's own conclusion with its owner standing
    /// over it.
    ///
    /// **YouTube goes through a different door, and the separation is
    /// structural.** `youTubeTerms` below cannot reach `classify`, because
    /// placing a channel under a domain by matching a term list against its name
    /// is *"infer or estimate the content category/type of a video or channel"* —
    /// III.E.4.h, prohibited outright. It reads `topicCategories`, `tags` and
    /// `categoryId`, which YouTube supplies, and drops anything carrying none of
    /// them. Fewer channels are placed; none is guessed.
    ///
    /// **Sports bypass `classify` too**, for the reason `mix` gives: a term list
    /// matched against a title cannot tell watching a sport from playing one.
    ///
    /// Nothing here is published. `subjects` remains the only thing feeding
    /// `discovery_cards`, and it stays music-only — a channel name on a table
    /// every signed-in account may read is the III.E.3.b breach
    /// `publishDiscoveryCard` committed once already.
    static func terms(
        records: [DistilledRecord],
        musicArtists: [MusicHighlights.Artist],
        podcastShows: [ListeningHighlights.Show],
        events: [ListeningHighlights.Event],
        sports: [LifestyleHighlights.Sport],
        limitPerDomain: Int = 12
    ) -> [DomainTerms] {
        var buckets: [Domain: [String: Term]] = [:]

        func add(_ term: Term, to domain: Domain) {
            var byText = buckets[domain] ?? [:]
            if let existing = byText[term.id] {
                byText[term.id] = Term(
                    text: existing.text,
                    weight: existing.weight + term.weight,
                    artworkURL: existing.artworkURL ?? term.artworkURL,
                    kind: existing.kind,
                    banValues: Array(Set(existing.banValues + term.banValues)).sorted(),
                    // The union is the point: this branch *is* the merge, and
                    // until now nothing recorded that it had happened.
                    sources: existing.sources.union(term.sources)
                )
            } else {
                byText[term.id] = term
            }
            buckets[domain] = byText
        }

        // Music: **the stamped subject and the primary performer, as two terms.**
        //
        // A Bach partita played by Itzhak Perlman is two facts about a listener,
        // not one, and they must never merge — they are different people. This
        // page used to emit only `storedSubject`, which for classical is the
        // composer, so the performer was simply lost: Perlman survived in
        // `MusicHighlights.topArtists` and nowhere on this card. For everything
        // that is not classical the two strings are identical and `Term.id`
        // collapses them, so nothing changes for pop.
        //
        // **The first credit only, not every credit.** `creditedArtists` splits
        // the whole pipe-joined list, and emitting a term per credit would put
        // every featured artist on the card. The primary performer is who the
        // recording is *by*; the long tail is `topArtists`' job.
        //
        // **The two terms are backed by the same rows**, which has a consequence
        // worth stating rather than leaving to be discovered: striking one off
        // marks those rows removed, so the other's weight drops with it.
        // Striking "Bach" thins "Perlman". That follows from `applyingBans`
        // working per row rather than per term, and it is arguably right — the
        // recording did go — but it will surprise somebody.
        var artistArtwork: [String: URL] = [:]
        for artist in musicArtists where artist.artworkURL != nil {
            artistArtwork[artist.name.lowercased()] = artist.artworkURL
        }
        // Sources come from every music row, **not** from the deduplicated set.
        // Dedupe drops the losing row, so a term built from survivors alone
        // would claim one source for a recording owned on two services — and the
        // glyph strip exists precisely to show that it is on both.
        var termSources: [String: Set<String>] = [:]
        for record in MusicHighlights.allSongRows(in: records) {
            for text in [storedSubject(for: record), primaryPerformer(of: record)]
            where !text.isEmpty {
                termSources[text.lowercased(), default: []].insert(record.source)
            }
        }
        func sources(for text: String) -> Set<String> {
            termSources[text.lowercased()] ?? []
        }

        for record in MusicHighlights.deduplicatedSongs(in: records) {
            // A set so the pop case — where subject and performer are the same
            // string — adds one term rather than the same one twice.
            var texts: [String] = []
            for text in [storedSubject(for: record), primaryPerformer(of: record)]
            where !text.isEmpty && !texts.contains(where: { $0.lowercased() == text.lowercased() }) {
                texts.append(text)
            }
            for text in texts {
                add(Term(text: text, weight: 1,
                         artworkURL: artistArtwork[text.lowercased()],
                         kind: .artist, banValues: [text],
                         sources: sources(for: text)),
                    to: .music)
            }
        }

        for show in podcastShows {
            guard let domain = classify(title: show.name, channel: show.publisher, detail: "") else { continue }
            add(Term(text: show.name, weight: max(show.episodes, 1), artworkURL: nil,
                     kind: .show,
                     banValues: show.showID.isEmpty ? [show.name] : [show.name, show.showID],
                     // A literal rather than a field, because
                     // `ListeningHighlights.shows` filters on exactly this source.
                     sources: ["apple_podcasts"]),
                to: domain)
        }

        // The organizer, not the calendar's name — same reasoning as `mix`.
        for event in events {
            guard let domain = classify(title: event.name, channel: event.organizer, detail: "") else { continue }
            add(Term(text: event.name, weight: 1, artworkURL: nil,
                     kind: .event, banValues: [event.name],
                     // Carried rather than assumed: this is the one term type
                     // with two real sources, `apple_calendar` and
                     // `google_calendar`, so a literal here would be a lie.
                     sources: [event.source]),
                to: domain)
        }

        for sport in sports {
            add(Term(text: sport.name, weight: max(sport.sessions, 1), artworkURL: nil,
                     kind: .sport, banValues: [sport.name],
                     sources: ["health"]),
                to: .playedSport)
        }

        for (domain, term) in youTubeTerms(records: records) {
            add(term, to: domain)
        }

        var grouped: [DomainTerms] = []
        for (domain, byText) in buckets {
            let ranked = byText.values.sorted { a, b in
                a.weight == b.weight ? a.text < b.text : a.weight > b.weight
            }
            grouped.append(DomainTerms(domain: domain, terms: Array(ranked.prefix(limitPerDomain))))
        }
        // Ties break on the domain's name, so the same library always draws the
        // same cards in the same order — a page that reshuffled between two
        // visits would read as unstable.
        grouped.sort { a, b in
            a.weight == b.weight ? a.domain.rawValue < b.domain.rawValue : a.weight > b.weight
        }
        return grouped
    }

    /// YouTube's channels, placed only by labels YouTube itself supplied.
    ///
    /// **`classify` is deliberately not in scope here**, and that is the whole
    /// design of this function rather than a note on it. A channel is aggregated
    /// across every row that mentions it — a subscription carries the avatar and
    /// the channel's topics, a liked video carries the video's category id and
    /// the creator's tags — and the union goes to
    /// `domain(youTubeTopics:creatorTags:categoryID:)`, which reads and never
    /// guesses. A channel with none of the three is **absent**, not placed
    /// somewhere plausible.
    ///
    /// Worth knowing this list empties on its own: `0016` deletes YouTube titles
    /// and channel names 30 days after collection, so these terms disappear for
    /// anybody who has not re-distilled in a month. That is the retention rule
    /// working, and it must not be drawn as a failure.
    private static func youTubeTerms(records: [DistilledRecord]) -> [(Domain, Term)] {
        struct Channel {
            var topics: [String] = []
            var tags: [String] = []
            var categoryID: String?
            var artwork: URL?
            var ids: Set<String> = []
            var rows = 0
        }

        var channels: [String: Channel] = [:]

        for record in records where record.source == "youtube" && !record.isRemovedByUser {
            let name = record.creator.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            var channel = channels[name] ?? Channel()
            channel.rows += 1
            channel.topics += splitList(record.extraValue("topics"))
            channel.tags += splitList(record.extraValue("tags"))
            if channel.categoryID == nil { channel.categoryID = record.extraValue("category_id") }
            // Only a subscription's thumbnail is the *channel's* avatar; a liked
            // video's is a still from that video, which is a picture of one
            // thing rather than of the channel.
            if record.dataType == "subscription", channel.artwork == nil {
                channel.artwork = record.extraValue("artwork").flatMap(URL.init(string:))
                if !record.itemID.isEmpty { channel.ids.insert(record.itemID) }
            }
            if let channelID = record.extraValue("channel_id"), !channelID.isEmpty {
                channel.ids.insert(channelID)
            }
            channels[name] = channel
        }

        var placed: [(Domain, Term)] = []
        for (name, channel) in channels {
            guard let domain = domain(
                youTubeTopics: channel.topics,
                creatorTags: channel.tags,
                categoryID: channel.categoryID
            ) else { continue }
            placed.append((domain, Term(
                text: name,
                weight: channel.rows,
                artworkURL: channel.artwork,
                kind: .channel,
                banValues: [name] + channel.ids.sorted(),
                sources: ["youtube"]
            )))
        }
        return placed
    }

    /// `topics` and `tags` are stored pipe-joined by `YouTubeDistiller`.
    private static func splitList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    // MARK: - Reading YouTube's own labels

    /// Topics we will not carry into a profile, whatever YouTube says.
    ///
    /// **These are not domains we lack a sentence for — they are inferences we
    /// decline to make.** Religion, politics and health status are protected
    /// characteristics, and a content tag is exactly how one arrives without
    /// anybody deciding to collect it: subscribe to a diocese's channel and a
    /// naive mapping writes down your religion. `Military` is here for the same
    /// reason at one remove.
    ///
    /// They are dropped at the mapping rather than filtered later, so there is
    /// one place to look and no path around it.
    private static let refusedTopics: Set<String> = [
        "Religion", "Politics", "Health", "Military", "Society"
    ]

    /// A domain from YouTube's own topic categories and video category id.
    ///
    /// **This exists so the category is read rather than inferred.** The
    /// compliance guide's don't-list includes *"Infer or estimate the content
    /// category/type of a video or channel"*, under the heading *"Only offer
    /// metrics that are available via YouTube's API services"* — and the
    /// category is available, so `classify` is the wrong tool for anything
    /// that came from YouTube. `classify` remains right for Apple Music and the
    /// rest, which carry no such term.
    ///
    /// Topics win over the category id because they are more specific: a
    /// channel tagged `Technology` is placed better than the same video's
    /// category 28, which is "Science & Technology" and cannot tell the two
    /// apart on its own.
    ///
    /// `nil` again means *unplaced*, and it is a more common answer here than
    /// with `classify` — YouTube leaves plenty of channels untagged. That is
    /// the trade: fewer lines, none of them guessed.
    static func domain(
        youTubeTopics topics: [String],
        creatorTags: [String] = [],
        categoryID: String?
    ) -> Domain? {
        for topic in topics {
            if refusedTopics.contains(topic) { continue }
            if let domain = domainForTopic(topic) { return domain }
        }
        for tag in creatorTags {
            if let domain = domainForCreatorTag(tag) { return domain }
        }
        guard let categoryID else { return nil }
        return domainForCategoryID(categoryID)
    }

    /// Creator-supplied `snippet.tags`, which the API returns and which are
    /// therefore *read* rather than inferred — the same footing as
    /// `topicCategories`, and worth having because YouTube's own topic
    /// assignment is patchy while creators tag almost everything.
    ///
    /// **Matched whole, never as substrings, and that is the line.** A tag is
    /// an explicit label, so recognising `"physics"` is translation. Matching
    /// `"phys"` inside a title would be a guess wearing the same clothes, and
    /// the guide's prohibition is on estimating a category — so the moment this
    /// starts pattern-matching freeform text it becomes the thing Part C exists
    /// to stop. Small controlled vocabulary, exact comparison, lowercased.
    ///
    /// Nothing here reaches a refused topic: no tag maps to religion, politics
    /// or health, and none should be added that does.
    private static func domainForCreatorTag(_ tag: String) -> Domain? {
        switch tag.trimmingCharacters(in: .whitespaces).lowercased() {
        case "music", "song", "album", "concert", "live music":
            return .music
        case "comedy", "standup", "stand up", "stand-up", "sketch", "parody":
            return .comedy
        case "film", "movie", "movies", "cinema", "trailer", "short film", "anime":
            return .film
        case "gaming", "game", "games", "video game", "gameplay", "speedrun", "esports", "minecraft":
            return .gaming
        case "technology", "tech", "programming", "software", "coding", "hardware", "ai":
            return .tech
        case "science", "physics", "chemistry", "biology", "astronomy", "mathematics", "maths", "math", "engineering":
            return .science
        case "food", "cooking", "recipe", "recipes", "baking", "cuisine":
            return .food
        case "fitness", "workout", "gym", "training", "yoga", "running":
            return .fitness
        case "sports", "sport", "highlights", "football", "basketball", "soccer", "tennis":
            return .spectatorSport
        case "education", "tutorial", "how to", "howto", "explained", "documentary", "history":
            return .learning
        case "art", "design", "painting", "drawing", "illustration", "photography", "architecture":
            return .art
        case "travel", "vlog travel", "backpacking", "tourism":
            return .travel
        default:
            return nil
        }
    }

    /// YouTube's topic categories are Wikipedia article names, so they are
    /// matched on substrings of a known vocabulary rather than exhaustively —
    /// the music and gaming families alone run to a dozen entries each
    /// (`Rock_music`, `Strategy_video_game`) and all of them end the same way.
    private static func domainForTopic(_ topic: String) -> Domain? {
        if topic.hasSuffix("music") || topic == "Music" || topic == "Jazz" { return .music }
        if topic.hasSuffix("game") || topic == "Video_game_culture" { return .gaming }
        if topic == "Humor" { return .comedy }
        if topic == "Movies" || topic == "TV_shows" { return .film }
        if topic == "Performing_arts" { return .art }
        if topic == "Fitness" { return .fitness }
        if topic == "Food" { return .food }
        if topic == "Technology" { return .tech }
        if topic == "Tourism" { return .travel }
        if topic == "Knowledge" { return .learning }
        // The sports family: the topic list names individual sports directly.
        let sports: Set<String> = [
            "Sport", "American_football", "Baseball", "Basketball", "Boxing",
            "Cricket", "Football", "Golf", "Ice_hockey", "Mixed_martial_arts",
            "Motorsport", "Tennis", "Volleyball", "Professional_wrestling"
        ]
        if sports.contains(topic) { return .spectatorSport }
        // `Entertainment`, `Lifestyle_(sociology)`, `Hobby`, `Business`,
        // `Fashion`, `Pets`, `Vehicles` are deliberately unplaced: each is
        // broad enough that a line written from it would say nothing.
        return nil
    }

    /// The numeric ids are YouTube's own and stable. Only the ones that map to
    /// a domain we can write a sentence about are here.
    ///
    /// **25 (News & Politics) and 29 (Nonprofits & Activism) are absent by
    /// decision**, matching `refusedTopics`.
    private static func domainForCategoryID(_ id: String) -> Domain? {
        switch id {
        case "10": return .music
        case "20": return .gaming
        case "23", "34": return .comedy
        case "1", "18", "30", "31", "32", "33", "35", "36", "37", "38", "39", "40", "41", "43", "44":
            return .film
        case "17": return .spectatorSport
        case "19": return .travel
        case "26", "27": return .learning
        case "28": return .science
        default: return nil
        }
    }

    // MARK: - Writing the line

    /// The second line of the example profile's caption.
    ///
    /// Written as an *offer* rather than a description — "or we could also…" —
    /// because its job is to sound like the second thing someone mentions when
    /// they are hoping you will say yes, which is what a caption on a dating
    /// profile is.
    ///
    /// `subject` is what the offer is about: a channel, a sport, a film.
    static func line(for domain: Domain, subject: String) -> String {
        switch domain {
        case .music:
            // Unreachable through `ExampleProfile`, which rejects a second music
            // item before it gets here — but a total switch beats a fatalError.
            return "Or we could trade playlists, if \(subject) is on yours too."
        case .comedy:
            return "Or we could watch \(subject) and find out whether we laugh at the same things."
        case .film:
            return "Or we could argue about \(subject) — I'll bring the popcorn."
        case .gaming:
            return "Or I could lose to you at whatever \(subject) has me playing this week."
        case .tech:
            return "Or we could get far too deep into \(subject) over coffee."
        case .science:
            return "Or I could talk your ear off about whatever \(subject) has posted this week."
        case .food:
            return "Or I could cook you something I learned from \(subject), badly."
        case .fitness:
            return "Or you could drag me out for whatever \(subject) has me attempting."
        case .spectatorSport:
            return "Or we could watch \(subject) and pretend we could do that."
        case .learning:
            return "Or I could tell you far too much about \(subject)."
        case .art:
            return "Or we could go looking at things, the way \(subject) does."
        case .travel:
            return "Or we could go somewhere \(subject) has already talked me into."
        case .playedSport:
            return "Join me for \(invitation(to: subject)) on Saturday?"
        }
    }

    /// A sport as it reads after "join me for".
    ///
    /// Health names sports as bare nouns — "Tennis", "Running", "Strength
    /// training" — and dropping those into the sentence gives "join me for
    /// Running on Saturday?", which nobody says. English wants three different
    /// shapes here and the table below is which sport takes which:
    ///
    /// - **Bare** for games and named disciplines: *join me for tennis*.
    /// - **An article and a count noun** for cardio, where the gerund names the
    ///   activity but the invitation is to one instance of it: *join me for a
    ///   run*, not *for running*.
    /// - **A session word** where the activity has no natural count noun:
    ///   *a lift*, *a HIIT class*.
    private static func invitation(to sport: String) -> String {
        let phrases: [String: String] = [
            // Games and disciplines — no article.
            "Tennis": "tennis", "Badminton": "badminton",
            "Table tennis": "table tennis", "Basketball": "basketball",
            "Football": "football", "American football": "American football",
            "Baseball": "baseball", "Volleyball": "volleyball",
            "Golf": "golf", "Bowling": "bowling", "Yoga": "yoga",
            "Pilates": "pilates", "Barre": "barre", "Dance": "dancing",
            "Martial arts": "martial arts", "Skiing": "skiing",
            "Snowboarding": "snowboarding", "Fitness gaming": "something ridiculous",

            // One instance of the thing, which is what you are inviting someone to.
            "Running": "a run", "Walking": "a walk", "Hiking": "a hike",
            // "a ride" alone would collide with horse riding, and a bike is the
            // more likely of the two to need saying.
            "Cycling": "a bike ride", "Horse riding": "a ride",
            "Swimming": "a swim", "Rowing": "a row", "Climbing": "a climb",
            "Skating": "a skate", "Surfing": "a surf", "Paddling": "a paddle",
            "Stretching": "a stretch",

            // No count noun of their own, so they borrow a session word.
            "Strength training": "a lift", "Functional strength": "a lift",
            "Core training": "a core session", "HIIT": "a HIIT class",
            "Elliptical": "a gym session", "Stairs": "a stair session",
            "Mind and body": "something calmer"
        ]
        // An unmapped sport keeps its own name rather than being flattened into
        // "a workout" — an unnamed sport is still a distinct sport, the same
        // reasoning `HealthKitDistiller.name(for:)` uses. Lowercased and bare,
        // which is the shape most sport nouns already take.
        return phrases[sport] ?? sport.lowercased()
    }
}
