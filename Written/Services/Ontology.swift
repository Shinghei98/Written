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
