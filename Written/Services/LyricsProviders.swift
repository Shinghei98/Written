import Foundation

/// One place lyrics can be got from.
///
/// Returns *candidates* rather than one body, because every source carries
/// several entries for the same song and their quality varies wildly — see
/// `LyricsService.fetchHook`, which tries them in turn until one yields a hook.
/// An empty array is the only failure mode; nothing here throws.
protocol LyricsProvider {
    func lyrics(artist: String, title: String) async -> [String]
}

// MARK: - LRCLIB

/// The default source: purpose-built for lyrics, keyless, and with a documented
/// contract. Strong on Western and Korean catalogue.
struct LRCLIBProvider: LyricsProvider {
    let timeout: TimeInterval

    private static let exact = URL(string: "https://lrclib.net/api/get")!
    private static let search = URL(string: "https://lrclib.net/api/search")!

    private struct Track: Decodable {
        let artistName: String?
        let plainLyrics: String?
    }

    func lyrics(artist: String, title: String) async -> [String] {
        var found: [String] = []

        // The exact endpoint is the best answer when it works, but it wants the
        // artist spelled its way and a library spells them its own: "周杰倫 Jay Chou"
        // 404s where "周杰倫" succeeds, for the same song.
        var exact = URLComponents(url: Self.exact, resolvingAgainstBaseURL: false)
        exact?.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if let track: Track = await HTTP.json(exact?.url, timeout: timeout),
           let lyrics = track.plainLyrics {
            found.append(lyrics)
        }

        // So a title search backs it up, filtered by artist — a search for 凝眸
        // returns 張遠's song before 丁禹兮's, and quoting the wrong singer's
        // chorus is worse than quoting nothing.
        var search = URLComponents(url: Self.search, resolvingAgainstBaseURL: false)
        search?.queryItems = [URLQueryItem(name: "q", value: title)]
        let results: [Track] = await HTTP.json(search?.url, timeout: timeout) ?? []
        found += results
            .filter { SongHooks.artistsMatch($0.artistName ?? "", artist) }
            .compactMap(\.plainLyrics)

        return found
    }
}

// MARK: - NetEase Cloud Music

/// The Chinese catalogue, which LRCLIB does not have.
///
/// This is not a marginal gain: 今夜睡大街 by 潮池蓝 returns **zero** LRCLIB results
/// under every spelling of the song and the artist, romanized or not, while
/// NetEase has it along with that artist's whole discography. For a library that
/// is mostly Mandopop and C-pop, LRCLIB alone misses exactly the songs that
/// matter most.
///
/// The API is undocumented and unofficial, and it could change or start refusing
/// requests without notice. That is why it is second and why every failure here
/// is an empty array: a breakage degrades to the previous behaviour — the
/// bundled table, then naming the song — rather than to an error on screen.
struct NetEaseProvider: LyricsProvider {
    let timeout: TimeInterval

    private static let search = URL(string: "https://music.163.com/api/search/get")!
    private static let lyric = "https://music.163.com/api/song/lyric"

    /// Sent on every request. Without it the endpoints reject the call.
    private static let referer = "https://music.163.com"

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { let name: String? }
                let id: Int
                let artists: [Artist]?
            }
            let songs: [Song]?
        }
        let result: Result?
    }

    private struct LyricResponse: Decodable {
        struct Lyric: Decodable { let lyric: String? }
        let lrc: Lyric?
    }

    func lyrics(artist: String, title: String) async -> [String] {
        // Form-encoded POST, not the `…/get/web` GET variant — that one answers
        // with an encrypted blob, while this returns plain JSON.
        var request = URLRequest(url: Self.search, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "s", value: title),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        guard let response: SearchResponse = await HTTP.json(request),
              let songs = response.result?.songs
        else { return [] }

        var found: [String] = []
        for song in songs {
            let credited = (song.artists ?? []).compactMap(\.name).joined(separator: " ")
            guard SongHooks.artistsMatch(credited, artist) else { continue }
            if let lyrics = await lyric(for: song.id) { found.append(lyrics) }
        }
        return found
    }

    /// `lv=1&kv=1&tv=-1` asks for the original lyric and skips the translation
    /// and karaoke tracks, which would otherwise arrive as separate bodies of
    /// the same song and dilute the tally.
    private func lyric(for id: Int) async -> String? {
        guard let url = URL(string: "\(Self.lyric)?id=\(id)&lv=1&kv=1&tv=-1") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")

        let response: LyricResponse? = await HTTP.json(request)
        return response?.lrc?.lyric
    }
}

// MARK: - Shared transport

/// One JSON GET/POST, with every failure flattened to `nil`.
///
/// A caption is not worth distinguishing a timeout from a 404 from a schema
/// change: the caller does the same thing in every case.
enum HTTP {
    static func json<T: Decodable>(_ url: URL?, timeout: TimeInterval) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Identifies the app and nothing about the user. LRCLIB asks for it.
        request.setValue("Written/0.1 (https://github.com/written)", forHTTPHeaderField: "User-Agent")
        return await json(request)
    }

    static func json<T: Decodable>(_ request: URLRequest) async -> T? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
