import Foundation

/// The recognisable line of a song — the bit someone would hum back at you.
///
/// A local table rather than a lyrics API, for three reasons that all point the
/// same way: there is no key to put in this app (see `AppConfig` — no client
/// secret belongs here), lyrics providers licence redistribution per-provider,
/// and a caption on the profile screen is not worth a network round trip that
/// can fail in front of an audience.
///
/// What is stored is a **hook**, not a lyric: one short phrase, the hummable
/// one. Extending this is meant to be easy — add a line, keyed by
/// `normalized(artist) + "|" + normalized(title)`.
enum SongHooks {

    /// The hook for a song, or `nil` when we don't know it — which is the
    /// common case for a real library and is handled by the caller, not papered
    /// over here.
    static func hook(artist: String, title: String) -> String? {
        table[key(artist: artist, title: title)]
    }

    static func key(artist: String, title: String) -> String {
        "\(normalized(artist))|\(normalized(title))"
    }

    /// Titles as they arrive are not titles as anyone says them: the API hands
    /// back "Baby (feat. Ludacris)", Apple hands back "Baby - Remastered 2019",
    /// and neither matches a table keyed on "baby". This strips the furniture
    /// so real records hit the table at all.
    ///
    /// Diacritics fold too, so "Beyoncé" and "Beyonce" are one key — and the
    /// CJK titles this app is full of pass through untouched, which is the
    /// point of folding rather than stripping to ASCII.
    static func normalized(_ text: String) -> String {
        var value = text.lowercased()

        // Everything after a dash-delimited suffix: "- Remastered", "- Live".
        if let dash = value.range(of: " - ") {
            value = String(value[value.startIndex..<dash.lowerBound])
        }
        // Bracketed suffixes: "(feat. X)", "[Official Video]".
        for opener in ["(", "[", " feat.", " ft.", " with "] {
            if let mark = value.range(of: opener) {
                value = String(value[value.startIndex..<mark.lowerBound])
            }
        }

        // Traditional folds to simplified so 周杰倫 and 周杰伦 are one key. Both
        // spellings are in the wild for the same artist — a library says one,
        // lyrics databases say the other — and without this they are two
        // different people to every lookup in the app.
        value = value.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? value

        return value
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when two artist names are plausibly the same artist.
    ///
    /// Containment either way, because the sources disagree about how much to
    /// say: a library writes "周杰倫 Jay Chou" where a lyrics database writes
    /// "周杰伦". After normalization one contains the other, which is as much
    /// agreement as is available and more than exact equality would allow.
    static func artistsMatch(_ left: String, _ right: String) -> Bool {
        let a = normalized(left), b = normalized(right)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    /// `entries` run through `normalized` once, so the literal below can be
    /// written the way the songs are actually spelled and still match a lookup.
    ///
    /// This is load-bearing rather than tidy: `normalized` folds traditional
    /// Chinese to simplified, so a key typed as 青花瓷 by 周杰倫 would otherwise
    /// never be found by a lookup that had already been folded to 周杰伦.
    private static let table: [String: String] = entries.reduce(into: [:]) { table, entry in
        let halves = entry.key.split(separator: "|", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return }
        table[key(artist: halves[0], title: halves[1])] = entry.value
    }

    /// Keyed `artist|title`, as written rather than as normalized.
    ///
    /// Chosen to cover the ranges the app's own fixtures and its likely first
    /// users sit in — Mandopop, K-pop, Western pop — rather than to be
    /// exhaustive, which it can never be. A miss is not a bug.
    private static let entries: [String: String] = [
        // Western pop
        "justin bieber|baby": "Baby, baby, baby oh~",
        "justin bieber|sorry": "Is it too late now to say sorry?",
        "taylor swift|shake it off": "Shake it off, shake it off",
        "taylor swift|blank space": "Got a long list of ex-lovers",
        "taylor swift|cruel summer": "It's a cruel summer",
        "adele|hello": "Hello from the other side",
        "adele|rolling in the deep": "We could have had it all",
        "ed sheeran|shape of you": "I'm in love with the shape of you",
        "ed sheeran|perfect": "Darling, just hold my hand",
        "the weeknd|blinding lights": "I said, ooh, I'm blinded by the lights",
        "the weeknd|save your tears": "Save your tears for another day",
        "dua lipa|levitating": "I got you, moonlight, you're my starlight",
        "harry styles|as it was": "You know it's not the same as it was",
        "billie eilish|bad guy": "So you're a tough guy",
        "olivia rodrigo|good 4 u": "Good for you, I guess you moved on really easily",
        "sabrina carpenter|espresso": "That's that me espresso",
        "miley cyrus|flowers": "I can buy myself flowers",
        "queen|bohemian rhapsody": "Is this the real life? Is this just fantasy?",
        "a-ha|take on me": "Take on me, take me on",
        "journey|don't stop believin'": "Don't stop believin'",
        "abba|dancing queen": "You are the dancing queen",
        "coldplay|yellow": "Look at the stars, look how they shine for you",
        "coldplay|viva la vida": "I used to rule the world",
        "oasis|wonderwall": "You're gonna be the one that saves me",
        "bruno mars|just the way you are": "You're amazing just the way you are",
        "mark ronson|uptown funk": "Uptown funk you up",
        "rick astley|never gonna give you up": "Never gonna give you up",

        // K-pop
        "bts|dynamite": "'Cause I, I, I'm in the stars tonight",
        "bts|butter": "Smooth like butter",
        "blackpink|ddu-du ddu-du": "Ddu-du ddu-du du",
        "blackpink|how you like that": "How you like that?",
        "newjeans|super shy": "Super shy, super shy",
        "newjeans|ditto": "Oh, ditto",
        "newjeans|hype boy": "You're my hype boy",
        "le sserafim|perfect night": "It's a perfect night",
        "le sserafim|antifragile": "Antifragile, tikitaka",
        "ive|love dive": "Narcissistic, my god, I love it",
        "aespa|next level": "I'm on the next level",
        "twice|what is love?": "What is love?",
        "psy|gangnam style": "Oppan Gangnam style",
        "babymonster|sheesh": "Sheesh, sheesh",
        "(g)i-dle|queencard": "I'm a queencard",

        // Mandopop / C-pop
        "jay chou|qing hua ci": "天青色等烟雨，而我在等你",
        "周杰倫 jay chou|qing hua ci": "天青色等烟雨，而我在等你",
        "jay chou|青花瓷": "天青色等烟雨，而我在等你",
        "周杰倫 jay chou|青花瓷": "天青色等烟雨，而我在等你",
        "jay chou|夜曲": "为你弹奏萧邦的夜曲",
        "周杰倫 jay chou|夜曲": "为你弹奏萧邦的夜曲",
        "jay chou|告白氣球": "亲爱的，爱上你",
        "周杰倫 jay chou|告白氣球": "亲爱的，爱上你",
        "jay chou|七里香": "雨下整夜，我的爱溢出就像雨水",
        "周杰倫 jay chou|七里香": "雨下整夜，我的爱溢出就像雨水",
        "jay chou|稻香": "还记得你说家是唯一的城堡",
        "周杰倫 jay chou|稻香": "还记得你说家是唯一的城堡",
        "david tao|愛很簡單": "爱很简单",
        "leehom wang|唯一": "你是我的唯一",
        "jj lin|江南": "圈圈圆圆圈圈",
        "eason chan|十年": "十年之前，我不认识你",
        "mayday|突然好想你": "突然好想你",
        "joker xue|演员": "简单点，说话的方式简单点",
        "teresa teng|月亮代表我的心": "月亮代表我的心",

        // J-pop
        "yoasobi|idol": "無敵の笑顔で荒らすメディア",
        "kenshi yonezu|lemon": "夢ならばどれほどよかったでしょう",
        "official hige dandism|pretender": "グッバイ",
        "radwimps|前前前世": "君の前前前世から僕は"
    ]
}
