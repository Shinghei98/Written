import Foundation

/// Finds the hook of a song — the line someone would hum back at you — by
/// fetching its lyrics and working out which line is the chorus.
///
/// **A chorus is the line that repeats.** That is not a heuristic standing in
/// for something better; it is what the word means, and it is why this can be
/// computed rather than curated. Checked against the hand-written entries in
/// `SongHooks`: for 青花瓷 the algorithm returns 天青色等煙雨 而我在等妳, which is
/// exactly what a person typed into that table independently.
///
/// ## Why LRCLIB
///
/// It needs **no API key**, which is the whole reason a network lyrics lookup is
/// possible in this app at all — `AppConfig`'s rule is that no client secret
/// belongs here, and every commercial lyrics provider would have broken it.
/// Coverage was checked against a real distillation before this was written:
/// four of five top tracks resolved, including Mandopop and K-pop, which are the
/// catalogues a curated English table is worst at.
///
/// ## What leaves the device
///
/// One artist and one track title per top song, and nothing else — no user id,
/// no library, no listening history. Worth stating plainly because it is the
/// first thing in this app that sends any distilled value anywhere; see the note
/// in `CLAUDE.md` about data staying on-device.
actor LyricsService {

    static let shared = LyricsService()

    private let exactEndpoint = URL(string: "https://lrclib.net/api/get")!
    private let searchEndpoint = URL(string: "https://lrclib.net/api/search")!

    /// A caption is not worth making a screen wait. On a slow network this gives
    /// up and the bundled table answers instead.
    private static let timeout: TimeInterval = 6

    /// Both the hooks we found and the songs we know have none, so a 404 is
    /// asked once rather than on every appearance of the screen. `nil` value
    /// means "looked, found nothing".
    private var cache: [String: String?]

    /// In `.cachesDirectory`: it is derived from a third party and re-fetchable,
    /// so it should be evictable and must not be backed up. Deliberately not
    /// anywhere `CSVExporter` can see — these are not distilled records and have
    /// no business in an export.
    private static let cacheURL: URL? = {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("song-hooks.json")
    }()

    init() {
        cache = Self.loadCache()
    }

    /// The song's hook, or `nil` when there isn't one to be had.
    ///
    /// Never throws: every failure — offline, 404, a song whose lyrics simply
    /// don't repeat — is the same answer to the caller, which is "use the line
    /// that doesn't quote anything".
    func hook(artist: String, title: String) async -> String? {
        let key = "\(SongHooks.normalized(artist))|\(SongHooks.normalized(title))"
        if let cached = cache[key] { return cached }

        let found = await fetchHook(artist: artist, title: title)
        cache[key] = found
        saveCache()
        return found
    }

    // MARK: - Fetching

    /// How many candidate lyric bodies to try per provider. Both sources return
    /// several entries for the same song, of wildly differing quality.
    private static let candidatesTried = 8

    /// Each source in turn, and within a source each candidate, until one yields
    /// a hook.
    ///
    /// Trying *candidates* rather than taking the first match is load-bearing
    /// and was learned the hard way: LRCLIB's top hit for 青花瓷 is a
    /// 6,000-character blob with no repeating line, where a later one is a clean
    /// transcript that yields 天青色等煙雨 而我在等妳.
    private func fetchHook(artist: String, title: String) async -> String? {
        for provider in providers {
            for lyrics in await provider.lyrics(artist: artist, title: title).prefix(Self.candidatesTried) {
                if let hook = Self.chorus(in: lyrics, title: title) { return hook }
            }
        }
        return nil
    }

    /// LRCLIB first: it is a purpose-built lyrics API with a documented, stable
    /// contract. NetEase second: it covers the Chinese catalogue LRCLIB simply
    /// does not have — 今夜睡大街 by 潮池蓝 returns nothing at LRCLIB under any
    /// spelling of either — but its API is undocumented and could change without
    /// notice, so nothing depends on it that LRCLIB can answer first.
    private var providers: [LyricsProvider] {
        [LRCLIBProvider(timeout: Self.timeout), NetEaseProvider(timeout: Self.timeout)]
    }

    // MARK: - Finding the chorus

    /// Shortest and longest a hook may be, in characters.
    ///
    /// Both bounds earn their place: below the floor you get a one-word refrain
    /// ("oh", "yeah") that names no song, and above the ceiling you get a whole
    /// verse, which is not what anybody hums and does not fit a caption.
    private static let hookLength = 4...42

    /// How many times a line must appear to count as the chorus. Two is enough —
    /// a line said twice in a song was said on purpose.
    private static let minimumRepeats = 2

    /// The most repeated line; ties broken by how much of the title it echoes,
    /// then by whichever came first.
    ///
    /// The middle term is what separates a line of the song from *the* line.
    /// 今夜睡大街 has three lines repeated six times each — 这 无情的人间,
    /// 不过是 一无所有 失去一切, and 睡在冰冷的大街 — and only the last is the hook.
    /// What marks it is that it echoes the title, which is what hooks do. On
    /// first appearance alone the wrong one wins by two lines.
    ///
    /// Character overlap rather than substring, because a CJK title and its hook
    /// share characters without either containing the other: 今夜睡大街 ∩
    /// 睡在冰冷的大街 = 睡, 大, 街.
    ///
    /// The final term keeps it deterministic. Without it the same song could
    /// caption differently between launches, and a bio that changes on its own
    /// reads as a bug.
    static func chorus(in lyrics: String, title: String) -> String? {
        var counts: [String: Int] = [:]
        var order: [String: Int] = [:]
        let titleCharacters = Set(SongHooks.normalized(title))

        for (index, raw) in lyrics.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = Self.cleaned(String(raw))
            guard hookLength.contains(line.count) else { continue }
            // Section markers — "[Chorus]", "(x2)" — describe the song rather
            // than being part of it, and repeat exactly like a hook would.
            guard !line.hasPrefix("["), !line.hasPrefix("(") else { continue }
            // Credits — "作词：…", "Produced by: …" — are lines like any other to
            // a tally, and on a short song they can out-repeat the chorus.
            guard !line.contains("："), !line.contains(": ") else { continue }

            counts[line, default: 0] += 1
            if order[line] == nil { order[line] = index }
        }

        func rank(_ line: String) -> (Int, Int, Int) {
            (counts[line] ?? 0, titleCharacters.intersection(line).count, -(order[line] ?? 0))
        }

        return counts.keys
            .filter { (counts[$0] ?? 0) >= minimumRepeats }
            .max { rank($0) < rank($1) }
    }

    /// One lyric line, stripped of the furniture the sources wrap it in.
    ///
    /// NetEase returns LRC, where a line may carry several leading timestamps —
    /// `[00:12.34][01:40.10]同一句` — because a repeated line is stored once with
    /// every time it occurs. Leaving them on would make each occurrence a
    /// distinct string and the repeat count would collapse to one, which is
    /// precisely the tally this whole thing rests on.
    private static func cleaned(_ raw: String) -> String {
        var line = raw
        while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            line = String(line[line.index(after: close)...])
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Cache on disk

    private static func loadCache() -> [String: String?] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }

        // An empty string on disk is how "looked, found nothing" is stored —
        // JSON can hold a `[String: String]` far more simply than an optional.
        return stored.mapValues { $0.isEmpty ? nil : $0 }
    }

    private func saveCache() {
        guard let url = Self.cacheURL else { return }
        let storable = cache.mapValues { $0 ?? "" }
        guard let data = try? JSONEncoder().encode(storable) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
